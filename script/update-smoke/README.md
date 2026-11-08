# Public update regression

This test driver compiles the production `UpdateChecker.swift`. It replaces only Sparkle's UI responses, so the real feed, request headers, downloader, signature validation, installer and relauncher are exercised. It does not verify button appearance or accessibility.

Compile the Objective-C driver and Swift entry point against the pinned Sparkle artifact after `script/build.sh` has resolved packages:

```sh
mkdir -p .build/update-smoke
SPARKLE_DIR="$PWD/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
clang -fobjc-arc -F "$SPARKLE_DIR" -c script/update-smoke/Driver.m -o .build/update-smoke/Driver.o
swiftc -parse-as-library -swift-version 6 -import-objc-header script/update-smoke/Driver.h \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_DIR" \
  macos/Tokenory/Services/UpdateChecker.swift script/update-smoke/main.swift \
  .build/update-smoke/Driver.o -o .build/update-smoke/smoke
```

Use only a disposable signed app under `.build/update-smoke/`, with a separate `SUDefaultsDomain` in its Info.plist. Give the test copy a lower build number and re-sign it with the same Developer ID. Keep the production feed URL and public key. Run the copy with `open -n --env TOKENORY_TESTING=1 PATH` to avoid starting collection during the test.

`smoke ABSOLUTE_APP_PATH update` accepts the real public update and verifies installation/relaunch callbacks. Inspect the installed bundle version and signature afterwards. `smoke ABSOLUTE_APP_PATH current` verifies that the same production feed reports the current release as up to date.

The update replaces the test copy's Info.plist, including its temporary defaults domain. Before the `current` test, restore the isolated domain and re-sign the test copy. Stop the test app and remove the temporary app, binary, object and defaults domain when finished. Keep the verification logs with the release evidence.
