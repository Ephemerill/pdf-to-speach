# Narrate

Turn PDFs, pasted text, or articles behind a login (JSTOR, university proxies…) into
audiobooks — read along with word-by-word highlighting. Everything runs on your Mac;
no accounts, no API keys, nothing leaves the machine.

- **Speech:** [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) via ONNX — the best-sounding
  open TTS model that runs comfortably on a laptop CPU (≈5× faster than real time on Apple Silicon).
  16 curated English voices (US/UK, graded by quality) with instant samples.
- **OCR:** macOS Vision framework — reads page scans (JSTOR's reader), screenshots, anything on screen.
- **Output:** MP3 (default), M4A or WAV, saved next to the PDF (or in `~/Downloads`), plus a
  `.narrate.json` sidecar so you can drop the audio file back on the app later and resume read-along.

## Run

Double-click `Narrate.command`, or:

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python app.py
```

First launch downloads the voice model (≈340 MB) into `models/`. Requires macOS 13+ and Python 3.11+.
`ffmpeg` is optional (enables M4A and slightly better MP3 encoding).

## Using it

1. **Drop a PDF** (or click to browse). You can narrow to a page range.
2. **Paste text** — blank lines separate paragraphs.
3. **From a link** — paste a URL and hit *Open*. Narrate opens its own browser window; sign in or
   solve the site's bot check if asked (this sticks between runs). Once the article is on screen,
   hit **Capture page text**. Narrate tries, in order: page-scan images → OCR (JSTOR's viewer),
   the article's text, then scroll-and-screenshot → OCR. Running headers, page numbers and
   footnotes are stripped automatically.
4. Pick a voice (▶ plays a sample at the chosen speed), set speed and format, **Generate**.
5. The reader opens: click any word to jump there; `space` play/pause, `←`/`→` skip 10 s,
   `↑`/`↓` paragraphs; playback speed 0.75–2×.

## Layout

```
app.py              window, JS bridge, generation pipeline
ui/index.html       the interface (single file)
narrate/tts.py      Kokoro engine, chunking, word timings, encoding
narrate/pdf_text.py PDF text extraction + cleanup
narrate/capture.py  built-in browser capture: page images / DOM text / screenshots → Vision OCR
narrate/media.py    localhost streaming of the finished audio to the in-app player
```

Set `NARRATE_DEBUG=1` to log the capture pipeline.
