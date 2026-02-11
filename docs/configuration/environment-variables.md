# Environment Variables

This page explains every environment variable currently used by Cullarr runtime code.

Use this page when you are editing `.env`, `.env.compose.sqlite`, or `.env.compose.postgres`.

## How configuration is resolved

Cullarr settings come from three layers:

1. Environment variables
2. Database-backed application settings (`app_settings`)
3. Code defaults

Environment variables override database settings when both exist for the same capability.

## Database URL behavior (strict rules)

Cullarr has four database roles per environment:
- primary
- cache
- queue
- cable

Rules enforced at boot:

1. If any variable in an environment group is present, all four variables in that group must be non-blank.
2. Every configured URL must be unique across all groups and roles.
3. Leaving an environment group entirely unset uses SQLite fallback files for that environment.

### Why blank values fail

`DATABASE_URL=` still counts as "present" because the key exists, but its value is blank.
That triggers the "incomplete URL group" boot error.

## Database URL format and examples

General Postgres URL format:

```text
postgresql://USER:PASSWORD@HOST:PORT/DB_NAME
```

### Local Postgres example

```text
postgresql://postgres:postgres@127.0.0.1:5432/cullarr_development
```

### Docker Compose internal-network example

```text
postgresql://postgres:postgres@postgres:5432/cullarr_production
```

### Password with special characters

If your password has reserved URL characters (`@`, `:`, `/`, `?`, `#`), URL-encode them.

Example password: `p@ss:word#1`

Encoded URL:

```text
postgresql://app_user:p%40ss%3Aword%231@db.example.com:5432/cullarr_production
```

## Runtime and process variables

| Variable | Required | Example | What it controls | Why you might change it |
| --- | --- | --- | --- | --- |
| `RAILS_ENV` | yes in deployed environments | `production` | Rails environment mode | Required for deployment profile behavior |
| `SECRET_KEY_BASE` | required in production | long random string | Session/cookie signing and framework secrets | Required for secure production boot |
| `PORT` | optional | `3000` | Web server port | Change if `3000` is occupied |
| `RAILS_MAX_THREADS` | optional | `5` | Active Record connection pool sizing baseline | Increase for more concurrency |
| `JOB_CONCURRENCY` | optional | `1` | Solid Queue process count (`config/queue.yml`) | Increase worker throughput |
| `RAILS_LOG_LEVEL` | optional | `info` | Production log verbosity | Use `debug` for diagnostics, `warn` for quieter logs |
| `DISABLE_SYNC_STARTUP_RECOVERY` | optional | `1` | Disables stale sync recovery at boot | Emergency control for startup debugging |
| `SOLID_QUEUE_IN_PUMA` | optional | `1` | Enables Solid Queue plugin in Puma | Advanced deployment tuning |
| `PIDFILE` | optional | `/tmp/puma.pid` | Explicit Puma PID file path | Process manager integration |
| `CI` | optional in test jobs | `1` | Enables eager loading in test env | Better CI parity with production boot |

## Development database group

Set all or none:

- `DATABASE_URL`
- `CACHE_DATABASE_URL`
- `QUEUE_DATABASE_URL`
- `CABLE_DATABASE_URL`

Example:

```bash
export DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_development
export CACHE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_cache_development
export QUEUE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_queue_development
export CABLE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_cable_development
```

## Test database group

Set all or none:

- `TEST_DATABASE_URL`
- `TEST_CACHE_DATABASE_URL`
- `TEST_QUEUE_DATABASE_URL`
- `TEST_CABLE_DATABASE_URL`

Example:

```bash
export TEST_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_test
export TEST_CACHE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_cache_test
export TEST_QUEUE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_queue_test
export TEST_CABLE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/cullarr_cable_test
```

## Production database group

Set all or none:

- `PRODUCTION_DATABASE_URL`
- `PRODUCTION_CACHE_DATABASE_URL`
- `PRODUCTION_QUEUE_DATABASE_URL`
- `PRODUCTION_CABLE_DATABASE_URL`

Example:

```bash
export PRODUCTION_DATABASE_URL=postgresql://postgres:postgres@postgres:5432/cullarr_production
export PRODUCTION_CACHE_DATABASE_URL=postgresql://postgres:postgres@postgres:5432/cullarr_cache_production
export PRODUCTION_QUEUE_DATABASE_URL=postgresql://postgres:postgres@postgres:5432/cullarr_queue_production
export PRODUCTION_CABLE_DATABASE_URL=postgresql://postgres:postgres@postgres:5432/cullarr_cable_production
```

## Deletion gate variables

| Variable | Default | What it controls | Why it exists |
| --- | --- | --- | --- |
| `CULLARR_DELETE_MODE_ENABLED` | `false` | Global switch for delete mode | Prevents accidental destructive execution |
| `CULLARR_DELETE_MODE_SECRET` | unset | Secret used to validate delete unlock tokens | Adds explicit secret gate to destructive flow |

> [!IMPORTANT]
> Keep delete mode disabled unless you intentionally need deletion execution and have validated your guardrails.

## Integration safety policy variables

| Variable | Default | What it controls | Example |
| --- | --- | --- | --- |
| `CULLARR_ALLOWED_INTEGRATION_HOSTS` | unset (permissive) | Hostname pattern allowlist for integration base URLs | `sonarr.local,radarr.local,tautulli.local` |
| `CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES` | unset (permissive) | CIDR allowlist for direct or resolved integration host IPs | `192.168.1.0/24,10.0.0.0/24` |
| `CULLARR_IMAGE_PROXY_ALLOWED_HOSTS` | unset (default list) | Host allowlist override for the image proxy | `image.tmdb.org,assets.example.com` |

Pattern behavior for `CULLARR_ALLOWED_INTEGRATION_HOSTS`:
- Supports wildcard matching with `*`
- Case-insensitive
- Examples: `*.local`, `sonarr-*`, `radarr.internal.example.com`

## Active Record encryption variables

| Variable | Required in production | What it controls |
| --- | --- | --- |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS` | yes | Key ring used for non-deterministic encryption (integration API key ciphertext) |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | yes | Deterministic encryption key |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | yes | Salt used by key derivation |

Generate starter values:

```bash
bin/rails db:encryption:init
```

Key ring format (`PRIMARY_KEYS`):
- comma-separated
- oldest key first
- active key last

Example:

```text
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS=old_key_material,new_active_key_material
```

## Docker Compose bootstrap variables (Postgres profile)

These are used by the `postgres` container service itself:

| Variable | Default in example file | Purpose |
| --- | --- | --- |
| `POSTGRES_USER` | `postgres` | Database superuser used during bootstrap |
| `POSTGRES_PASSWORD` | `postgres` | Superuser password |
| `POSTGRES_DB` | `postgres` | Initial maintenance database name |

These values are separate from Cullarr's four production role URLs.

## Where to define variables

- Local development: `.env`
- Compose SQLite profile: `.env.compose.sqlite`
- Compose Postgres profile: `.env.compose.postgres`
- CI jobs: pipeline secret environment

## Quick validation checklist

- [ ] No DB URL key is set to an empty string.
- [ ] If any URL in a group is set, all 4 are set.
- [ ] All configured DB URLs are unique.
- [ ] Production has `SECRET_KEY_BASE` and all three encryption keys.
- [ ] Integration allowlists are either intentionally unset or intentionally scoped.
