# Narrate

Turn PDFs, pasted text, or articles behind a login (JSTOR, university proxies…) into
audiobooks — and read along with word-by-word highlighting. A native Mac app; everything
runs on your machine. No accounts, no API keys, nothing leaves the Mac.

- **Speech:** [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) via ONNX — the best-sounding
  open TTS model that runs comfortably on a laptop (≈5× faster than real time on Apple Silicon).
  16 curated English voices (US/UK, graded by quality) with instant samples.
- **OCR:** macOS Vision — reads page scans (JSTOR's reader), screenshots, anything on screen.
- **Output:** MP3 (default), M4A or WAV, saved next to the PDF (or in `~/Downloads`), plus a
  `.narrate.json` sidecar so you can drop the audio file back on the app later and resume read-along.

## Install

```sh
./build.sh          # → dist/Narrate.app
```

Then double-click `dist/Narrate.app` (or drag it to `/Applications`). That's it — the app is
self-contained: a Swift/SwiftUI front end with a relocatable Python runtime and the Kokoro
engine embedded inside the bundle. Nobody needs Python installed.

First launch downloads the voice model (≈340 MB, once) into `~/Library/Application Support/Narrate/`.
Requires macOS 15+. `ffmpeg` (Homebrew) is optional — it enables M4A and slightly better MP3s.

Building needs Xcode (or the Command Line Tools) for `swiftc`; there is no Xcode project, the
build script compiles the sources directly. `./build.sh --swift` rebuilds just the Swift side.
The build is ad-hoc signed, so it runs on the Mac that built it; distributing it to other Macs
without Gatekeeper warnings needs a Developer ID signature + notarization.

## Using it

1. **PDF** — drop it on the window (or the Dock icon), or click to browse. You can narrow to a page range.
2. **Text** — paste anything; blank lines separate paragraphs.
3. **Link** — paste a URL and hit *Open*. Narrate opens its own browser window; sign in or solve the
   site's bot check if asked (logins stick between runs). Once the article is on screen, hit
   **Capture Page Text**. It tries, in order: page-scan images → OCR (JSTOR's viewer), the article's
   text, then scroll-and-screenshot → OCR. Running headers, page numbers and footnotes are stripped.
4. Pick a voice (▶ plays a sample at the chosen speed), set speed and format, **Generate Audiobook** (⌘↩).
5. The reader opens as soon as the first chunk is synthesized and plays while the rest generates in
   the background. Skip anywhere — the engine synthesizes that part next, then fills in the gaps.
   The finished file (and its sidecar) is written once everything is done.
6. Click any word to jump there; `space` play/pause, `←`/`→` skip 10 s, `↑`/`↓` paragraphs; playback
   speed 0.75–3×. The text follows the narration; scroll and it steps aside until the spoken word
   comes back into view. *Show in Finder* reveals the audio file.

## Layout

```
build.sh                        builds dist/Narrate.app (Swift + embedded Python + icon + signing)
NarrateApp/Sources/
  NarrateApp.swift              app entry, windows, menu commands, Finder open-with
  AppModel.swift                all state: setup, documents, generation, reader
  HomeView.swift                setup screen (source, document, voices, options)
  ReaderView.swift              reader screen + player bar
  ReadAlongTextView.swift       NSTextView-based read-along with word highlighting
  Browser.swift                 built-in capture browser window (WKWebView)
  Capture.swift                 page images / DOM text / screenshots → Vision OCR → paragraphs
  Engine.swift                  JSON-lines bridge to the Python engine subprocess
  ModelDownloader.swift         one-time model download with progress
  Player.swift                  AVAudioPlayer wrappers
  Models.swift                  voices, documents, narration + sidecar format
NarrateApp/Resources/           Info.plist, icon generator
engine/narrate_engine.py        the Python side: stdin/stdout JSON server (streams chunks, honours skip-ahead)
engine/narrate/tts.py           Kokoro engine, chunking, word timings, encoding
engine/narrate/pdf_text.py      PDF text extraction + cleanup
legacy/                         the original pywebview version (kept for reference)
```

Diagnostics: *Help ▸ Show Engine Log* reveals `engine.log`; the Swift side logs to the unified log
under subsystem `com.narrate.app` (`log stream --predicate 'subsystem == "com.narrate.app"' --info`).
