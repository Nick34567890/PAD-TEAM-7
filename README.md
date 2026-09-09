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

