BEGIN;
CREATE TABLE codex_activity_threads (
    id TEXT PRIMARY KEY NOT NULL CHECK(length(id) > 0),
    parent_id TEXT,
    depth INTEGER NOT NULL CHECK(depth >= 0),
    name TEXT,
    provider TEXT,
    started_ms INTEGER NOT NULL CHECK(started_ms > 0),
    date TEXT NOT NULL,
    CHECK((depth = 0 AND parent_id IS NULL)
          OR (depth > 0 AND parent_id IS NOT NULL AND length(parent_id) > 0 AND parent_id <> id))
);
CREATE INDEX codex_activity_thread_date ON codex_activity_threads(date, depth);
CREATE TABLE codex_activity_aliases (
    ledger_id TEXT NOT NULL CHECK(length(ledger_id) > 0),
    thread_id TEXT NOT NULL REFERENCES codex_activity_threads(id) ON DELETE CASCADE,
    PRIMARY KEY(ledger_id, thread_id)
);
CREATE TABLE codex_main_turn_starts (
    thread_id TEXT NOT NULL REFERENCES codex_activity_threads(id) ON DELETE CASCADE,
    turn_id TEXT NOT NULL CHECK(length(turn_id) > 0),
    started_ms INTEGER NOT NULL CHECK(started_ms > 0),
    date TEXT NOT NULL,
    model TEXT,
    model_conflicted INTEGER NOT NULL CHECK(model_conflicted IN (0, 1)),
    CHECK(model_conflicted = 0 OR model IS NULL),
    PRIMARY KEY(thread_id, turn_id)
);
CREATE INDEX codex_main_turn_starts_date ON codex_main_turn_starts(date);
PRAGMA user_version=6;
COMMIT;
