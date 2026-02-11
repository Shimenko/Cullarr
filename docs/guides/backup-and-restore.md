# Backup And Restore

This guide provides end-to-end backup and restore flows for both runtime styles:
- local app run (`bin/dev`)
- Docker Compose (`web`/`worker` containers)

## Why services should be stopped first

Stop write-capable app services before backup or restore.

If `web`/`worker` keep writing while you copy or restore data, you can end up with inconsistent snapshots.

## Before You Start

From repository root:

```bash
cd /path/to/cullarr
mkdir -p backup
```

## Stop/start commands by runtime

Local app run:
- stop: Ctrl+C in the `bin/dev` terminal
- start: `bin/dev`

Docker Compose:
- stop app services: `docker compose --profile <sqlite|postgres> --env-file <env-file> stop web worker`
- start app services: `docker compose --profile <sqlite|postgres> --env-file <env-file> start web worker`

## SQLite: full backup

### Local app run

1. Stop local app processes (`bin/dev` terminal, Ctrl+C).
2. Copy DB role files:

```bash
cp storage/development.sqlite3 backup/development.sqlite3
cp storage/development_cache.sqlite3 backup/development_cache.sqlite3
cp storage/development_queue.sqlite3 backup/development_queue.sqlite3
cp storage/development_cable.sqlite3 backup/development_cable.sqlite3
```

3. Start local app again:

```bash
bin/dev
```

### Docker Compose (sqlite profile)

1. Stop app services:

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite stop web worker
```

2. Copy DB files:

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite cp web:/rails/storage/production.sqlite3 ./backup/production.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp web:/rails/storage/production_cache.sqlite3 ./backup/production_cache.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp web:/rails/storage/production_queue.sqlite3 ./backup/production_queue.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp web:/rails/storage/production_cable.sqlite3 ./backup/production_cable.sqlite3
```

3. Start app services:

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite start web worker
```

## SQLite: full restore

### Local app run

1. Stop local app processes.
2. Restore files:

```bash
cp backup/development.sqlite3 storage/development.sqlite3
cp backup/development_cache.sqlite3 storage/development_cache.sqlite3
cp backup/development_queue.sqlite3 storage/development_queue.sqlite3
cp backup/development_cable.sqlite3 storage/development_cable.sqlite3
```

3. Start local app again:

```bash
bin/dev
```

### Docker Compose (sqlite profile)

1. Stop app services:

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite stop web worker
```

2. Restore files into container storage:

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite cp ./backup/production.sqlite3 web:/rails/storage/production.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp ./backup/production_cache.sqlite3 web:/rails/storage/production_cache.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp ./backup/production_queue.sqlite3 web:/rails/storage/production_queue.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp ./backup/production_cable.sqlite3 web:/rails/storage/production_cable.sqlite3
```

3. Start stack:

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite up -d
```

## Postgres: full backup

### Local/host-level Postgres access

Backup all four role databases:

```bash
pg_dump -h <host> -U <user> -d cullarr_production > backup/cullarr_production.sql
pg_dump -h <host> -U <user> -d cullarr_cache_production > backup/cullarr_cache_production.sql
pg_dump -h <host> -U <user> -d cullarr_queue_production > backup/cullarr_queue_production.sql
pg_dump -h <host> -U <user> -d cullarr_cable_production > backup/cullarr_cable_production.sql
```

### Docker Compose (postgres profile)

If using the Compose `postgres` service:

```bash
docker compose --profile postgres --env-file .env.compose.postgres exec -T postgres pg_dump -U <postgres-user> -d cullarr_production > backup/cullarr_production.sql
docker compose --profile postgres --env-file .env.compose.postgres exec -T postgres pg_dump -U <postgres-user> -d cullarr_cache_production > backup/cullarr_cache_production.sql
docker compose --profile postgres --env-file .env.compose.postgres exec -T postgres pg_dump -U <postgres-user> -d cullarr_queue_production > backup/cullarr_queue_production.sql
docker compose --profile postgres --env-file .env.compose.postgres exec -T postgres pg_dump -U <postgres-user> -d cullarr_cable_production > backup/cullarr_cable_production.sql
```

## Postgres: full restore

1. Stop app services first.

### Local/host-level Postgres access

```bash
psql -h <host> -U <user> -d cullarr_production < backup/cullarr_production.sql
psql -h <host> -U <user> -d cullarr_cache_production < backup/cullarr_cache_production.sql
psql -h <host> -U <user> -d cullarr_queue_production < backup/cullarr_queue_production.sql
psql -h <host> -U <user> -d cullarr_cable_production < backup/cullarr_cable_production.sql
```

### Docker Compose (postgres profile)

```bash
docker compose --profile postgres --env-file .env.compose.postgres exec -T postgres psql -U <postgres-user> -d cullarr_production < backup/cullarr_production.sql
docker compose --profile postgres --env-file .env.compose.postgres exec -T postgres psql -U <postgres-user> -d cullarr_cache_production < backup/cullarr_cache_production.sql
docker compose --profile postgres --env-file .env.compose.postgres exec -T postgres psql -U <postgres-user> -d cullarr_queue_production < backup/cullarr_queue_production.sql
docker compose --profile postgres --env-file .env.compose.postgres exec -T postgres psql -U <postgres-user> -d cullarr_cable_production < backup/cullarr_cable_production.sql
```

2. Start app services again.

## Post-restore verification (run every time)

1. Liveness endpoint:

```bash
curl -i http://localhost:3000/up
```

Expected: `200`.

2. Sign-in test:
- open `/session/new`
- sign in with known operator account

3. Run history test:
- open `/runs`
- confirm historical run rows are visible

4. Authenticated API health test:
- in browser session, request `/api/v1/health`
- expected: `200` with `{ "status": "ok" }`

## Restore drill (required at least once)

Perform a full backup + restore drill at least once per environment and keep a short log.

Template:

```text
Date: YYYY-MM-DD
Environment: local/staging/production
Runtime: local-app/docker-compose
Profile: sqlite/postgres
Backup source: ...
Restore target: ...
Verification:
- /up = pass/fail
- sign in = pass/fail
- /runs history visible = pass/fail
- /api/v1/health authenticated = pass/fail
Notes: ...
```

## Common mistakes

- backing up only one DB role in Postgres mode
- restoring while web/worker are still running
- skipping authenticated API health check
- skipping sign-in and runs-history verification
