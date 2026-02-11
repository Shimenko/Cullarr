# Architecture

Cullarr is a Rails monolith with a web process and a worker process.

## Runtime shape

- **Web process**
  - server-rendered UI
  - JSON API endpoints under `/api/v1/*`
  - session/auth handling

- **Worker process**
  - sync jobs
  - deletion workflow jobs
  - async execution via Solid Queue

## Why this shape

Cullarr needs fast candidate filtering and explicit safety decisions across multiple external systems.

Doing all candidate evaluation directly against Sonarr/Radarr/Tautulli APIs would be slower and harder to reason about, so Cullarr keeps a local normalized index.

## Data flow summary

1. Pull inventory and watch context from integrations.
2. Normalize into local tables.
3. Compute candidate rows from local data.
4. Apply guardrails and expose explainable reasons.
5. Only execute destructive workflows through explicit gated flows.

## Process boundaries

### Controllers

Controllers handle transport concerns:
- params
- auth
- response shape
- status codes

### Services

Services handle orchestration:
- integration health checks
- sync phase execution
- candidate query and guardrail logic
- deletion planning and execution

### Models

Models enforce persistence-level invariants:
- validations
- typed defaults
- derived serialization helpers

## Storage model

Each environment has four DB roles:
- `primary`
- `cache`
- `queue`
- `cable`

SQLite is supported for simple setups.
Postgres is supported with strict URL group + uniqueness enforcement.

## API and UI separation

- UI routes are unversioned and HTML-focused.
- API routes are versioned in `/api/v1/*` and return JSON.
- API responses include `X-Cullarr-Api-Version: v1`.

## Non-goals

- automatic scheduled deletion without explicit unlock
- multi-tenant SaaS partitioning
- hiding guardrail uncertainty behind optimistic assumptions
