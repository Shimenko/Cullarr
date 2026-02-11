# Deploy With Docker Compose

Cullarr ships with two Docker Compose profiles:
- `sqlite`
- `postgres`

Both profiles run:
- `web`
- `worker`
- `db-init`

`postgres` profile also runs:
- `postgres`

## Choose a profile

Use `sqlite` when you want simpler single-host deployment.

Use `postgres` when you want stronger concurrent behavior and explicit role-separated production databases.

## Prerequisites

- Docker and Docker Compose installed
- Ports available (`3000` default)
- Repository checked out on host

## Deploy with SQLite profile

### 1) Prepare env file

```bash
cp .env.compose.sqlite.example .env.compose.sqlite
```

Edit `.env.compose.sqlite`:
- set `SECRET_KEY_BASE`
- set encryption keys
- keep delete mode disabled unless intentionally enabling

### 2) Start services

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite up --build -d
```

### 3) Verify services

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite ps
```

Expected:
- `db-init` exits successfully
- `web` and `worker` are healthy/running

## Deploy with Postgres profile

### 1) Prepare env file

```bash
cp .env.compose.postgres.example .env.compose.postgres
```

Edit `.env.compose.postgres`:
- set `SECRET_KEY_BASE`
- set encryption keys
- set all four `PRODUCTION_*_DATABASE_URL` values
- confirm all four URLs are unique

### 2) Start services

```bash
docker compose --profile postgres --env-file .env.compose.postgres up --build -d
```

### 3) Verify services

```bash
docker compose --profile postgres --env-file .env.compose.postgres ps
```

Expected:
- `postgres` healthy
- `db-init` exits successfully
- `web` and `worker` healthy/running

## Why `db-init` exists

`db-init` runs `bin/rails db:prepare` before web and worker start.

This avoids startup races where multiple app services attempt schema preparation at the same time.

## Health checks

Use both checks:

1. Liveness check (no auth):
`GET /up`

2. API health check (auth required):
`GET /api/v1/health`

### Example smoke checks

```bash
curl -i http://localhost:3000/up
```

Expected:
- `HTTP/1.1 200 OK`

`/api/v1/health` requires an authenticated session cookie. If called unauthenticated, expect `401`.

## Update workflow

When updating to a new image/build:

```bash
docker compose --profile <sqlite|postgres> --env-file <file> pull
docker compose --profile <sqlite|postgres> --env-file <file> up -d --build
```

Then run the same smoke checks.

## Related guides

- [Environment variables](../configuration/environment-variables.md)
- [Backup and restore](backup-and-restore.md)
- [Troubleshooting](../troubleshooting/common-issues.md)
