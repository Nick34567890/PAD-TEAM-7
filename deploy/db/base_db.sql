-- base_db — owned exclusively by base-service.
-- Applied at boot by src/db/migrate.ts, and mounted by the team deployment for a fresh volume.

CREATE TABLE IF NOT EXISTS bases (
  base_id          UUID PRIMARY KEY,
  lobby_id         TEXT NOT NULL UNIQUE,
  home_room_id     TEXT NOT NULL,
  level            INT  NOT NULL DEFAULT 1,
  defense_rating   INT  NOT NULL DEFAULT 10,
  storage_capacity INT  NOT NULL DEFAULT 50,
  storage_used     INT  NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS facilities (
  facility_id UUID PRIMARY KEY,
  base_id     UUID NOT NULL REFERENCES bases(base_id) ON DELETE CASCADE,
  type        TEXT NOT NULL,
  level       INT  NOT NULL DEFAULT 1,
  status      TEXT NOT NULL DEFAULT 'operational',
  UNIQUE (base_id, type)
);

CREATE TABLE IF NOT EXISTS barricades (
  barricade_id UUID PRIMARY KEY,
  base_id      UUID NOT NULL REFERENCES bases(base_id) ON DELETE CASCADE,
  room_id      TEXT NOT NULL,
  material     TEXT NOT NULL,
  strength     INT  NOT NULL,
  health       INT  NOT NULL,
  built_by     TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (base_id, room_id)
);

CREATE TABLE IF NOT EXISTS decorations (
  decoration_id UUID PRIMARY KEY,
  base_id       UUID NOT NULL REFERENCES bases(base_id) ON DELETE CASCADE,
  slot          TEXT NOT NULL,
  item_id       TEXT NOT NULL,
  UNIQUE (base_id, slot)
);

CREATE TABLE IF NOT EXISTS kiki_interactions (
  interaction_id  UUID PRIMARY KEY,
  base_id         UUID NOT NULL REFERENCES bases(base_id) ON DELETE CASCADE,
  player_id       TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  reward_item_id  TEXT,
  day             INT  NOT NULL
);

-- Kiki is limited to once per in-game day per player.
CREATE UNIQUE INDEX IF NOT EXISTS kiki_one_per_day
  ON kiki_interactions (base_id, player_id, day);

-- Replay protection for every mutating endpoint: the stored response is returned verbatim.
CREATE TABLE IF NOT EXISTS base_events (
  idempotency_key TEXT PRIMARY KEY,
  base_id         UUID,
  kind            TEXT NOT NULL,
  payload         JSONB,
  response        JSONB,
  status_code     INT NOT NULL DEFAULT 200,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS barricades_base_idx ON barricades (base_id);
CREATE INDEX IF NOT EXISTS facilities_base_idx ON facilities (base_id);
