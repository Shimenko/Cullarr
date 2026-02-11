# Local Setup

This guide gets Cullarr running locally with safe defaults.

If you want Docker Compose instead of local app run, use:
- [Run with Docker Compose](../guides/deploy-with-docker-compose.md)

## Before You Run Commands

Open a terminal and go to the repository root first:

```bash
cd /path/to/cullarr
```

All commands in this guide assume you are in that directory.

## What You Will Have At The End

- running web app at `http://localhost:3000`
- background worker running
- first operator account created
- local database prepared

## Prerequisites

- Ruby + Bundler installed
- repository cloned

## 1) Install dependencies

```bash
bundle install
```

## 2) Create local environment file

```bash
cp .env.example .env
```

For first run, keep DB URL variables commented out. That keeps you in SQLite mode.

## 3) Prepare database

```bash
bin/rails db:prepare
```

Expected result:
- no errors
- SQLite files created in `storage/`

## 4) Start app

```bash
bin/dev
```

This starts:
- web server
- Tailwind watcher
- worker (`bin/jobs start`)

If you want quieter logs:

```bash
bin/dev-quiet
```

## 5) Create first operator account

Open:
- `http://localhost:3000/session/new`

On a new install, this is a one-time account creation screen.
After that, it becomes sign-in only.

## 6) Confirm app is healthy

1. `http://localhost:3000/up` returns `200`
2. sign in works
3. `http://localhost:3000/runs` loads
4. `http://localhost:3000/candidates` loads

## Optional: switch local to Postgres

Edit `.env` and set all four development URLs together:

```dotenv
DATABASE_URL=postgresql://cullarr_app:replace_me@127.0.0.1:5432/cullarr_development
CACHE_DATABASE_URL=postgresql://cullarr_app:replace_me@127.0.0.1:5432/cullarr_cache_development
QUEUE_DATABASE_URL=postgresql://cullarr_app:replace_me@127.0.0.1:5432/cullarr_queue_development
CABLE_DATABASE_URL=postgresql://cullarr_app:replace_me@127.0.0.1:5432/cullarr_cable_development
```

Then restart and prepare:

```bash
# stop current local run first if active (Ctrl+C)
bin/rails db:prepare
bin/dev
```

> [!IMPORTANT]
> If one URL in the group is set, all 4 must be set and non-blank.

Docker Compose variant (if you prefer containerized runtime):

```bash
cp .env.compose.postgres.example .env.compose.postgres
# edit PRODUCTION_*_DATABASE_URL and secrets in .env.compose.postgres
docker compose --profile postgres --env-file .env.compose.postgres up --build -d
```

## Next step

- [Connect integrations and run your first sync](../guides/connect-integrations-and-run-sync.md)
