BEGIN;
CREATE TABLE IF NOT EXISTS codex_turns (
    id TEXT PRIMARY KEY,
    date TEXT NOT NULL,
    model TEXT NOT NULL,
    body TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS codex_turns_date_model ON codex_turns(date,model);
PRAGMA user_version=4;
COMMIT;
