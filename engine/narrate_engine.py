"""Narrate engine — the Python half of the Mac app.

The Swift app launches this as a subprocess and talks JSON lines over stdin/stdout:

    → {"id": 1, "op": "extract", "path": "/x.pdf"}
    ← {"id": 1, "event": "progress", ...}          (zero or more, for long jobs)
    ← {"id": 1, "result": {...}}  |  {"id": 1, "error": "message"}

Ops: hello, warm_up, extract, sample, narrate, hq_unload, cancel, prioritize. Jobs run one at a time
on a worker thread so `cancel` / `prioritize` can be read while a narration is in flight.

`quality` ("standard" | "high") on `sample` / `narrate` picks Kokoro or Fish Audio S2 Pro.

`narrate` streams: it emits a `plan` event (the chunk list), then one `chunk` event per synthesized
chunk (a WAV file the app can play immediately) in whatever order the app asked for via
`prioritize`, and finally the assembled, encoded file as its result.
"""
from __future__ import annotations

import hashlib
import json
import os
import queue
import re
import sys
import threading
import traceback

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from narrate import fish, pdf_text, tts  # noqa: E402

# The protocol owns the real stdout. Everything else (our prints, onnxruntime / phonemizer
# chatter at the C level) is routed to stderr so it can never corrupt a JSON line.
_proto = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
os.dup2(2, 1)
sys.stdout = sys.stderr
_out_lock = threading.Lock()


def send(msg: dict) -> None:
    with _out_lock:
        _proto.write(json.dumps(msg, ensure_ascii=False) + "\n")
        _proto.flush()


class Engine:
    def __init__(self) -> None:
        self.tts = tts.Engine()
        self.fish = fish.FishEngine(self.tts)
        self.jobs: queue.Queue = queue.Queue()
        self.cancel = threading.Event()
        self.current_id: int | None = None
        self.cancelled: set = set()   # ids cancelled before their turn came
        self.priority = 0        # chunk index the listener wants next (see op_narrate)
        threading.Thread(target=self._worker, daemon=True).start()

    # -- job plumbing -------------------------------------------------------
    def _worker(self) -> None:
        while True:
            req = self.jobs.get()
            if req is None:               # stdin closed: finish up and exit
                self.jobs.task_done()
                return
            rid = req.get("id")
            if rid in self.cancelled:          # cancelled while still queued
                self.cancelled.discard(rid)
                send({"id": rid, "error": "cancelled", "cancelled": True})
                self.jobs.task_done()
                continue
            self.current_id = rid
            self.cancel.clear()
            try:
                result = getattr(self, "op_" + req["op"])(req)
                send({"id": rid, "result": result if result is not None else {}})
            except InterruptedError:
                send({"id": rid, "error": "cancelled", "cancelled": True})
            except Exception as e:  # noqa: BLE001
                traceback.print_exc()
                send({"id": rid, "error": str(e) or e.__class__.__name__})
            finally:
                self.current_id = None
                self.jobs.task_done()

    def progress(self, rid, **payload) -> None:
        send({"id": rid, "event": "progress", **payload})

    # -- ops ----------------------------------------------------------------
    def op_hello(self, req):
        # sample_key changes whenever the sample script does, so the app can drop stale cached previews.
        return {"version": 3, "ffmpeg": bool(tts.ffmpeg()), "model_ready": tts.model_ready(),
                "hq_ready": fish.model_ready(),
                "voices": [v.__dict__ for v in tts.VOICES],
                "sample_key": hashlib.sha1(tts.SAMPLE_TEXT.encode()).hexdigest()[:10]}

    def op_warm_up(self, req):
        self.tts.warm_up()
        return {"ready": True}

    def op_extract(self, req):
        rid = req["id"]
        doc = pdf_text.extract(req["path"], req.get("first"), req.get("last"),
                               progress=lambda label: self.progress(rid, label=label))
        return {"name": doc.name, "path": doc.path, "pages": doc.pages, "page_blocks": doc.page_blocks,
                "page_blocks_all": doc.page_blocks_all,
                "outline": [s.__dict__ for s in doc.outline], "outline_source": doc.outline_source}

    def backend(self, req, rid=None):
        if req.get("quality") != "high":
            return self.tts
        if not self.fish.loaded and rid is not None:
            self.progress(rid, label="Loading the high quality voice model…")
        self.fish.warm_up()
        return self.fish

    def op_sample(self, req):
        b = self.backend(req)
        audio = b.sample(req["voice"], float(req.get("speed", 1.0)))
        with open(req["out"], "wb") as f:
            f.write(tts.wav_bytes(audio, b.sample_rate))
        return {"path": req["out"]}

    def op_hq_unload(self, req):
        self.fish.unload()
        return {}

    def op_narrate(self, req):
        rid = req["id"]
        paragraphs = [re.sub(r"\s+", " ", p).strip() for p in req["paragraphs"]]
        paragraphs = [p for p in paragraphs if p]
        voice, speed = req["voice"], float(req.get("speed", 1.0))
        chunk_dir = req["chunk_dir"]
        os.makedirs(chunk_dir, exist_ok=True)

        high = req.get("quality") == "high"
        plan = self.tts.plan(paragraphs, fish.FishEngine.max_chunk if high else tts.MAX_CHUNK)
        send({"id": rid, "event": "plan",
              "chunks": [{k: v for k, v in c.items() if k != "text"} for c in plan]})
        # A voice switched mid-book starts where the listener is (`start_word`, in reading order —
        # chunking differs between qualities), not at the top.
        self.priority = 0
        word = int(req.get("start_word", 0))
        first_word = np.cumsum([0] + [len(p.split()) for p in paragraphs])
        for c in plan:
            if first_word[c["paragraph"]] + c["word_offset"] <= word:
                self.priority = c["index"]
        backend = self.backend(req, rid)
        sr = backend.sample_rate
        backend.should_stop = self.cancel.is_set
        batch = getattr(backend, "first_batch", 1)
        pending = set(range(len(plan)))
        done: dict[int, tuple] = {}
        while pending:
            if self.cancel.is_set():
                raise InterruptedError
            # Serve the chunk the listener skipped to (and onwards) first, then go back for the gaps.
            order = sorted(i for i in pending if i >= self.priority) + sorted(i for i in pending if i < self.priority)
            ks = order[:batch]
            batch = getattr(backend, "batch_size", 1)
            for k, (audio, words) in zip(ks, tts.synth_chunks(backend, plan, ks, voice, speed)):
                path = os.path.join(chunk_dir, f"chunk-{k:05d}.wav")
                with open(path, "wb") as f:
                    f.write(tts.wav_bytes(audio, sr))
                done[k] = (audio, words)
                pending.discard(k)
                send({"id": rid, "event": "chunk", "index": k, "path": path,
                      "duration": round(len(audio) / sr, 3),
                      "words": [[w.start, w.end] for w in words]})
                self.progress(rid, done=len(done), total=len(plan))

        self.progress(rid, label="Encoding…")
        pieces, out_words = [], [[] for _ in paragraphs]
        offset = 0.0
        for k, c in enumerate(plan):
            audio, words = done[k]
            pieces.append(audio)
            out_words[c["paragraph"]] += [[w.text, round(offset + w.start, 3), round(offset + w.end, 3)] for w in words]
            offset += len(audio) / sr
        full = np.concatenate(pieces) if pieces else np.zeros(sr // 2, np.float32)
        out = tts.encode(full, req["out_base"], req.get("fmt", "mp3"), sr)
        return {"path": out, "duration": round(len(full) / sr, 2), "paragraphs": out_words}

    # -- stdin loop ---------------------------------------------------------
    def serve(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError:
                continue
            op = req.get("op")
            if op == "cancel":
                target = req.get("target")
                if self.current_id is not None and target in (None, self.current_id):
                    self.cancel.set()
                elif target is not None:
                    self.cancelled.add(target)
                send({"id": req.get("id"), "result": {}})
            elif op == "prioritize":
                self.priority = int(req.get("chunk", 0))
                send({"id": req.get("id"), "result": {}})
            elif op == "hello":
                # Answer immediately (not queued) so the app can show state before the model loads.
                send({"id": req.get("id"), "result": self.op_hello(req)})
            elif hasattr(self, "op_" + str(op)):
                self.jobs.put(req)
            else:
                send({"id": req.get("id"), "error": f"unknown op {op!r}"})
        # stdin closed: the app quit (or died). Don't finish a job nobody will receive — a high
        # quality book would keep ~7 GB and the GPU busy for hours.
        self.cancel.set()
        while not self.jobs.empty():
            try:
                self.jobs.get_nowait(); self.jobs.task_done()
            except queue.Empty:
                break
        self.jobs.put(None)
        self.jobs.join()


if __name__ == "__main__":
    Engine().serve()
