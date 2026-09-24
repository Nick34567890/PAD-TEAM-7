CREATE TABLE IF NOT EXISTS players(player_id uuid PRIMARY KEY,username text UNIQUE NOT NULL,email text UNIQUE NOT NULL,password_hash text NOT NULL,level int NOT NULL DEFAULT 1,xp int NOT NULL DEFAULT 0,title text NOT NULL DEFAULT '',avatar text NOT NULL DEFAULT '',inventory_version int NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS refresh_tokens(token_hash text PRIMARY KEY,player_id uuid NOT NULL REFERENCES players ON DELETE CASCADE,expires_at timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS inventory_items(player_id uuid REFERENCES players ON DELETE CASCADE,item_id text NOT NULL,count int NOT NULL CHECK(count>=0),PRIMARY KEY(player_id,item_id));
CREATE TABLE IF NOT EXISTS friendships(player_id uuid REFERENCES players ON DELETE CASCADE,friend_id uuid REFERENCES players ON DELETE CASCADE,status text NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(player_id,friend_id));
CREATE TABLE IF NOT EXISTS presence(player_id uuid PRIMARY KEY REFERENCES players ON DELETE CASCADE,status text NOT NULL,lobby_id uuid,last_seen_at timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS xp_events(idempotency_key text PRIMARY KEY,player_id uuid REFERENCES players,payload text NOT NULL,response jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS inventory_events(idempotency_key text PRIMARY KEY,player_id uuid REFERENCES players,payload text NOT NULL,response jsonb NOT NULL,inventory_version int NOT NULL,created_at timestamptz NOT NULL DEFAULT now());

