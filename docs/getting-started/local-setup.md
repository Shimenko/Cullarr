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

## Optional: expose local app to your Tailnet

If you use Tailscale, you can share your local Cullarr dev app over your tailnet
without binding Rails to public interfaces.

1. Make sure Tailscale is running and authenticated on this machine.
2. Make sure **Serve** is enabled for your tailnet in Tailscale admin.
3. Start Cullarr through the Tailnet launcher:

```bash
bin/dev-tailnet
```

Expected behavior:
- configures `tailscale serve` to proxy to `http://127.0.0.1:3000`
- detects this device tailnet DNS name (for example `machine-name.your-tailnet.ts.net`)
- exports `RAILS_DEVELOPMENT_HOSTS` so Rails Host Authorization accepts that host

The launcher prints the Tailnet URL after setup.

No `.env` edits are required for default behavior.

- default target: `https://<this-node>.ts.net` on port `443`
- default local app port: `3000`
- optional overrides: `TAILNET_SCHEME`, `TAILNET_PORT`, `PORT`

To stop sharing later:

```bash
tailscale serve reset
```

### Tailnet troubleshooting

If you see:

```text
Serve is not enabled on your tailnet.
```

Use the URL printed by Tailscale to enable Serve for your tailnet, then rerun:

```bash
bin/dev-tailnet
```

If you see:

```text
Warning: client version "..." != tailscaled server version "..."
```

Tailscale CLI and daemon are on different builds. This is usually non-fatal.
To remove the warning, update both to matching versions.

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
