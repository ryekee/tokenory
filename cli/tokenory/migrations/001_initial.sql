CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
INSERT INTO meta VALUES ('revision', 0);
CREATE TABLE usage_records (
    source TEXT NOT NULL, batch_id TEXT NOT NULL DEFAULT '', item_key TEXT NOT NULL,
    date TEXT NOT NULL, client TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
    input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL,
    cache_write INTEGER NOT NULL, reasoning INTEGER NOT NULL, tokens INTEGER NOT NULL,
    estimated_cost REAL, source_cost REAL, requests INTEGER, body TEXT NOT NULL,
    PRIMARY KEY (source, batch_id, item_key)
);
CREATE INDEX usage_date_client ON usage_records(date, client);
CREATE INDEX usage_model_provider ON usage_records(model, provider);
CREATE TABLE coverage_choices (
    date TEXT NOT NULL, client TEXT NOT NULL, source TEXT NOT NULL, batch_id TEXT NOT NULL DEFAULT '',
    PRIMARY KEY(date, client)
);
CREATE TABLE import_previews (id INTEGER PRIMARY KEY, source TEXT NOT NULL, content_hash TEXT NOT NULL, body TEXT NOT NULL);
CREATE TABLE import_batches (
    id INTEGER PRIMARY KEY, source TEXT NOT NULL, content_hash TEXT NOT NULL,
    created_at TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, body TEXT NOT NULL
);
CREATE UNIQUE INDEX active_import_content ON import_batches(source,content_hash) WHERE active=1;
CREATE TABLE price_snapshots (id TEXT PRIMARY KEY, created_at TEXT NOT NULL, body TEXT NOT NULL);
CREATE TABLE scan_runs (id INTEGER PRIMARY KEY, started_at TEXT NOT NULL, body TEXT NOT NULL);
CREATE VIEW effective_usage AS
SELECT r.* FROM usage_records r JOIN coverage_choices c
ON r.date=c.date AND r.client=c.client AND r.source=c.source AND r.batch_id=c.batch_id;
PRAGMA user_version=1;
