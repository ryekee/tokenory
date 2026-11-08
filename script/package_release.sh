#!/usr/bin/env bash
# Build a signed, notarized GitHub release with a matching Sparkle feed.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
NOTES="${1:?usage: package_release.sh RELEASE_NOTES.md}"
[[ -f "$NOTES" ]]
IDENTITY="${TOKENORY_SIGNING_IDENTITY:-Developer ID Application: Shenzhen Hiko Technology Co., Ltd. (JQTFJ8P2T7)}"
PROFILE="${TOKENORY_NOTARY_PROFILE:-Hiko-notray}"
ACCOUNT="ee.ryek.tokenory"
TOKENORY_CONFIGURATION=Release ./script/build.sh
BUILT_APP="$ROOT_DIR/.build/xcode/Build/Products/Release/Tokenory.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
OUT="$ROOT_DIR/.build/releases/v$VERSION"
[[ ! -e "$OUT/Tokenory.app" ]] || { echo "Release directory already contains an app: $OUT" >&2; exit 1; }
mkdir -p "$OUT"
cp "$NOTES" "$OUT/release-notes.md"
ditto "$BUILT_APP" "$OUT/Tokenory.app"
APP="$OUT/Tokenory.app"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Sign nested code from the inside out so every bundled executable has our Team ID.
for component in \
    "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK/Versions/B/Autoupdate" \
    "$FRAMEWORK/Versions/B/Updater.app" \
    "$FRAMEWORK" \
    "$APP/Contents/Helpers/tokenory" \
    "$APP"; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$component"
done
codesign --verify --deep --strict "$APP"
ARCHIVE="Tokenory-$VERSION-macOS-arm64.zip"
ditto -c -k --keepParent "$APP" "$OUT/$ARCHIVE"
xcrun notarytool submit "$OUT/$ARCHIVE" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/notarization.json"
python3 - "$OUT/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization failed: {result}")
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# Stapling changes the archive. Sparkle must sign the final bytes served to users.
ditto -c -k --keepParent "$APP" "$OUT/$ARCHIVE"
cp "$NOTES" "$OUT/${ARCHIVE%.zip}.md"
"$ROOT_DIR/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --account "$ACCOUNT" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/ryekee/tokenory/releases/download/v$VERSION/" \
    --link "https://github.com/ryekee/tokenory/releases/tag/v$VERSION" "$OUT"
(cd "$OUT" && shasum -a 256 "$ARCHIVE" appcast.xml > SHA256SUMS.txt)
printf 'Release artifacts: %s\n' "$OUT"
