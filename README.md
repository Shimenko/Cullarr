# Cullarr

Cullarr helps you review media deletion candidates safely by combining:
- Sonarr and Radarr library inventory
- Tautulli watch history
- explicit guardrails and operator review signals

It is designed to be safe first, fast second.

> [!IMPORTANT]
> Cullarr does not run automatic scheduled deletion by default.
> Delete mode is disabled by default and destructive paths are explicitly gated.

## What you get

- Candidate review UI with blockers, risk flags, and reason details
- Integration health checks and compatibility signals
- Sync run tracking with live progress
- File-level deletion planning workflow (guarded)

## 5-minute local start

### 1) Install gems

```bash
bundle install
```

### 2) Create `.env`

```bash
cp .env.example .env
```

For first run, keep DB URL variables commented out to use SQLite.

### 3) Prepare database

```bash
bin/rails db:prepare
```

### 4) Start app + worker + CSS watcher

```bash
bin/dev
```

### 5) Open and bootstrap login

- Open [http://localhost:3000/session/new](http://localhost:3000/session/new)
- Create first operator account (one-time bootstrap)

### 6) Quick health check

- [http://localhost:3000/up](http://localhost:3000/up) should return `200`
- [http://localhost:3000/runs](http://localhost:3000/runs) should load after sign-in

## Database configuration

Cullarr uses four database roles per environment:
- `primary`
- `cache`
- `queue`
- `cable`

### SQLite (default)

If all DB URL variables in an environment are unset, SQLite files in `storage/` are used.

### Postgres (strict mode)

If any URL in a group is set, all 4 URLs in that group are required.
All configured URLs must be unique across all groups.

Development group:
- `DATABASE_URL`
- `CACHE_DATABASE_URL`
- `QUEUE_DATABASE_URL`
- `CABLE_DATABASE_URL`

Test group:
- `TEST_DATABASE_URL`
- `TEST_CACHE_DATABASE_URL`
- `TEST_QUEUE_DATABASE_URL`
- `TEST_CABLE_DATABASE_URL`

Production group:
- `PRODUCTION_DATABASE_URL`
- `PRODUCTION_CACHE_DATABASE_URL`
- `PRODUCTION_QUEUE_DATABASE_URL`
- `PRODUCTION_CABLE_DATABASE_URL`

Example development group:

```bash
export DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_development
export CACHE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_cache_development
export QUEUE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_queue_development
export CABLE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_cable_development
bin/rails db:prepare
```

## Required production security variables

- `SECRET_KEY_BASE`
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

Generate encryption starter values with:

```bash
bin/rails db:encryption:init
```

## Deploy with Docker Compose

Profiles:
- `sqlite`
- `postgres`

Start with:
- [docs/guides/deploy-with-docker-compose.md](docs/guides/deploy-with-docker-compose.md)

## Documentation map

Start at [docs/README.md](docs/README.md).

| Task | Document |
| --- | --- |
| Local setup | [docs/getting-started/local-setup.md](docs/getting-started/local-setup.md) |
| Connect integrations + run first sync | [docs/guides/connect-integrations-and-run-sync.md](docs/guides/connect-integrations-and-run-sync.md) |
| Review candidates safely | [docs/guides/review-candidates-safely.md](docs/guides/review-candidates-safely.md) |
| Environment variables | [docs/configuration/environment-variables.md](docs/configuration/environment-variables.md) |
| Application settings | [docs/configuration/application-settings.md](docs/configuration/application-settings.md) |
| Troubleshooting | [docs/troubleshooting/common-issues.md](docs/troubleshooting/common-issues.md) |
| API reference | [docs/reference/api.md](docs/reference/api.md) |

## Verification commands

```bash
bundle install && \
  bin/rails db:prepare && \
  bundle exec rubocop && \
  bundle exec erb_lint app/views/**/*.erb app/components/**/*.erb && \
  bundle exec brakeman -q && \
  bundle exec bundle-audit check --update && \
  bundle exec rspec
```
