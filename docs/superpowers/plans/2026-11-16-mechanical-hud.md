# Mechanical HUD Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task. User approved the prototype and explicitly requested implementation; no further design approval is pending.

**Goal:** Ship the approved mechanical HUD with real daily totals and persistent audio controls; retain the website prototype.

**Architecture:** Reuse UsageStore's independent today query. A pure HUD reading/roll model feeds a SwiftUI drum display in an AppKit NSPanel. An observable preferences object persists UI settings; a short PCM sample supplies synchronized mechanical clicks.

**Tech Stack:** Swift 6, SwiftUI, AppKit, AVFoundation, XCTest; existing Rust worker remains unchanged.

**Spec:** `docs/superpowers/specs/2026-11-16-mechanical-hud-design.md`

## Global Constraints
- Preserve prototype and font license in tracked docs/prototypes/mechanical-hud.
- All new UI copy uses the en/zh-Hans String Catalog.
- Keep today's total independent of dashboard filters; unknown cost never becomes zero.
- Update Xcode configuration through macos/project.yml and XcodeGen.

## Review Focus
- Midnight, wake and late responses: no previous-day readout or audible reset.
- Partial/unknown estimates: mark partial, show unavailable for unknown.
- Updates during animation: converge to newest value without mid-roll jumps.
- Hide/reopen, mute and Reduce Motion: no background animation or leftover audio.
- Digit carry, large totals and saved offscreen positions: legible exact final values.

### Task 1: Reading, motion and preferences
**Files:** Models/HUDReading.swift, Stores/HUDPreferences.swift, Services/HUDAnimator.swift, TokenoryTests/HUDTests.swift.
**Interfaces:** HUDReading(day:metric:summary:); HUDRoll(from:to:); HUDPreferences(defaults:); HUDAnimator.receive(_:animated:).
- [x] Add tests for cost conversion/unknown/partial, day transitions, carry, braking curve, coalesced updates, preference persistence.
- [x] Observe failure before implementation, implement and run native focused tests.

### Task 2: Native surface and real data
**Files:** Views/MechanicalHUDView.swift, Views/HUDSettingsView.swift, Services/HUDController.swift, Services/HUDSound.swift; App/TokenoryApp.swift, Views/MenuBarView.swift, Views/SettingsView.swift, Stores/UsageStore.swift.
- [x] Reuse today query; expose reporting date and usage error; refresh at midnight and wake.
- [x] Add floating draggable panel, font resource, matching case/drums/icon buttons, mute/volume/preview.
- [x] Verify tests for panel lifecycle, missing data, accessibility/localized labels and font loading.

### Task 3: Delivery and validation
**Files:** docs/prototypes/mechanical-hud, DESIGN.md, module AGENTS.md files, docs/local/mechanical-hud.md.
- [x] Preserve standalone demo and license; document run instructions and data/motion semantics.
- [x] Run native suite and script/build_and_run.sh --verify.
- [x] Inspect real HUD and Settings with actual ledger data, both languages and appearances.
- [x] Review diff and fix material findings; leave source changes reviewable on codex/mechanical-hud.

## Validation ledger — 2026-11-16

- Initial HUD test compilation failed because the new model types did not exist; the implemented focused suite passed 5/5.
- Final native suite: 37 tests, 0 failures (`/tmp/tokenory-hud-final-tests.log`). Covers font/localization, large integers, missing/partial estimates, motion/carry/coalescing, persistence, midnight generation protection and first panel lifecycle.
- Independent review found two issues: default NSPanel content prevented first installation; cancelling a roll on metric/reset could leave audio running. Both fixed. The panel regression test failed before the fix and passes afterward; nonrolling animation generations now explicitly stop audio.
- Project `script/build_and_run.sh --verify` succeeds and launches the app with the real local ledger. No release/version bump or remote publishing.
- Native checks: first show, live totals matching the dashboard's daily row, tokens/cost switch, audio popover, sound enable/disable, volume, preview, hide/reopen and restart persistence. Chinese/English and dark/light Settings were inspected; a Debug-only `--light-appearance` argument scopes light validation to this app. Settings/HUD are fixed-size surfaces; 6- and 9-digit real readings fit.
- Restored Chinese, system appearance, HUD visible, sound off and volume 35%. Local screenshot evidence: `local-data/hud-validation/`.
- Approved HTML and SIL font license retained in tracked `docs/prototypes/mechanical-hud/` for future website reuse.
- Scope decision: native SwiftUI/AppKit implementation and standalone demo remain separate. No Rust/ledger schema changes. Work stays on `codex/mechanical-hud`; unrelated earlier plan is untouched.

## Follow-up: continuous in-flight increments

User requested new totals extend the active roll. Replaced the pending-next-roll queue with per-drum paths that preserve sampled position/velocity and the existing animation clock. Unchanged drums keep their original trajectory; updated drums use monotone Hermite braking with bounded remaining revolutions. Sound follows actual digit-boundary crossings.

Regression tests first failed on delayed reading updates and the second-roll reset. Updated tests pass for unchanged generation, exact position continuity, finite-difference velocity continuity, carry into a new digit, monotone travel, 30 rapid increments without a backlog or phantom clicks, and exact final values. Full native suite: 39 tests, zero failures (`/tmp/tokenory-hud-retarget-suite.log`). The retained website prototype remains intact.

## Follow-up: compact dimensions and edge placement

Scaled the native HUD to 50% on each axis (220 × 92 pt window, 210 × 82 pt case). Settings now offers six persisted positions in a 2 × 3 grid. Placement uses the current display's visibleFrame, keeping the case 5 pt inside the menu bar/Dock-safe area. Display changes and reopening reapply the selected position; dragging remains available within the session.

Full native suite: 40 tests, zero failures (`/tmp/tokenory-hud-placement-tests.log`), including all six coordinates on an offset display, preference persistence and live panel relocation. Build-and-run passed. Actual Chinese/dark Settings verified selection highlighting and switching top-center/bottom-right; the compact HUD and normal-size audio popover were inspected. Evidence: `local-data/hud-validation/placement-settings.png`, `native-hud-compact.png`. English/light placement layout and physical multi-display/Dock changes were not manually exercised. The website prototype remains intact.

## Follow-up: menu checkmark and proportional corner margins

MenuBarView now uses a plain clickable row with a leading checkmark for HUD visibility. Corner placement calculates side case margins as bottom case margin × full screen width / height, including the bottom Dock reservation; visibleFrame containment takes precedence for a side Dock or an ideal margin smaller than transparent padding. Center positions stay unchanged. Full native suite passed (40 tests), then focused HUD suite passed (12 tests) after adding portrait/side-Dock coverage. Build-and-run passed; this follow-up was not manually inspected in the menu popover.

Realtime investigation: Config defaults to 60 seconds between completed scans; IPC collects then persists before scanFinished/usageChanged, and UsageStore refreshes the HUD data from those events. Hook or file-watch driven collection is a proposed next step, not implemented here. Hooks can reduce scheduling latency but accuracy and cadence still depend on when each agent publishes usage.

## Follow-up: trailing checkmark, M units and Codex research

Moved the menu-row checkmark after its label. Token drums now show millions with six decimals and a trailing M, retaining exact Int64 animation values and single-token precision; sub-million values get a fixed leading zero drum. Cost remains dollar-prefixed. Focused HUD suite passed (13 tests), including zero, one-token, million carry, large values and unchanged cost formatting. Build-and-run passed; real HUD inspected and captured at `local-data/hud-validation/native-hud-millions.png`. Menu popup placement was not manually inspected.

Codex source and local event-metadata investigation is in `docs/local/codex-realtime-usage.md`; realtime ingestion is a proposal only, with no hook installation or ledger changes.

## Follow-up: real Codex updates, integer display and active monitor

Implemented Codex default/extra/headless root watching, 250 ms event coalescing, and 500 ms metadata checks for logs active in this worker session. FSEvents alone failed the real open-descriptor append test; the metadata check fixes this observed gap. Changed files use the existing append-aware parser, validation and stable record keys. Full scans remain the recovery path. Native todayUsageChanged refreshes only the daily summary; HUD retains its current roll position, velocity and clock. No usage estimates or hook installation. Headless capture changes reconcile the Codex lane to preserve cross-file supersession; a regression reproduced 200 instead of 100 tokens before that fix.

Removed M and restored grouped integer Tokens. The visible panel checks pointer display every 250 ms and reapplies the selected safe-area placement only when the display changes; no Accessibility or screen-recording permission is used.

Validation: full tokenory suite passed 90 tests before the final headless regression; final codex_live suite passed all 3 tests. The new-root and open-handle append test measured 274 ms and 328 ms respectively, using temporary fixtures (not production end-to-end latency). Existing tokens-core Codex tests: 124 passed. Native suite: 43 passed, including real log append → worker event → today summary → active roll continuity, plus pointer selection across horizontally and vertically arranged screen rectangles. Build-and-run passed. Live production scan diagnostics showed changed-file collection around 0.36–1.6 seconds in the inspected samples; the startup full scan took about 19 seconds. These are collection durations, not display latency guarantees. Integer HUD inspected in the real app. Physical cursor transfer between monitors has not been manually exercised.
