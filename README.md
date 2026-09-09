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

---

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

