# Environment Variables

This page explains every environment variable used by Cullarr runtime code.

## Preferred workflow: `.env` files first

Use environment files as the primary configuration method.

- local app run: `.env`
- Docker Compose sqlite profile: `.env.compose.sqlite`
- Docker Compose postgres profile: `.env.compose.postgres`

Prefer editing files over temporary `export` commands so your configuration is reproducible.

## Important rule: restart required

When you change environment variables, restart app processes.

Local app run:

```bash
cd /path/to/cullarr
# stop the current process (Ctrl+C) if running
bin/dev
```

Docker Compose:

```bash
cd /path/to/cullarr
docker compose --profile <sqlite|postgres> --env-file <env-file> up -d --build
```

Environment changes are not hot-reloaded.

## Configuration order

Cullarr resolves settings in this order:

1. environment variables
2. DB-backed settings (`app_settings` table)
3. code defaults

## Database URL rules (strict)

Cullarr has four database roles per environment:
- `primary`
- `cache`
- `queue`
- `cable`

Rules enforced at boot:

1. If any URL in an environment group is set, all 4 in that group must be set and non-blank.
2. All configured URLs must be unique across all environments and roles.
3. If an entire group is unset, that environment falls back to SQLite files.

### Why `KEY=` fails

`DATABASE_URL=` still means “key exists,” but value is blank.
That triggers the incomplete-group boot error.

## Database URL format

```text
postgresql://USER:PASSWORD@HOST:PORT/DB_NAME
```

### Example: local Postgres host

```text
postgresql://cullarr_app:replace_me@127.0.0.1:5432/cullarr_development
```

### Example: Docker internal host

```text
postgresql://cullarr_app:replace_me@postgres:5432/cullarr_production
```

### Password with special characters

URL-encode reserved chars (`@`, `:`, `/`, `?`, `#`).

```text
postgresql://cullarr_app:p%40ss%3Aword%231@db.example.com:5432/cullarr_production
```

## Core app variables

| Variable            | Required                     | Typical value      | Restart needed | What it does                                 |
|---------------------|------------------------------|--------------------|----------------|----------------------------------------------|
| `RAILS_ENV`         | yes for production-like runs | `production`       | yes            | Rails runtime mode                           |
| `SECRET_KEY_BASE`   | yes in production            | long random string | yes            | signs sessions/cookies and framework secrets |
| `PORT`              | optional                     | `3000`             | yes            | web server port                              |
| `RAILS_MAX_THREADS` | optional                     | `5`                | yes            | thread count + DB pool baseline              |
| `JOB_CONCURRENCY`   | optional                     | `1`                | yes            | worker process concurrency                   |
| `RAILS_LOG_LEVEL`   | optional                     | `info`             | yes            | runtime log level                            |

## Advanced variables (usually leave unset)

| Variable                        | Typical value   | Restart needed | When to use it                                     | Should most users set this? |
|---------------------------------|-----------------|----------------|----------------------------------------------------|-----------------------------|
| `DISABLE_SYNC_STARTUP_RECOVERY` | `1`             | yes            | temporary startup-debugging only                   | no                          |
| `SOLID_QUEUE_IN_PUMA`           | `1`             | yes            | run queue plugin in Puma for single-process setups | usually no                  |
| `PIDFILE`                       | `/tmp/puma.pid` | yes            | fixed PID path for process managers                | no                          |
| `CI`                            | `1`             | yes            | CI/test environment toggle                         | CI pipelines only           |

## DB URL groups

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

## Deletion gate variables

| Variable                      | Default | Restart needed | What it does                                      |
|-------------------------------|---------|----------------|---------------------------------------------------|
| `CULLARR_DELETE_MODE_ENABLED` | `false` | yes            | global deletion execution switch                  |
| `CULLARR_DELETE_MODE_SECRET`  | unset   | yes            | secret used to sign/validate delete unlock tokens |

### Why `CULLARR_DELETE_MODE_SECRET` exists

Deletion unlock tokens are signed against this secret.
Without it, delete unlock is rejected even if delete mode is enabled.

### `.env` file example (preferred)

```dotenv
CULLARR_DELETE_MODE_ENABLED=true
CULLARR_DELETE_MODE_SECRET=<generate-with-openssl-rand-hex-32>
```

Generate a secret value:

```bash
cd /path/to/cullarr
openssl rand -hex 32
```

> [!WARNING]
> Keep delete mode disabled unless you intentionally need destructive execution.

## Integration URL safety policy

These variables control which integration base URLs are allowed.

| Variable                                     | Default            | Restart needed | What it does               |
|----------------------------------------------|--------------------|----------------|----------------------------|
| `CULLARR_ALLOWED_INTEGRATION_HOSTS`          | unset (permissive) | yes            | hostname pattern allowlist |
| `CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES` | unset (permissive) | yes            | IP network-range allowlist |

### What is an IP network range?

`CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES` uses IP range notation (sometimes called CIDR).

Examples:
- `192.168.1.0/24` means `192.168.1.0` through `192.168.1.255`
- `10.0.0.0/16` means `10.0.0.0` through `10.0.255.255`

### How these are applied

- If both variables are unset: integration URL validation is permissive.
- If either is set: URL host must match allowed host patterns or resolve to an allowed IP range.

### What to put in integration settings when these are enabled

Nothing extra in integration records.
You still enter normal base URL + API key in Settings.
These policies are global and read from environment variables.

### `.env` file example: home lab

```dotenv
CULLARR_ALLOWED_INTEGRATION_HOSTS=sonarr.local,radarr.local,tautulli.local
CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES=192.168.1.0/24
```

### `.env` file example: wildcard hosts

```dotenv
CULLARR_ALLOWED_INTEGRATION_HOSTS=*.media.internal,sonarr-*,radarr-*
```

## Image-related variable

| Variable                            | Default | Restart needed | What it does                                             |
|-------------------------------------|---------|----------------|----------------------------------------------------------|
| `CULLARR_IMAGE_PROXY_ALLOWED_HOSTS` | unset   | yes            | optional host allowlist override for image proxy fetches |

This controls allowed upstream image hosts for UI image fetch behavior.
If you are not customizing image host policy, leave it unset.

## Active Record encryption variables

| Variable                                       | Required in production | Restart needed | Purpose                       |
|------------------------------------------------|------------------------|----------------|-------------------------------|
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`        | yes                    | yes            | key ring for encrypted fields |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`   | yes                    | yes            | deterministic encryption key  |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | yes                    | yes            | key derivation salt           |

Generate starter values.

Local app run:

```bash
cd /path/to/cullarr
bin/rails db:encryption:init
```

Docker Compose:

```bash
cd /path/to/cullarr
docker compose --profile <sqlite|postgres> --env-file <env-file> run --rm web bin/rails db:encryption:init
```

### `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS` format

- comma-separated list
- oldest key first
- active key last

Example:

```dotenv
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS=key_2025_01,key_2026_02
```

For full rotation workflow and re-encryption task usage, follow:
- [Rotate Active Record encryption keys](../guides/rotate-encryption-keys.md)

## Docker Postgres bootstrap variables

Used by postgres container service itself:

| Variable            | Example              | Restart needed |
|---------------------|----------------------|----------------|
| `POSTGRES_USER`     | `cullarr_admin`      | yes            |
| `POSTGRES_PASSWORD` | long random password | yes            |
| `POSTGRES_DB`       | `postgres`           | yes            |

## Better Postgres credentials (recommended)

Avoid defaults like `postgres/postgres` outside quick local testing.

Generate values:

```bash
cd /path/to/cullarr
openssl rand -base64 32 | tr -d '\n'
```

Then place them in your env file:

```dotenv
POSTGRES_USER=cullarr_admin
POSTGRES_PASSWORD=<paste-generated-value>
```

Use a separate least-privilege app user for `PRODUCTION_*_DATABASE_URL` where possible.

## Temporary shell override (optional fallback)

If you need a one-off shell override for local experiments, `export` is still valid.
Use this only as a temporary method.

## Where these values live

- local app run: `.env`
- compose sqlite: `.env.compose.sqlite`
- compose postgres: `.env.compose.postgres`
- CI/CD: secret environment variables

## Quick validation checklist

- [ ] no DB URL key is set to empty string
- [ ] URL groups are complete when enabled
- [ ] configured DB URLs are unique
- [ ] production has `SECRET_KEY_BASE` + all encryption keys
- [ ] any changed env variable was followed by app restart
