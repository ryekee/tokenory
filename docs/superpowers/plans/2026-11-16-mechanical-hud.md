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
