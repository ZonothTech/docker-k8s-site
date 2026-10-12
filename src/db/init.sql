-- Optional bootstrap for the Pinboard database.
-- The API creates this table itself on first start; this file exists so that
-- labs can show Postgres' /docker-entrypoint-initdb.d mechanism.
CREATE TABLE IF NOT EXISTS notes (
  id         BIGSERIAL PRIMARY KEY,
  text       TEXT NOT NULL,
  author     TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO notes (text, author) VALUES ('Hello from init.sql 👋', 'postgres')
ON CONFLICT DO NOTHING;
