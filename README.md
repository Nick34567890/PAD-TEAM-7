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

