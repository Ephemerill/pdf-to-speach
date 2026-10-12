"""High quality voices: Fish Audio S2 Pro (5B, dual-autoregressive) running on Apple's MLX, int8.

S2 Pro has no stock voices — it clones whatever reference recording it's given. Each of Narrate's
voices therefore has a high quality twin: Kokoro reads a short reference passage in that voice (at
the chosen speed, which S2 picks up as the speaking pace), and S2 Pro speaks the book in that voice
with its own far more natural prosody. References are rendered once and cached on disk; their codec
encoding is cached in memory while the model is loaded.

S2 Pro gives no word timings, so the read-along's are estimated: words are laid out by syllable
weight over the voiced part of the audio, pinned at the pauses actually found in it. (Measured
against Kokoro's exact timings: ~0.12 s average error. Warping Kokoro's own timings onto the audio
was tried and did worse.)

The weights (~6.7 GB) are downloaded by the app into `<models>/fish-s2-pro` only when the user turns
high quality on. Fish Audio Research License: free for personal and non-commercial use.
"""
from __future__ import annotations

import gc
import os
import re
import threading
from dataclasses import dataclass

import numpy as np
import soundfile as sf

from . import tts

MODEL_DIR = os.path.join(tts.MODEL_DIR, "fish-s2-pro")
# The exact files (and sizes) the app downloads; the engine only checks they're all there.
MODEL_FILES = {
    "config.json": None, "tokenizer.json": None, "tokenizer_config.json": None,
    "special_tokens_map.json": None, "chat_template.jinja": None,
    "codec-mlx/config.json": None, "codec-mlx/model.safetensors": None, "model.safetensors": None,
}
REF_DIR = os.path.join(os.path.dirname(tts.MODEL_DIR), "fish-references")

# A calm, varied passage (~14 s): long enough for S2 Pro to catch the timbre and pace, short
# enough to keep every prompt cheap.
REFERENCE_TEXT = ("The library was quiet that morning. Sunlight fell across the long wooden tables, "
                  "and somewhere in the stacks a page turned. She opened the book to its first chapter "
                  "and began to read aloud, slowly, letting each sentence settle before the next one.")


def model_ready() -> bool:
    return all(os.path.isfile(os.path.join(MODEL_DIR, f)) for f in MODEL_FILES)


class FishEngine:
    sample_rate = 44_100

    def __init__(self, kokoro: tts.Engine) -> None:
        self._kokoro = kokoro
        self._runtime = None
        self._refs: dict[tuple[str, float], object] = {}
        self._lock = threading.Lock()

    @property
    def loaded(self) -> bool:
        return self._runtime is not None

    def _get(self):
        with self._lock:
            if self._runtime is None:
                if not model_ready():
                    raise RuntimeError("The high quality voice model isn't downloaded yet.")
                from mlx_speech.generation.fish_s2_pro import FishS2ProRuntime
                import mlx.core as mx
                self._runtime = FishS2ProRuntime.from_dir(MODEL_DIR)
                # The codec in half precision: 30% faster, half the memory, -48 dB from fp32 (inaudible).
                self._runtime.codec.model.model.set_dtype(mx.float16)
                self.sample_rate = int(self._runtime.codec.sample_rate)
            return self._runtime

    def warm_up(self) -> None:
        self._get()

    def unload(self) -> None:
        """Give the ~7 GB back (quality switched off, or the model is being deleted)."""
        with self._lock:
            self._runtime = None
            self._fast = None
            self._refs.clear()
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:  # noqa: BLE001
            pass

    # -- voices -------------------------------------------------------------

    def _reference(self, voice_id: str, speed: float) -> "_Voice":
        speed = round(speed * 20) / 20                   # 0.05 steps: a handful of cached references at most
        key = (voice_id, speed)
        voice = self._refs.get(key)
        if voice is not None:
            return voice
        os.makedirs(REF_DIR, exist_ok=True)
        path = os.path.join(REF_DIR, f"{voice_id}@{speed:.2f}.wav")
        if not os.path.isfile(path):
            audio = self._kokoro.synth(REFERENCE_TEXT, voice_id, speed)
            peak = float(np.abs(audio).max()) or 1.0
            tmp = path + ".part.wav"
            sf.write(tmp, audio * min(1.0, 0.9 / peak), tts.SAMPLE_RATE, subtype="PCM_16")
            os.replace(tmp, path)
        rt = self._get()
        ref = rt.encode_reference(path, REFERENCE_TEXT)
        # Every prompt for this voice starts with the same ~400 tokens (instructions + the reference
        # recording); run them through the model once and reuse their keys/values for every chunk.
        a = rt._build_generation_prompt("a", reference_text=ref.reference_text, reference_codes=ref.reference_codes)
        b = rt._build_generation_prompt("b", reference_text=ref.reference_text, reference_codes=ref.reference_codes)
        n = min(a.shape[1], b.shape[1])
        same = np.array((a[:, :n] == b[:, :n]).all(axis=0))
        prefix_len = int(np.argmin(same)) if not same.all() else n
        voice = _Voice(ref=ref, prefix_len=prefix_len, kv=self._prefill_prefix(a[:, :prefix_len]))
        self._refs[key] = voice
        return voice

    # -- synthesis ----------------------------------------------------------

    # Decoding is bound by reading the weights, so several chunks generated side by side cost little
    # more than one: on an M2 Pro one chunk alone runs ~0.7× real time, four together ~1.5×. The
    # first batch is smaller so listening can start sooner.
    batch_size = 4
    first_batch = 2
    # Shorter chunks than Kokoro's: each batch waits for its longest chunk, and the first one is
    # what the listener waits for.
    max_chunk = 170
    # Set by the engine: polled between frames, raises InterruptedError to abandon a batch.
    should_stop = None

    def synth_many(self, texts: list[str], voice_id: str, speed: float = 1.0) -> list[np.ndarray]:
        """Audio for several chunks at once (one batch)."""
        import mlx.core as mx
        rt = self._get()
        voice = self._reference(voice_id, speed)
        # ~21 codec frames a second, a word ≈ 0.35 s: generous headroom, but a cap so a confused
        # generation can't ramble on for a minute.
        caps = [min(1500, 120 + int(len(t) * 2.2)) for t in texts]
        prompts = [rt._build_generation_prompt(t, reference_text=voice.ref.reference_text,
                                               reference_codes=voice.ref.reference_codes) for t in texts]
        out = []
        for codes in self._generate(prompts, voice, caps):
            if int(codes.shape[1]) == 0:
                raise RuntimeError("The high quality model produced no audio for this passage.")
            wav = rt.codec.decode(codes)
            out.append(_trim(np.array(wav.astype(mx.float32)).reshape(-1), self.sample_rate))
        mx.clear_cache()                      # don't sit on GBs of freed buffers between batches
        return out

    def synth(self, text: str, voice_id: str, speed: float = 1.0) -> np.ndarray:
        return self.synth_many([text], voice_id, speed)[0]

    def synth_timed_many(self, texts: list[str], voice_id: str, speed: float = 1.0) -> list[tuple[np.ndarray, list[tts.Word]]]:
        return [(a, estimate_words(a, self.sample_rate, t.split())) for a, t in zip(self.synth_many(texts, voice_id, speed), texts)]

    def synth_timed(self, text: str, voice_id: str, speed: float = 1.0) -> tuple[np.ndarray, list[tts.Word]]:
        return self.synth_timed_many([text], voice_id, speed)[0]

    def sample(self, voice_id: str, speed: float = 1.0) -> np.ndarray:
        return self.synth(tts.SAMPLE_TEXT.format(name=tts.VOICE_BY_ID[voice_id].name), voice_id, speed)

    # -- generation ---------------------------------------------------------
    #
    # mlx-speech's own loop samples on the CPU — an argsort over the whole 155k-token vocabulary
    # (twice) per frame and a GPU→CPU round trip for each of the 10 codebooks — and re-runs the
    # fast decoder's whole prefix at every codebook: ~450 ms per 1/21 s frame on an M2 Pro (0.1× real
    # time). This keeps everything on the GPU and batched: the slow model runs several prompts side by
    # side (left-padded, masked, per-row positions; the shared voice prefix computed once per voice),
    # sampling uses the same rules (temperature / top-k / top-p and the repetition-aware fallback) via
    # the Gumbel-max trick over just the 4096 audio codes, the nine fast-decoder steps are one compiled
    # graph with a KV cache, and each frame is queued before the previous one's stop check.

    _TOP_K = 30
    _RAS_WINDOW = 10

    def _slow(self, x, cache: "_KV", pos, mask):
        """The 36-layer slow model on embeddings x (B, L, D) written at cache slots [cache.len, +L),
        token positions `pos` (B,) for the first of them. Returns logits and the fast model's input
        for the last position."""
        import mlx.core as mx
        model = self._runtime.model
        b, n, _ = x.shape
        start = cache.len
        for li, layer in enumerate(model.layers):
            att = layer.attention
            q, k, v = mx.split(att.wqkv(layer.attention_norm(x)), [att.q_size, att.q_size + att.kv_size], axis=-1)
            q = q.reshape(b, n, att.n_head, att.head_dim).transpose(0, 2, 1, 3)
            k = k.reshape(b, n, att.n_local_heads, att.head_dim).transpose(0, 2, 1, 3)
            v = v.reshape(b, n, att.n_local_heads, att.head_dim).transpose(0, 2, 1, 3)
            if hasattr(att, "q_norm"):
                q, k = att.q_norm(q), att.k_norm(k)
            q = mx.fast.rope(q, att.head_dim, traditional=True, base=att.rotary_emb.base, scale=1.0, offset=pos)
            k = mx.fast.rope(k, att.head_dim, traditional=True, base=att.rotary_emb.base, scale=1.0, offset=pos)
            cache.k[li][:, :, start:start + n, :] = k
            cache.v[li][:, :, start:start + n, :] = v
            o = mx.fast.scaled_dot_product_attention(q, cache.k[li][:, :, :start + n, :], cache.v[li][:, :, :start + n, :],
                                                     scale=att.scale, mask=mask)
            x = x + att.wo(o.transpose(0, 2, 1, 3).reshape(b, n, att.n_head * att.head_dim))
            x = x + layer.feed_forward(layer.ffn_norm(x))
        cache.len = start + n
        last = model.norm(x[:, -1:, :])
        return model.embeddings.as_linear(last), model.fast_project_in(last)

    def _prefill_prefix(self, tokens):
        import mlx.core as mx
        model = self._runtime.model
        n = int(tokens.shape[1])
        cache = _KV.new(model, 1, n, model.layers[0].attention_norm.weight.dtype)
        causal = mx.triu(mx.full((n, n), -mx.inf, dtype=mx.float32), k=1)
        self._slow(model._embed(tokens[None]), cache, mx.array([0]), causal[None, None].astype(cache.dtype))
        kv = ([k[:, :, :n, :] for k in cache.k], [v[:, :, :n, :] for v in cache.v])
        mx.eval(kv)
        return kv

    def _fast_fn(self):
        """The nine fast-decoder steps as one compiled graph, with a KV cache: each step runs a single
        new token through its four layers."""
        if getattr(self, "_fast", None) is None:
            import mlx.core as mx
            model = self._runtime.model
            nc = self._runtime.config.audio_decoder_config.num_codebooks

            def run(x, pos, kv):
                """x: (B, 1, D) at position `pos`; kv: per-layer lists of past keys/values."""
                for li, layer in enumerate(model.fast_layers):
                    att = layer.attention
                    b = x.shape[0]
                    q, k, v = mx.split(att.wqkv(layer.attention_norm(x)), [att.q_size, att.q_size + att.kv_size], axis=-1)
                    q = q.reshape(b, 1, att.n_head, att.head_dim).transpose(0, 2, 1, 3)
                    k = k.reshape(b, 1, att.n_local_heads, att.head_dim).transpose(0, 2, 1, 3)
                    v = v.reshape(b, 1, att.n_local_heads, att.head_dim).transpose(0, 2, 1, 3)
                    if hasattr(att, "q_norm"):
                        q, k = att.q_norm(q), att.k_norm(k)
                    q = mx.fast.rope(q, att.head_dim, traditional=True, base=att.rotary_emb.base, scale=1.0, offset=pos)
                    k = mx.fast.rope(k, att.head_dim, traditional=True, base=att.rotary_emb.base, scale=1.0, offset=pos)
                    kv[li][0].append(k); kv[li][1].append(v)
                    keys = mx.concatenate(kv[li][0], axis=2) if pos else k
                    vals = mx.concatenate(kv[li][1], axis=2) if pos else v
                    o = mx.fast.scaled_dot_product_attention(q, keys, vals, scale=att.scale)
                    x = x + att.wo(o.transpose(0, 2, 1, 3).reshape(b, 1, att.n_head * att.head_dim))
                    x = x + layer.feed_forward(layer.ffn_norm(x))
                return x

            def fast(hidden, code0, noise):
                kv = [([], []) for _ in model.fast_layers]
                run(hidden, 0, kv)                                   # position 0: the slow model's state
                prev = code0
                codes = [code0]
                for i in range(nc - 1):
                    x = run(model.fast_embeddings(prev)[:, None, :], i + 1, kv)
                    logits = model.fast_output(model.fast_norm(x)[:, -1]).astype(mx.float32)
                    prev = _sample(logits, 0.8, 0.8, self._TOP_K, noise[i])
                    codes.append(prev)
                return mx.stack(codes, axis=1)
            self._fast = mx.compile(fast)
        return self._fast

    def _generate(self, prompts: list, voice: "_Voice", caps: list[int]) -> list:
        """Codes (num_codebooks × frames) for each prompt, all generated in one batch."""
        import mlx.core as mx
        rt = self._runtime
        model, cfg = rt.model, rt.config
        nc = cfg.audio_decoder_config.num_codebooks
        sem0 = int(cfg.semantic_start_token_id)
        nsem = int(cfg.semantic_end_token_id) - sem0 + 1
        stops = mx.array(sorted(rt._stop_ids), dtype=mx.int32)
        fast = self._fast_fn()
        k = self._TOP_K
        rows = len(prompts)
        P = voice.prefix_len
        # Each row: [shared voice prefix][left padding][its own text + assistant header][generated…]
        suffix = [p[:, P:] for p in prompts]
        lens = [int(s.shape[1]) for s in suffix]
        width = max(lens)
        pads = [width - n for n in lens]
        tokens = mx.concatenate([mx.concatenate([mx.zeros((nc + 1, pd), dtype=mx.int32), s.astype(mx.int32)], axis=1)[None]
                                 for s, pd in zip(suffix, pads)], axis=0)
        cap = P + width + max(caps) + 2
        dtype = voice.kv[0][0].dtype
        cache = _KV.new(model, rows, cap, dtype)
        for li in range(len(model.layers)):
            cache.k[li][:, :, :P, :] = voice.kv[0][li]
            cache.v[li][:, :, :P, :] = voice.kv[1][li]
        cache.len = P
        pad = mx.array(pads)
        slots = mx.arange(cap)
        # Padding slots are never attended to (and padded rows count positions from their own text).
        key_ok = ~((slots[None, :] >= P) & (slots[None, :] < P + pad[:, None]))            # (B, cap)
        neg = mx.array(-1e9, dtype=dtype)
        q_slots = P + mx.arange(width)
        allowed = key_ok[:, None, :P + width] & (slots[None, None, :P + width] <= q_slots[None, :, None])
        mask = mx.where(allowed, mx.array(0, dtype=dtype), neg)[:, None]                      # (B, 1, W, P+W)
        step_mask = mx.where(key_ok, mx.array(0, dtype=dtype), neg)[:, None, None, :]         # (B, 1, 1, cap)
        logits, hidden = self._slow(model._embed(tokens), cache, P - pad, mask)

        def step(logits, hidden, recent):
            lg = logits[:, -1, :].astype(mx.float32)
            sub = mx.concatenate([lg[:, sem0:sem0 + nsem], mx.take(lg, stops, axis=1)], axis=1)
            g = mx.random.gumbel((2 + nc - 1, rows, k))
            a = _sample(sub, 0.8, 0.8, k, g[0])
            b = _sample(sub, 1.0, 0.9, k, g[1])
            tok = mx.where(mx.any(recent == a[:, None], axis=1), b, a)      # repetition-aware sampling
            is_stop = tok >= nsem
            code0 = mx.minimum(tok, nsem - 1).astype(mx.int32)
            codes = fast(hidden, code0, g[2:])                               # (B, nc)
            frame = mx.concatenate([(code0 + sem0)[:, None], codes], axis=1)[:, :, None]   # (B, nc+1, 1)
            j = cache.len
            logits, hidden = self._slow(model._embed(frame), cache, j - pad, step_mask[..., :j + 1])
            recent = mx.concatenate([recent[:, 1:], tok[:, None]], axis=1)
            return codes, is_stop, logits, hidden, recent

        recent = mx.full((rows, self._RAS_WINDOW), -1, dtype=mx.int32)
        frames = []
        done = [None] * rows
        codes, stop, logits, hidden, recent = step(logits, hidden, recent)
        mx.async_eval(codes, stop, logits, hidden, recent)
        for t in range(max(caps)):
            if t % 8 == 0 and self.should_stop and self.should_stop():
                raise InterruptedError
            prev_codes, prev_stop = codes, stop
            if t + 1 < max(caps):
                codes, stop, logits, hidden, recent = step(logits, hidden, recent)
                mx.async_eval(codes, stop, logits, hidden, recent)
            flags = prev_stop.tolist()
            frames.append(prev_codes)
            for r in range(rows):
                if done[r] is None and (flags[r] or t + 1 >= caps[r]):
                    done[r] = t if flags[r] else t + 1
            if all(d is not None for d in done):
                break
        stacked = mx.stack(frames, axis=0) if frames else mx.zeros((0, rows, nc), dtype=mx.int32)   # (T, B, nc)
        return [stacked[:done[r] or 0, r, :].T for r in range(rows)]


class _KV:
    """Slow-model keys/values: one (B, kv_heads, capacity, head_dim) buffer per layer."""
    def __init__(self, k, v, dtype):
        self.k, self.v, self.dtype, self.len = k, v, dtype, 0

    @classmethod
    def new(cls, model, rows: int, capacity: int, dtype):
        import mlx.core as mx
        att = model.layers[0].attention
        shape = (rows, att.n_local_heads, capacity, att.head_dim)
        return cls([mx.zeros(shape, dtype=dtype) for _ in model.layers],
                   [mx.zeros(shape, dtype=dtype) for _ in model.layers], dtype)


@dataclass
class _Voice:
    ref: object                 # mlx-speech PreparedReference (codes + transcript)
    prefix_len: int             # prompt tokens shared by every chunk in this voice
    kv: tuple                   # their keys/values per slow layer: ([k…], [v…]), batch 1


def _sample(logits, temperature: float, top_p: float, top_k: int, gumbel):
    """One token per row from `logits` (rows × vocab): temperature, top-k, then top-p (nucleus) —
    exactly mlx-speech's rules — sampled with the Gumbel-max trick so it stays on the GPU."""
    import mlx.core as mx
    idx = mx.argpartition(-logits, kth=top_k - 1, axis=-1)[..., :top_k]
    vals = mx.take_along_axis(logits, idx, axis=-1) / temperature
    order = mx.argsort(-vals, axis=-1)
    vals = mx.take_along_axis(vals, order, axis=-1)
    probs = mx.softmax(vals, axis=-1)
    drop = (mx.cumsum(probs, axis=-1) - probs) > top_p                   # always keeps the top token
    vals = mx.where(drop, mx.array(-mx.inf, dtype=vals.dtype), vals)
    choice = mx.argmax(vals + gumbel, axis=-1)
    picked = mx.take_along_axis(order, choice[:, None], axis=-1)
    return mx.take_along_axis(idx, picked, axis=-1)[:, 0].astype(mx.int32)


# ------------------------------------------------------------------ audio analysis

_FRAME = 0.01   # seconds


def _envelope(audio: np.ndarray, sr: int) -> np.ndarray:
    hop = max(1, int(sr * _FRAME))
    n = len(audio) // hop
    if n == 0:
        return np.zeros(0, np.float32)
    frames = audio[: n * hop].reshape(n, hop)
    return np.sqrt((frames.astype(np.float32) ** 2).mean(axis=1))


def _silence_threshold(env: np.ndarray) -> float:
    loud = np.percentile(env, 95) if len(env) else 0.0
    return max(1e-4, float(loud) * 0.06)


def _trim(audio: np.ndarray, sr: int) -> np.ndarray:
    """Cut the dead air S2 Pro sometimes leaves at either end (keeping a short natural tail)."""
    env = _envelope(audio, sr)
    if not len(env):
        return audio
    voiced = np.nonzero(env > _silence_threshold(env))[0]
    if not len(voiced):
        return audio
    hop = int(sr * _FRAME)
    start = max(0, (voiced[0] - 3) * hop)
    end = min(len(audio), (voiced[-1] + 12) * hop)
    return audio[start:end]


def _pauses(env: np.ndarray, min_len: float = 0.12) -> list[tuple[float, float]]:
    """Silent stretches inside the speech, as (start, end) seconds."""
    quiet = env <= _silence_threshold(env)
    voiced = np.nonzero(~quiet)[0]
    if not len(voiced):
        return []
    first, last = voiced[0], voiced[-1]
    out, run = [], None
    for i in range(first, last + 1):
        if quiet[i]:
            run = i if run is None else run
        elif run is not None:
            if (i - run) * _FRAME >= min_len:
                out.append((run * _FRAME, i * _FRAME))
            run = None
    return out


_VOWELS = re.compile(r"[aeiouy]+", re.I)


def _weight(word: str) -> float:
    """Rough spoken length of a written word, in syllables."""
    letters = re.sub(r"[^A-Za-z]", "", word)
    syl = max(1, len(_VOWELS.findall(letters))) if letters else 0
    digits = sum(c.isdigit() for c in word)
    symbols = sum(c in "$%€£&@+=" for c in word)
    return max(0.6, syl + digits * 1.1 + symbols * 1.5)


def estimate_words(audio: np.ndarray, sr: int, words: list[str]) -> list[tts.Word]:
    """Word timings for speech that came without any: syllable-weighted layout stretched over the
    voiced part of `audio`, with boundaries after punctuation pinned to the real pauses in it."""
    total = len(audio) / sr
    if not words:
        return []
    env = _envelope(audio, sr)
    voiced = np.nonzero(env > _silence_threshold(env))[0] if len(env) else np.zeros(0, int)
    t0 = voiced[0] * _FRAME if len(voiced) else 0.0
    t1 = (voiced[-1] + 1) * _FRAME if len(voiced) else total
    pause_w = [1.4 if w[-1:] in ".!?" else 0.8 if w[-1:] in ",;:" else 0.0 for w in words]
    starts, ends, acc = [], [], 0.0
    for w, pw in zip(words, pause_w):
        starts.append(acc)
        acc += _weight(w)
        ends.append(acc)
        acc += pw
    span = max(ends[-1], 1e-6)
    scale = (t1 - t0) / span
    # Anchors map layout time → audio time. Boundaries after punctuation snap to a nearby real pause.
    anchors = [(0.0, t0)]
    pauses = _pauses(env)
    used = -1
    for i in range(len(words) - 1):
        if not pause_w[i]:
            continue
        gap_mid = (ends[i] + starts[i + 1]) / 2
        expect = t0 + gap_mid * scale
        best, best_d = None, max(0.5, 0.1 * (t1 - t0))
        for j, (ps, pe) in enumerate(pauses):
            if j <= used or ps <= anchors[-1][1]:
                continue
            d = abs((ps + pe) / 2 - expect)
            if d < best_d:
                best, best_d = j, d
        if best is not None:
            used = best
            ps, pe = pauses[best]
            anchors.append((ends[i], ps))
            anchors.append((starts[i + 1], pe))
    anchors.append((span, t1))
    xs = np.array([a for a, _ in anchors]); ys = np.array([b for _, b in anchors])
    keep = np.concatenate([[True], np.diff(xs) > 1e-6])      # strictly increasing for interp
    xs, ys = xs[keep], ys[keep]
    s_out = np.interp(starts, xs, ys)
    e_out = np.interp(ends, xs, ys)
    return [tts.Word(w, round(float(a), 3), round(float(max(b, a + 0.04)), 3)) for w, a, b in zip(words, s_out, e_out)]
