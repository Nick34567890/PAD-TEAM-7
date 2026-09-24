# Database scripts

One schema per service, mirroring the `src/db/schema.sql` each service applies at boot. They are
published here so the team's deployment can create a database without cloning a private repository,
and so the schemas can be reviewed against the contract in one place.

| File | Database | Service |
| --- | --- | --- |
| [`base_db.sql`](./base_db.sql) | `base_db` | Base Service (`8007`) |
| [`crafting_db.sql`](./crafting_db.sql) | `crafting_db` | Crafting Service (`8008`) |

Every statement is `CREATE ... IF NOT EXISTS`, so applying a script twice is a no-op.

The team deployment mounts each file into its Postgres container's
`/docker-entrypoint-initdb.d/`, which Postgres runs **only when the data volume is empty** — that
is, on the very first start. A service also applies its own schema at boot, so a database that
already holds data is left untouched either way.

Applying one by hand:

```bash
psql "postgres://base:<password>@localhost:5432/base_db" -f base_db.sql
```

Owners add their file here as their service joins `deploy/docker-compose.yml`.
