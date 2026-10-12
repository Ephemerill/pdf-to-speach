#!/bin/zsh
# Ships a release: Developer ID signed + notarized build, GitHub Release, and the Sparkle appcast.
#
#   ./release.sh            uses the version in NarrateApp/Resources/Info.plist and release-notes/<version>.md
#
# What it does:
#   1. ./build.sh --dmg, signed with the Developer ID and notarized (app and DMG, tickets stapled)
#   2. zips the stapled app (the Sparkle update archive — also what 2.4's old in-app updater fetches)
#   3. signs the zip with the EdDSA key in the keychain (generate_keys --account narrate)
#   4. creates GitHub release v<version> with the DMG + zip and the notes
#   5. adds the update to appcast.xml on the gh-pages branch (served by GitHub Pages at SUFeedURL)
#
# Needs, once per Mac:
#   - the "Developer ID Application" certificate in the keychain
#   - xcrun notarytool store-credentials narrate --apple-id … --team-id 86L5N846P4
#   - the Sparkle key: build/sparkle-*/bin/generate_keys --account narrate (back it up with -x!)
#   - gh auth login
set -euo pipefail
cd "$(dirname "$0")"

export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: GABRIEL JONATHAN LOSH (86L5N846P4)}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-narrate}"
REPO="Ephemerill/pdf-to-speach"
PAGES="https://ephemerill.github.io/pdf-to-speach"
PLIST=NarrateApp/Resources/Info.plist
VERSION=$(plutil -extract CFBundleShortVersionString raw $PLIST)
BUILD_NUMBER=$(plutil -extract CFBundleVersion raw $PLIST)
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw $PLIST)
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"

[[ -f "$NOTES" ]] || { echo "Write $NOTES first."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first (the release is tagged at HEAD)."; exit 1; }
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "$TAG is already released."; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || { echo "No notary profile '$NOTARY_PROFILE'."; exit 1; }

echo "▸ Building Narrate $VERSION ($BUILD_NUMBER), signed + notarized…"
./build.sh --dmg
spctl --assess --type execute -vv dist/Narrate.app
DMG="dist/Narrate-$VERSION-arm64.dmg"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo "▸ Update archive…"
rm -f dist/Narrate.zip
ditto -c -k --sequesterRsrc --keepParent dist/Narrate.app dist/Narrate.zip
SPARKLE_BIN=$(ls -d build/sparkle-*/bin | tail -1)
ED=$("$SPARKLE_BIN/sign_update" --account narrate dist/Narrate.zip)       # sparkle:edSignature="…" length="…"
cp "$DMG" dist/Narrate.dmg                                                  # stable name for the README's "latest" link

echo "▸ GitHub release $TAG…"
git push origin HEAD
gh release create "$TAG" "$DMG" dist/Narrate.dmg dist/Narrate.zip --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "Narrate $TAG" --notes-file "$NOTES"

echo "▸ Appcast…"
WT=build/gh-pages
git worktree remove --force "$WT" 2>/dev/null || true
git fetch origin gh-pages 2>/dev/null || true
if git rev-parse --verify -q origin/gh-pages >/dev/null; then
  git worktree add -B gh-pages "$WT" origin/gh-pages
else
  git worktree add --detach "$WT"
  (cd "$WT" && git checkout --orphan gh-pages && git rm -rfq . && git clean -fdq)
fi
/usr/bin/python3 - "$WT/appcast.xml" "$VERSION" "$BUILD_NUMBER" "$MIN_OS" "$NOTES" "$ED" \
  "https://github.com/$REPO/releases/download/$TAG/Narrate.zip" "$PAGES" <<'PY'
import html, os, re, sys
from email.utils import formatdate
path, version, build, min_os, notes_path, ed, url, pages = sys.argv[1:]

def md_to_html(md: str) -> str:
    out, in_list = [], False
    for line in md.splitlines():
        line = line.rstrip()
        text = html.escape(line.lstrip("-#* ").strip())
        text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
        if line.startswith(("- ", "* ")):
            if not in_list: out.append("<ul>"); in_list = True
            out.append(f"<li>{text}</li>"); continue
        if in_list: out.append("</ul>"); in_list = False
        if line.startswith("#"): out.append(f"<h3>{text}</h3>")
        elif text: out.append(f"<p>{text}</p>")
    if in_list: out.append("</ul>")
    return "\n".join(out)

item = f"""    <item>
      <title>Narrate {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{md_to_html(open(notes_path).read())}
      ]]></description>
      <enclosure url="{url}" type="application/octet-stream" {ed} />
    </item>
"""
if os.path.exists(path):
    feed = open(path).read()
    feed = feed.replace("    <item>", item + "    <item>", 1) if "<item>" in feed else feed.replace("  </channel>", item + "  </channel>")
else:
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Narrate</title>
    <link>{pages}/appcast.xml</link>
    <description>Updates for Narrate</description>
    <language>en</language>
{item}  </channel>
</rss>
"""
open(path, "w").write(feed)
PY
cat > "$WT/index.html" <<HTML
<!doctype html><meta charset="utf-8"><title>Narrate</title>
<meta http-equiv="refresh" content="0; url=https://github.com/$REPO/releases/latest">
<p>Narrate's update feed lives here (<a href="appcast.xml">appcast.xml</a>). Downloads: <a href="https://github.com/$REPO/releases/latest">latest release</a>.</p>
HTML
touch "$WT/.nojekyll"
(cd "$WT" && git add -A && git commit -qm "Appcast: Narrate $VERSION" && git push -q origin gh-pages)
git worktree remove --force "$WT"

# First release through Pages: switch Pages on for the branch.
gh api "repos/$REPO/pages" >/dev/null 2>&1 || \
  gh api -X POST "repos/$REPO/pages" -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null

echo "✓ Narrate $VERSION released: https://github.com/$REPO/releases/tag/$TAG"
echo "  Appcast: $PAGES/appcast.xml (Pages can take a minute to publish)"
