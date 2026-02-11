# Run With Docker Compose

Cullarr provides two compose profiles:
- `sqlite`
- `postgres`

If you prefer local app run (non-Docker), use:
- [Local setup](../getting-started/local-setup.md)

## Before You Begin

From repository root:

```bash
cd /path/to/cullarr
```

You need:
- Docker + Docker Compose
- available host port (default `3000`)
- secrets ready (`SECRET_KEY_BASE`, encryption keys)

## Services in each profile

Both profiles run:
- `web`
- `worker`
- `db-init`

`postgres` profile also runs:
- `postgres`

`db-init` runs `bin/rails db:prepare` before app services start. This prevents two services trying to prepare DB at same time.

## Reverse proxy websocket requirement

Turbo Streams live updates depend on Action Cable websocket upgrades.

If you place Cullarr behind a reverse proxy, ensure websocket headers are forwarded.

Nginx location example:

```nginx
location /cable {
  proxy_pass http://127.0.0.1:3000/cable;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_set_header Host $host;
}
```

Without websocket forwarding, run progress pages still load, but live updates can stall.

## 1) Start sqlite profile

Copy env file:

```bash
cp .env.compose.sqlite.example .env.compose.sqlite
```

Edit required values in `.env.compose.sqlite`.

Start:

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite up --build -d
```

Check service states:

```bash
docker compose --profile sqlite --env-file .env.compose.sqlite ps
```

## 2) Start postgres profile

Copy env file:

```bash
cp .env.compose.postgres.example .env.compose.postgres
```

Edit `.env.compose.postgres` and change defaults:
- replace `POSTGRES_PASSWORD`
- replace app DB URL credentials
- set `SECRET_KEY_BASE`
- set encryption keys

Start:

```bash
docker compose --profile postgres --env-file .env.compose.postgres up --build -d
```

Check service states:

```bash
docker compose --profile postgres --env-file .env.compose.postgres ps
```

## 3) Use existing Postgres databases

If you already have Postgres running, point `PRODUCTION_*_DATABASE_URL` to those DBs.

Requirements:
- all 4 role DB URLs provided
- DB URLs are unique
- DB user has permission to create/update tables in those DBs

Then run DB prepare (inside app container):

```bash
docker compose --profile postgres --env-file .env.compose.postgres run --rm web bin/rails db:prepare
```

`db:prepare` will create schema objects/tables as needed.

## 4) Verify running services

Basic checks:

```bash
curl -i http://localhost:3000/up
```

Expected:
- `HTTP/1.1 200 OK`

Also verify sign-in and `/runs` UI.

`/api/v1/health` requires authenticated session. Unauthenticated request should return `401`.

## 5) View logs

Tail all services:

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> logs -f
```

Tail one service:

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> logs -f web
```

## 6) Open a shell in container

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> exec web sh
```

Useful commands inside web container:

```bash
bin/rails db:prepare
bin/rails c
bin/rails runner 'puts SyncRun.count'
```

## 7) Restart after env changes

If you edit `.env.compose.*`, restart services:

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> up -d --build
```

## 8) Stop services cleanly

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> down
```

## Next documents

- [Backup and restore](backup-and-restore.md)
- [Environment variables](../configuration/environment-variables.md)
- [Troubleshooting](../troubleshooting/common-issues.md)
