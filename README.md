# In Kahoots with the Undead

**FAF.PAD21.1 — Autumn 2026 · Laboratory 0**
Distributed systems project: surviving the university exam season during a zombie apocalypse.

Players wake up in FAF Cab from the power nap of the century, armed with an axe and a laptop, and
must survive the end of the semester by gathering resources, expanding their base and clearing out
zombies — all while exams are still in session. Not even the professors turning undead is cause
enough to cancel the PBL presentations.

This is the **Common Public Repository (CPR)**. It holds the system design, the complete
communication contract between all eight microservices, and the team's engineering workflow. The
services themselves live in private repositories linked here as submodules.

---

## At a glance

| # | Service | Owner | Language | Port | Database |
| --- | --- | --- | --- | --- | --- |
| 1 | Player Service | Islam Abu Koush | Go | `8001` | `player_db` |
| 2 | Game Service | Islam Abu Koush | Go | `8002` | `game_db` |
| 3 | Exam Service | Ilico Artemie | TypeScript | `8003` | `exam_db` |
| 4 | World Service | Ilico Artemie | TypeScript | `8004` | `world_db` |
| 5 | Zombie Service | Roenco Maxim | Go | `8005` | `zombie_db` |
| 6 | Resource Service | Roenco Maxim | Go | `8006` | `resource_db` |
| 7 | Base Service | Gancear Nichita | TypeScript | `8007` | `base_db` |
| 8 | Crafting Service | Gancear Nichita | TypeScript | `8008` | `crafting_db` |

Supporting infrastructure: **API Gateway** on `8080`, **Service Registry** on `8500`.

---

## Table of contents

- [Team and ownership](#team-and-ownership)
- [Service boundaries](#service-boundaries)
- [Technology choices and trade-offs](#technology-choices-and-trade-offs)
- [Data management](#data-management)
- [API conventions](#api-conventions)
- [Authentication and authorization](#authentication-and-authorization)
- [Communication contract](#communication-contract)
  - [1. Player Service](#1-player-service)
  - [2. Game Service](#2-game-service)
  - [3. Exam Service](#3-exam-service)
  - [4. World Service](#4-world-service)
  - [5. Zombie Service](#5-zombie-service)
  - [6. Resource Service](#6-resource-service)
  - [7. Base Service](#7-base-service)
  - [8. Crafting Service](#8-crafting-service)
- [Event catalogue](#event-catalogue)
- [Failure and consistency model](#failure-and-consistency-model)
- [GitHub workflow](#github-workflow)
- [Repository layout](#repository-layout)
- [Glossary](#glossary)

## Team and ownership

Each member owns two services end to end: schema, implementation, tests, deployment and the section
of this contract that describes them.

| Member | Services | Language | Private repositories |
| --- | --- | --- | --- |
| Islam Abu Koush | Player, Game | Go | [`player-service`](./player-service), [`game-service`](./game-service) |
| Ilico Artemie | Exam, World | TypeScript | [`exam-service`](./exam-service), [`world-service`](./world-service) |
| Roenco Maxim | Zombie, Resource | Go | [`zombie-service`](./zombie-service), [`resource-service`](./resource-service) |
| Gancear Nichita | Base, Crafting | TypeScript | [`base-service`](./base-service), [`crafting-service`](./crafting-service) |

**Ownership rule.** A change to a service is authored by its owner. A change that alters this
contract requires review from every owner whose service consumes the affected endpoint — listed per
service under *Consumed by*.

---

## Technology choices and trade-offs

The team works in **two languages: Go and TypeScript**, split four services each, along ownership
lines so no member context-switches between stacks mid-lab.

| Owner | Services | Stack | Communication patterns | Motivation and trade-offs |
| --- | --- | --- | --- | --- |
| Islam Abu Koush | Player, Game | **Go** — Chi router, `pgx`, `gorilla/websocket`, `golang-migrate` | REST + JWT, **WebSocket fan-out**, in-process scheduled timers, event publication | Game Service is the only service that must hold thousands of concurrent, long-running timers — a ten-minute bench-chop per player per lobby — while streaming progress to every connected client. A goroutine per action costs kilobytes, and channels model the "timer fires → apply outcome → broadcast" pipeline without a scheduler dependency. Player Service shares the stack because it is the authentication hot path on every gateway request, where a static binary with predictable latency and no warm-up matters. **Trade-off:** Go has no ORM worth the name, so both services carry hand-written SQL and explicit error handling on every branch — noticeably more code for the plain CRUD parts of Player Service. We accept that because the concurrency requirement is non-negotiable and the CRUD is shallow. |
| Ilico Artemie | Exam, World | **TypeScript** — NestJS, TypeORM, `class-validator` | REST + JWT, **event publication** (`ExamPassed`), event consumption, read-heavy queries | These are the two most *relational* domains in the system. Exam Service models courses, questions, attempts, answers, grades and achievements; World Service models a literal graph of rooms, corridors, resource nodes, spawn points and wings. TypeORM entities and relations express both directly instead of through hand-written joins, and migrations keep those schemas reviewable as the grading rules and the map generator grow across eight labs. `class-validator` DTOs enforce this contract at the controller boundary, and identical NestJS module structure across both services matters when one person owns them and switches between them daily. The pair is also joined by one causal chain — passing an exam expands the university — so keeping them in one stack keeps that chain in one test harness. **Trade-off:** Node's single-threaded event loop means World Service, which Game Service queries on every cycle tick, must keep hot map reads in an in-process cache and scale horizontally rather than by adding cores. Procedural map generation is deliberately kept off the request path — it runs at wing-unlock time, never per query — so it can never stall the loop. |
| Roenco Maxim | Zombie, Resource | **Go** — Chi router, `pgx`, `golang-migrate` | REST + JWT, **idempotent transactions**, async notifications, transactional writes | Resource Service is the system's shared write hub: Game, World, Base, Crafting and Zombie all mutate stock through it, so it carries the highest write volume in the system and every one of those writes must be atomic and exactly-once under concurrent load. Go's explicit error handling means no failure branch in the ledger can be silently swallowed, `database/sql` transactions map directly onto the deduct-then-credit flow, and a unique index on the idempotency key sits at the centre of it. Low allocation overhead keeps the hub cheap precisely where the traffic concentrates. Zombie Service shares the stack because it is polled for live instance state on every cycle tick, with the same latency profile. **Trade-off:** with no ORM, the zombie type / behaviour / instance / inventory graph is hand-written SQL and mapping code — noticeably more boilerplate than TypeORM would need for the same registry. We accept that because the hub's correctness and throughput matter more than CRUD ergonomics, and because the ledger is exactly the code we want to be forced to read line by line. |
| Gancear Nichita | Base, Crafting | **TypeScript** — NestJS, TypeORM, `class-validator` | REST + JWT, **orchestrated saga** across Resource and Player, idempotent mutations, event publication | Base Service has the widest entity graph in the system — bases, facilities, barricades, decorations, storage tiers, Kiki reward tables — and TypeORM migrations keep that graph reviewable as it grows across eight labs. Crafting Service runs the project's most interesting distributed operation: consume materials from Resource Service, deliver the product to Player Service, atomically and exactly once, with compensation when the second step fails. NestJS's dependency injection lets that saga be unit-tested against injected fakes for both remote services instead of a live environment. **Trade-off:** the same single-threaded caveat applies, and TypeScript's type safety stops at the network boundary — a contract drift in Resource Service is a runtime failure, not a compile error. We mitigate that with contract tests pinned to the payloads in this document. |

### Why two languages rather than one

The course requires it, but the split is drawn to be useful rather than arbitrary. **Go takes the
four services where concurrency, throughput and transactional integrity under load dominate** — the
real-time game loop, the authentication hot path, the resource ledger and the zombie tick.
**TypeScript takes the four where a rich relational domain model dominates** — exams and grading,
the campus map graph, the base graph and the crafting saga.

Each language sits where its strengths are load-bearing rather than incidental, and each has exactly
two owners, so no pull request is ever blocked waiting on the only person who can read it.

---

## Data management

### Database per service

Each service owns a **private PostgreSQL database**. No service connects to another service's
database, and no service reads another service's tables. All cross-service data access goes through
the REST endpoints in this contract or through published events.

**Why:** services migrate and deploy independently; a schema change never blocks another member; and
the boundaries above are enforced by infrastructure instead of by good intentions.

**What it costs us, honestly:** no cross-service joins, so a screen showing a player's base *and*
their inventory requires two calls. Data is eventually consistent between services. Every write
spanning more than one service has to be designed as a saga with an explicit compensation path.
Those costs are why the next two subsections exist.

### Idempotency

Every mutating cross-service request carries an **`Idempotency-Key`** header holding a client-chosen
UUID. The receiving service stores it under a **unique index** alongside the serialized response.

- First request with a key → the operation executes, the result is stored and returned.
- Any repeat of that key → the **stored response is replayed verbatim**. Nothing executes twice.
- A different payload under an already-used key → `409 IDEMPOTENCY_KEY_REUSED`.

This is load-bearing, not decorative. Game Service drives gameplay through timed actions delivered
over WebSockets, and a client reconnect can replay a completion event. Without the key, one dropped
connection during a scavenge awards the resources twice, and the economy is unrecoverable within a
session.

### Sagas and compensation

Operations spanning services are **orchestrated sagas**. The initiating service writes a durable job
row *before* any remote call, drives each step keyed on the same idempotency key, and compensates if
a later step fails permanently.

Three sagas exist in this system:

| Saga | Orchestrator | Steps | Compensation |
| --- | --- | --- | --- |
| **Craft an item** | Crafting | consume materials (Resource) → deliver item (Player) | Return materials to the pool under `<key>:compensate` |
| **Trade between players** | Game | verify ownership (Player) → debit A (Player) → credit B (Player) | Reverse the debit under `<key>:compensate` |
| **Build or upgrade** | Base | consume materials (Resource) → apply structure change (local) | Return materials; local change never commits without the consume |

Because every step is keyed, a saga is safe to replay from any point. Each orchestrator exposes a
`GET` on its job resource so callers can confirm the terminal state instead of retrying blindly.

---

## Communication contract

Transport is JSON over HTTP for all synchronous calls. Each endpoint lists method, path, required
auth, request payload, success response with status code, and its error codes.

---

### 1. Player Service

**Owner:** Islam Abu Koush · **Go** · **Port `8001`** · [`player-service`](./player-service)

Owns the global identity and progression of players — registration, authentication, profiles,
friends, presence, XP and levels — and the **persistent player inventory**: consumables such as
Coffee, Energy Drinks and Davidan branded sandwiches, cosmetics, and crafted equipment.

**Consumed by:** every service (token validation) · Game (XP, inventory, trade transfers) ·
Crafting (item delivery, level gating) · Base (Kiki rewards, cosmetic ownership) · Zombie (XP theft)
· Exam (achievement rewards).

**Calls out to:** nothing. Player Service is a leaf and has no runtime dependency on another service
— deliberately, since every other service depends on it for authentication.

#### Data model

| Table | Key columns |
| --- | --- |
| `players` | `player_id`, `username` (unique), `email` (unique), `password_hash`, `level`, `xp`, `title`, `created_at` |
| `inventory_items` | `player_id`, `item_id`, `count` — composite primary key |
| `friendships` | `player_id`, `friend_id`, `status`, `created_at` |
| `presence` | `player_id`, `status`, `lobby_id`, `last_seen_at` |
| `xp_events` | `idempotency_key` (unique), `player_id`, `amount`, `reason`, `created_at` |
| `inventory_events` | `idempotency_key` (unique), `player_id`, `payload`, `response`, `created_at` |

#### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/v1/players/register` | public | Create an account |
| `POST` | `/api/v1/players/login` | public | Authenticate, receive tokens |
| `POST` | `/api/v1/players/refresh` | public | Exchange a refresh token |
| `GET` | `/api/v1/auth/jwks` | public | Public keys for token validation |
| `GET` | `/api/v1/players/{player_id}` | player | Public profile |
| `PATCH` | `/api/v1/players/{player_id}` | player | Update own profile |
| `POST` | `/api/v1/players/{player_id}/xp` | service | Award XP |
| `GET` | `/api/v1/players/{player_id}/inventory` | player | Full inventory |
| `PATCH` | `/api/v1/players/{player_id}/inventory` | service | Add or remove items |
| `POST` | `/api/v1/players/{player_id}/friends` | player | Send a friend request |
| `GET` | `/api/v1/players/{player_id}/friends` | player | Friends and their presence |
| `DELETE` | `/api/v1/players/{player_id}/friends/{friend_id}` | player | Remove a friend |
| `PUT` | `/api/v1/players/{player_id}/presence` | player | Update presence |

---

**`POST /api/v1/players/register`** — create an account.

```json
{ "username": "undead_survivor", "email": "player@faf.university", "password": "correct-horse-battery" }
```

`201 Created`

```json
{
  "player_id": "player-uuid-123",
  "username": "undead_survivor",
  "email": "player@faf.university",
  "level": 1,
  "xp": 0,
  "created_at": "2026-09-09T10:00:00Z"
}
```

Errors: `400 VALIDATION_FAILED` (password under 12 characters, malformed email) ·
`409 USERNAME_TAKEN` · `409 EMAIL_TAKEN`

---

**`POST /api/v1/players/login`** — authenticate.

```json
{ "email": "player@faf.university", "password": "correct-horse-battery" }
```

`200 OK`

```json
{
  "access_token": "<jwt>",
  "refresh_token": "<opaque>",
  "token_type": "Bearer",
  "expires_in": 3600,
  "player_id": "player-uuid-123",
  "roles": ["player"]
}
```

Errors: `401 INVALID_CREDENTIALS` — deliberately identical for a wrong password and an unknown
email, so the endpoint does not confirm which accounts exist.

---

**`POST /api/v1/players/refresh`** — exchange a refresh token for a new access token. The old refresh
token is rotated and invalidated.

```json
{ "refresh_token": "<opaque>" }
```

`200 OK` — same body as login.
Errors: `401 REFRESH_TOKEN_INVALID` · `401 REFRESH_TOKEN_EXPIRED`

---

**`GET /api/v1/auth/jwks`** — public keys, fetched by every service at boot.

`200 OK`

```json
{ "keys": [{ "kty": "RSA", "kid": "2026-09", "use": "sig", "alg": "RS256", "n": "...", "e": "AQAB" }] }
```

---

**`GET /api/v1/players/{player_id}`** — public profile.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "player_id": "player-uuid-123",
  "username": "undead_survivor",
  "level": 7,
  "xp": 1340,
  "xp_to_next_level": 260,
  "title": "Survivor of the Pumpkin",
  "avatar": "axe_wielding",
  "presence": { "status": "in_game", "lobby_id": "lobby-uuid-789" }
}
```

Errors: `404 PLAYER_NOT_FOUND`

---

**`PATCH /api/v1/players/{player_id}`** — update own profile. Only `title` and `avatar` are mutable
here; a title must already be unlocked through Exam Service.
Headers: `Authorization: Bearer <jwt>`

```json
{ "title": "Pumpkin Slayer", "avatar": "axe_wielding" }
```

`200 OK` — updated profile.
Errors: `403 FORBIDDEN` (editing another player) · `403 TITLE_NOT_UNLOCKED`

---

**`POST /api/v1/players/{player_id}/xp`** — award XP. Called by Game (kills, actions), Exam
(passing), Zombie (theft, negative amount).
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "amount": 50, "reason": "zombie_killed", "source": "game-service" }
```

`200 OK`

```json
{
  "player_id": "player-uuid-123",
  "xp": 1390,
  "level": 7,
  "leveled_up": false,
  "xp_to_next_level": 210
}
```

A negative `amount` never takes XP below the current level floor. Errors: `404 PLAYER_NOT_FOUND` ·
`409 IDEMPOTENCY_KEY_REUSED`

---

**`GET /api/v1/players/{player_id}/inventory`** — full inventory.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "player_id": "player-uuid-123",
  "items": [
    { "item_id": "coffee-01", "name": "Coffee", "count": 3, "category": "consumable" },
    { "item_id": "energy-01", "name": "Energy Drink", "count": 1, "category": "consumable" },
    { "item_id": "sandwich-01", "name": "Davidan Sandwich", "count": 2, "category": "consumable" },
    { "item_id": "axe-01", "name": "Improvised Axe", "count": 1, "category": "equipment" },
    { "item_id": "poster-faf-01", "name": "FAF Poster", "count": 1, "category": "cosmetic" }
  ]
}
```

---

**`PATCH /api/v1/players/{player_id}/inventory`** — add or remove items. Called by Crafting
(delivery), Game (trades, action rewards), Base (Kiki), Zombie (theft).
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "operation": "add",
  "items": [{ "item_id": "barricade-kit-01", "count": 1 }],
  "reason": "crafted",
  "source": "crafting-service"
}
```

`operation` ∈ `add`, `remove`. A `remove` that would take any count below zero fails atomically —
the whole batch is rejected, nothing partially applies.

`200 OK`

```json
{
  "player_id": "player-uuid-123",
  "applied": [{ "item_id": "barricade-kit-01", "count": 1 }],
  "inventory_version": 44
}
```

Errors: `409 INSUFFICIENT_ITEMS` with `details.missing` · `409 IDEMPOTENCY_KEY_REUSED`

---

**`POST /api/v1/players/{player_id}/friends`** — send a friend request.
Headers: `Authorization: Bearer <jwt>`

```json
{ "friend_id": "player-uuid-456" }
```

`201 Created` — `{ "friend_id": "player-uuid-456", "status": "pending" }`
Errors: `404 PLAYER_NOT_FOUND` · `409 ALREADY_FRIENDS` · `422 CANNOT_FRIEND_SELF`

---

**`GET /api/v1/players/{player_id}/friends`** — friends with live presence.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "player_id": "player-uuid-456", "username": "kiki_fan", "status": "accepted", "presence": "online" },
    { "player_id": "player-uuid-789", "username": "bench_chopper", "status": "pending", "presence": "offline" }
  ]
}
```

---

**`DELETE /api/v1/players/{player_id}/friends/{friend_id}`** — remove a friend.
Headers: `Authorization: Bearer <jwt>` · `204 No Content`

---

**`PUT /api/v1/players/{player_id}/presence`** — update presence. Called by the client on state
change and by Game Service on lobby join or leave.
Headers: `Authorization: Bearer <jwt>`

```json
{ "status": "in_game", "lobby_id": "lobby-uuid-789" }
```

`status` ∈ `online`, `offline`, `in_game`, `in_exam`. `200 OK` returns the stored presence.

---

### 2. Game Service

**Owner:** Islam Abu Koush · **Go** · **Port `8002`** · [`game-service`](./game-service)

The central real-time gameplay service. Owns game sessions and lobbies, the day/night cycle, session
timers and timed player actions. Actions execute **asynchronously with live progress delivered over
WebSockets**. Also coordinates trading between players — including players in different
universities and lobbies — verifying ownership and performing the transfer atomically, and controls
the short-lived behaviour of zombies during a cycle.

> **Game Service does not permanently own the university map or the player inventory.** It
> coordinates gameplay and notifies when actions, attacks or cycles finish.

**Calls out to:** World (rooms, nodes, spawn points) · Zombie (configs, spawn, kill) · Exam (request
an exam on a Professor Zombie encounter) · Resource (apply gathered resources) · Player (XP,
inventory, trades) · Base (create base, apply barricade damage).

**Consumed by:** the game client, over both REST and WebSocket.

#### Data model

| Table | Key columns |
| --- | --- |
| `lobbies` | `lobby_id`, `host_id`, `university`, `name`, `max_players`, `phase`, `day`, `status` |
| `lobby_players` | `lobby_id`, `player_id`, `joined_at`, `health` |
| `actions` | `action_id`, `lobby_id`, `player_id`, `type`, `target`, `started_at`, `completes_at`, `status` |
| `trades` | `trade_id`, `from_player_id`, `to_player_id`, `offer`, `request`, `status`, `idempotency_key` |
| `encounters` | `encounter_id`, `lobby_id`, `player_id`, `zombie_id`, `exam_id`, `outcome` |

#### Timed actions

| `action_type` | Duration | Yields | Requires |
| --- | --- | --- | --- |
| `chop_bench` | 600 s | `wood-01` | A room with a bench node |
| `scavenge_canteen` | 300 s | `food-01`, `coffee-01` | Canteen room |
| `search_library` | 420 s | `paper-01` | Library room |
| `strip_laboratory` | 480 s | `metal-01`, `electronics-01` | Laboratory room |
| `clear_room` | 180 s | Room becomes safe | Live zombies present |
| `barricade_room` | 240 s | Barricade built via Base | Materials in pool |
| `repair_base` | 300 s | Barricade health restored | Damaged barricade |

A player may hold **one active action at a time**. Starting a second returns `409 ACTION_ALREADY_ACTIVE`.

#### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/v1/lobbies` | player | Create a lobby |
| `GET` | `/api/v1/lobbies` | player | List joinable lobbies |
| `GET` | `/api/v1/lobbies/{lobby_id}` | player | Lobby state |
| `POST` | `/api/v1/lobbies/{lobby_id}/join` | player | Join |
| `POST` | `/api/v1/lobbies/{lobby_id}/leave` | player | Leave |
| `POST` | `/api/v1/lobbies/{lobby_id}/actions` | player | Start a timed action |
| `GET` | `/api/v1/actions/{action_id}` | player | Action progress |
| `DELETE` | `/api/v1/actions/{action_id}` | player | Cancel an action |
| `POST` | `/api/v1/lobbies/{lobby_id}/trades` | player | Offer a trade |
| `POST` | `/api/v1/trades/{trade_id}/respond` | player | Accept or decline |
| `POST` | `/api/v1/lobbies/{lobby_id}/encounters` | service | Trigger a zombie encounter |
| `POST` | `/api/v1/lobbies/{lobby_id}/cycle` | service | Advance day/night |
| `WS` | `/ws/v1/lobbies/{lobby_id}` | player | Live event stream |

---

**`POST /api/v1/lobbies`** — create a lobby. Triggers world generation in World Service and base
creation in Base Service before returning.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{ "name": "Cab Survivors", "university": "FAF", "max_players": 8 }
```

`201 Created`

```json
{
  "lobby_id": "lobby-uuid-789",
  "name": "Cab Survivors",
  "host_id": "player-uuid-123",
  "university": "FAF",
  "max_players": 8,
  "phase": "day",
  "day": 1,
  "status": "waiting",
  "players": [{ "player_id": "player-uuid-123", "username": "undead_survivor" }],
  "base_id": "base-uuid-001",
  "created_at": "2026-09-09T11:00:00Z"
}
```

Errors: `503 DEPENDENCY_UNAVAILABLE` if World or Base cannot be reached — the lobby is not created.

---

**`GET /api/v1/lobbies`** — list joinable lobbies. Query: `university`, `status`, `limit`, `cursor`.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    {
      "lobby_id": "lobby-uuid-789",
      "name": "Cab Survivors",
      "university": "FAF",
      "players": 3,
      "max_players": 8,
      "phase": "night",
      "day": 4,
      "status": "active"
    }
  ],
  "next_cursor": null
}
```

---

**`GET /api/v1/lobbies/{lobby_id}`** — full lobby state including players, health and active actions.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "lobby_id": "lobby-uuid-789",
  "name": "Cab Survivors",
  "phase": "night",
  "day": 4,
  "status": "active",
  "phase_ends_at": "2026-09-09T11:45:00Z",
  "base_id": "base-uuid-001",
  "players": [
    {
      "player_id": "player-uuid-123",
      "username": "undead_survivor",
      "health": 80,
      "current_action": { "action_id": "action-uuid-001", "type": "chop_bench", "percent": 40 }
    }
  ]
}
```

Errors: `404 LOBBY_NOT_FOUND` · `403 NOT_A_MEMBER`

---

**`POST /api/v1/lobbies/{lobby_id}/join`**
Headers: `Authorization: Bearer <jwt>`

```json
{ "player_id": "player-uuid-456" }
```

`200 OK` — lobby state.
Errors: `409 LOBBY_FULL` · `409 ALREADY_JOINED` · `422 LOBBY_FINISHED`

---

**`POST /api/v1/lobbies/{lobby_id}/leave`** — cancels any active action without reward.
Headers: `Authorization: Bearer <jwt>` · `204 No Content`

---

**`POST /api/v1/lobbies/{lobby_id}/actions`** — start a timed action. Returns immediately; progress
arrives over WebSocket.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{ "action_type": "chop_bench", "target_room_id": "room-a1", "target_node_id": "node-bench-3" }
```

`202 Accepted`

```json
{
  "action_id": "action-uuid-001",
  "action_type": "chop_bench",
  "player_id": "player-uuid-123",
  "target_room_id": "room-a1",
  "status": "in_progress",
  "started_at": "2026-09-09T11:00:00Z",
  "completes_at": "2026-09-09T11:10:00Z",
  "duration_seconds": 600
}
```

Errors: `409 ACTION_ALREADY_ACTIVE` · `404 ROOM_NOT_FOUND` (rejected by World) ·
`422 NODE_DEPLETED` · `422 WRONG_PHASE` (some actions are day-only)

---

**`GET /api/v1/actions/{action_id}`** — poll progress, for clients without a live socket.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "action_id": "action-uuid-001",
  "status": "in_progress",
  "elapsed_seconds": 240,
  "duration_seconds": 600,
  "percent": 40,
  "completes_at": "2026-09-09T11:10:00Z"
}
```

`status` ∈ `in_progress`, `completed`, `cancelled`, `interrupted`. A completed action includes
`reward`.

---

**`DELETE /api/v1/actions/{action_id}`** — cancel. No partial reward is granted.
Headers: `Authorization: Bearer <jwt>` · `204 No Content`
Errors: `409 ACTION_ALREADY_COMPLETED`

---

**`POST /api/v1/lobbies/{lobby_id}/trades`** — offer a trade. Ownership on both sides is verified
against Player Service before the offer is created. `cross_university` trades are permitted between
players in different lobbies.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "to_player_id": "player-uuid-456",
  "offer": [{ "item_id": "coffee-01", "count": 2 }],
  "request": [{ "item_id": "metal-01", "count": 5 }],
  "expires_in_seconds": 300
}
```

`201 Created`

```json
{
  "trade_id": "trade-uuid-001",
  "from_player_id": "player-uuid-123",
  "to_player_id": "player-uuid-456",
  "offer": [{ "item_id": "coffee-01", "count": 2 }],
  "request": [{ "item_id": "metal-01", "count": 5 }],
  "cross_university": true,
  "status": "pending",
  "expires_at": "2026-09-09T11:05:00Z"
}
```

Errors: `409 INSUFFICIENT_ITEMS` (offerer does not hold the offer) · `404 PLAYER_NOT_FOUND`

---

**`POST /api/v1/trades/{trade_id}/respond`** — accept or decline. Accepting runs the **trade saga**:
verify both sides still hold their items, debit each, credit each, all keyed on the trade's
idempotency key. Any failure reverses the debit.
Headers: `Authorization: Bearer <jwt>`

```json
{ "action": "accept" }
```

`200 OK`

```json
{
  "trade_id": "trade-uuid-001",
  "status": "completed",
  "transferred": {
    "to_player_uuid_456": [{ "item_id": "coffee-01", "count": 2 }],
    "to_player_uuid_123": [{ "item_id": "metal-01", "count": 5 }]
  },
  "completed_at": "2026-09-09T11:03:00Z"
}
```

Errors: `409 INSUFFICIENT_ITEMS` — status becomes `failed`, nothing moves · `422 TRADE_EXPIRED` ·
`403 NOT_THE_RECIPIENT`

---

**`POST /api/v1/lobbies/{lobby_id}/encounters`** — a zombie has reached a player. For a
`professor_zombie`, Game Service requests an exam from Exam Service and returns its id; for a
`tourist_zombie`, it instructs Zombie Service to steal.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "player_id": "player-uuid-123", "zombie_id": "zombie-uuid-001", "room_id": "exam-hall-3" }
```

`200 OK`

```json
{
  "encounter_id": "encounter-uuid-001",
  "zombie_type": "professor_zombie",
  "outcome": "exam_requested",
  "exam_id": "exam-uuid-555",
  "expires_at": "2026-09-09T11:20:00Z"
}
```

`outcome` ∈ `exam_requested`, `resources_stolen`, `xp_stolen`, `player_escaped`.

---

**`POST /api/v1/lobbies/{lobby_id}/cycle`** — advance the day/night cycle. Called by the internal
scheduler. Night spawns zombies via Zombie Service; day depletes and regenerates nodes via World.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

`200 OK`

```json
{
  "lobby_id": "lobby-uuid-789",
  "phase": "day",
  "day": 5,
  "phase_ends_at": "2026-09-09T12:15:00Z",
  "zombies_spawned": 0,
  "zombies_despawned": 6
}
```

---

#### WebSocket

```
wss://<gateway>/ws/v1/lobbies/{lobby_id}?token=<jwt>
```

The token is validated on upgrade; membership of the lobby is required. The connection closes with
`4401` on an invalid token and `4403` on non-membership.

**Client → server**

```json
{ "type": "subscribe",       "channels": ["actions", "zombies", "chat"] }
{ "type": "action_progress", "action_id": "action-uuid-001" }
{ "type": "attack",          "zombie_id": "zombie-uuid-001" }
{ "type": "ping" }
```

**Server → client**

```json
{ "type": "action_started",     "action_id": "action-uuid-001", "player_id": "player-uuid-123", "duration_seconds": 600 }
{ "type": "action_progress",    "action_id": "action-uuid-001", "elapsed_seconds": 240, "percent": 40 }
{ "type": "action_completed",   "action_id": "action-uuid-001", "reward": [{ "item_id": "wood-01", "count": 4 }] }
{ "type": "action_interrupted", "action_id": "action-uuid-001", "reason": "zombie_attack" }
{ "type": "zombie_spawned",     "zombie_id": "zombie-uuid-002", "type_id": "tourist_zombie", "room_id": "room-a1" }
{ "type": "zombie_attack",      "zombie_id": "zombie-uuid-001", "target_player_id": "player-uuid-123", "damage": 15 }
{ "type": "zombie_killed",      "zombie_id": "zombie-uuid-001", "killer_id": "player-uuid-123", "loot": [] }
{ "type": "encounter_started",  "encounter_id": "encounter-uuid-001", "zombie_type": "professor_zombie", "exam_id": "exam-uuid-555" }
{ "type": "trade_offered",      "trade_id": "trade-uuid-001", "from_player_id": "player-uuid-123" }
{ "type": "cycle_changed",      "phase": "night", "day": 5, "phase_ends_at": "2026-09-09T12:15:00Z" }
{ "type": "base_damaged",       "room_id": "lab-204", "barricade_health": 18 }
{ "type": "error",              "code": "ACTION_ALREADY_ACTIVE", "message": "..." }
{ "type": "pong" }
```

Heartbeat: the server sends `pong` to every `ping`; a client silent for 60 seconds is disconnected.
On reconnect the client re-subscribes and receives the current state — **completion events replayed
after a reconnect are safe, because every downstream write is keyed by idempotency key.**

---

### 5. Zombie Service

**Owner:** Roenco Maxim · **Go** · **Port `8005`** · [`zombie-service`](./zombie-service)

Owns the **persistent definitions and state of zombies**: types, statistics, behaviour
configuration, sprites and special abilities, plus every live instance and what it is carrying.

Two major categories are mandatory:

- **Professor Zombies** — retain their academic behaviour and can initiate exams against players.
- **Tourist Zombies** — behave as a roaming horde and can steal resources or XP.

Further variants differ in movement speed, health, attack strength, perception radius and special
behaviour.

**Stolen goods are held by the instance.** When a Tourist Zombie steals from a player or a resource
node, the items sit in that zombie inventory until it is killed, at which point the whole inventory
transfers atomically to the killer. This is what makes hunting a laden zombie worthwhile, and it is
why zombie instances are persistent rather than ephemeral.

**Calls out to:** Player (steal or restore XP and items) · Resource (deduct from a node pool on a
world steal).
**Consumed by:** Game (type configs, spawning, encounter and kill resolution).

#### Zombie types

| `type_id` | Name | HP | Damage | Speed | Perception | Special behaviour |
| --- | --- | --- | --- | --- | --- | --- |
| `professor_zombie` | Professor Zombie | 120 | 15 | 1.0 | 5 | Initiates an exam instead of attacking |
| `tourist_zombie` | Tourist Zombie | 70 | 10 | 1.5 | 4 | Steals up to 2 item stacks, then flees |
| `caffeinated_sprinter` | Caffeinated Sprinter | 50 | 8 | 3.0 | 7 | Cannot be outrun; ignores barricades below strength 20 |
| `bureaucrat` | Bureaucrat | 200 | 5 | 0.6 | 3 | Halves XP gain while alive in the room |
| `night_owl` | Night Owl | 90 | 20 | 1.2 | 6 | Damage doubles during the night phase |

#### Data model

| Table | Key columns |
| --- | --- |
| `zombie_types` | `type_id`, `name`, `health`, `damage`, `speed`, `perception_radius`, `sprite`, `loot_table_id` |
| `behaviours` | `behaviour_id`, `type_id`, `trigger`, `action`, `params` |
| `zombie_instances` | `zombie_id`, `type_id`, `lobby_id`, `room_id`, `health`, `state`, `spawned_at` |
| `instance_inventory` | `zombie_id`, `item_id`, `count` |
| `theft_events` | `idempotency_key` (unique), `zombie_id`, `victim_type`, `victim_id`, `payload` |

#### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/v1/zombie-types` | player / service | Type registry |
| `GET` | `/api/v1/zombie-types/{type_id}` | player / service | Type with behaviours |
| `POST` | `/api/v1/zombies` | service | Spawn an instance |
| `GET` | `/api/v1/lobbies/{lobby_id}/zombies` | service | Live instances |
| `GET` | `/api/v1/zombies/{zombie_id}` | service | One instance with inventory |
| `POST` | `/api/v1/zombies/{zombie_id}/steal` | service | Record a theft |
| `POST` | `/api/v1/zombies/{zombie_id}/damage` | service | Apply damage |
| `POST` | `/api/v1/zombies/{zombie_id}/kill` | service | Kill and transfer loot |
| `DELETE` | `/api/v1/zombies/{zombie_id}` | service | Despawn at cycle end |

---

**`GET /api/v1/zombie-types`** — the registry. Query: `category` ∈ `professor`, `tourist`, `variant`.
Headers: `Authorization: Bearer <jwt>` or `Bearer <service_jwt>`

`200 OK`

```json
{
  "items": [
    {
      "type_id": "professor_zombie",
      "name": "Professor Zombie",
      "category": "professor",
      "health": 120,
      "damage": 15,
      "speed": 1.0,
      "perception_radius": 5,
      "sprite": "sprites/professor.png",
      "can_initiate_exam": true
    },
    {
      "type_id": "tourist_zombie",
      "name": "Tourist Zombie",
      "category": "tourist",
      "health": 70,
      "damage": 10,
      "speed": 1.5,
      "perception_radius": 4,
      "sprite": "sprites/tourist.png",
      "can_steal": true
    }
  ]
}
```

---

**`GET /api/v1/zombie-types/{type_id}`** — a type with its full behaviour rules.
Headers: `Authorization: Bearer <jwt>` or `Bearer <service_jwt>`

`200 OK`

```json
{
  "type_id": "tourist_zombie",
  "name": "Tourist Zombie",
  "category": "tourist",
  "health": 70,
  "damage": 10,
  "speed": 1.5,
  "perception_radius": 4,
  "loot_table_id": "loot-tourist-01",
  "behaviours": [
    { "trigger": "player_within_radius", "action": "chase", "params": { "radius": 4 } },
    { "trigger": "reached_player", "action": "steal_items", "params": { "max_stacks": 2 } },
    { "trigger": "steal_succeeded", "action": "flee_to_room", "params": { "prefer": "corridor" } },
    { "trigger": "phase_day", "action": "despawn", "params": {} }
  ]
}
```

Errors: `404 ZOMBIE_TYPE_NOT_FOUND`

---

**`POST /api/v1/zombies`** — spawn an instance. Called by Game Service on a night cycle.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "type_id": "tourist_zombie", "lobby_id": "lobby-uuid-789", "room_id": "lab-204", "spawn_id": "spawn-11" }
```

`201 Created`

```json
{
  "zombie_id": "zombie-uuid-002",
  "type_id": "tourist_zombie",
  "lobby_id": "lobby-uuid-789",
  "room_id": "lab-204",
  "health": 70,
  "max_health": 70,
  "state": "roaming",
  "inventory": [],
  "spawned_at": "2026-09-09T21:00:00Z"
}
```

`state` ∈ `roaming`, `chasing`, `stealing`, `fleeing`, `examining`, `dead`.

---

**`GET /api/v1/lobbies/{lobby_id}/zombies`** — live instances with inventories. Query: `room_id`,
`state`.
Headers: `Authorization: Bearer <service_jwt>`

`200 OK`

```json
{
  "items": [
    {
      "zombie_id": "zombie-uuid-001",
      "type_id": "professor_zombie",
      "room_id": "exam-hall-3",
      "health": 120,
      "state": "roaming",
      "inventory": []
    },
    {
      "zombie_id": "zombie-uuid-002",
      "type_id": "tourist_zombie",
      "room_id": "corridor-b",
      "health": 55,
      "state": "fleeing",
      "inventory": [
        { "item_id": "coffee-01", "count": 1 },
        { "item_id": "metal-01", "count": 3 }
      ]
    }
  ]
}
```

---

**`GET /api/v1/zombies/{zombie_id}`** — one instance.
Headers: `Authorization: Bearer <service_jwt>` · `200 OK` — the item shape above.
Errors: `404 ZOMBIE_NOT_FOUND`

---

**`POST /api/v1/zombies/{zombie_id}/steal`** — record a theft. `victim_type` `player` deducts from
Player Service inventory or XP; `node` deducts from the room pool in Resource Service. Either way the
goods land in this zombie inventory.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "victim_type": "player",
  "victim_id": "player-uuid-123",
  "items": [{ "item_id": "sandwich-01", "count": 1 }],
  "xp": 0
}
```

`200 OK`

```json
{
  "zombie_id": "zombie-uuid-002",
  "stolen": [{ "item_id": "sandwich-01", "count": 1 }],
  "xp_stolen": 0,
  "state": "fleeing",
  "inventory": [
    { "item_id": "coffee-01", "count": 1 },
    { "item_id": "metal-01", "count": 3 },
    { "item_id": "sandwich-01", "count": 1 }
  ]
}
```

If the victim holds nothing, the response is `200 OK` with an empty `stolen` array — a failed theft
is a game outcome, not an error. Errors: `409 IDEMPOTENCY_KEY_REUSED` · `422 ZOMBIE_ALREADY_DEAD`

---

**`POST /api/v1/zombies/{zombie_id}/damage`** — apply damage from a player attack.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "amount": 25, "source_player_id": "player-uuid-123", "weapon_item_id": "axe-01" }
```

`200 OK`

```json
{ "zombie_id": "zombie-uuid-002", "health": 30, "max_health": 70, "state": "fleeing", "killed": false }
```

When health reaches zero the response carries `"killed": true`, and Game Service must follow with the
kill call to collect the loot.

---

**`POST /api/v1/zombies/{zombie_id}/kill`** — kill the instance and transfer its **entire inventory**
to the killer, atomically, through Player Service. Also rolls the loot table for the type.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "killer_player_id": "player-uuid-123", "lobby_id": "lobby-uuid-789" }
```

`200 OK`

```json
{
  "zombie_id": "zombie-uuid-002",
  "type_id": "tourist_zombie",
  "killer_player_id": "player-uuid-123",
  "transferred_items": [
    { "item_id": "coffee-01", "count": 1 },
    { "item_id": "metal-01", "count": 3 },
    { "item_id": "sandwich-01", "count": 1 }
  ],
  "loot_rolled": [{ "item_id": "energy-01", "count": 1 }],
  "xp_awarded": 40,
  "state": "dead",
  "despawned": true
}
```

If the transfer to Player Service fails permanently, the zombie is **not** marked dead and the
inventory is retained — the kill is retried rather than silently destroying the loot. Errors:
`404 ZOMBIE_NOT_FOUND` · `422 ZOMBIE_ALREADY_DEAD` · `503 DEPENDENCY_UNAVAILABLE`

---

**`DELETE /api/v1/zombies/{zombie_id}`** — despawn at dawn. **Any inventory still held is returned to
the resource pool it came from**, so goods are never destroyed by the cycle boundary.
Headers: `Authorization: Bearer <service_jwt>`

`200 OK`

```json
{
  "zombie_id": "zombie-uuid-002",
  "despawned": true,
  "inventory_returned": [{ "item_id": "metal-01", "count": 3 }]
}
```

---

### 6. Resource Service

**Owner:** Roenco Maxim · **Go** · **Port `8006`** · [`resource-service`](./resource-service)

Owns the **resource economy of the university, independently from the physical map**. Tracks
resources such as wood, metal scraps, paper and food — their quantities and where they were
gathered. When Game Service starts a timed gathering action, Resource Service is responsible for
validating and applying the eventual resource change to the relevant node or player.

It also handles resource consumption for barricading rooms, upgrading the base, crafting items and
feeding Kiki.

> This separation means Game Service can manage *"the player is scavenging for five minutes"* while
> Resource Service owns *"the player received twelve food when the action completed."*

**Every mutating operation is idempotent**, so reconnects or duplicated completion events cannot
award resources twice. This is the single most important correctness property in the system, because
Resource Service is the shared write hub: Game, World, Zombie, Base and Crafting all mutate stock
through it.

**Calls out to:** nothing during a transaction — Resource Service is deliberately a leaf on the write
path so that no remote failure can leave a partial ledger.
**Consumed by:** Game (gather) · Base (consume) · Crafting (consume, compensate) · Zombie (node
theft) · World (pool creation).

#### Data model

| Table | Key columns |
| --- | --- |
| `pools` | `pool_id`, `lobby_id`, `room_id`, `node_id`, `kind`, `created_at` |
| `pool_stock` | `pool_id`, `item_id`, `stock` — composite primary key |
| `player_resources` | `player_id`, `lobby_id`, `item_id`, `amount` |
| `transactions` | `transaction_id`, `idempotency_key` (unique), `type`, `source`, `target`, `items`, `status`, `response`, `created_at` |

`kind` ∈ `node` (a world resource node), `player` (a player carrying raw materials), `lobby` (a
shared stockpile).

#### Idempotency, concretely

```sql
CREATE UNIQUE INDEX idx_tx_idem ON transactions (idempotency_key);
```

Every write opens a transaction, attempts the insert, and on a unique-violation returns the stored
`response` column verbatim without touching stock. That single index is what makes a replayed
WebSocket completion event harmless.

#### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/v1/pools` | service | Create a pool |
| `GET` | `/api/v1/pools` | service | List pools |
| `GET` | `/api/v1/pools/{pool_id}` | service | One pool with stock |
| `GET` | `/api/v1/players/{player_id}/resources` | player | A player raw materials |
| `POST` | `/api/v1/transactions/gather` | service | Node → player, idempotent |
| `POST` | `/api/v1/transactions/consume` | service | Player → sink, idempotent |
| `POST` | `/api/v1/transactions/transfer` | service | Pool → pool, idempotent |
| `GET` | `/api/v1/transactions/{transaction_id}` | service | Verify a transaction |
| `POST` | `/api/v1/transactions/{transaction_id}/compensate` | service | Reverse a transaction |

---

**`POST /api/v1/pools`** — create a pool. Called by World Service on world generation and on each
wing unlock.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "lobby_id": "lobby-uuid-789",
  "room_id": "lab-204",
  "node_id": "node-metal-7",
  "kind": "node",
  "initial_stock": [
    { "item_id": "metal-01", "count": 15 },
    { "item_id": "electronics-01", "count": 4 }
  ]
}
```

`201 Created`

```json
{
  "pool_id": "pool-uuid-001",
  "lobby_id": "lobby-uuid-789",
  "room_id": "lab-204",
  "node_id": "node-metal-7",
  "kind": "node",
  "stock": [
    { "item_id": "metal-01", "count": 15 },
    { "item_id": "electronics-01", "count": 4 }
  ]
}
```

Errors: `409 POOL_ALREADY_EXISTS`

---

**`GET /api/v1/pools`** — list pools. Query: `lobby_id`, `room_id`, `kind`.
Headers: `Authorization: Bearer <service_jwt>`

`200 OK`

```json
{
  "items": [
    {
      "pool_id": "pool-uuid-001",
      "room_id": "lab-204",
      "kind": "node",
      "stock": [
        { "item_id": "metal-01", "count": 12 },
        { "item_id": "electronics-01", "count": 4 }
      ]
    },
    {
      "pool_id": "pool-uuid-002",
      "room_id": "canteen",
      "kind": "node",
      "stock": [
        { "item_id": "food-01", "count": 30 },
        { "item_id": "coffee-01", "count": 15 }
      ]
    }
  ]
}
```

---

**`GET /api/v1/pools/{pool_id}`**
Headers: `Authorization: Bearer <service_jwt>` · `200 OK` — the item shape above.
Errors: `404 POOL_NOT_FOUND`

---

**`GET /api/v1/players/{player_id}/resources`** — raw materials a player is carrying in a lobby.
Distinct from Player Service inventory, which holds finished goods. Query: `lobby_id` (required).
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "player_id": "player-uuid-123",
  "lobby_id": "lobby-uuid-789",
  "resources": [
    { "item_id": "wood-01", "amount": 24 },
    { "item_id": "metal-01", "amount": 9 },
    { "item_id": "paper-01", "amount": 5 }
  ]
}
```

---

**`POST /api/v1/transactions/gather`** — a completed gathering action. Deducts from the node pool and
credits the player. **The endpoint a replayed WebSocket completion hits.**
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "lobby_id": "lobby-uuid-789",
  "player_id": "player-uuid-123",
  "source_pool_id": "pool-uuid-001",
  "items": [{ "item_id": "metal-01", "count": 3 }],
  "reason": "action_completed",
  "action_id": "action-uuid-001"
}
```

`200 OK`

```json
{
  "transaction_id": "tx-uuid-044",
  "idempotency_key": "idem-uuid-abc",
  "type": "gather",
  "status": "completed",
  "items_moved": [{ "item_id": "metal-01", "count": 3 }],
  "player_balance": [{ "item_id": "metal-01", "amount": 12 }],
  "pool_remaining": [{ "item_id": "metal-01", "count": 9 }],
  "replayed": false,
  "created_at": "2026-09-09T11:10:00Z"
}
```

A repeat of the same key returns the identical body with `"replayed": true` and **no stock change**.
If the pool holds less than requested, the transaction moves what is available and reports
`"partial": true` — a depleted node yields less rather than failing the action. Errors:
`404 POOL_NOT_FOUND` · `409 IDEMPOTENCY_KEY_REUSED` (same key, different payload)

---

**`POST /api/v1/transactions/consume`** — spend a player raw materials. Called by Base (upgrades,
barricades) and Crafting (recipe inputs). **Atomic across the whole item list** — either every line
is deducted or none is.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "lobby_id": "lobby-uuid-789",
  "player_id": "player-uuid-123",
  "items": [
    { "item_id": "wood-01", "count": 4 },
    { "item_id": "metal-01", "count": 2 }
  ],
  "reason": "craft",
  "reference_id": "craft-uuid-001"
}
```

`200 OK`

```json
{
  "transaction_id": "tx-uuid-091",
  "type": "consume",
  "status": "completed",
  "items_consumed": [
    { "item_id": "wood-01", "count": 4 },
    { "item_id": "metal-01", "count": 2 }
  ],
  "player_balance": [
    { "item_id": "wood-01", "amount": 20 },
    { "item_id": "metal-01", "amount": 10 }
  ],
  "replayed": false
}
```

`409 INSUFFICIENT_RESOURCES`

```json
{
  "error": {
    "code": "INSUFFICIENT_RESOURCES",
    "message": "Player does not hold enough materials.",
    "details": { "missing": [{ "item_id": "metal-01", "required": 2, "available": 1 }] }
  }
}
```

---

**`POST /api/v1/transactions/transfer`** — move stock between pools. Used for zombie node theft and
for returning a despawned zombie inventory.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "from_pool_id": "pool-uuid-001",
  "to_pool_id": "pool-uuid-zombie-002",
  "items": [{ "item_id": "metal-01", "count": 3 }],
  "reason": "zombie_theft"
}
```

`200 OK`

```json
{
  "transaction_id": "tx-uuid-112",
  "type": "transfer",
  "status": "completed",
  "items_moved": [{ "item_id": "metal-01", "count": 3 }],
  "replayed": false
}
```

Errors: `409 INSUFFICIENT_RESOURCES` · `404 POOL_NOT_FOUND`

---

**`GET /api/v1/transactions/{transaction_id}`** — verify a transaction. Callers use this to confirm
an outcome after a timeout instead of retrying blindly.
Headers: `Authorization: Bearer <service_jwt>`

`200 OK`

```json
{
  "transaction_id": "tx-uuid-091",
  "idempotency_key": "idem-uuid-def",
  "type": "consume",
  "status": "completed",
  "player_id": "player-uuid-123",
  "items": [
    { "item_id": "wood-01", "count": 4 },
    { "item_id": "metal-01", "count": 2 }
  ],
  "reason": "craft",
  "reference_id": "craft-uuid-001",
  "compensated_by": null,
  "created_at": "2026-09-09T12:30:00Z"
}
```

`status` ∈ `completed`, `failed`, `compensated`. Errors: `404 TRANSACTION_NOT_FOUND`

---

**`POST /api/v1/transactions/{transaction_id}/compensate`** — reverse a completed transaction. The
compensation is itself keyed, so a retried compensation does not double-refund.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "reason": "crafting_delivery_failed" }
```

`200 OK`

```json
{
  "transaction_id": "tx-uuid-091",
  "status": "compensated",
  "compensation_transaction_id": "tx-uuid-092",
  "items_restored": [
    { "item_id": "wood-01", "count": 4 },
    { "item_id": "metal-01", "count": 2 }
  ]
}
```

Errors: `422 ALREADY_COMPENSATED` · `422 CANNOT_COMPENSATE_FAILED_TRANSACTION`

---

## Event catalogue

Asynchronous events are facts that already happened. A publisher never waits for a consumer, and a
consumer that is down must be able to catch up — so every event carries an `event_id` and consumers
deduplicate on it exactly as endpoints deduplicate on `Idempotency-Key`.

Envelope:

```json
{
  "event_id": "evt-uuid-0091",
  "type": "ExamPassed",
  "version": 1,
  "occurred_at": "2026-09-09T11:24:10Z",
  "producer": "exam-service",
  "payload": { }
}
```

| Event | Producer | Consumers | Payload | Effect |
| --- | --- | --- | --- | --- |
| `PlayerRegistered` | Player | Exam | `{ player_id, username }` | Enrol the player in the starting courses |
| `PlayerLeveledUp` | Player | Crafting | `{ player_id, level }` | Re-evaluate level-gated recipes |
| `LobbyCreated` | Game | World, Base | `{ lobby_id, university, seed }` | Generate world and base |
| `LobbyFinished` | Game | World, Base, Zombie, Resource | `{ lobby_id }` | Release per-lobby state |
| `CycleChanged` | Game | Zombie, World | `{ lobby_id, phase, day }` | Spawn or despawn; regenerate nodes |
| `ActionCompleted` | Game | Resource | `{ action_id, player_id, pool_id, items }` | Apply the gathered resources |
| `ExamPassed` | Exam | World, Player, Crafting | `{ player_id, course_id, grade }` | Unlock a wing; award XP; re-evaluate recipes |
| `AchievementUnlocked` | Exam | Player | `{ player_id, code, reward }` | Grant the reward and title |
| `WingUnlocked` | World | Crafting, Game | `{ lobby_id, wing_code, rooms_added }` | Re-evaluate wing-gated recipes |
| `ZombieKilled` | Zombie | Player, Game | `{ zombie_id, killer_player_id, loot, xp }` | Award loot and XP |
| `ResourcesStolen` | Zombie | Game | `{ zombie_id, victim_id, items }` | Notify the client over WebSocket |
| `ItemCrafted` | Crafting | Player, Game | `{ job_id, player_id, output_item_id, count }` | Notify the client |
| `CraftCompensated` | Crafting | Game | `{ job_id, player_id, restored_items }` | Notify the client the craft was rolled back |
| `BaseUpgraded` | Base | Game, World | `{ base_id, lobby_id, level, defense_rating }` | Update defence in the live loop |
| `BarricadeDestroyed` | Base | Game, Zombie | `{ base_id, room_id, destroyed_by }` | Room becomes reachable again |

**Transport for Lab 0–1** is direct HTTP `POST` to a consumer webhook, with retry and exponential
backoff. **From Lab 2** these move onto a message broker; the envelope above is designed so that
migration changes the transport and not a single payload.

---

## Failure and consistency model

What happens when part of the system is unavailable — written down now so it is designed for rather
than discovered during a demo.

| Failure | Effect | Handling |
| --- | --- | --- |
| **Player Service down** | Nothing authenticates; the system is effectively offline | Accepted single point of failure for Lab 0. Gateway caches the JWKS so already-issued tokens keep validating; from Lab 3 Player Service runs replicated |
| **Resource Service down** | No gathering, crafting, building | Callers return `503 DEPENDENCY_UNAVAILABLE`. Game Service keeps the timer running and retries the credit with the same key — the player is not robbed of a completed action |
| **World Service down** | No new lobbies; barricades cannot be validated | Existing lobbies keep running from Game Service cached room data. Base returns `503` for new barricades |
| **Exam Service down** | Professor Zombie encounters cannot start | Game Service degrades the encounter to a normal attack rather than blocking the cycle |
| **Zombie Service down** | No spawns this cycle | Game Service skips the spawn step; the night is quiet. Live instances are unaffected because Zombie holds their state |
| **Base or Crafting down** | Those features return `503` | No other service depends on them for a core loop — this is the cheapest failure in the system, by design |
| **A saga fails midway** | Materials consumed but item undelivered | Compensation returns them under `<key>:compensate`; the job records `compensated` and the client is notified |
| **A client reconnects and replays** | Duplicate completion event | The idempotency key makes the replay a no-op that returns the original result |

**Consistency guarantees we actually make:**

- **Within one service** — strongly consistent, enforced by PostgreSQL transactions.
- **Across services** — eventually consistent. A player who crafts an item may briefly see the
  materials gone before the item appears in their inventory. That window is bounded by the saga and
  never lost, only delayed.
- **Never** — no service exposes a read that depends on another service having already applied a
  write. Every screen is composed from independent reads that may be a moment out of step.

---

## Service boundaries

Every service encapsulates exactly one domain and owns the data for that domain alone. The *does not
own* column is the important one — it is what stops this design collapsing into a distributed
monolith.

| Service | Owns | Does **not** own |
| --- | --- | --- |
| **Player** | Identity, credentials, JWT issuance, profiles, friends, presence, XP, levels, persistent inventory | Resource pools, map geometry, base state, exam results |
| **Game** | Lobbies, day/night cycle, session and action timers, trade coordination, WebSocket sessions | The map, player inventory, resource stock, zombie definitions — it *orchestrates and notifies*, it does not persist them |
| **Exam** | Courses, exam instances, attempts, questions, answers, grades, achievements, diploma progress | Player XP ledger, map unlocks — it only publishes `ExamPassed` |
| **World** | Campus geography: rooms, corridors, zones, resource-node placement, spawn configuration, wings | What players built inside rooms, resource quantities, zombie runtime state |
| **Zombie** | Zombie type registry, stats, behaviour configuration, live instances and their stolen inventories | Player inventory, resource pools, the map itself |
| **Resource** | The resource economy: pools, stock levels, and every idempotent gather/consume/transfer transaction | Room locations, what is built with the resources, player inventory of crafted goods |
| **Base** | Player-built state: base level, facilities, barricades, storage tiers, decorations, Kiki | Campus geography, resource stock, player inventory |
| **Crafting** | Recipe catalogue, unlock rules, craft job records | Resources consumed, the item once delivered, the exam and level state it queries |

### The four boundaries most likely to be challenged

> **World vs Base.** World Service owns the campus *geography*. Base Service owns what players have
> *built or changed* within that geography. A room exists because World says so; a barricade **in**
> that room exists because Base says so. World never mutates on a player's behalf.

> **Game vs Resource.** Game Service owns *"the player is scavenging for five minutes."* Resource
> Service owns *"the player received twelve food when the action completed."* Game holds the timer;
> Resource holds the truth about stock.

> **Player inventory vs Resource pools.** Raw materials in the world live in Resource Service pools.
> Finished goods a player carries live in Player Service inventory. Crafting is the bridge: it
> consumes from the first and delivers to the second.

> **Zombie vs Game.** Zombie Service owns what a zombie *is* and its persistent instance state,
> including anything it has stolen. Game Service owns what a zombie *does during this cycle*. A
> zombie's loot survives the cycle; its current aggression target does not.

---

## API conventions

These apply to every service. They exist so that eight services written by four people in two
languages behave the same way at the network boundary.

### Versioning

All routes are prefixed **`/api/v1/`**. A breaking change to any payload or response ships as
`/api/v2/` alongside `v1`, and `v1` is removed only after every consumer has migrated. WebSocket
routes are versioned the same way: `/ws/v1/`.

### Error envelope

Every non-2xx response uses one shape, so clients and services parse errors identically:

```json
{
  "error": {
    "code": "INSUFFICIENT_RESOURCES",
    "message": "Not enough metal scraps to complete this upgrade.",
    "details": { "missing": [{ "item_id": "metal-01", "required": 12, "available": 5 }] }
  },
  "request_id": "req-uuid-8f21"
}
```

| Status | When | Example `code` |
| --- | --- | --- |
| `400` | Malformed or failing validation | `VALIDATION_FAILED` |
| `401` | Missing, expired or invalid token | `UNAUTHENTICATED` |
| `403` | Authenticated but not permitted, or a locked game state | `RECIPE_LOCKED` |
| `404` | Resource does not exist | `PLAYER_NOT_FOUND` |
| `409` | Conflicts with current state | `INSUFFICIENT_RESOURCES`, `ACTION_ALREADY_ACTIVE` |
| `422` | Well-formed but not satisfiable by game rules | `MAX_LEVEL_REACHED` |
| `429` | Rate or cycle limit hit | `KIKI_ALREADY_FED` |
| `500` | Unexpected failure | `INTERNAL_ERROR` |
| `503` | A required downstream service is unreachable | `DEPENDENCY_UNAVAILABLE` |

### Common headers

| Header | Direction | Purpose |
| --- | --- | --- |
| `Authorization: Bearer <jwt>` | in | Player or service token |
| `Idempotency-Key: <uuid>` | in | Required on every mutating cross-service call |
| `X-Request-Id: <uuid>` | both | Propagated unchanged across every hop for tracing |

### Identifiers, time and pagination

- IDs are **UUID v4** strings. Item and type identifiers are stable human-readable slugs
  (`metal-01`, `professor_zombie`) agreed across all services in the [glossary](#glossary).
- Timestamps are **RFC 3339 / ISO 8601 in UTC**: `2026-09-09T12:30:00Z`.
- List endpoints accept `limit` (default 50, max 200) and `cursor`, and return
  `{ "items": [...], "next_cursor": "..." }`. Collections shown below omit the envelope for brevity
  where a full page is always returned.

---

## Authentication and authorization

**Player Service is the only issuer of tokens.** Everything else validates them.

### Player token

Issued on login, valid 60 minutes, paired with a 30-day refresh token.

```json
{
  "sub": "player-uuid-123",
  "username": "undead_survivor",
  "roles": ["player"],
  "iss": "player-service",
  "exp": 1789000000
}
```

Roles: `player`, `moderator`. Signed **RS256**; every service validates against Player Service's
public key, fetched at boot from `GET /api/v1/auth/jwks` and cached. No shared private key ever
leaves Player Service.

### Service token

Cross-service calls carry a separate token signed **HS256** with an internal secret distributed
through environment variables and never committed.

```json
{ "sub": "crafting-service", "roles": ["service"], "aud": "resource-service", "exp": 1789000000 }
```

Endpoints marked **`service`** below reject player tokens outright and are not routable from the
public gateway. Endpoints marked **`player`** accept a player token; a player may only act on their
own `sub` unless they hold `moderator`.

---

### 3. Exam Service

**Owner:** Ilico Artemie · **TypeScript** · **Port `8003`** · [`exam-service`](./exam-service)

Responsible for the **actual academic progression** of players. Maintains active exams for the
semester, exam attempts, questions, answers, grades and pass/fail results. When a player encounters a
Professor Zombie, Game Service requests an exam from this service. Questions are generated from a
static seeded bank — deliberately, since the interesting problem here is the distributed workflow,
not question generation.

Tracks course completion, grades, achievements and diploma milestones. Passing specific exams
triggers events: completing all Math exams awards the **"Survived the Pumpkin"** achievement and
notifies World Service to unlock a new wing.

**Calls out to:** Player (award XP and achievement rewards).
**Consumed by:** Game (request an exam) · World (`ExamPassed` → unlock a wing) · Crafting (recipe
gating) · Base (facility gating).

#### Data model

| Table | Key columns |
| --- | --- |
| `courses` | `course_id`, `name`, `department`, `credits`, `required_for_diploma` |
| `questions` | `question_id`, `course_id`, `text`, `options`, `correct_option`, `difficulty` |
| `exams` | `exam_id`, `player_id`, `course_id`, `lobby_id`, `status`, `score`, `started_at`, `expires_at` |
| `exam_questions` | `exam_id`, `question_id`, `position`, `answered_option` |
| `player_courses` | `player_id`, `course_id`, `status`, `best_grade`, `attempts` |
| `achievements` | `achievement_id`, `player_id`, `code`, `awarded_at` |

#### Grading rules

Ten questions per exam, one point each, **six correct to pass**. An exam expires 300 seconds after
issue; an expired exam is graded on whatever was answered. Three failed attempts on a course locks
it until the next in-game day.

#### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/v1/courses` | player | Course catalogue |
| `POST` | `/api/v1/exams` | service | Issue an exam for an encounter |
| `GET` | `/api/v1/exams/{exam_id}` | player | Exam with its questions |
| `POST` | `/api/v1/exams/{exam_id}/answers` | player | Save an answer |
| `POST` | `/api/v1/exams/{exam_id}/submit` | player | Submit and grade |
| `GET` | `/api/v1/players/{player_id}/exams` | player | Active and past exams |
| `GET` | `/api/v1/players/{player_id}/courses` | player | Course progress |
| `GET` | `/api/v1/players/{player_id}/achievements` | player | Achievements earned |
| `GET` | `/api/v1/players/{player_id}/diploma` | player | Diploma progress |
| `GET` | `/api/v1/players/{player_id}/passed` | service | Passed course ids, for gating |

---

**`GET /api/v1/courses`** — catalogue. Query: `department`.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "course_id": "math-101", "name": "Mathematical Analysis", "department": "Math", "credits": 6, "required_for_diploma": true },
    { "course_id": "math-102", "name": "Linear Algebra", "department": "Math", "credits": 5, "required_for_diploma": true },
    { "course_id": "pad-201", "name": "Distributed Systems", "department": "SE", "credits": 6, "required_for_diploma": true }
  ]
}
```

---

**`POST /api/v1/exams`** — issue an exam. Called by Game Service on a Professor Zombie encounter.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "player_id": "player-uuid-123",
  "lobby_id": "lobby-uuid-789",
  "course_id": "math-101",
  "encounter_id": "encounter-uuid-001"
}
```

`201 Created`

```json
{
  "exam_id": "exam-uuid-555",
  "player_id": "player-uuid-123",
  "course_id": "math-101",
  "status": "in_progress",
  "question_count": 10,
  "passing_score": 6,
  "started_at": "2026-09-09T11:20:00Z",
  "expires_at": "2026-09-09T11:25:00Z"
}
```

Omitting `course_id` makes the service pick a course the player has not yet passed. Errors:
`409 EXAM_ALREADY_ACTIVE` · `422 COURSE_LOCKED` (three failed attempts today) ·
`422 ALL_COURSES_PASSED`

---

**`GET /api/v1/exams/{exam_id}`** — the exam with its questions. Correct answers are never included
in the response.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "exam_id": "exam-uuid-555",
  "course_id": "math-101",
  "course_name": "Mathematical Analysis",
  "status": "in_progress",
  "expires_at": "2026-09-09T11:25:00Z",
  "seconds_remaining": 240,
  "questions": [
    {
      "question_id": "q-math-017",
      "position": 1,
      "text": "What is the derivative of sin(x)?",
      "options": ["cos(x)", "-cos(x)", "sin(x)", "-sin(x)"],
      "answered_option": null
    }
  ]
}
```

Errors: `403 NOT_YOUR_EXAM` · `404 EXAM_NOT_FOUND`

---

**`POST /api/v1/exams/{exam_id}/answers`** — save one answer. Idempotent by nature: re-answering the
same question overwrites the previous choice.
Headers: `Authorization: Bearer <jwt>`

```json
{ "question_id": "q-math-017", "option_index": 0 }
```

`200 OK` — `{ "question_id": "q-math-017", "answered_option": 0, "answered_count": 1, "total": 10 }`

Errors: `422 EXAM_EXPIRED` · `422 EXAM_ALREADY_SUBMITTED`

---

**`POST /api/v1/exams/{exam_id}/submit`** — grade the exam. On a pass, publishes `ExamPassed` and
awards XP through Player Service.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

`200 OK`

```json
{
  "exam_id": "exam-uuid-555",
  "course_id": "math-101",
  "score": 8,
  "passing_score": 6,
  "passed": true,
  "grade": 9,
  "xp_awarded": 250,
  "achievements_unlocked": [
    { "code": "survived_the_pumpkin", "name": "Survived the Pumpkin", "description": "Passed every Math exam." }
  ],
  "world_unlock_requested": { "wing": "engineering" },
  "submitted_at": "2026-09-09T11:24:10Z"
}
```

Errors: `422 EXAM_ALREADY_SUBMITTED` · `409 IDEMPOTENCY_KEY_REUSED`

---

**`GET /api/v1/players/{player_id}/exams`** — active and historical exams. Query: `status`, `limit`.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "exam_id": "exam-uuid-555", "course_id": "math-101", "status": "passed", "score": 8, "grade": 9, "submitted_at": "2026-09-09T11:24:10Z" },
    { "exam_id": "exam-uuid-554", "course_id": "pad-201", "status": "in_progress", "expires_at": "2026-09-09T11:40:00Z" }
  ]
}
```

---

**`GET /api/v1/players/{player_id}/courses`** — per-course progress.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "course_id": "math-101", "name": "Mathematical Analysis", "status": "passed", "best_grade": 9, "attempts": 1 },
    { "course_id": "math-102", "name": "Linear Algebra", "status": "failed", "best_grade": 4, "attempts": 3, "locked_until_day": 6 },
    { "course_id": "pad-201", "name": "Distributed Systems", "status": "not_attempted", "attempts": 0 }
  ]
}
```

---

**`GET /api/v1/players/{player_id}/achievements`**
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    {
      "code": "survived_the_pumpkin",
      "name": "Survived the Pumpkin",
      "description": "Passed every Math exam.",
      "awarded_at": "2026-09-09T11:24:10Z",
      "reward": { "item_id": "energy-01", "count": 3, "title": "Survivor of the Pumpkin" }
    }
  ]
}
```

---

**`GET /api/v1/players/{player_id}/diploma`** — progress toward graduating, which is the win
condition of a session.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "player_id": "player-uuid-123",
  "credits_earned": 17,
  "credits_required": 60,
  "courses_passed": 3,
  "courses_required": 10,
  "gpa": 8.3,
  "graduated": false
}
```

---

**`GET /api/v1/players/{player_id}/passed`** — passed course ids only. The gating query used by
Crafting and Base; deliberately minimal so it stays cheap under repeated calls.
Headers: `Authorization: Bearer <service_jwt>`

`200 OK` — `{ "player_id": "player-uuid-123", "passed_course_ids": ["math-101", "math-102"] }`

---

### 4. World Service

**Owner:** Ilico Artemie · **TypeScript** · **Port `8004`** · [`world-service`](./world-service)

Creates and owns the **persistent physical state of the university**: the campus map, including
rooms, corridors, zones, resource nodes, barricade positions and zombie spawn configuration.

Different room types provide different resources:

| Room type | Yields |
| --- | --- |
| Laboratory | `metal-01` metal scraps, `electronics-01` electronics |
| Library | `paper-01` paper |
| Canteen | `food-01` food, `coffee-01` coffee |
| Classroom | `textbook-01` textbooks, `paper-01` paper |
| Corridor | nothing — connective only |
| FAF Cab | the starting homeroom, held as a base by Base Service |

**The map expands when players pass exams.** Exam Service publishes `ExamPassed`; World Service
procedurally generates and unlocks an appropriate new section of the university.

**Calls out to:** Resource (create pools for newly unlocked rooms).
**Consumed by:** Game (rooms, nodes, spawn points) · Base (room existence validation) · Zombie (spawn
configuration) · Crafting (wing-gated recipes).

#### Data model

| Table | Key columns |
| --- | --- |
| `worlds` | `world_id`, `lobby_id` (unique), `seed`, `generated_at` |
| `wings` | `wing_id`, `world_id`, `code`, `name`, `unlocked`, `unlocked_at`, `unlock_course_id` |
| `rooms` | `room_id`, `world_id`, `wing_id`, `code`, `type`, `x`, `y`, `safe` |
| `corridors` | `corridor_id`, `world_id`, `room_a`, `room_b` |
| `resource_nodes` | `node_id`, `room_id`, `item_id`, `richness`, `depleted_until_day` |
| `spawn_points` | `spawn_id`, `room_id`, `zombie_type_id`, `weight`, `night_only` |

#### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/v1/worlds` | service | Generate a world for a lobby |
| `GET` | `/api/v1/worlds/{lobby_id}` | player | Full map |
| `GET` | `/api/v1/worlds/{lobby_id}/wings` | player | Wings and unlock state |
| `GET` | `/api/v1/worlds/{lobby_id}/rooms` | player | Rooms, filterable |
| `GET` | `/api/v1/rooms/{room_id}` | player / service | One room with its nodes |
| `GET` | `/api/v1/worlds/{lobby_id}/nodes` | service | Resource nodes |
| `GET` | `/api/v1/worlds/{lobby_id}/spawns` | service | Spawn points for a phase |
| `POST` | `/api/v1/worlds/{lobby_id}/unlock` | service | Unlock a wing on `ExamPassed` |
| `PATCH` | `/api/v1/rooms/{room_id}` | service | Mark a room safe or contested |

---

**`POST /api/v1/worlds`** — generate the world for a new lobby. Creates rooms, nodes and spawn points
from a seed, then asks Resource Service to create a pool per node-bearing room.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "lobby_id": "lobby-uuid-789", "university": "FAF", "seed": "cab-survivors-2026" }
```

`201 Created`

```json
{
  "world_id": "world-uuid-001",
  "lobby_id": "lobby-uuid-789",
  "seed": "cab-survivors-2026",
  "home_room_id": "faf-cab",
  "wings": [
    { "wing_id": "wing-uuid-01", "code": "block_1", "name": "Block 1", "unlocked": true },
    { "wing_id": "wing-uuid-02", "code": "engineering", "name": "Engineering Wing", "unlocked": false, "unlock_course_id": "math-101" }
  ],
  "room_count": 24,
  "node_count": 31
}
```

Errors: `409 WORLD_ALREADY_EXISTS`

---

**`GET /api/v1/worlds/{lobby_id}`** — the full map. Locked wings are returned as stubs, without their
rooms.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "world_id": "world-uuid-001",
  "lobby_id": "lobby-uuid-789",
  "home_room_id": "faf-cab",
  "rooms": [
    { "room_id": "faf-cab", "code": "faf-cab", "type": "homeroom", "wing": "block_1", "x": 0, "y": 0, "safe": true },
    { "room_id": "lab-204", "code": "lab-204", "type": "laboratory", "wing": "block_1", "x": 2, "y": 1, "safe": false }
  ],
  "corridors": [{ "room_a": "faf-cab", "room_b": "lab-204" }],
  "locked_wings": [{ "code": "engineering", "name": "Engineering Wing", "unlock_course_id": "math-101" }]
}
```

---

**`GET /api/v1/worlds/{lobby_id}/wings`**
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "code": "block_1", "name": "Block 1", "unlocked": true, "room_count": 12 },
    { "code": "engineering", "name": "Engineering Wing", "unlocked": false, "unlock_course_id": "math-101", "room_count": 8 }
  ]
}
```

---

**`GET /api/v1/worlds/{lobby_id}/rooms`** — rooms in unlocked wings. Query: `type`, `wing`, `safe`.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    {
      "room_id": "lab-204",
      "code": "lab-204",
      "type": "laboratory",
      "wing": "block_1",
      "safe": false,
      "node_count": 2,
      "connects_to": ["faf-cab", "corridor-b"]
    }
  ]
}
```

---

**`GET /api/v1/rooms/{room_id}`** — one room with its nodes and spawn points. **Base Service calls
this to validate a room exists before spending any resource on a barricade.**
Headers: `Authorization: Bearer <jwt>` or `Bearer <service_jwt>`

`200 OK`

```json
{
  "room_id": "lab-204",
  "code": "lab-204",
  "type": "laboratory",
  "wing": "block_1",
  "safe": false,
  "nodes": [
    { "node_id": "node-metal-7", "item_id": "metal-01", "richness": 3, "depleted": false },
    { "node_id": "node-elec-2", "item_id": "electronics-01", "richness": 1, "depleted": true, "depleted_until_day": 6 }
  ],
  "spawn_points": [{ "spawn_id": "spawn-11", "zombie_type_id": "tourist_zombie", "weight": 5, "night_only": true }],
  "connects_to": ["faf-cab", "corridor-b"]
}
```

Errors: `404 ROOM_NOT_FOUND` — the response Base Service relies on to reject a bad barricade request.

---

**`GET /api/v1/worlds/{lobby_id}/nodes`** — every node, for Game Service action validation. Query:
`item_id`, `depleted`.
Headers: `Authorization: Bearer <service_jwt>`

`200 OK`

```json
{
  "items": [
    { "node_id": "node-metal-7", "room_id": "lab-204", "item_id": "metal-01", "richness": 3, "pool_id": "pool-uuid-001", "depleted": false }
  ]
}
```

---

**`GET /api/v1/worlds/{lobby_id}/spawns`** — spawn points for the current phase. Query: `phase`.
Headers: `Authorization: Bearer <service_jwt>`

`200 OK`

```json
{
  "phase": "night",
  "items": [
    { "spawn_id": "spawn-11", "room_id": "lab-204", "zombie_type_id": "tourist_zombie", "weight": 5 },
    { "spawn_id": "spawn-12", "room_id": "exam-hall-3", "zombie_type_id": "professor_zombie", "weight": 2 }
  ]
}
```

---

**`POST /api/v1/worlds/{lobby_id}/unlock`** — unlock a wing. Triggered by `ExamPassed`. Generates the
wing rooms and nodes, then creates their resource pools.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "course_id": "math-101", "player_id": "player-uuid-123" }
```

`200 OK`

```json
{
  "wing": { "code": "engineering", "name": "Engineering Wing", "unlocked": true, "unlocked_at": "2026-09-09T11:24:12Z" },
  "rooms_added": [
    { "room_id": "eng-101", "type": "laboratory" },
    { "room_id": "eng-102", "type": "classroom" }
  ],
  "nodes_added": 6,
  "pools_created": 4
}
```

`200 OK` with `"already_unlocked": true` if the wing was already open — unlocking is naturally
idempotent. Errors: `422 NO_WING_FOR_COURSE`

---

**`PATCH /api/v1/rooms/{room_id}`** — mark a room safe or contested. Called by Game Service after a
`clear_room` action or a night spawn.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "safe": true, "reason": "room_cleared" }
```

`200 OK` — `{ "room_id": "lab-204", "safe": true }`

---

### 7. Base Service

**Owner:** Gancear Nichita · **TypeScript** · **Port `8007`** · [`base-service`](./base-service)

Responsible for the **player survival base**, initially represented by the FAF Cab room. Manages base
upgrades, barricades, facilities and defensive improvements. Players spend resources obtained through
Resource Service to reinforce rooms, construct barricades, improve facilities, unlock storage
capacity and decorate the homeroom.

The base can also contain **Kiki**, whose interactions provide random booster objects or other
rewards.

> The service tracks the persistent state of the base separately from World Service: **World Service
> owns the campus geography, while Base Service owns what the players have built or changed within
> that geography.**

**Calls out to:** Resource (consume materials) · World (validate a room exists) · Player (deliver
Kiki rewards, verify cosmetic ownership) · Exam (facility unlock gating).
**Consumed by:** Game (create base, apply barricade damage) · Crafting (workbench level check).

#### Data model

| Table | Key columns |
| --- | --- |
| `bases` | `base_id`, `lobby_id` (unique), `home_room_id`, `level`, `defense_rating`, `storage_capacity` |
| `facilities` | `facility_id`, `base_id`, `type`, `level`, `status` |
| `barricades` | `barricade_id`, `base_id`, `room_id`, `material`, `strength`, `health` |
| `decorations` | `decoration_id`, `base_id`, `slot`, `item_id` |
| `kiki_interactions` | `interaction_id`, `base_id`, `player_id`, `idempotency_key` (unique), `reward_item_id`, `day` |
| `base_events` | `idempotency_key` (unique), `base_id`, `kind`, `payload`, `response` |

#### Upgrade tiers

| Base level | Cost | Defense | Storage |
| --- | --- | --- | --- |
| 1 → 2 | `wood-01` ×10, `metal-01` ×5 | 10 → 22 | 50 → 90 |
| 2 → 3 | `wood-01` ×15, `metal-01` ×8 | 22 → 45 | 90 → 150 |
| 3 → 4 | `wood-01` ×20, `metal-01` ×12 | 45 → 60 | 150 → 200 |
| 4 → 5 | `metal-01` ×18, `electronics-01` ×4 | 60 → 85 | 200 → 280 |

Maximum level is 10. Facilities: `workbench`, `generator`, `infirmary`, `storage`, `watchtower`.
Barricade materials: `wood` (strength 30), `metal` (strength 60), `reinforced` (strength 100,
requires base level ≥ 3).

#### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/v1/bases` | service | Create the base for a lobby |
| `GET` | `/api/v1/bases/{base_id}` | player | Full base state |
| `GET` | `/api/v1/bases` | player | Find a base by lobby |
| `GET` | `/api/v1/bases/{base_id}/blueprints` | player | Costs and unlock state |
| `POST` | `/api/v1/bases/{base_id}/upgrade` | player | Raise the base one level |
| `GET` | `/api/v1/bases/{base_id}/facilities` | player | List facilities |
| `POST` | `/api/v1/bases/{base_id}/facilities` | player | Build or upgrade a facility |
| `GET` | `/api/v1/bases/{base_id}/barricades` | player | List barricades |
| `POST` | `/api/v1/bases/{base_id}/barricades` | player | Construct a barricade |
| `PATCH` | `/api/v1/barricades/{barricade_id}` | player / service | Repair or damage |
| `POST` | `/api/v1/bases/{base_id}/storage` | player | Unlock storage capacity |
| `POST` | `/api/v1/bases/{base_id}/decorations` | player | Decorate the homeroom |
| `POST` | `/api/v1/bases/{base_id}/kiki` | player | Interact with Kiki |

---

**`POST /api/v1/bases`** — create the base. Called by Game Service on lobby creation.
Headers: `Authorization: Bearer <service_jwt>` · `Idempotency-Key: <uuid>`

```json
{ "lobby_id": "lobby-uuid-789", "home_room_id": "faf-cab" }
```

`201 Created`

```json
{
  "base_id": "base-uuid-001",
  "lobby_id": "lobby-uuid-789",
  "home_room_id": "faf-cab",
  "level": 1,
  "defense_rating": 10,
  "storage_capacity": 50,
  "facilities": [],
  "created_at": "2026-09-09T11:00:00Z"
}
```

Errors: `409 BASE_ALREADY_EXISTS`

---

**`GET /api/v1/bases/{base_id}`**
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "base_id": "base-uuid-001",
  "lobby_id": "lobby-uuid-789",
  "home_room_id": "faf-cab",
  "level": 3,
  "defense_rating": 45,
  "storage_capacity": 150,
  "storage_used": 88,
  "facilities": [
    { "facility_id": "fac-uuid-01", "type": "workbench", "level": 2, "status": "operational" },
    { "facility_id": "fac-uuid-02", "type": "generator", "level": 1, "status": "damaged" }
  ],
  "barricade_count": 4,
  "decorations": [{ "slot": "wall_north", "item_id": "poster-faf-01" }],
  "kiki": { "present": true, "fed_on_day": 4, "next_available_day": 5 }
}
```

Errors: `404 BASE_NOT_FOUND`

---

**`GET /api/v1/bases?lobby_id={lobby_id}`** — lookup for callers holding only a lobby id. Response
identical to the above.

---

**`GET /api/v1/bases/{base_id}/blueprints`** — next-tier costs and unlock state, so clients can
render affordability without duplicating the cost table.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "base_id": "base-uuid-001",
  "current_level": 3,
  "next_level": 4,
  "upgrade_cost": [
    { "item_id": "wood-01", "count": 20 },
    { "item_id": "metal-01", "count": 12 }
  ],
  "affordable": false,
  "missing": [{ "item_id": "metal-01", "required": 12, "available": 9 }],
  "facilities": [
    {
      "type": "workbench",
      "current_level": 2,
      "next_level": 3,
      "cost": [{ "item_id": "metal-01", "count": 8 }],
      "locked": false
    },
    {
      "type": "infirmary",
      "current_level": 0,
      "next_level": 1,
      "cost": [{ "item_id": "paper-01", "count": 10 }],
      "locked": true,
      "unlock_condition": { "type": "exam_passed", "value": "bio-101" }
    }
  ]
}
```

---

**`POST /api/v1/bases/{base_id}/upgrade`** — raise the base one level. Consumes materials through
Resource Service, then applies the change locally in the same logical unit.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{ "player_id": "player-uuid-123" }
```

`200 OK`

```json
{
  "base_id": "base-uuid-001",
  "level": 4,
  "defense_rating": 60,
  "storage_capacity": 200,
  "consumed": [
    { "item_id": "wood-01", "count": 20 },
    { "item_id": "metal-01", "count": 12 }
  ],
  "transaction_id": "tx-uuid-201"
}
```

Errors: `409 INSUFFICIENT_RESOURCES` with `details.missing` · `422 MAX_LEVEL_REACHED`

---

**`POST /api/v1/bases/{base_id}/facilities`** — build if absent, upgrade if present.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{ "player_id": "player-uuid-123", "type": "workbench" }
```

`200 OK`

```json
{
  "facility_id": "fac-uuid-01",
  "base_id": "base-uuid-001",
  "type": "workbench",
  "level": 3,
  "status": "operational",
  "consumed": [{ "item_id": "metal-01", "count": 8 }],
  "transaction_id": "tx-uuid-202"
}
```

Errors: `403 FACILITY_LOCKED` with the unlock condition · `409 INSUFFICIENT_RESOURCES` ·
`422 MAX_FACILITY_LEVEL`

---

**`GET /api/v1/bases/{base_id}/facilities`**
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "facility_id": "fac-uuid-01", "type": "workbench", "level": 3, "status": "operational" },
    { "facility_id": "fac-uuid-02", "type": "generator", "level": 1, "status": "damaged" }
  ]
}
```

---

**`POST /api/v1/bases/{base_id}/barricades`** — the room is validated against World Service **before**
any material is spent.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{ "player_id": "player-uuid-123", "room_id": "lab-204", "material": "wood" }
```

`201 Created`

```json
{
  "barricade_id": "barricade-uuid-001",
  "base_id": "base-uuid-001",
  "room_id": "lab-204",
  "material": "wood",
  "strength": 30,
  "health": 30,
  "built_by": "player-uuid-123",
  "consumed": [{ "item_id": "wood-01", "count": 10 }]
}
```

Errors: `404 ROOM_NOT_FOUND` (rejected upstream by World) · `409 ROOM_ALREADY_BARRICADED` ·
`403 MATERIAL_REQUIRES_HIGHER_LEVEL` · `409 INSUFFICIENT_RESOURCES`

---

**`GET /api/v1/bases/{base_id}/barricades`** — query: `room_id`.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "barricade_id": "barricade-uuid-001", "room_id": "lab-204", "material": "wood", "strength": 30, "health": 18 }
  ]
}
```

---

**`PATCH /api/v1/barricades/{barricade_id}`** — repair is player-initiated and costs materials; damage
is applied by Game Service during a zombie attack and costs nothing.
Headers: `Authorization: Bearer <jwt>` (repair) or `Bearer <service_jwt>` (damage) ·
`Idempotency-Key: <uuid>`

```json
{ "operation": "repair", "player_id": "player-uuid-123" }
```

```json
{ "operation": "damage", "amount": 12, "zombie_id": "zombie-uuid-001" }
```

`200 OK`

```json
{ "barricade_id": "barricade-uuid-001", "health": 30, "strength": 30, "destroyed": false }
```

When health reaches zero the barricade is removed and the response reports `"destroyed": true`.
Errors: `404 BARRICADE_NOT_FOUND` · `409 INSUFFICIENT_RESOURCES` · `422 ALREADY_FULL_HEALTH`

---

**`POST /api/v1/bases/{base_id}/storage`** — unlock the next storage tier.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{ "player_id": "player-uuid-123" }
```

`200 OK`

```json
{
  "base_id": "base-uuid-001",
  "storage_capacity": 250,
  "previous_capacity": 200,
  "consumed": [{ "item_id": "metal-01", "count": 15 }]
}
```

---

**`POST /api/v1/bases/{base_id}/decorations`** — place a cosmetic the player already owns. Ownership
is verified against Player Service.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{ "player_id": "player-uuid-123", "slot": "wall_north", "item_id": "poster-faf-01" }
```

`201 Created`

```json
{
  "decoration_id": "decor-uuid-001",
  "base_id": "base-uuid-001",
  "slot": "wall_north",
  "item_id": "poster-faf-01"
}
```

Errors: `403 ITEM_NOT_OWNED` · `409 SLOT_OCCUPIED`

---

**`POST /api/v1/bases/{base_id}/kiki`** — feed Kiki and roll a weighted random reward, delivered to
the player inventory through Player Service. Limited to **once per in-game day per player**.
**Idempotency matters most here** — a replayed request would otherwise hand out a free second reward.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{ "player_id": "player-uuid-123", "offering": { "item_id": "food-01", "count": 2 } }
```

`200 OK`

```json
{
  "interaction_id": "kiki-uuid-001",
  "player_id": "player-uuid-123",
  "mood": "pleased",
  "reward": { "item_id": "energy-01", "name": "Energy Drink", "count": 1, "rarity": "uncommon" },
  "next_available_day": 5
}
```

Reward table: `common` 60 % (consumable ×1), `uncommon` 30 % (consumable ×2 or booster),
`rare` 9 % (equipment), `legendary` 1 % (cosmetic). Errors: `429 KIKI_ALREADY_FED` with
`next_available_day` · `409 INSUFFICIENT_RESOURCES` (no offering to give)

---

### 8. Crafting Service

**Owner:** Gancear Nichita · **TypeScript** · **Port `8008`** · [`crafting-service`](./crafting-service)

Allows players to combine resources into useful survival equipment. Recipes are defined by the
service and can require resources obtained from different areas of the university. The service
validates that the player has the required materials and **performs the crafting operation
atomically**. Crafted objects are transferred to the player inventory through Player Service.

Some recipes only become available after passing particular exams, reaching a certain level,
unlocking a university wing or discovering a special resource.

**Calls out to:** Resource (consume inputs, compensate) · Player (deliver output, read level) · Exam
(passed courses) · World (unlocked wings) · Base (workbench level).
**Consumed by:** Game (crafting from an in-game workbench action).

#### Recipe catalogue

| Recipe id | Name | Inputs | Output | Unlock |
| --- | --- | --- | --- | --- |
| `recipe-barricade-kit` | Barricade Kit | `wood-01` ×4, `metal-01` ×2 | `barricade-kit-01` ×1 | — |
| `recipe-improvised-weapon` | Improvised Weapon | `paper-01` ×2, `metal-01` ×3 | `axe-01` ×1 | player level ≥ 2 |
| `recipe-energy-booster` | Energy Booster | `food-01` ×3, `chemicals-01` ×1 | `energy-01` ×2 | — |
| `recipe-zombie-detector` | Zombie Detector | `metal-01` ×5, `electronics-01` ×2 | `detector-01` ×1 | wing `engineering` unlocked |
| `recipe-cheat-sheet` | Exam Cheat Sheet | `paper-01` ×5, `wood-01` ×1 | `cheatsheet-01` ×1 | course `math-101` passed |
| `recipe-reinforced-plate` | Reinforced Plate | `metal-01` ×8, `textbook-01` ×2 | `plate-01` ×1 | workbench level ≥ 2 |

#### Data model

| Table | Key columns |
| --- | --- |
| `recipes` | `recipe_id`, `name`, `category`, `output_item_id`, `output_count`, `required_facility`, `required_facility_level` |
| `recipe_inputs` | `recipe_id`, `item_id`, `count` |
| `recipe_unlocks` | `recipe_id`, `condition_type`, `condition_value` |
| `craft_jobs` | `job_id`, `idempotency_key` (unique), `player_id`, `recipe_id`, `status`, `consume_tx_id`, `deliver_ref`, `created_at` |

`condition_type` ∈ `player_level`, `exam_passed`, `wing_unlocked`, `facility_level`,
`resource_discovered`.
`status` ∈ `pending`, `completed`, `failed`, `compensated`.

#### The crafting saga

Crafting spans three services, so it is an orchestrated saga with the craft job as the local source
of truth:

1. Resolve the recipe → `404 RECIPE_NOT_FOUND`.
2. Evaluate unlock conditions against Player, Exam, World and Base → `403 RECIPE_LOCKED` or
   `422 FACILITY_LEVEL_TOO_LOW`.
3. Insert a `craft_job` carrying the caller idempotency key. **The unique index is the gate: on
   conflict, return the stored result and stop.** A retry never crafts twice.
4. `POST /api/v1/transactions/consume` on Resource Service, forwarding the same key. Resource Service
   is itself idempotent, so a retried step 4 is safe. On insufficient stock → job `failed`, commit,
   return `409`.
5. `PATCH /api/v1/players/{id}/inventory` with `operation: add`, same key, to deliver the output.
6. Mark the job `completed` and publish `ItemCrafted`.

**Compensation.** If step 5 fails permanently after step 4 succeeded, the service calls
`POST /api/v1/transactions/{consume_tx_id}/compensate` to return the materials, and marks the job
`compensated`. **The player is never left having paid for an item they did not receive.**

Because every step is keyed off one idempotency key, the saga is replayable from any point.

#### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/v1/recipes` | player | Recipe catalogue |
| `GET` | `/api/v1/recipes/{recipe_id}` | player | Recipe detail |
| `GET` | `/api/v1/recipes/available` | player | Catalogue annotated per player |
| `POST` | `/api/v1/recipes/{recipe_id}/preview` | player | Dry run — craftable? |
| `POST` | `/api/v1/crafts` | player | Craft, atomically and exactly once |
| `GET` | `/api/v1/crafts/{job_id}` | player | Terminal state of a craft |
| `GET` | `/api/v1/crafts` | player | Craft history |

---

**`GET /api/v1/recipes`** — the catalogue, independent of any player. Query: `category` ∈ `defense`,
`weapon`, `consumable`, `utility`.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    {
      "recipe_id": "recipe-barricade-kit",
      "name": "Barricade Kit",
      "category": "defense",
      "inputs": [
        { "item_id": "wood-01", "count": 4 },
        { "item_id": "metal-01", "count": 2 }
      ],
      "output": { "item_id": "barricade-kit-01", "count": 1 },
      "unlock_condition": null
    },
    {
      "recipe_id": "recipe-cheat-sheet",
      "name": "Exam Cheat Sheet",
      "category": "utility",
      "inputs": [
        { "item_id": "paper-01", "count": 5 },
        { "item_id": "wood-01", "count": 1 }
      ],
      "output": { "item_id": "cheatsheet-01", "count": 1 },
      "unlock_condition": { "type": "exam_passed", "value": "math-101" }
    }
  ]
}
```

---

**`GET /api/v1/recipes/{recipe_id}`**
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "recipe_id": "recipe-zombie-detector",
  "name": "Zombie Detector",
  "category": "utility",
  "description": "Beeps when a Professor Zombie is within three rooms.",
  "inputs": [
    { "item_id": "metal-01", "count": 5 },
    { "item_id": "electronics-01", "count": 2 }
  ],
  "output": { "item_id": "detector-01", "count": 1 },
  "unlock_condition": { "type": "wing_unlocked", "value": "engineering" },
  "required_facility": { "type": "workbench", "level": 2 }
}
```

Errors: `404 RECIPE_NOT_FOUND`

---

**`GET /api/v1/recipes/available?player_id={player_id}&lobby_id={lobby_id}`** — the catalogue
annotated per player, with the reason each locked recipe is locked.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "recipe_id": "recipe-barricade-kit", "name": "Barricade Kit", "unlocked": true },
    {
      "recipe_id": "recipe-cheat-sheet",
      "name": "Exam Cheat Sheet",
      "unlocked": false,
      "locked_reason": "Requires passing course math-101.",
      "unlock_condition": { "type": "exam_passed", "value": "math-101" }
    }
  ]
}
```

---

**`POST /api/v1/recipes/{recipe_id}/preview`** — evaluate unlocks **and** material availability
without consuming anything, so a client can grey out a button instead of discovering the failure by
attempting a craft.
Headers: `Authorization: Bearer <jwt>`

```json
{ "player_id": "player-uuid-123", "lobby_id": "lobby-uuid-789", "base_id": "base-uuid-001" }
```

`200 OK`

```json
{
  "recipe_id": "recipe-zombie-detector",
  "craftable": false,
  "unlocked": true,
  "missing_materials": [{ "item_id": "electronics-01", "required": 2, "available": 0 }],
  "facility_ok": true
}
```

---

**`POST /api/v1/crafts`** — craft an item, atomically and exactly once.
Headers: `Authorization: Bearer <jwt>` · `Idempotency-Key: <uuid>`

```json
{
  "player_id": "player-uuid-123",
  "recipe_id": "recipe-barricade-kit",
  "lobby_id": "lobby-uuid-789",
  "base_id": "base-uuid-001"
}
```

`201 Created`

```json
{
  "job_id": "craft-uuid-001",
  "player_id": "player-uuid-123",
  "recipe_id": "recipe-barricade-kit",
  "status": "completed",
  "consumed": [
    { "item_id": "wood-01", "count": 4 },
    { "item_id": "metal-01", "count": 2 }
  ],
  "produced": { "item_id": "barricade-kit-01", "count": 1 },
  "consume_tx_id": "tx-uuid-091",
  "completed_at": "2026-09-09T12:30:00Z"
}
```

A replayed key returns `200 OK` with the identical body and `"replayed": true`. Nothing is crafted or
consumed a second time.

`409 INSUFFICIENT_RESOURCES`

```json
{
  "error": {
    "code": "INSUFFICIENT_RESOURCES",
    "message": "Not enough materials to craft Barricade Kit.",
    "details": { "job_id": "craft-uuid-002", "status": "failed", "missing": [{ "item_id": "metal-01", "required": 2, "available": 1 }] }
  }
}
```

Other errors: `403 RECIPE_LOCKED` with the unlock condition · `422 FACILITY_LEVEL_TOO_LOW` ·
`500 CRAFT_COMPENSATED` when delivery failed and the materials were returned.

---

**`GET /api/v1/crafts/{job_id}`** — the terminal state of a craft, for confirming an outcome after a
timeout rather than retrying blindly.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "job_id": "craft-uuid-001",
  "player_id": "player-uuid-123",
  "recipe_id": "recipe-barricade-kit",
  "status": "completed",
  "consume_tx_id": "tx-uuid-091",
  "created_at": "2026-09-09T12:29:58Z",
  "completed_at": "2026-09-09T12:30:00Z"
}
```

Errors: `404 CRAFT_JOB_NOT_FOUND`

---

**`GET /api/v1/crafts?player_id={player_id}`** — craft history. Query: `status`, `limit`, `cursor`.
Headers: `Authorization: Bearer <jwt>`

`200 OK`

```json
{
  "items": [
    { "job_id": "craft-uuid-001", "recipe_id": "recipe-barricade-kit", "status": "completed", "completed_at": "2026-09-09T12:30:00Z" },
    { "job_id": "craft-uuid-002", "recipe_id": "recipe-zombie-detector", "status": "failed", "created_at": "2026-09-09T12:31:00Z" }
  ],
  "next_cursor": null
}
```

---


## GitHub workflow

### Branches

| Branch | Purpose | Protected |
| --- | --- | --- |
| `main` | Production-ready, always deployable. Only release PRs from `development` land here. | Yes |
| `development` | Integration branch and the repository default. All feature work targets this. | Yes |

### Protection rules

Applied identically to `main` and `development`:

- Require a pull request before merging
- **Require 2 approving reviews** — with four members and eight interdependent services, one approval
  is not enough to catch a contract break in a service the author does not own
- Dismiss stale approvals when new commits are pushed
- Require branches to be up to date before merging
- Require conversation resolution before merging
- Do not allow bypassing these settings, including for administrators
- Block force pushes and deletions

### Branch naming

```
<type>/<service>/<issue-number>-<short-kebab-summary>
```

Examples:

```
feat/crafting-service/42-atomic-craft-saga
fix/zombie-service/57-loot-lost-on-despawn
refactor/resource-service/61-idempotency-index
docs/contracts/70-add-world-unlock-endpoint
```

| Type | Use for |
| --- | --- |
| `feat/` | New functionality |
| `fix/` | Bug fixes |
| `hotfix/` | Urgent fixes branched from `main` |
| `refactor/` | Restructuring with no behaviour change |
| `perf/` | Performance work |
| `test/` | Adding or repairing tests |
| `docs/` | Documentation, including this contract |
| `chore/` | Dependencies, CI, tooling |

The `<service>` segment is one of the eight service names, or `contracts` for changes to this
document, or `shared` for anything genuinely cross-cutting. **The issue number is mandatory** — it is
how the GitHub Project board tracks work automatically, and it means a branch name alone tells you
what the change was for.

### Commits

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`, imperative
mood, no trailing period.

```
feat(crafting): add compensation path when delivery fails
fix(zombie): return stolen loot to the pool on despawn
docs(contracts): document the resource consume endpoint
```

### Merging

**Squash and merge into `development`.** One feature becomes one commit, keeping history linear and
reverts trivial.

**Merge commit for release PRs into `main`,** so a release is a single identifiable point in history
that can be tagged and rolled back as a unit.

Feature branches are deleted automatically on merge.

### Pull requests

Every PR uses [`.github/PULL_REQUEST_TEMPLATE.md`](./.github/PULL_REQUEST_TEMPLATE.md) and must
carry: what changed and why, the linked issue, how to test, and the **contract-impact** section.

**Contract-change protocol.** If a PR changes any endpoint, payload, response or event shape in this
document:

1. The change to this README ships **in the same PR** as the code.
2. Every owner whose service appears under that service's *Consumed by* line is added as a reviewer.
3. The PR is labelled `contract-change`.
4. Breaking changes ship as `/api/v2/` alongside `v1`; `v1` is removed only once every consumer has
   migrated.

This exists because a silent contract drift in Resource Service breaks four services owned by three
people, and TypeScript will not catch it at compile time.

### Testing

| Scope | Requirement |
| --- | --- |
| Unit coverage | **≥ 80 %** of domain logic per service, measured in CI |
| Idempotency | **Every** endpoint accepting `Idempotency-Key` has a test that replays the key and asserts no second effect |
| Sagas | Crafting, trading and base upgrades have integration tests covering success, insufficient-resources, and compensation-after-delivery-failure |
| Contract | Each consumer keeps fixture tests pinned to the exact payloads in this document |
| Pre-PR | The full suite passes locally; CI enforces it from Lab 2 |

The idempotency and saga rows are not negotiable — they are the correctness properties this
architecture rests on, and an untested compensation path is an unwritten one.

### Versioning and releases

Semantic Versioning per service, `MAJOR.MINOR.PATCH`.

| Bump | When |
| --- | --- |
| `MAJOR` | Breaking contract change other services depend on |
| `MINOR` | Backward-compatible feature — new zombie type, new recipe, new wing |
| `PATCH` | Bug fix or internal improvement |

Releases are tagged `v1.2.0` on `main` and published as GitHub Releases with a changelog in
Keep a Changelog format (`Added` / `Changed` / `Fixed` / `Removed` / `Security`). The CPR carries its
own tag for each lab presentation: `lab-0`, `lab-1`, and so on, so any lab can be reproduced exactly
as presented.

### Code review

Reviewers check, in order: does it match the contract in this document; are the idempotency and
error paths tested; does it stay inside the service boundary; and are there secrets or build
artefacts in the diff. Authors keep PRs focused, push fixes as separate commits so the diff stays
reviewable, and re-request review after addressing feedback.

### Definition of done

A task is done when: the code is merged to `development`; tests pass and coverage holds; this README
is updated if the contract moved; the service README is updated if its endpoints moved; the linked
issue is closed by the PR; and the Project board card has moved to **Done** automatically.

### Non-negotiables

- No `.env`, credential, API key, `node_modules/`, `vendor/` or build artefact is ever committed.
  `.gitignore` is the first line of defence and review is the second.
- No direct pushes to `main` or `development`.
- No service reads another service's database.
- No endpoint ships without appearing in this document.

---

## Repository layout

```
.
├── README.md                          ← this document: design + contract + workflow
├── .gitignore
├── .gitmodules                        ← the eight private service repositories
├── .github/
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── CODEOWNERS
├── docs/                              ← architecture diagrams (to be added)
├── guide-private.md                   ← how to create and link the private repos
├── player-service/                    ← submodule (private)
├── game-service/                      ← submodule (private)
├── exam-service/                      ← submodule (private)
├── world-service/                     ← submodule (private)
├── zombie-service/                    ← submodule (private)
├── resource-service/                  ← submodule (private)
├── base-service/                      ← submodule (private)
└── crafting-service/                  ← submodule (private)
```

### Submodules

The eight service repositories are **private by design**. Only the professor is invited to them —
team members integrate against the contract in this document rather than by reading each other's
source, which is what keeps the boundaries honest.

```bash
git clone --recurse-submodules https://github.com/<GITHUB_ORG>/<CPR_REPO>.git
```

Cloning a submodule without access fails with a permission error. **That is expected behaviour, not
a misconfiguration.** Step-by-step instructions for creating, populating and linking these
repositories are in **[guide-private.md](./guide-private.md)**.

---

## Glossary

Shared vocabulary. **Item identifiers are contract, not implementation detail** — a service inventing
its own spelling for `metal-01` is a breaking change.

### Resource items

| `item_id` | Name | Source |
| --- | --- | --- |
| `wood-01` | Wood | Chopping benches |
| `metal-01` | Metal Scraps | Laboratories |
| `paper-01` | Paper | Library, classrooms |
| `food-01` | Food | Canteen |
| `coffee-01` | Coffee | Canteen |
| `electronics-01` | Electronics | Laboratories, engineering wing |
| `textbook-01` | Textbook | Classrooms |
| `chemicals-01` | Chemicals | Laboratories, engineering wing |

### Crafted and consumable items

| `item_id` | Name | Category |
| --- | --- | --- |
| `barricade-kit-01` | Barricade Kit | equipment |
| `axe-01` | Improvised Axe | equipment |
| `detector-01` | Zombie Detector | equipment |
| `plate-01` | Reinforced Plate | equipment |
| `cheatsheet-01` | Exam Cheat Sheet | consumable |
| `energy-01` | Energy Drink | consumable |
| `sandwich-01` | Davidan Sandwich | consumable |
| `poster-faf-01` | FAF Poster | cosmetic |

### Terms

| Term | Meaning |
| --- | --- |
| **CPR** | Common Public Repository — this repository |
| **Lobby** | One game session, owned by Game Service |
| **Cycle** | One day or night phase within a lobby |
| **Pool** | A container of resource stock owned by Resource Service, scoped to a node, player or lobby |
| **Node** | A resource-yielding point in a room, owned by World Service |
| **Wing** | A section of the university, unlocked by passing exams |
| **Saga** | A multi-service operation with an explicit compensation path |
| **Idempotency key** | A caller-supplied UUID making a mutating request safe to retry |
| **Kiki** | The FAF Cab resident who exchanges offerings for random rewards |

---

<div align="center">

**FAF.PAD21.1 — Autumn 2026 — Laboratory 0**
Technical University of Moldova · Faculty of Computers, Informatics and Microelectronics

</div>
