#!/bin/zsh
# Builds dist/Narrate.app — a self-contained Mac app (Swift UI + embedded Python engine) — and,
# with --dmg, the disk image people download.
#
#   ./build.sh              full build (downloads a relocatable Python + deps on first run, cached in build/)
#   ./build.sh --swift      rebuild only the Swift binary into the existing app (fast, for UI work)
#   ./build.sh --dmg        full build, then dist/Narrate-<version>-<arch>.dmg
#
#   ARCH=x86_64 ./build.sh --dmg      Intel build (on Apple Silicon this needs Rosetta for the pip step)
#
# Distribution signing (otherwise the app is ad-hoc signed and Gatekeeper makes users approve it):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   sign with hardened runtime
#   NOTARY_PROFILE=narrate                                          also notarize + staple, using the
#                                                                   keychain profile created by
#                                                                   `xcrun notarytool store-credentials narrate`
#
# Needs: Xcode (or Command Line Tools) for swiftc. No Xcode project, no system Python required.
set -euo pipefail
cd "$(dirname "$0")"

# Prefer a full Xcode toolchain when one is installed: the standalone Command Line Tools can ship
# with a compiler/SDK mismatch that fails to build anything importing Foundation.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCH="${ARCH:-$(uname -m)}"                        # arm64 | x86_64
PY_VER="3.12.14"
PY_TAG="20260901"
PY_ARCH=$([[ "$ARCH" == "arm64" ]] && echo aarch64 || echo x86_64)
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/cpython-${PY_VER}+${PY_TAG}-${PY_ARCH}-apple-darwin-install_only_stripped.tar.gz"
MIN_MACOS="15.0"
VERSION=$(plutil -extract CFBundleShortVersionString raw NarrateApp/Resources/Info.plist)

APP="dist/Narrate.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
BUILD="build"
PYDIR="$BUILD/python-$ARCH"
MODCACHE="$BUILD/modulecache"
ENTITLEMENTS="NarrateApp/Resources/Narrate.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
mkdir -p "$BUILD" "$MODCACHE" dist

swift_only=false; make_dmg=false
[[ "${1:-}" == "--swift" ]] && swift_only=true
[[ "${1:-}" == "--dmg" ]] && make_dmg=true

# Sign one Mach-O / bundle. Ad hoc unless SIGN_IDENTITY is set, in which case hardened runtime + timestamp.
sign() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$@"
  else
    codesign --force --sign - "$@"
  fi
}

# ---------------------------------------------------------------- 1. Swift binary
echo "▸ Compiling Swift ($ARCH)…"
mkdir -p "$CONTENTS/MacOS"
xcrun swiftc -O -parse-as-library -swift-version 5 -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -module-cache-path "$MODCACHE" \
  NarrateApp/Sources/*.swift -o "$CONTENTS/MacOS/Narrate"

if $swift_only && [[ -d "$RES/python" ]]; then
  sign "$CONTENTS/MacOS/Narrate" >/dev/null 2>&1 || true
  echo "✓ Swift binary updated in $APP"
  exit 0
fi

# ---------------------------------------------------------------- 2. Embedded Python + deps
if [[ ! -x "$PYDIR/bin/python3" ]]; then
  echo "▸ Downloading relocatable Python ${PY_VER} (${PY_ARCH})…"
  curl -L --progress-bar -o "$BUILD/python.tar.gz" "$PY_URL"
  rm -rf "$PYDIR" "$BUILD/python"
  tar -xzf "$BUILD/python.tar.gz" -C "$BUILD"          # extracts to build/python
  mv "$BUILD/python" "$PYDIR"
  rm "$BUILD/python.tar.gz"
fi

PY="$PYDIR/bin/python3"
RUN_PY=(arch "-$ARCH" "$PY")                          # run the runtime under its own architecture
if [[ ! -f "$PYDIR/.deps-ok" ]] || [[ engine/requirements.txt -nt "$PYDIR/.deps-ok" ]]; then
  echo "▸ Installing engine dependencies ($ARCH)…"
  "${RUN_PY[@]}" -m pip install --quiet --upgrade pip
  "${RUN_PY[@]}" -m pip install --quiet --no-compile -r engine/requirements.txt
  # Trim what a bundled runtime never needs.
  SP="$PYDIR/lib/python${PY_VER%.*}/site-packages"
  "${RUN_PY[@]}" -m pip uninstall --quiet -y pip setuptools 2>/dev/null || true
  rm -rf "$PYDIR/lib/python${PY_VER%.*}"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3,pydoc_data} \
         "$SP"/numpy/{_core,lib,linalg,fft,random,polynomial,ma,testing}/tests \
         "$SP"/onnxruntime/{datasets,tools} "$SP"/pymupdf/mupdf-devel 2>/dev/null || true
  find "$PYDIR" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
  touch "$PYDIR/.deps-ok"
fi

# ---------------------------------------------------------------- 3. Assemble the bundle
echo "▸ Assembling $APP…"
rm -rf "$RES"
mkdir -p "$RES"
cp NarrateApp/Resources/Info.plist "$CONTENTS/Info.plist"
echo -n "APPL????" > "$CONTENTS/PkgInfo"
rsync -a --exclude "__pycache__" engine/ "$RES/engine/"
rsync -a --exclude ".deps-ok" "$PYDIR/" "$RES/python/"

if [[ ! -f "$BUILD/AppIcon.icns" ]] || [[ NarrateApp/Resources/make-icon.swift -nt "$BUILD/AppIcon.icns" ]]; then
  echo "▸ Rendering app icon…"
  rm -rf "$BUILD/AppIcon.iconset"
  xcrun swift -module-cache-path "$MODCACHE" NarrateApp/Resources/make-icon.swift "$BUILD/AppIcon.iconset" >/dev/null
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$RES/AppIcon.icns"

# ---------------------------------------------------------------- 4. Sign
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "▸ Signing with $SIGN_IDENTITY (hardened runtime)…"
  # Inside-out: every Mach-O in the embedded runtime first, then the main executable, then the bundle.
  find "$RES/python" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -u+x \) -print0 \
    | while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q "Mach-O"; then sign "$f" >/dev/null 2>&1 || true; fi
      done
  sign "$CONTENTS/MacOS/Narrate" >/dev/null
  sign "$APP" >/dev/null
  codesign --verify --deep --strict "$APP"
else
  echo "▸ Signing (ad hoc — set SIGN_IDENTITY for a distributable build)…"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
fi
xattr -cr "$APP" 2>/dev/null || true
touch "$APP"                                          # make Finder refresh the icon
echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))."

$make_dmg || exit 0

# ---------------------------------------------------------------- 5. Notarize the app (optional)
notarize() {   # notarize <zip-or-dmg>
  echo "▸ Notarizing $(basename "$1")… (waits for Apple, usually a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
if [[ -n "$NOTARY_PROFILE" ]]; then
  [[ -n "$SIGN_IDENTITY" ]] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY too"; exit 1; }
  ditto -c -k --keepParent "$APP" "$BUILD/Narrate.zip"
  notarize "$BUILD/Narrate.zip"
  xcrun stapler staple "$APP"
  rm -f "$BUILD/Narrate.zip"
fi

# ---------------------------------------------------------------- 6. Disk image
DMG="dist/Narrate-${VERSION}-${ARCH}.dmg"
echo "▸ Creating $DMG…"
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE" "$DMG" "$BUILD/Narrate-rw.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$BUILD/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
hdiutil create -quiet -volname "Narrate" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$BUILD/Narrate-rw.dmg"
# Give the mounted volume the app icon and a tidy "drag to Applications" window before compressing.
MOUNT=$(hdiutil attach -readwrite -noverify -nobrowse "$BUILD/Narrate-rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
SetFile -a C "$MOUNT" 2>/dev/null || true
osascript >/dev/null 2>&1 <<EOF || true
tell application "Finder"
  tell disk "Narrate"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 160, 760, 520}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set position of item "Narrate.app" of container window to {140, 170}
    set position of item "Applications" of container window to {420, 170}
    close
  end tell
end tell
EOF
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$BUILD/Narrate-rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$BUILD/Narrate-rw.dmg"
rm -rf "$STAGE"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
  fi
fi
echo "✓ $DMG ($(du -sh "$DMG" | cut -f1)) — this is the file to share."
