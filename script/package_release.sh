#!/usr/bin/env bash
# Build a signed, notarized GitHub release with bilingual Sparkle notes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
NOTES="${1:?usage: package_release.sh RELEASE_NOTES.json}"
SIGNING_TEMP="$(mktemp -d)"
NOTES_SNAPSHOT="$SIGNING_TEMP/release-notes.json"
trap 'rm -f "$NOTES_SNAPSHOT" "$SIGNING_TEMP/embedded.provisionprofile" "$SIGNING_TEMP/CloudKit.entitlements"; rmdir "$SIGNING_TEMP"' EXIT
cp "$NOTES" "$NOTES_SNAPSHOT"
python3 ./script/release_notes.py "$NOTES_SNAPSHOT" > /dev/null
IDENTITY="${TOKENORY_SIGNING_IDENTITY:-Developer ID Application: Shenzhen Hiko Technology Co., Ltd. (JQTFJ8P2T7)}"
PROFILE="${TOKENORY_NOTARY_PROFILE:-Hiko-notray}"
ACCOUNT="ee.ryek.tokenory"
PROFILE_OPTIONS=(--identity "$IDENTITY" --out "$SIGNING_TEMP")
if [[ -n "${TOKENORY_DEVELOPER_ID_PROFILE:-}" ]]; then
    PROFILE_OPTIONS+=(--profile "$TOKENORY_DEVELOPER_ID_PROFILE")
fi
IDENTITY="$(python3 ./script/cloudkit_release_profile.py prepare "${PROFILE_OPTIONS[@]}")"
TOKENORY_CONFIGURATION=Release ./script/build.sh
BUILT_APP="$ROOT_DIR/.build/xcode/Build/Products/Release/Tokenory.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
OUT="$ROOT_DIR/.build/releases/v$VERSION"
[[ ! -e "$OUT/Tokenory.app" ]] || { echo "Release directory already contains an app: $OUT" >&2; exit 1; }
mkdir -p "$OUT"
cp "$NOTES_SNAPSHOT" "$OUT/release-notes.json"
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
    "$APP/Contents/Helpers/tokenory"; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$component"
done
cp "$SIGNING_TEMP/embedded.provisionprofile" "$APP/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements "$SIGNING_TEMP/CloudKit.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
python3 ./script/cloudkit_release_profile.py verify "$APP" "$SIGNING_TEMP/CloudKit.entitlements"
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
"$ROOT_DIR/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --account "$ACCOUNT" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/ryekee/tokenory/releases/download/v$VERSION/" \
    --link "https://github.com/ryekee/tokenory/releases/tag/v$VERSION" "$OUT"
python3 ./script/release_notes.py "$OUT/release-notes.json" --appcast "$OUT/appcast.xml"
(cd "$OUT" && shasum -a 256 "$ARCHIVE" appcast.xml > SHA256SUMS.txt)
printf 'Release artifacts: %s\n' "$OUT"
