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

**[Download Narrate.dmg](https://github.com/Ephemerill/pdf-to-speach/releases/latest/download/Narrate.dmg)**
(all versions: [Releases](https://github.com/Ephemerill/pdf-to-speach/releases)), open it, drag **Narrate** onto **Applications**. Done — the
app is self-contained (a Swift/SwiftUI front end with a relocatable Python runtime and the Kokoro
engine embedded in the bundle); nobody needs Python installed.

First launch downloads the voice model (≈340 MB, once) into `~/Library/Application Support/Narrate/`.
Requires macOS 15+ and an Apple Silicon Mac (an Intel build can be made with `ARCH=x86_64`).
`ffmpeg` (Homebrew) is optional — it enables M4A and slightly better MP3s.

> **Until the app is signed with a Developer ID and notarized**, macOS shows *"Apple could not
> verify Narrate is free of malware"* on first open. Click **Done**, then go to
> **System Settings ▸ Privacy & Security**, scroll down and click **Open Anyway**. Once.

## Build

```sh
./build.sh            # → dist/Narrate.app           (what you run while developing)
./build.sh --swift    #   rebuild just the Swift side (seconds)
./build.sh --dmg      # → dist/Narrate-2.0-arm64.dmg  (what you give to people)
```

Needs Xcode (or the Command Line Tools) for `swiftc`; there is no Xcode project, the script compiles
the sources directly. The first full build downloads a relocatable Python and the engine's wheels
into `build/` (cached afterwards).

**Publishing a release:** `dist/` is not committed (an 80 MB binary doesn't belong in git history).
Instead, push a version tag and GitHub builds and attaches the DMG for you:

```sh
git tag v2.1 && git push origin v2.1      # → github.com/…/releases/tag/v2.1 with Narrate.dmg
```

(`.github/workflows/release.yml`; *Actions ▸ Release ▸ Run workflow* builds a DMG without releasing.)

**Shipping without the Gatekeeper prompt** needs the Apple Developer Program:

1. In Xcode ▸ Settings ▸ Accounts, create a *Developer ID Application* certificate.
2. Make an app-specific password at appleid.apple.com and store it once:
   `xcrun notarytool store-credentials narrate --apple-id you@example.com --team-id TEAMID`
3. Build: `SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=narrate ./build.sh --dmg`

That signs every binary with the hardened runtime, has Apple notarize the app and the disk image,
and staples the tickets — the DMG then opens on any Mac with no warnings.

## Using it

1. **PDF** — drop it on the window (or the Dock icon), or click to browse. You can narrow to a page range.
2. **Text** — paste anything; blank lines separate paragraphs.
3. **Link** — paste a URL and hit *Open*. Narrate opens its own browser window; sign in or solve the
   site's bot check if asked (logins stick between runs). Once the article is on screen, hit
   **Capture Page Text**. It tries, in order: page-scan images → OCR (JSTOR's viewer), the article's
   text, then scroll-and-screenshot → OCR. Running headers, page numbers and footnotes are stripped.
4. Pick a voice: click the voice row (or ⇧⌘V) for a grid of sixteen colour orbs, one per voice —
   hover one to hear it, click to choose. Previews are instant because samples are rendered once in
   the background and cached. Speed and format live under *Options* (1× MP3 by default; your
   choices are remembered). **Generate Audiobook** (⌘↩).
5. The reader opens as soon as the first chunk is synthesized and plays while the rest generates in
   the background. Skip anywhere — the engine synthesizes that part next, then fills in the gaps.
   The finished file (and its sidecar) is written once everything is done.
6. Click any word to jump there; `space` play/pause, `←`/`→` skip 10 s, `↑`/`↓` paragraphs; playback
   speed 0.75–3×. The text follows the narration; scroll and it steps aside until the spoken word
   comes back into view.
7. To carry on listening on your phone: **AirDrop** in the toolbar (⇧⌘D) sends the MP3 straight to
   your iPhone or iPad, **Share** offers Messages/Mail/Notes etc., and **Export ▸ Save a Copy…**
   (⇧⌘E) drops a copy anywhere — e.g. iCloud Drive for the Files app. *Show in Finder* reveals the
   original.
8. Updates come from GitHub Releases: Narrate checks once a day (toggle under *Options*) and offers
   a one-click update — it downloads `Narrate.zip`, swaps itself out and relaunches. *Narrate ▸ Check
   for Updates…* checks right away. Because the app downloads the update itself, there's no Gatekeeper
   prompt the second time round.

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
  Glass.swift                   Liquid Glass (macOS 26) / material (macOS 15) styling helpers
  VoiceOrb.swift                animated voice orbs, the voice row and the picker popover
  Updater.swift                 in-app updates from GitHub Releases (Narrate.zip)
NarrateApp/Resources/           Info.plist, icon generator
engine/narrate_engine.py        the Python side: stdin/stdout JSON server (streams chunks, honours skip-ahead)
engine/narrate/tts.py           Kokoro engine, chunking, word timings, encoding
engine/narrate/pdf_text.py      PDF text extraction + cleanup
legacy/                         the original pywebview version (kept for reference)
```

Diagnostics: *Help ▸ Show Engine Log* reveals `engine.log`; the Swift side logs to the unified log
under subsystem `com.narrate.app` (`log stream --predicate 'subsystem == "com.narrate.app"' --info`).
