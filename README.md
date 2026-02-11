# Cullarr

Cullarr helps you decide what media is safe to remove.

It combines data from:
- Sonarr
- Radarr
- Tautulli

In this documentation, an **integration** means one Sonarr, Radarr, or Tautulli instance. You can add multiple instances of each.

> [!IMPORTANT]
> Delete mode is disabled by default. You can run Cullarr safely for sync + candidate review without enabling deletion execution.

## Quick Start (Local)

Run from the repository root:

```bash
cd /path/to/cullarr
bundle install
cp .env.example .env
bin/rails db:prepare
bin/dev
```

Open:
- [http://localhost:3000/session/new](http://localhost:3000/session/new) to create/sign in operator account
- [http://localhost:3000/up](http://localhost:3000/up) for liveness check (`200` expected)

Optional (Tailnet):
- Run `bin/dev-tailnet` instead of `bin/dev` to expose your local app to your Tailscale tailnet via `tailscale serve`
- Stop sharing with `tailscale serve reset`

## Quick Start (Docker Compose)

```bash
cd /path/to/cullarr
cp .env.compose.sqlite.example .env.compose.sqlite
docker compose --profile sqlite --env-file .env.compose.sqlite up --build -d
```

Then open:
- [http://localhost:3000/session/new](http://localhost:3000/session/new)
- [http://localhost:3000/up](http://localhost:3000/up)

## What Cullarr Does

- Syncs inventory + watch data from integrations
- Shows candidates with clear reasons, blockers, and risk indicators
- Blocks destructive actions when safety conditions fail
- Tracks run status and errors with correlation IDs

## Safety At A Glance

- Delete mode: off by default
- Re-authentication required for sensitive actions
- Candidate blockers checked again at execution time
- Protected path prefixes can be configured
- Keep markers can block specific media from deletion

## Postgres And SQLite

Cullarr supports both:
- SQLite (simple local/self-host defaults)
- Postgres (recommended for larger libraries and concurrency)

Each environment uses four DB roles (`primary`, `cache`, `queue`, `cable`).
If any DB URL is set in a group, all four are required, and all configured URLs must be unique.

## Required Production Secrets

- `SECRET_KEY_BASE`
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

Generate starter values:

Local app run:

```bash
cd /path/to/cullarr
bin/rails secret
bin/rails db:encryption:init
```

Docker Compose:

```bash
cd /path/to/cullarr
docker compose --profile <sqlite|postgres> --env-file <env-file> run --rm web bin/rails secret
docker compose --profile <sqlite|postgres> --env-file <env-file> run --rm web bin/rails db:encryption:init
```

## Docker Compose

Profiles:
- `sqlite`
- `postgres`

Run/start guide:
- [docs/guides/deploy-with-docker-compose.md](docs/guides/deploy-with-docker-compose.md)

## Documentation

Main index:
- [docs/README.md](docs/README.md)

Recommended reading order:
1. [docs/getting-started/local-setup.md](docs/getting-started/local-setup.md)
2. [docs/guides/connect-integrations-and-run-sync.md](docs/guides/connect-integrations-and-run-sync.md)
3. [docs/guides/review-candidates-safely.md](docs/guides/review-candidates-safely.md)
4. [docs/configuration/environment-variables.md](docs/configuration/environment-variables.md)

## Verification Commands

```bash
cd /path/to/cullarr
bundle install && \
  bin/rails db:prepare && \
  bundle exec rubocop && \
  bundle exec erb_lint app/views/**/*.erb app/components/**/*.erb && \
  bundle exec brakeman -q && \
  bundle exec bundle-audit check --update && \
  bundle exec rspec
```
