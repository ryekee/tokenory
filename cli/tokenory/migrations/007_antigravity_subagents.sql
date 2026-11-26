BEGIN;
CREATE TABLE antigravity_subagent_spawns (
    client TEXT NOT NULL CHECK(client IN ('antigravity', 'antigravity-cli')),
    child_id TEXT NOT NULL CHECK(length(child_id) > 0),
    parent_id TEXT NOT NULL CHECK(length(parent_id) > 0 AND parent_id <> child_id),
    name TEXT,
    started_ms INTEGER,
    PRIMARY KEY(client, child_id)
);
PRAGMA user_version=7;
COMMIT;
