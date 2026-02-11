# Local Setup

This guide gets Cullarr running on your machine with a safe default setup.

> [!TIP]
> Start with SQLite first. You can switch to Postgres later after confirming the app boots, you can sign in, and the first sync works.

## What You Are Setting Up

After this guide, you will have:
- a running web app at `http://localhost:3000`
- a background worker process
- a local operator account
- prepared databases (`primary`, `cache`, `queue`, `cable`)

## Prerequisites

- Ruby and Bundler installed
- Repository cloned
- Shell access in repository root

Optional but useful:
- Docker (if you want to test compose-based deployment later)

## Step 1: Install dependencies

```bash
bundle install
```

Expected result:
- Bundler finishes without errors.
- Gem dependencies are installed.

## Step 2: Create your local environment file

```bash
cp .env.example .env
```

Keep database URL variables commented out in `.env` for your first run.
That keeps development in SQLite mode.

## Step 3: Prepare the database

```bash
bin/rails db:prepare
```

Expected result:
- No boot errors.
- SQLite files are created in `storage/`.

## Step 4: Start the app

```bash
bin/dev
```

`bin/dev` starts three processes:
- web server (`bin/rails server`)
- CSS watcher (`bin/rails tailwindcss:watch`)
- worker (`bin/jobs start`)

If you prefer quieter logs:

```bash
bin/dev-quiet
```

## Step 5: Create the first operator account

Open `http://localhost:3000/session/new`.

On first boot, this page is a one-time registration screen:
- email
- password
- password confirmation

After this account is created, the same URL becomes sign-in only.

## Step 6: Verify local health

Run these checks in order:

1. Open `http://localhost:3000/up`.
Expected: HTTP `200`.

2. Sign in through `http://localhost:3000/session/new`.
Expected: redirect to dashboard.

3. Open `http://localhost:3000/runs`.
Expected: Runs page loads and shows sync status panels.

4. Open `http://localhost:3000/candidates`.
Expected: Candidates page loads. It may show empty-state guidance before your first sync.

## Optional: Switch local development to Postgres

Cullarr supports strict Postgres role separation in each environment (`primary`, `cache`, `queue`, `cable`).

Set all four development URLs together:

```bash
export DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_development
export CACHE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_cache_development
export QUEUE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_queue_development
export CABLE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_cable_development
bin/rails db:prepare
```

> [!IMPORTANT]
> If any one URL in a group is set, all four are required. Configured URLs must also be unique.

## Next steps

1. [Connect integrations and run your first sync](../guides/connect-integrations-and-run-sync.md)
2. [Review candidates safely](../guides/review-candidates-safely.md)
3. [Read environment variable reference](../configuration/environment-variables.md)
