# Codex Turn Analysis Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the backend task and final independent review. The controller owns native integration.

**Goal:** Integrate the approved real-data slow-turn prototype into Tokenory.

**Architecture:** Collect completed main Codex turns during the existing background scan, cache unchanged files, persist analytics independently of priced usage, and expose a typed `codexTurns` query. The native page lazily loads the selected dates/model, derives full-range summaries, and keeps chart/list selection stable.

**Tech Stack:** Existing Rust/SQLite IPC, Swift 6, SwiftUI, Swift Charts, String Catalog.

**Spec:** `DESIGN.md`, current user-approved `local-data/prototypes/codex-slow-turns/template.html`, and its `README.md` timing findings.

## Global Constraints

- Preserve user edits to DESIGN.md, root AGENTS.md, and copy-review.md. No release/version changes or publication.
- Hero: sum(generated)/sum(duration seconds); arithmetic mean of present TTFT; average reasoning tokens per turn with known reasoning. Missing is not zero.
- Generated includes reasoning, excludes input/cache. Never double-count token_usage_record and token_count.
- No adjusted-speed metric. Tool wait is completed-call log timestamp to paired return, interval union; never create_time or background process lifetime.
- Native panels and controls; shared toolbar date range and page model filter; chronological temporal chart with monotone interpolation across gaps, no synthetic observations.
- List supports duration, speed, reasoning, newest and oldest; chart order stays chronological.
- Minimum window 800pt; list/detail stack below 720pt detail width; numeric totals 32pt; bilingual String Catalog; semantic colors; accessible keyboard/pointer readouts and selection.

## Review Focus

- Replayed events, duplicate responses, subagents, incomplete turns and malformed usage must not produce false totals.
- Background process lifetime and argument generation must not become tool blocking time.
- Unchanged scans must avoid reparsing logs, schema upgrade/restore must preserve existing ledger and backups.
- Rapid date/model changes and scan updates must not publish stale results or reset selection; pagination must not alter summary/chart.
- Empty/missing TTFT, long model/project labels, English/Chinese and narrow light/dark layouts must remain usable.

## Task 1 — Rust analytics (backend agent)

Files: new `cli/tokenory/src/codex_turns.rs`, migration 004, module export, collector/database/IPC integration, focused Rust tests and local module maps.

Interface: `codexTurns` accepts existing Filter dates/model; returns `{revision, models:[String], turns:[CodexTurn]}`. Models are the date-filtered catalog before model filtering. Each turn has `id,sessionId,turnId,project,model,effort?,startMs,endMs,durationMs,ttftMs?,generatedTokens,reasoningTokens?,requests,toolCalls,toolWaitMs?`. All times are integer milliseconds; id stable across scans. Unknown timing stays null. Only completed main Codex turns, from source scanner paths (including configured extra paths). No private prompt/response/tool text persisted.

- [x] Write behavioral parser/persistence/query tests; verify targeted failures.
- [x] Implement boundaries, background cached scanning, storage migration/restore and query.
- [x] Run `cargo test --manifest-path cli/Cargo.toml -p tokenory`; review changes.

## Task 2 — Native presentation (controller)

Files: new Models/CodexTurns.swift, Views/CodexTurnsView.swift and CodexTurnChart.swift; UsageStore, DashboardView, Localizable.xcstrings, native tests and module maps.

- [x] Add typed report and presentation calculations with tests for weighted speed, missing TTFT, stable chronology, sorting and no synthetic gap points.
- [x] Add lazy generation-guarded data loading and refresh after scans, independent of overview pagination.
- [x] Implement approved hero/chart/list/details, native controls, meaningful help and complete bilingual copy.
- [x] Generate Xcode project using project entry point; build/test.

## Task 3 — Acceptance

- [x] Independent whole-change review; address concrete findings.
- [ ] Complete full visual matrix: real data, Chinese light/dark and English light checked; minimum width and English dark remain unverified. See docs/local/codex-turns.md.
- [x] Update design extension, operating instructions and validation evidence; retain delivery artifacts, remove unneeded temporary files.

## Decisions / progress

- User approved implementation directly; proceed without another design approval round.
- Work stays on a feature branch in this shared checkout so current user-owned design changes remain available; agents have disjoint file ownership.
