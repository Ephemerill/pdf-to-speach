#!/bin/zsh
# Builds dist/Narrate.app — a self-contained Mac app (Swift UI + embedded Python engine).
#
#   ./build.sh            full build (downloads a relocatable Python + deps on first run, cached in build/)
#   ./build.sh --swift    rebuild only the Swift binary into the existing app (fast, for UI work)
#
# Needs: Xcode (or Command Line Tools) for swiftc. No Xcode project, no system Python required.
set -euo pipefail
cd "$(dirname "$0")"

# Prefer a full Xcode toolchain when one is installed: the standalone Command Line Tools can ship
# with a compiler/SDK mismatch that fails to build anything importing Foundation.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCH=$(uname -m)                                   # arm64 | x86_64
PY_VER="3.12.14"
PY_TAG="20260901"
PY_ARCH=$([[ "$ARCH" == "arm64" ]] && echo aarch64 || echo x86_64)
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/cpython-${PY_VER}+${PY_TAG}-${PY_ARCH}-apple-darwin-install_only_stripped.tar.gz"
MIN_MACOS="15.0"

APP="dist/Narrate.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
BUILD="build"
MODCACHE="$BUILD/modulecache"
mkdir -p "$BUILD" "$MODCACHE" dist

swift_only=false
[[ "${1:-}" == "--swift" ]] && swift_only=true

# ---------------------------------------------------------------- 1. Swift binary
echo "▸ Compiling Swift…"
mkdir -p "$CONTENTS/MacOS"
xcrun swiftc -O -parse-as-library -swift-version 5 -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -module-cache-path "$MODCACHE" \
  NarrateApp/Sources/*.swift -o "$CONTENTS/MacOS/Narrate"

if $swift_only && [[ -d "$RES/python" ]]; then
  codesign --force --sign - "$CONTENTS/MacOS/Narrate" >/dev/null 2>&1 || true
  echo "✓ Swift binary updated in $APP"
  exit 0
fi

# ---------------------------------------------------------------- 2. Embedded Python + deps
if [[ ! -x "$BUILD/python/bin/python3" ]]; then
  echo "▸ Downloading relocatable Python ${PY_VER} (${PY_ARCH})…"
  curl -L --progress-bar -o "$BUILD/python.tar.gz" "$PY_URL"
  rm -rf "$BUILD/python"
  tar -xzf "$BUILD/python.tar.gz" -C "$BUILD"          # extracts to build/python
  rm "$BUILD/python.tar.gz"
fi

PY="$BUILD/python/bin/python3"
if [[ ! -f "$BUILD/.deps-ok" ]] || [[ engine/requirements.txt -nt "$BUILD/.deps-ok" ]]; then
  echo "▸ Installing engine dependencies…"
  "$PY" -m pip install --quiet --upgrade pip
  "$PY" -m pip install --quiet --no-compile -r engine/requirements.txt
  # Trim what a bundled runtime never needs.
  SP="$BUILD/python/lib/python${PY_VER%.*}/site-packages"
  "$PY" -m pip uninstall --quiet -y pip setuptools 2>/dev/null || true
  rm -rf "$BUILD/python/lib/python${PY_VER%.*}"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3,pydoc_data} \
         "$SP"/numpy/{_core,lib,linalg,fft,random,polynomial,ma,testing}/tests \
         "$SP"/onnxruntime/{datasets,tools} "$SP"/pymupdf/mupdf-devel 2>/dev/null || true
  find "$BUILD/python" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
  touch "$BUILD/.deps-ok"
fi

# ---------------------------------------------------------------- 3. Assemble the bundle
echo "▸ Assembling $APP…"
rm -rf "$RES"
mkdir -p "$RES"
cp NarrateApp/Resources/Info.plist "$CONTENTS/Info.plist"
echo -n "APPL????" > "$CONTENTS/PkgInfo"
rsync -a --exclude "__pycache__" engine/ "$RES/engine/"
rsync -a "$BUILD/python/" "$RES/python/"

if [[ ! -f "$BUILD/AppIcon.icns" ]] || [[ NarrateApp/Resources/make-icon.swift -nt "$BUILD/AppIcon.icns" ]]; then
  echo "▸ Rendering app icon…"
  rm -rf "$BUILD/AppIcon.iconset"
  xcrun swift -module-cache-path "$MODCACHE" NarrateApp/Resources/make-icon.swift "$BUILD/AppIcon.iconset" >/dev/null
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$RES/AppIcon.icns"

# ---------------------------------------------------------------- 4. Sign (ad hoc) so macOS runs it locally
echo "▸ Signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
xattr -cr "$APP" 2>/dev/null || true
touch "$APP"                                          # make Finder refresh the icon

echo "✓ Built $APP ($(du -sh "$APP" | cut -f1)). Double-click it, or drag it to /Applications."
