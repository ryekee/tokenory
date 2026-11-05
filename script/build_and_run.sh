#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) echo 'usage: build_and_run.sh [--debug|--logs|--telemetry|--verify]' >&2; exit 2 ;; esac
if pgrep -x Tokenory >/dev/null; then
  osascript -e 'tell application id "ee.ryek.tokenory" to quit'
fi
"$ROOT_DIR/script/build.sh"
APP_BUNDLE="$ROOT_DIR/.build/xcode/Build/Products/${TOKENORY_CONFIGURATION:-Debug}/Tokenory.app"
if [[ "$MODE" == --debug ]]; then exec lldb -- "$APP_BUNDLE/Contents/MacOS/Tokenory"; fi
/usr/bin/open "$APP_BUNDLE"
case "$MODE" in
 --verify) sleep 1; pgrep -x Tokenory ;;
 --logs|--telemetry) /usr/bin/log stream --info --style compact --predicate 'process == "Tokenory"' ;;
esac
