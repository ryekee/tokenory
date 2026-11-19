# Mechanical HUD

Enable **Show HUD / 显示 HUD** from the menu bar or Settings → HUD. Settings offers six positions in a 2 × 3 grid. The selected position, visibility, metric and audio preferences persist. The visible HUD follows the display containing the pointer (checked every 250 ms, without Accessibility permission). Placement uses that display’s visible frame to avoid the menu bar and Dock; the case sits 5 pt inside the vertical edges. Corner side margins equal the bottom case margin (including Dock) multiplied by the full screen aspect ratio, with side-Dock avoidance taking priority. Reopening the HUD or changing display geometry reapplies the selected position. Position is controlled through the six presets.

When a player opens a macOS full-screen Space, the HUD stays on the desktop and reappears automatically when you return. The rollers stay quiet while the panel is outside the active Space.

The native counter uses 50% of the original dimensions: 210 × 82 pt for the case, 220 × 92 pt including transparent margins. Older saved window dimensions are replaced with this compact size.

The text-fragment button selects exact integer Tokens with digit grouping and no M suffix; the coin selects USD cost. $ appears before the cost drums. The menu bar visibility row shows its checkmark after the label. Values use `UsageStore.today`, an all-agent query independent of dashboard date/model/tool filters. Codex log create/modify notifications trigger a 250 ms coalesced refresh of changed files. A 500 ms metadata check of active logs covers repeated writes through an open file descriptor, which macOS FSEvents may coalesce. The existing parser append cache and stable event keys preserve exact usage and deduplication. Headless capture changes use a Codex-wide reconciliation so the corresponding rollout can suppress duplicate captures. A todayUsageChanged event refreshes the daily counter immediately after persistence; incoming values extend the current roll. Periodic full scans remain for recovery and other agents. No estimated consumption is introduced. HUD and menu-bar Today query the device-local midnight-to-midnight timestamp interval (inclusive start, exclusive end). The next midnight is computed with calendar arithmetic for 23/25-hour DST days; timezone/day-change notifications and wake events refresh it. Date-only imported totals retain their recorded day because they cannot be split into another timezone. Historical reporting buckets are not rewritten. Unknown estimates display —; partial prices display ≈ with the known subtotal and explanatory help. A failed today query displays unavailable until a successful refresh.

The speaker button directly toggles roller sound, with its icon and pressed state reflecting the setting. Muting stops active sound immediately. Volume is adjusted in Settings; the independent sound switch and 0–100% volume both persist. Hide the HUD through the menu bar or Settings. First use defaults to HUD off, sound off, 35% volume.

The rolling curve allocates 16% of its duration to acceleration, 18% to cruising and 66% to deceleration. When the entire increment fits in the visible units travel (up to 30 steps), a higher drum eases into its next digit over the last fifth of the lower cycle and arrives at the carry boundary. For example, the tens drum begins moving at 128 and settles at 130 on a 123-to-135 roll. Larger increments use the original bounded visual rotations. Clicks follow visible digit crossings. Incoming increments retarget from the current position and velocity on the same animation clock. Initial display, day/metric changes, downward corrections and Reduce Motion settle without rolling or sound. Hiding destroys the hosted view and stops audio.

Native owners: `HUDReading`, `HUDAnimator`, `HUDPreferences`, `HUDController`, `HUDSound`, `MechanicalHUDView`, `HUDSettingsView`. Saira Extra Condensed SemiBold and its SIL license are bundled under Resources/Fonts. XcodeGen discovers these resources through the existing source declaration.

## Website prototype

The original prototype and font license live in `docs/prototypes/mechanical-hud/`. Each click in the homepage demo sends one simulated model turn into the counter, with API-equivalent cost computed from bundled rates. A single click follows the shape of `HUDRoll`'s 4.2-second curve. Rapid clicks retarget the same roll, capped at six seconds from its start. One numeric trajectory drives the visible odometer. A higher drum eases through its carry over the last 80% of the lower cycle and lands at the exact digit boundary. Large increments can skip intermediate teeth so the demo settles at the exact cumulative value by the deadline. Further clicks in the same burst update the settled value without another roll.

## Verification

Each readout render captures one immutable drum-position snapshot. Deferred SwiftUI children use that snapshot for both indices and values, including while a day refresh clears the reading or a correction reduces its digit count. This addresses the `MechanicalHUDView.readout` array-bounds crash reported on 2026-11-17 in 0.1.6 (8).

`xcodebuild test -project macos/Tokenory.xcodeproj -scheme Tokenory -derivedDataPath .build/xcode -destination 'platform=macOS'`

`script/build_and_run.sh --verify`

HUDTests covers exact large integers, cost rounding/missing/partial data, carry, monotone deceleration, midnight and metric resets, continuous retargeting and frequent updates, silent reduced motion, preferences and bundled font/localizations. UsageStoreTests covers day-query generation protection and failed-query state. Real-window checks and current results are recorded in the implementation plan.
