# Cullarr Rails Monolith MVP

Cullarr helps operators safely identify media deletion candidates from Sonarr/Radarr/Tautulli data.

## Local setup

```bash
bundle install
bin/rails db:prepare
```

## Environment files and switching behavior

- Use `.env` for local development variables.
- `bin/dev` reads `.env` through Foreman.
- `bin/rails` and `bundle exec ...` also read `.env` via `dotenv-rails`.
- Start from `.env.example`:

```bash
cp .env.example .env
```

## Database modes

### SQLite (default)

Switch rule:
- SQLite is used when all DB URL vars for that environment are unset/empty.
- Do not set DB URL vars to empty strings (for example `DATABASE_URL=`). Leave them truly unset/commented out.

```bash
bin/rails db:prepare
bin/dev
```

SQLite files are written under `storage/` for primary, cache, queue, and cable databases.

### Postgres

Switch rule:
- Postgres mode is strict: if any URL in an environment group is set, all four URLs in that group must be set.
- Configured URLs must be unique. Reusing a DB URL across roles/environments fails boot.
- Development Postgres group:
  - `DATABASE_URL`
  - `CACHE_DATABASE_URL`
  - `QUEUE_DATABASE_URL`
  - `CABLE_DATABASE_URL`
- Missing/blank URLs or duplicate URLs fail fast during boot via `config/initializers/database_url_guard.rb`.

Development example:

```bash
export DATABASE_URL=postgresql://localhost/cullarr_development
export CACHE_DATABASE_URL=postgresql://localhost/cullarr_cache_development
export QUEUE_DATABASE_URL=postgresql://localhost/cullarr_queue_development
export CABLE_DATABASE_URL=postgresql://localhost/cullarr_cable_development
bin/rails db:prepare
bin/dev
```

## Separate test databases (recommended with Postgres)

Use test-specific env vars. Test Postgres mode is also strict:
- `TEST_DATABASE_URL`
- `TEST_CACHE_DATABASE_URL`
- `TEST_QUEUE_DATABASE_URL`
- `TEST_CABLE_DATABASE_URL`

```bash
export TEST_DATABASE_URL=postgresql://localhost/cullarr_test
export TEST_CACHE_DATABASE_URL=postgresql://localhost/cullarr_cache_test
export TEST_QUEUE_DATABASE_URL=postgresql://localhost/cullarr_queue_test
export TEST_CABLE_DATABASE_URL=postgresql://localhost/cullarr_cable_test
RAILS_ENV=test bin/rails db:prepare
RAILS_ENV=test bundle exec rspec
```

## Separate production databases (recommended)

Production has its own URL group and should not reuse development/test URLs:
- `PRODUCTION_DATABASE_URL`
- `PRODUCTION_CACHE_DATABASE_URL`
- `PRODUCTION_QUEUE_DATABASE_URL`
- `PRODUCTION_CABLE_DATABASE_URL`

```bash
export PRODUCTION_DATABASE_URL=postgresql://localhost/cullarr_production
export PRODUCTION_CACHE_DATABASE_URL=postgresql://localhost/cullarr_cache_production
export PRODUCTION_QUEUE_DATABASE_URL=postgresql://localhost/cullarr_queue_production
export PRODUCTION_CABLE_DATABASE_URL=postgresql://localhost/cullarr_cable_production
RAILS_ENV=production bin/rails db:prepare
```

Fallback behavior:
- If all URL vars in an environment group are unset, that environment uses SQLite (`storage/*.sqlite3`).

## Run locally

```bash
bin/dev
```

`bin/dev` starts:
- Rails web server
- Tailwind watcher
- Solid Queue worker (`bin/jobs start`)

### Lower-noise option

If `bin/dev` is too noisy, use:

```bash
bin/dev-quiet
```

This still runs web + css watcher + worker, but css/worker logs go to files:
- `log/tailwindcss.log`
- `log/worker.log`

Helpful tails:

```bash
tail -f log/worker.log
tail -f log/tailwindcss.log
```

### Web-only option

When you only need HTTP/UI work and no background job execution:

```bash
bin/rails server
```

If you later need workers, start them in another terminal:

```bash
bin/jobs start
```

## Authentication bootstrap

On first visit, `/session/new` presents a one-time operator account creation form.
After the first operator is created, signup is disabled and the same endpoint becomes login-only.

## Verification

```bash
bundle exec rubocop
bundle exec erb_lint app/views/**/*.erb app/components/**/*.erb
bundle exec brakeman -q
bundle exec bundle-audit check --update
bundle exec rspec
```

## Integration URL allow policy (optional)

- By default, integration URL validation is permissive.
- To restrict integration targets, set one or both env vars:
  - `CULLARR_ALLOWED_INTEGRATION_HOSTS` (comma-separated host patterns with wildcard support)
  - `CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES` (comma-separated CIDR ranges)

Examples:

```bash
export CULLARR_ALLOWED_INTEGRATION_HOSTS=sonarr.local,radarr.local,tautulli.local
export CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES=192.168.1.0/24,10.0.0.0/24
```

When either list is configured, integration hosts must match the configured policy.

Wildcard examples:

```bash
export CULLARR_ALLOWED_INTEGRATION_HOSTS=*.local,sonarr-*,*
```

## Active Record Encryption keys

- Integration API keys are encrypted at rest via Active Record Encryption.
- Configure these env vars (required in production):
  - `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS` (comma-separated key ring, oldest first, active key last)
  - `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
  - `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`
- Generate values with:

```bash
bin/rails db:encryption:init
```

Key rotation workflow:

1. Append a new primary key to `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS` (keep old keys).
2. Deploy/restart with the updated key ring.
3. Re-encrypt stored integration API keys with the active key:

```bash
bin/rails cullarr:encryption:rotate_integration_api_keys
```

4. After verification, remove retired keys from the front of the key ring in a later deploy.

## API baseline

JSON operation endpoints are versioned under `/api/v1/*`.
Slice 1 provides the scaffold endpoint:
- `GET /api/v1/health` (authenticated)
