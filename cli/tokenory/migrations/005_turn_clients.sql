BEGIN;
CREATE TABLE turn_analytics_migration (
    id TEXT PRIMARY KEY,
    date TEXT NOT NULL,
    model TEXT NOT NULL,
    body TEXT NOT NULL,
    client TEXT NOT NULL DEFAULT 'codex'
);
INSERT INTO turn_analytics_migration(id,date,model,body,client)
SELECT id,date,model,body,COALESCE(json_extract(body,'$.client'),'codex') FROM codex_turns;
DROP TABLE codex_turns;
ALTER TABLE turn_analytics_migration RENAME TO codex_turns;
CREATE INDEX codex_turns_date_model ON codex_turns(date,model);
CREATE INDEX turn_analytics_client_date ON codex_turns(client,date,model);
PRAGMA user_version=5;
COMMIT;
