# Narrate

Turn PDFs, pasted text, web articles, or papers behind a login (JSTOR, university proxies…) into
audiobooks — and read along with word-by-word highlighting. A native Mac app; everything
runs on your machine. No accounts, no API keys, nothing leaves the Mac.

- **Speech:** [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) via ONNX — the best-sounding
  open TTS model that runs comfortably on a laptop (≈5× faster than real time on Apple Silicon).
  16 curated English voices (US/UK, graded by quality) with instant samples.
- **High Quality (optional):** [Fish Audio S2 Pro](https://huggingface.co/fishaudio/s2-pro) on Apple's
  MLX (int8, via [mlx-speech](https://github.com/appautomaton/mlx-speech)'s model code with Narrate's
  own batched, GPU-side generation loop — ~2× real time on an M2 Pro, ~20 s to first audio, ~8 GB of
  memory while speaking). Every voice has a high quality twin: S2 Pro
  clones a short Kokoro reading of that voice and speaks with its own prosody. The 6.7 GB model is only
  downloaded when High Quality is chosen. Fish Audio Research License: free for personal/non-commercial use.
- **OCR:** macOS Vision — reads page scans (JSTOR's reader), screenshots, anything on screen.
- **Output:** MP3 (default), M4A or WAV, saved next to the PDF (or in `~/Downloads`), plus a
  `.narrate.json` sidecar so you can drop the audio file back on the app later and resume read-along.

## Install

**[Download Narrate.dmg](https://github.com/Ephemerill/pdf-to-speach/releases/latest/download/Narrate.dmg)**
(all versions: [Releases](https://github.com/Ephemerill/pdf-to-speach/releases)), open it, drag **Narrate** onto **Applications**. Done — the
app is self-contained (a Swift/SwiftUI front end with a relocatable Python runtime and the Kokoro
engine embedded in the bundle); nobody needs Python installed.

First launch downloads the voice model (≈340 MB, once) into `~/Library/Application Support/Narrate/`
in the background — documents can be opened and set up meanwhile; *Generate* starts once it's in.
Requires macOS 15+ and an Apple Silicon Mac (an Intel build can be made with `ARCH=x86_64`).
`ffmpeg` (Homebrew) is optional — it enables M4A and slightly better MP3s.

Since 2.5 releases are signed with a Developer ID and notarized, so the DMG opens without warnings.

## Build

```sh
./build.sh            # → dist/Narrate.app           (what you run while developing)
./build.sh --swift    #   rebuild just the Swift side (seconds)
./build.sh --dmg      # → dist/Narrate-2.0-arm64.dmg  (what you give to people)
```

Needs Xcode (or the Command Line Tools) for `swiftc`; there is no Xcode project, the script compiles
the sources directly. The first full build downloads a relocatable Python and the engine's wheels
into `build/` (cached afterwards).

**Publishing a release** (signed, notarized, and announced to existing installs through Sparkle):

```sh
# bump CFBundleShortVersionString + CFBundleVersion in NarrateApp/Resources/Info.plist,
# write release-notes/<version>.md, commit, then:
./release.sh
```

`release.sh` builds with the Developer ID, notarizes and staples the app and the DMG, EdDSA-signs the
update zip, creates the GitHub Release (`Narrate.dmg`, `Narrate.zip`) and adds the update to
`appcast.xml` on the `gh-pages` branch, which GitHub Pages serves at the app's `SUFeedURL`. One-time
setup on the release Mac: the *Developer ID Application* certificate in the keychain,
`xcrun notarytool store-credentials narrate --apple-id … --team-id 86L5N846P4`, and the Sparkle key
(`build/sparkle-*/bin/generate_keys --account narrate` — back it up with `-x`; losing it means existing
installs can't verify future updates). `dist/` is not committed. The GitHub Actions workflow only
builds an unsigned DMG on demand (*Actions ▸ Build ▸ Run workflow*).

## Using it

1. **PDF** — drop it on the window (or the Dock icon), or click to browse. Every page is read once,
   and the file's chapters are listed (from its bookmarks, or detected from headings when it has
   none). Tick the chapters you want, type page ranges (`6-13, 24-50` — as many as you like in one
   audiobook), or open **Choose Pages…** to flip through the PDF itself: pages that won't be
   narrated are veiled, and Start Here / End Here marks a run of pages while you scroll. The word
   count, the preview and the reader only ever show what's selected.
2. **Text** — paste anything; blank lines separate paragraphs.
3. **Link** — paste a URL (or drag a link in) and Narrate reads the article: the page loads in a
   hidden web view and a Reader-style extractor pulls out the body text — no menus, ads, share bars,
   comments, footnote markers or endnotes — plus the title and author. Links straight to a PDF are
   downloaded to `~/Downloads` and opened like any PDF. If there's no article to be had (a login
   wall, a bot check, JSTOR's page scans), the built-in browser window opens on that page instead:
   sign in if asked (logins stick between runs), get the article on screen, then hit **Capture Page
   Text**. Capture tries, in order: page-scan images → OCR (JSTOR's viewer), the article's text,
   then scroll-and-screenshot → OCR. Running headers, page numbers and footnotes are stripped.
4. Pick a voice: click the voice row (or ⇧⌘V) for a grid of sixteen colour orbs, one per voice —
   hover one to hear it, click to choose. Previews are instant because samples are rendered once in
   the background and cached. **Standard / High Quality** sits under the voice; choosing High Quality
   downloads its model in the background (progress in the toolbar and the voice section, pausable,
   resumable; *Options ▸ High quality ▸ Delete…* frees the space again). Speed and format live under
   *Options* (1× MP3 by default; your choices are remembered). **Generate Audiobook** (⌘↩).
   For PDFs, *Skip page numbers & footnotes* (on by default) leaves out page numbers, running heads,
   footnotes and the note marks in the text, detected from the page layout.
5. The reader opens as soon as the first chunk is synthesized and plays while the rest generates in
   the background. Skip anywhere — the engine synthesizes that part next, then fills in the gaps.
   The finished file (and its sidecar) is written once everything is done.
6. Change voice (or quality) mid-book from the voice button at the left of the player: the new voice
   is generated from where you are and takes over at the next pause (a couple of seconds for standard
   voices, about half a minute for High Quality); the rest is redone in the background and the finished file is the new voice's.
   Click any word to jump there; `space` play/pause, `←`/`→` skip 10 s, `↑`/`↓` paragraphs; playback
   speed 0.75–3×. The text follows the narration; scroll and it steps aside until the spoken word
   comes back into view.
7. To carry on listening on your phone: **AirDrop** in the toolbar (⇧⌘D) sends the MP3 straight to
   your iPhone or iPad, **Share** offers Messages/Mail/Notes etc., and **Export ▸ Save a Copy…**
   (⇧⌘E) drops a copy anywhere — e.g. iCloud Drive for the Files app. *Show in Finder* reveals the
   original.
8. Updates come through [Sparkle](https://sparkle-project.org): Narrate checks the appcast once a
   day (toggle under *Options*) and offers the update with its release notes; *Narrate ▸ Check for
   Updates…* checks right away.

## Layout

```
build.sh                        builds dist/Narrate.app (Swift + embedded Python + icon + signing)
NarrateApp/Sources/
  NarrateApp.swift              app entry, windows, menu commands, Finder open-with
  AppModel.swift                all state: setup, documents, generation, reader
  HomeView.swift                setup screen (source, document, voices, options)
  ReaderView.swift              reader screen + player bar
  ReadAlongTextView.swift       NSTextView-based read-along with word highlighting
  PagePicker.swift              the Choose Pages window (PDFKit viewer, chapters, page ranges)
  Browser.swift                 the WKWebView behind links (hidden loads, PDF downloads) + its window
  Article.swift                 Reader-style article extraction (runs in the page as JS)
  Capture.swift                 page images / article text / screenshots → Vision OCR → paragraphs
  Engine.swift                  JSON-lines bridge to the Python engine subprocess
  ModelPack.swift               background, resumable model downloads (Kokoro; Fish S2 Pro on demand)
  QualityViews.swift            Standard/High Quality picker, download status, reader voice switcher
  Player.swift                  AVAudioPlayer wrappers
  Models.swift                  voices, documents, narration + sidecar format
  Glass.swift                   Liquid Glass (macOS 26) / material (macOS 15) styling helpers
  VoiceOrb.swift                animated voice orbs, the voice row and the picker popover
  Updater.swift                 Sparkle updater (appcast on gh-pages)
NarrateApp/Resources/           Info.plist, icon generator
engine/narrate_engine.py        the Python side: stdin/stdout JSON server (streams chunks, honours skip-ahead)
engine/narrate/tts.py           Kokoro engine, chunking, word timings, encoding
engine/narrate/fish.py          Fish Audio S2 Pro (high quality) on MLX: voice references, estimated word timings
engine/narrate/pdf_text.py      PDF text extraction (per page) + cleanup + footnote/page-number detection + chapter outline
release.sh                      signed + notarized release, GitHub Release, Sparkle appcast
legacy/                         the original pywebview version (kept for reference)
```

Diagnostics: *Help ▸ Show Engine Log* reveals `engine.log`; the Swift side logs to the unified log
under subsystem `com.narrate.app` (`log stream --predicate 'subsystem == "com.narrate.app"' --info`).
