#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIGURATION="${TOKENORY_CONFIGURATION:-Debug}"
if [[ -x "$ROOT_DIR/.tools/cargo/bin/cargo" ]]; then
  export CARGO_HOME="$ROOT_DIR/.tools/cargo" RUSTUP_HOME="$ROOT_DIR/.tools/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
if [[ "$CONFIGURATION" == Release ]]; then
  cargo build --manifest-path cli/Cargo.toml -p tokenory --release
else
  cargo build --manifest-path cli/Cargo.toml -p tokenory
fi
xcodegen generate --spec macos/project.yml
xcodebuild -project macos/Tokenory.xcodeproj -scheme Tokenory -configuration "$CONFIGURATION" -derivedDataPath .build/xcode -destination 'platform=macOS' build
printf '%s\n' "$ROOT_DIR/.build/xcode/Build/Products/$CONFIGURATION/Tokenory.app"
