-- crafting_db — owned exclusively by crafting-service.
-- Applied at boot by src/db/migrate.ts, and mounted by the team deployment for a fresh volume.

CREATE TABLE IF NOT EXISTS recipes (
  recipe_id               TEXT PRIMARY KEY,
  name                    TEXT NOT NULL,
  category                TEXT NOT NULL,
  description             TEXT,
  output_item_id          TEXT NOT NULL,
  output_count            INT  NOT NULL DEFAULT 1,
  required_facility       TEXT,
  required_facility_level INT
);

CREATE TABLE IF NOT EXISTS recipe_inputs (
  recipe_id TEXT NOT NULL REFERENCES recipes(recipe_id) ON DELETE CASCADE,
  item_id   TEXT NOT NULL,
  count     INT  NOT NULL,
  PRIMARY KEY (recipe_id, item_id)
);

CREATE TABLE IF NOT EXISTS recipe_unlocks (
  recipe_id       TEXT NOT NULL REFERENCES recipes(recipe_id) ON DELETE CASCADE,
  condition_type  TEXT NOT NULL,
  condition_value TEXT NOT NULL,
  PRIMARY KEY (recipe_id, condition_type, condition_value)
);

-- The craft job is the local source of truth for the saga. The unique index on the caller's
-- idempotency key is the gate: on conflict the stored result is returned and nothing is crafted.
CREATE TABLE IF NOT EXISTS craft_jobs (
  job_id          UUID PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  player_id       TEXT NOT NULL,
  recipe_id       TEXT NOT NULL REFERENCES recipes(recipe_id),
  status          TEXT NOT NULL,
  consume_tx_id   TEXT,
  deliver_ref     TEXT,
  response        JSONB,
  status_code     INT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS craft_jobs_player_idx ON craft_jobs (player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS craft_jobs_status_idx ON craft_jobs (status);

-- Replay protection for the mutating endpoints that are not crafts.
CREATE TABLE IF NOT EXISTS craft_events (
  idempotency_key TEXT PRIMARY KEY,
  base_id         UUID,
  kind            TEXT NOT NULL,
  payload         JSONB,
  response        JSONB,
  status_code     INT NOT NULL DEFAULT 200,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
