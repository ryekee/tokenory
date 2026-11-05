CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE reprice_previews (id INTEGER PRIMARY KEY, body TEXT NOT NULL);
PRAGMA user_version=2;
