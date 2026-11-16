# Mechanical HUD

Enable **Show HUD / 显示 HUD** from the menu bar or Settings → HUD. Drag the orange shell to move it. Right-click to hide. Position, visibility, selected metric and audio preferences persist.

The text-fragment button selects Tokens; the coin selects USD cost. Values use `UsageStore.today`, an all-agent query independent of dashboard date/model/tool filters. Updates arrive after ledger scans, not per generated token. The HUD refreshes at Beijing midnight and when the Mac wakes. Unknown estimates display —; partial prices display ≈ with the known subtotal and explanatory help. A failed today query displays unavailable until a successful refresh.

The speaker button opens audio controls. Sound has its own switch and 0–100% volume; both persist. The same controls and sound preview are in Settings. First use defaults to HUD off, sound off, 35% volume.

The rolling curve allocates 16% of its duration to acceleration, 18% to cruising and 66% to deceleration. Each drum settles on the exact integer digit; large deltas use bounded visual rotations. Clicks follow visible digit crossings, rather than an unrelated loop. Incoming increments extend the current roll immediately. Each changed drum starts its new path at its current position and velocity, then brakes monotonically to the latest target. The animation clock stays continuous and unchanged drums keep their original path. Repeated updates bound remaining visual revolutions rather than building a queue. Initial display, day/metric changes, downward corrections and Reduce Motion settle without rolling or sound. Hiding destroys the hosted view and stops audio.

Native owners: `HUDReading`, `HUDAnimator`, `HUDPreferences`, `HUDController`, `HUDSound`, `MechanicalHUDView`, `HUDSettingsView`. Saira Extra Condensed SemiBold and its SIL license are bundled under Resources/Fonts. XcodeGen discovers these resources through the existing source declaration.

## Website prototype

The approved interactive demo is retained in `docs/prototypes/mechanical-hud/index.html` with its font license. It is a standalone static page with embedded font and synthesized Web Audio. Open directly or serve statically; no dependencies or build step. Its simulated values are deliberately separate from the native ledger. Do not remove it during temporary-file cleanup.

## Verification

`xcodebuild test -project macos/Tokenory.xcodeproj -scheme Tokenory -derivedDataPath .build/xcode -destination 'platform=macOS'`

`script/build_and_run.sh --verify`

HUDTests covers exact large integers, cost rounding/missing/partial data, carry, monotone deceleration, midnight and metric resets, continuous retargeting and frequent updates, silent reduced motion, preferences and bundled font/localizations. UsageStoreTests covers day-query generation protection and failed-query state. Real-window checks and current results are recorded in the implementation plan.
