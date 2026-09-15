"""Kokoro-82M text-to-speech engine: model management, chunking, synthesis, encoding."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import urllib.request
from dataclasses import dataclass
from typing import Callable

import numpy as np
import soundfile as sf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The app sets NARRATE_MODEL_DIR (~/Library/Application Support/Narrate/models); fall back to ./models for dev runs.
MODEL_DIR = os.environ.get("NARRATE_MODEL_DIR") or os.path.join(ROOT, "models")
MODEL_BASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/"  # v1.1 files expose phoneme durations
MODEL_FILES = {"kokoro-v1.0.onnx": 325_505_369, "voices-v1.0.bin": 28_214_398}
SAMPLE_RATE = 24_000


@dataclass
class Word:
    text: str
    start: float
    end: float


@dataclass(frozen=True)
class Voice:
    id: str
    name: str
    accent: str      # "US" | "UK"
    gender: str      # "F" | "M"
    grade: str       # Kokoro's published quality grade
    note: str

    @property
    def lang(self) -> str:
        return "en-gb" if self.accent == "UK" else "en-us"


# Curated English voices, ordered by Kokoro's published quality grades.
VOICES: list[Voice] = [
    Voice("af_heart",    "Heart",    "US", "F", "A",  "Warm, natural, the flagship voice"),
    Voice("af_bella",    "Bella",    "US", "F", "A-", "Bright and expressive"),
    Voice("af_nicole",   "Nicole",   "US", "F", "B-", "Soft, intimate, ASMR-like"),
    Voice("bf_emma",     "Emma",     "UK", "F", "B-", "Calm British narrator"),
    Voice("af_aoede",    "Aoede",    "US", "F", "C+", "Clear and even"),
    Voice("af_kore",     "Kore",     "US", "F", "C+", "Crisp, slightly formal"),
    Voice("af_sarah",    "Sarah",    "US", "F", "C+", "Friendly and light"),
    Voice("am_fenrir",   "Fenrir",   "US", "M", "C+", "Deep, steady"),
    Voice("am_michael",  "Michael",  "US", "M", "C+", "Neutral newsreader"),
    Voice("am_puck",     "Puck",     "US", "M", "C+", "Youthful, energetic"),
    Voice("bf_isabella", "Isabella", "UK", "F", "C",  "Measured British"),
    Voice("bm_george",   "George",   "UK", "M", "C",  "Classic British narrator"),
    Voice("bm_fable",    "Fable",    "UK", "M", "C",  "Storyteller tone"),
    Voice("am_echo",     "Echo",     "US", "M", "D",  "Relaxed baritone"),
    Voice("bm_lewis",    "Lewis",    "UK", "M", "D+", "Gruff, characterful"),
    Voice("bm_daniel",   "Daniel",   "UK", "M", "D",  "Low and quiet"),
]
VOICE_BY_ID = {v.id: v for v in VOICES}

SAMPLE_TEXT = ("Hi, I'm {name}. I can read your documents aloud, "
               "from a single page to an entire book, right here on your Mac.")


# ------------------------------------------------------------------ model files

def model_ready() -> bool:
    return all(os.path.isfile(os.path.join(MODEL_DIR, f)) and
               os.path.getsize(os.path.join(MODEL_DIR, f)) == size
               for f, size in MODEL_FILES.items())


def download_model(progress: Callable[[str, float], None]) -> None:
    """Fetch model files (~340 MB) with a progress callback (label, 0..1)."""
    os.makedirs(MODEL_DIR, exist_ok=True)
    total = sum(MODEL_FILES.values())
    done = 0
    for fname, size in MODEL_FILES.items():
        dest = os.path.join(MODEL_DIR, fname)
        if os.path.isfile(dest) and os.path.getsize(dest) == size:
            done += size
            continue
        tmp = dest + ".part"
        req = urllib.request.Request(MODEL_BASE + fname, headers={"User-Agent": "narrate/1.0"})
        with urllib.request.urlopen(req) as r, open(tmp, "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
                done += len(chunk)
                progress(f"Downloading {fname}", done / total)
        os.replace(tmp, dest)
    progress("Ready", 1.0)


# ------------------------------------------------------------------ chunking

_SENT = re.compile(r"(?<=[.!?…])\s+(?=[\"'(\[]?[A-Z0-9])|(?<=[.!?…][\"')\]])\s+")
MAX_CHUNK = 320  # chars; keeps prosody steady and well under Kokoro's context limit


_ABBR = re.compile(r"\b(Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|Mt|vs|etc|e\.g|i\.e|Fig|No|Vol|pp|approx)\.$", re.I)


def split_sentences(paragraph: str) -> list[str]:
    out: list[str] = []
    for s in (x.strip() for x in _SENT.split(paragraph)):
        if not s:
            continue
        if out and _ABBR.search(out[-1]):           # "Dr." + "Smith ..." was a false split
            out[-1] = out[-1] + " " + s
        else:
            out.append(s)
    return out


def chunk_paragraph(paragraph: str) -> list[str]:
    sentences = split_sentences(paragraph)
    chunks: list[str] = []
    cur = ""
    for s in sentences:
        if len(s) > MAX_CHUNK:                      # runaway sentence: split on clauses
            parts = re.split(r"(?<=[,;:])\s+", s)
            for p in parts:
                if cur and len(cur) + len(p) + 1 > MAX_CHUNK:
                    chunks.append(cur); cur = ""
                cur = (cur + " " + p).strip()
            continue
        if cur and len(cur) + len(s) + 1 > MAX_CHUNK:
            chunks.append(cur); cur = ""
        cur = (cur + " " + s).strip()
    if cur:
        chunks.append(cur)
    return chunks


# ------------------------------------------------------------------ engine

def _espeak_config():
    """espeak-ng keeps its data path in a 160-byte buffer. Inside an app bundle in a deep folder the
    path overflows, espeak silently falls back to a nonexistent built-in path and exits the process.
    When that would happen, keep a copy of the (19 MB) data next to the models, at a short path.
    (phonemizer resolves symlinks, so it has to be a real directory.)"""
    import shutil
    import espeakng_loader
    from kokoro_onnx.config import EspeakConfig
    real = espeakng_loader.get_data_path()
    if len(real) < 140:
        return None
    short = os.path.join(os.path.dirname(MODEL_DIR), "espeak-ng-data")
    marker = os.path.join(short, "phontab")
    if not os.path.isfile(marker) or os.path.getsize(marker) != os.path.getsize(os.path.join(real, "phontab")):
        shutil.rmtree(short, ignore_errors=True)
        shutil.copytree(real, short)
    return EspeakConfig(lib_path=espeakng_loader.get_library_path(), data_path=short)


class Engine:
    def __init__(self) -> None:
        self._kokoro = None
        self._lock = threading.Lock()

    def _get(self):
        with self._lock:
            if self._kokoro is None:
                import onnxruntime as ort
                from kokoro_onnx import Kokoro
                so = ort.SessionOptions()
                so.intra_op_num_threads = max(1, (os.cpu_count() or 4) - 1)
                sess = ort.InferenceSession(os.path.join(MODEL_DIR, "kokoro-v1.0.onnx"), so,
                                            providers=["CPUExecutionProvider"])
                self._kokoro = Kokoro.from_session(sess, os.path.join(MODEL_DIR, "voices-v1.0.bin"),
                                                   espeak_config=_espeak_config())
            return self._kokoro

    def warm_up(self) -> None:
        self._get()

    def synth(self, text: str, voice_id: str, speed: float = 1.0) -> np.ndarray:
        v = VOICE_BY_ID[voice_id]
        audio, _ = self._get().create(text, voice=v.id, speed=speed, lang=v.lang)
        return audio.astype(np.float32)

    def synth_timed(self, text: str, voice_id: str, speed: float = 1.0) -> tuple[np.ndarray, list[Word]]:
        """Audio plus one (word, start, end) per whitespace-separated word of `text`."""
        v = VOICE_BY_ID[voice_id]
        audio, _, timings = self._get().create_timed(text, voice=v.id, speed=speed, lang=v.lang)
        audio = audio.astype(np.float32)
        words = text.split()
        # Group phoneme timings into spoken words (separated by space phonemes).
        spoken: list[tuple[float, float]] = []
        cur: list = []
        for t in timings:
            if t.phoneme == " ":
                if cur:
                    spoken.append((cur[0].start, cur[-1].end)); cur = []
            else:
                cur.append(t)
        if cur:
            spoken.append((cur[0].start, cur[-1].end))
        total = len(audio) / SAMPLE_RATE
        if not spoken:
            step = total / max(1, len(words))
            return audio, [Word(w, i * step, (i + 1) * step) for i, w in enumerate(words)]
        # Text words and spoken words usually line up 1:1. When they don't (numbers, symbols and
        # abbreviations expand to several spoken words) distribute spoken words by estimated weight.
        out: list[Word] = []
        n, m = len(words), len(spoken)
        if n == m:
            bounds = list(range(n + 1))
        else:
            weights = [max(1, sum(c.isdigit() for c in w) + (2 if any(c in "$%€£" for c in w) else 0)) for w in words]
            total_w = sum(weights)
            cum = 0.0
            bounds = [0]
            for wt in weights:
                cum += wt
                bounds.append(min(m, round(cum / total_w * m)))
        for i, w in enumerate(words):
            j, j_next = bounds[i], max(bounds[i], bounds[i + 1])
            j = min(j, m - 1)
            start = spoken[j][0]
            end = spoken[min(m, j_next) - 1][1] if j_next > j else spoken[j][1]
            out.append(Word(w, start, max(end, start + 0.05)))
        return audio, out

    def sample(self, voice_id: str, speed: float = 1.0) -> np.ndarray:
        return self.synth(SAMPLE_TEXT.format(name=VOICE_BY_ID[voice_id].name), voice_id, speed)

    # -- streaming narration ------------------------------------------------

    @staticmethod
    def plan(paragraphs: list[str]) -> list[dict]:
        """Split paragraphs into synthesis chunks. Chunks split on whitespace only, so the words of a
        paragraph's chunks, concatenated, are exactly `paragraph.split()` — the app relies on that
        to map chunk timings onto the text it already has."""
        out = []
        for pi, p in enumerate(paragraphs):
            offset = 0
            for text in chunk_paragraph(p):
                n = len(text.split())
                out.append({"index": len(out), "paragraph": pi, "word_offset": offset, "words": n, "text": text})
                offset += n
        return out

    def synth_chunk(self, plan: list[dict], k: int, voice_id: str, speed: float) -> tuple[np.ndarray, list[Word]]:
        """Audio for chunk k with its leading pause baked in (so concatenating chunks in order is the
        final narration), plus word timings relative to the chunk start."""
        c = plan[k]
        if k == 0:
            pause = 0.0
        else:
            pause = 0.55 if plan[k - 1]["paragraph"] != c["paragraph"] else 0.18
        audio, timed = self.synth_timed(c["text"], voice_id, speed)
        peak = float(np.abs(audio).max()) or 1.0
        audio = audio * min(1.0, 0.95 / peak)              # gentle peak normalisation, never clips
        if pause:
            audio = np.concatenate([np.zeros(int(SAMPLE_RATE * pause), np.float32), audio])
        words = [Word(w.text, round(pause + w.start, 3), round(pause + w.end, 3)) for w in timed]
        return audio, words


# ------------------------------------------------------------------ encoding

def ffmpeg() -> str | None:
    # GUI apps get a minimal PATH, so also look where Homebrew / MacPorts put it.
    found = shutil.which("ffmpeg")
    if found:
        return found
    for cand in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"):
        if os.access(cand, os.X_OK):
            return cand
    return None


def encode(audio: np.ndarray, path: str, fmt: str) -> str:
    """Write audio to `path` (extension chosen by fmt). Returns final path."""
    base = os.path.splitext(path)[0]
    if fmt == "wav":
        out = base + ".wav"
        sf.write(out, audio, SAMPLE_RATE, subtype="PCM_16")
    elif fmt == "m4a" and ffmpeg():
        out = base + ".m4a"
        subprocess.run([ffmpeg(), "-y", "-loglevel", "error", "-f", "f32le", "-ar", str(SAMPLE_RATE),
                        "-ac", "1", "-i", "pipe:0", "-c:a", "aac", "-b:a", "112k", "-movflags", "+faststart", out],
                       input=audio.tobytes(), check=True)
    else:
        out = base + ".mp3"
        if ffmpeg():
            subprocess.run([ffmpeg(), "-y", "-loglevel", "error", "-f", "f32le", "-ar", str(SAMPLE_RATE),
                            "-ac", "1", "-i", "pipe:0", "-c:a", "libmp3lame", "-q:a", "2", out],
                           input=audio.tobytes(), check=True)
        else:
            sf.write(out, audio, SAMPLE_RATE, format="MP3", bitrate_mode="VARIABLE", compression_level=0.25)
    return out


def wav_bytes(audio: np.ndarray) -> bytes:
    import io
    buf = io.BytesIO()
    sf.write(buf, audio, SAMPLE_RATE, format="WAV", subtype="PCM_16")
    return buf.getvalue()
