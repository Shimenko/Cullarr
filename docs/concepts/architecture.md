# How Cullarr Is Built

This is a practical view of the app structure so you can reason about behavior and troubleshooting quickly.

## One app, two process roles

Cullarr is a Rails monolith that usually runs two process types:

- `web`: serves HTML pages and `/api/v1/*` JSON endpoints
- `worker`: runs background jobs (sync and deletion workflow stages)

Both processes use the same application code and database.

## Why Cullarr keeps a local index

Cullarr does not compute every candidate directly from live Sonarr/Radarr/Tautulli calls on each request.

Instead, it syncs integration data into local tables and queries that index.

This gives:
- faster candidate pages
- consistent filtering across scopes
- clearer blocker reasons
- better resilience when integrations are temporarily slow or rate-limited

## Where key behavior lives

## HTTP and session behavior

- controllers in `app/controllers/`
- API controllers in `app/controllers/api/v1/`
- login/session handling in `app/controllers/application_controller.rb`

## Candidate evaluation

- main query logic in `app/services/candidates/query.rb`
- watched and blocker decisions are built there

## Integration communication

- adapters in `app/services/integrations/`
- retry/backoff behavior in `app/services/integrations/base_adapter.rb`

## Deletion workflow gates and execution

- planning in `app/services/deletion/plan_deletion_run.rb`
- execution stages in `app/services/deletion/process_action.rb`
- delete-mode unlock issuance in `app/services/deletion/issue_delete_mode_unlock.rb`

## Data model and persistence

- models in `app/models/`
- settings schema + defaults in `app/models/app_setting.rb`

## Route split: UI vs API

- HTML UI routes are unversioned (for example `/runs`, `/candidates`, `/settings`)
- JSON API routes are versioned under `/api/v1/*`

Even `/api/v1/health` requires authentication because all `/api/v1/*` inherits login requirements.

## Configuration shape

Each environment has four DB roles:
- primary
- cache
- queue
- cable

Cullarr supports:
- SQLite for simpler local setups
- Postgres with strict URL group and uniqueness checks

## Safety defaults by design

- delete mode is off by default
- sensitive actions require recent re-authentication
- guardrails are checked before planning and again at execution time

## What this means for operators

When something feels inconsistent, think in this order:
1. Was the latest sync successful?
2. Are path mappings and watch context up to date?
3. Is a guardrail intentionally blocking execution?
4. Is this an auth/re-auth/delete-mode gate issue?

## Related docs

- `/path/to/cullarr/docs/concepts/sync-and-query-flow.md`
- `/path/to/cullarr/docs/concepts/candidate-policy.md`
- `/path/to/cullarr/docs/reference/data-model.md`
