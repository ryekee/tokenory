# Mechanical HUD

Enable **Show HUD / 显示 HUD** from the menu bar or Settings → HUD. Right-click to hide. Settings offers six positions in a 2 × 3 grid. The selected position, visibility, metric and audio preferences persist. The visible HUD follows the display containing the pointer (checked every 250 ms, without Accessibility permission). Placement uses that display’s visible frame to avoid the menu bar and Dock; the case sits 5 pt inside the vertical edges. Corner side margins equal the bottom case margin (including Dock) multiplied by the full screen aspect ratio, with side-Dock avoidance taking priority. Reopening the HUD or changing display geometry reapplies the selected position. Position is controlled through the six presets.

The native counter uses 50% of the original dimensions: 210 × 82 pt for the case, 220 × 92 pt including transparent margins. The audio popover stays at normal size. Older saved window dimensions are replaced with this compact size.

The text-fragment button selects exact integer Tokens with digit grouping and no M suffix; the coin selects USD cost. $ appears before the cost drums. The menu bar visibility row shows its checkmark after the label. Values use `UsageStore.today`, an all-agent query independent of dashboard date/model/tool filters. Codex log create/modify notifications trigger a 250 ms coalesced refresh of changed files. A 500 ms metadata check of active logs covers repeated writes through an open file descriptor, which macOS FSEvents may coalesce. The existing parser append cache and stable event keys preserve exact usage and deduplication. Headless capture changes use a Codex-wide reconciliation so the corresponding rollout can suppress duplicate captures. A todayUsageChanged event refreshes the daily counter immediately after persistence; incoming values extend the current roll. Periodic full scans remain for recovery and other agents. No estimated consumption is introduced. HUD and menu-bar Today query the device-local midnight-to-midnight timestamp interval (inclusive start, exclusive end). The next midnight is computed with calendar arithmetic for 23/25-hour DST days; timezone/day-change notifications and wake events refresh it. Date-only imported totals retain their recorded day because they cannot be split into another timezone. Historical reporting buckets are not rewritten. Unknown estimates display —; partial prices display ≈ with the known subtotal and explanatory help. A failed today query displays unavailable until a successful refresh.

The speaker button opens audio controls. Sound has its own switch and 0–100% volume; both persist. The same switch and volume controls are in Settings. First use defaults to HUD off, sound off, 35% volume.

The rolling curve allocates 16% of its duration to acceleration, 18% to cruising and 66% to deceleration. Each drum settles on the exact integer digit; large deltas use bounded visual rotations. Clicks follow visible digit crossings, rather than an unrelated loop. Incoming increments extend the current roll immediately. Each changed drum starts its new path at its current position and velocity, then brakes monotonically to the latest target. The animation clock stays continuous and unchanged drums keep their original path. Repeated updates bound remaining visual revolutions rather than building a queue. Initial display, day/metric changes, downward corrections and Reduce Motion settle without rolling or sound. Hiding destroys the hosted view and stops audio.

Native owners: `HUDReading`, `HUDAnimator`, `HUDPreferences`, `HUDController`, `HUDSound`, `MechanicalHUDView`, `HUDSettingsView`. Saira Extra Condensed SemiBold and its SIL license are bundled under Resources/Fonts. XcodeGen discovers these resources through the existing source declaration.

## Website prototype

The approved interactive demo is retained in `docs/prototypes/mechanical-hud/index.html` with its font license. It is a standalone static page with embedded font and synthesized Web Audio. Open directly or serve statically; no dependencies or build step. Its simulated values are deliberately separate from the native ledger. Do not remove it during temporary-file cleanup.

## Verification

`xcodebuild test -project macos/Tokenory.xcodeproj -scheme Tokenory -derivedDataPath .build/xcode -destination 'platform=macOS'`

`script/build_and_run.sh --verify`

HUDTests covers exact large integers, cost rounding/missing/partial data, carry, monotone deceleration, midnight and metric resets, continuous retargeting and frequent updates, silent reduced motion, preferences and bundled font/localizations. UsageStoreTests covers day-query generation protection and failed-query state. Real-window checks and current results are recorded in the implementation plan.
