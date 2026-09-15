"""Narrate — drop a PDF (or paste text, or open a link), pick a voice, get a read-along audiobook.
Everything runs on-device: Kokoro-82M for speech, macOS Vision for OCR."""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import threading
import time
import traceback
from dataclasses import asdict

import webview

from narrate import capture, pdf_text, tts
from narrate.media import MediaServer

ROOT = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(ROOT, "ui", "index.html")
STORAGE = os.path.expanduser("~/Library/Application Support/Narrate")
HOME_SIZE = (470, 740)
READER_SIZE = (1080, 760)
SAFARI_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) "
             "Version/17.5 Safari/605.1.15")


class Api:
    def __init__(self) -> None:
        self.window: webview.Window | None = None
        self.browser: webview.Window | None = None
        self.engine = tts.Engine()
        self.media = MediaServer()
        self.doc: pdf_text.Document | None = None
        self.cancel = threading.Event()
        self.busy = False
        self._samples: dict[tuple[str, float], str] = {}

    # -- plumbing ---------------------------------------------------------
    def _emit(self, event: str, payload=None) -> None:
        if self.window:
            self.window.evaluate_js(f"narrate.on({json.dumps(event)}, {json.dumps(payload)})")

    def _set_doc(self, doc: pdf_text.Document, method: str | None = None) -> None:
        if not doc.paragraphs:
            self._emit("error", "No readable text found." + (" This PDF looks like scanned images." if doc.path else ""))
            return
        self.doc = doc
        self._emit("document", {
            "name": doc.name, "path": doc.path, "pages": doc.pages, "words": doc.words,
            "paragraphs": len(doc.paragraphs), "preview": doc.text[:600], "method": method,
        })

    def _open_pdf(self, path: str):
        try:
            self._set_doc(pdf_text.extract(path))
        except Exception as e:
            self._emit("error", f"Couldn't read that PDF: {e}")

    def _open_sidecar(self, path: str):
        """Re-open a previous narration from its .narrate.json next to the audio file."""
        try:
            with open(path) as f:
                r = json.load(f)
            if not os.path.isfile(r["path"]):
                raise FileNotFoundError(r["path"])
            r["url"] = self.media.url_for(r["path"])
            r["size"] = os.path.getsize(r["path"])
            self._emit("done", r)
        except Exception as e:
            self._emit("error", f"Couldn't reopen narration: {e}")

    def on_drop(self, event) -> None:
        for f in event.get("dataTransfer", {}).get("files", []):
            path = f.get("pywebviewFullPath")
            if not path:
                continue
            low = path.lower()
            if low.endswith(".pdf"):
                return self._open_pdf(path)
            if low.endswith(".narrate.json"):
                return self._open_sidecar(path)
            sidecar = os.path.splitext(path)[0] + ".narrate.json"
            if low.endswith((".mp3", ".m4a", ".wav")) and os.path.isfile(sidecar):
                return self._open_sidecar(sidecar)
        self._emit("error", "Drop a PDF (or an audiobook Narrate made earlier).")

    # -- exposed to JS ------------------------------------------------------
    def get_state(self):
        return {
            "model_ready": tts.model_ready(),
            "voices": [asdict(v) for v in tts.VOICES],
            "formats": ["mp3", "m4a", "wav"] if tts.ffmpeg() else ["mp3", "wav"],
        }

    def ensure_model(self):
        def run():
            try:
                if not tts.model_ready():
                    last = [0.0]

                    def prog(label, frac):
                        if frac - last[0] >= 0.005 or frac >= 1:
                            last[0] = frac
                            self._emit("model_progress", {"label": label, "frac": frac})
                    tts.download_model(prog)
                self._emit("model_progress", {"label": "Loading voice model…", "frac": 1})
                self.engine.warm_up()
                self._emit("model_ready")
            except Exception as e:
                self._emit("error", f"Model setup failed: {e}")
        threading.Thread(target=run, daemon=True).start()

    def browse(self):
        result = self.window.create_file_dialog(webview.FileDialog.OPEN, file_types=("PDF documents (*.pdf)",))
        if result:
            self._open_pdf(result[0])

    def load_text(self, text: str):
        paras = [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n\s*\n", text)]
        paras = [p for p in paras if p]
        title = (paras[0][:60] + ("…" if len(paras[0]) > 60 else "")) if paras else "Pasted text"
        self._set_doc(pdf_text.Document(name=title, path="", pages=0, paragraphs=paras))

    def set_pages(self, first, last):
        if not self.doc or not self.doc.path:
            return
        try:
            doc = pdf_text.extract(self.doc.path, int(first) if first else None, int(last) if last else None)
        except Exception as e:
            self._emit("error", str(e)); return
        self.doc = doc
        return {"words": doc.words, "paragraphs": len(doc.paragraphs), "preview": doc.text[:600]}

    # -- built-in browser -------------------------------------------------
    def open_browser(self, url: str):
        if not re.match(r"^https?://", url):
            url = "https://" + url
        if self.browser is not None:
            try:
                self.browser.load_url(url)
                return
            except Exception:
                self.browser = None
        w = webview.create_window("Narrate Browser — get the article on screen, then Capture", url,
                                  width=1100, height=820, text_select=True)
        self.browser = w

        def closed():
            self.browser = None
            self._emit("browser_open", False)
        w.events.closed += closed
        self._emit("browser_open", True)

    def capture_page(self):
        if self.browser is None:
            self._emit("error", "Open a link first."); return

        def run():
            try:
                title, paras, method = capture.capture(
                    self.browser, lambda label, frac: self._emit("capture_progress", {"label": label, "frac": frac}))
                self._set_doc(pdf_text.Document(name=title, path="", pages=0, paragraphs=paras), method)
                if not paras:
                    self._emit("error", "Couldn't find readable text on that page.")
            except Exception as e:
                traceback.print_exc()
                self._emit("error", f"Capture failed: {e}")
            finally:
                self._emit("capture_done")
        threading.Thread(target=run, daemon=True).start()

    # -- synthesis ----------------------------------------------------------
    def sample_voice(self, voice_id: str, speed: float):
        key = (voice_id, round(float(speed), 2))
        if key not in self._samples:
            audio = self.engine.sample(voice_id, float(speed))
            self._samples[key] = "data:audio/wav;base64," + base64.b64encode(tts.wav_bytes(audio)).decode()
        return self._samples[key]

    def generate(self, voice_id: str, speed: float, fmt: str):
        if not self.doc or self.busy:
            return
        doc = self.doc
        self.busy = True
        self.cancel.clear()

        def run():
            t0 = time.time()
            try:
                def prog(done, total, secs):
                    elapsed = time.time() - t0
                    eta = (elapsed / done) * (total - done) if done else None
                    self._emit("progress", {"done": done, "total": total, "seconds": secs, "eta": eta})
                audio, words = self.engine.narrate(doc.paragraphs, voice_id, float(speed), prog, self.cancel)
                self._emit("progress", {"label": "Encoding…"})
                folder = os.path.dirname(doc.path) if doc.path else os.path.expanduser("~/Downloads")
                stem = re.sub(r'[\\/:*?"<>|]+', " ", os.path.splitext(doc.name)[0]).strip()[:80] or "Narration"
                voice = tts.VOICE_BY_ID[voice_id]
                out = tts.encode(audio, os.path.join(folder, f"{stem} – {voice.name}"), fmt)
                result = {
                    "path": out, "name": os.path.basename(out), "title": os.path.splitext(doc.name)[0] if doc.path else doc.name,
                    "voice": voice.name,
                    "duration": round(len(audio) / tts.SAMPLE_RATE, 2),
                    "paragraphs": [[[w.text, w.start, w.end] for w in p] for p in words],
                }
                with open(os.path.splitext(out)[0] + ".narrate.json", "w") as f:
                    json.dump(result, f)
                result.update(url=self.media.url_for(out), size=os.path.getsize(out), took=time.time() - t0)
                self._emit("done", result)
            except InterruptedError:
                self._emit("cancelled")
            except Exception as e:
                traceback.print_exc()
                self._emit("error", f"Generation failed: {e}")
            finally:
                self.busy = False
        threading.Thread(target=run, daemon=True).start()

    def cancel_generate(self):
        self.cancel.set()

    # -- window & finder -----------------------------------------------------
    def _resize_centered(self, w: int, h: int):
        win = self.window
        cx, cy = win.x + win.width // 2, win.y + win.height // 2
        scr = webview.screens[0]
        x = max(0, min(cx - w // 2, scr.width - w))
        y = max(0, min(cy - h // 2, scr.height - h - 30))
        win.resize(w, h)
        win.move(x, y)

    def resize_for_reader(self):
        if self.window.width < READER_SIZE[0]:
            self._resize_centered(*READER_SIZE)

    def resize_for_home(self):
        self._resize_centered(*HOME_SIZE)

    def reveal(self, path: str):
        subprocess.Popen(["open", "-R", path])


def main() -> None:
    os.makedirs(STORAGE, exist_ok=True)
    api = Api()
    window = webview.create_window(
        "Narrate", UI, js_api=api, width=HOME_SIZE[0], height=HOME_SIZE[1], min_size=(440, 620),
        background_color="#0e0f13", text_select=False,
    )
    api.window = window

    def on_loaded():
        window.dom.get_element("#home").events.drop += api.on_drop

    window.events.loaded += on_loaded
    # private_mode=False keeps logins (JSTOR, university proxies) across runs in the built-in browser.
    webview.start(private_mode=False, storage_path=STORAGE, user_agent=SAFARI_UA)


if __name__ == "__main__":
    main()
