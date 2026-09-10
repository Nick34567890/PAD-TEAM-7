# System Architecture

The CPR is the public contract repository. Each service owns one domain and its private database;
services communicate through versioned HTTP APIs and selected domain events. The Game Service is
the runtime coordinator, while Player Service issues tokens and Resource Service is the atomic
resource write hub.

```mermaid
flowchart LR
    Client[Game client]
    Gateway[API Gateway :8080]
    Player[Player Service :8001\nGo]
    Game[Game Service :8002\nGo]
    Exam[Exam Service :8003\nTypeScript]
    World[World Service :8004\nTypeScript]
    Zombie[Zombie Service :8005\nGo]
    Resource[Resource Service :8006\nGo]
    Base[Base Service :8007\nTypeScript]
    Crafting[Crafting Service :8008\nTypeScript]
    Registry[Service Registry :8500]

    Client --> Gateway
    Gateway --> Player
    Gateway --> Game
    Gateway --> Exam
    Gateway --> World
    Gateway --> Base
    Gateway --> Crafting

    Game --> Player
    Game --> World
    Game --> Exam
    Game --> Zombie
    Game --> Resource
    Game --> Base
    Exam -. ExamPassed .-> World
    World --> Resource
    Zombie --> Player
    Zombie --> Resource
    Base --> Resource
    Base --> World
    Base --> Player
    Base --> Exam
    Crafting --> Resource
    Crafting --> Player
    Crafting --> Exam
    Crafting --> World
    Crafting --> Base
    Player -. service discovery .-> Registry
    Game -. service discovery .-> Registry
```

## Runtime rules

- Every service owns its own PostgreSQL database; no service reads another service's tables.
- REST uses `/api/v1/`; WebSocket sessions use `/ws/v1/`.
- Player Service issues RS256 player tokens. Other services validate them using Player JWKS.
- Cross-service writes use service tokens and an `Idempotency-Key`.
- `ExamPassed` is the event that unlocks new World wings.
- Game owns timers and orchestration, but not map, inventory, resource, or zombie truth.

See the [full communication contract](../README.md#communication-contract) for payloads,
responses, errors, and data models.