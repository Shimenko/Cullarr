# Backup And Restore

This guide covers practical backup and restore procedures for both deployment profiles.

## What to back up

### SQLite profile

Back up these files from `/rails/storage` (inside container) or your mounted volume:
- `production.sqlite3`
- `production_cache.sqlite3`
- `production_queue.sqlite3`
- `production_cable.sqlite3`

If image caching is enabled, also back up related cached files under the same storage volume.

### Postgres profile

Back up all four production databases:
- `cullarr_production`
- `cullarr_cache_production`
- `cullarr_queue_production`
- `cullarr_cable_production`

Also back up any persistent storage volume content you care about (for example image cache files).

## SQLite backup example

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite stop web worker

docker compose --profile sqlite --env-file .env.compose.sqlite cp web:/rails/storage/production.sqlite3 ./backup/production.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp web:/rails/storage/production_cache.sqlite3 ./backup/production_cache.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp web:/rails/storage/production_queue.sqlite3 ./backup/production_queue.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp web:/rails/storage/production_cable.sqlite3 ./backup/production_cable.sqlite3

docker compose --profile sqlite --env-file .env.compose.sqlite start web worker
```

## SQLite restore example

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite stop web worker

docker compose --profile sqlite --env-file .env.compose.sqlite cp ./backup/production.sqlite3 web:/rails/storage/production.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp ./backup/production_cache.sqlite3 web:/rails/storage/production_cache.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp ./backup/production_queue.sqlite3 web:/rails/storage/production_queue.sqlite3
docker compose --profile sqlite --env-file .env.compose.sqlite cp ./backup/production_cable.sqlite3 web:/rails/storage/production_cable.sqlite3

docker compose --profile sqlite --env-file .env.compose.sqlite up -d
```

## Postgres backup example

```bash
pg_dump -h <host> -U <user> -d cullarr_production > backup/cullarr_production.sql
pg_dump -h <host> -U <user> -d cullarr_cache_production > backup/cullarr_cache_production.sql
pg_dump -h <host> -U <user> -d cullarr_queue_production > backup/cullarr_queue_production.sql
pg_dump -h <host> -U <user> -d cullarr_cable_production > backup/cullarr_cable_production.sql
```

## Postgres restore example

```bash
psql -h <host> -U <user> -d cullarr_production < backup/cullarr_production.sql
psql -h <host> -U <user> -d cullarr_cache_production < backup/cullarr_cache_production.sql
psql -h <host> -U <user> -d cullarr_queue_production < backup/cullarr_queue_production.sql
psql -h <host> -U <user> -d cullarr_cable_production < backup/cullarr_cable_production.sql
```

## Minimum restore drill (run at least once)

Perform this drill in each environment at least once and record the date and commands used.

1. Create fresh backups.
2. Stop app services.
3. Restore from backup.
4. Start services.
5. Run smoke checks.

### Smoke checks after restore

1. `GET /up` returns `200`.
2. Sign-in page loads and valid login works.
3. Runs page loads and historical runs are visible.
4. `GET /api/v1/health` returns `200` when called with an authenticated session.

## Restore drill log template

```text
Date: YYYY-MM-DD
Environment: <local/staging/production>
Profile: <sqlite/postgres>
Backup source: <path or snapshot id>
Restore target: <host/path>
Validation:
- /up: pass/fail
- login: pass/fail
- runs history visible: pass/fail
- /api/v1/health (authenticated): pass/fail
Notes: <anything unexpected>
```

## Common mistakes

- Backing up only one database role in Postgres mode.
- Restoring while web/worker are still writing.
- Skipping authenticated health validation (`/api/v1/health`).
