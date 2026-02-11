# Sync And Query Flow

Cullarr evaluates candidates from local indexed data, not directly from live integration APIs in every request.

## Sync run lifecycle

A sync run moves through these high-level phases:

1. Sonarr inventory
2. Radarr inventory
3. Tautulli users
4. Tautulli library mapping
5. Tautulli history
6. Tautulli metadata
7. Mapping and risk detection
8. Cleanup

Each run tracks status, phase, progress, and error context.

## Trigger behavior

Manual sync requests do not overlap.

If a run is already active:
- request may be rejected with `sync_already_running`
- or coalesced as `sync_queued_next`

This avoids concurrent writes competing over the same inventory state.

## Candidate query flow

When `/candidates` or `GET /api/v1/candidates` is called, Cullarr:

1. Validates filters (scope, watched mode, users, pagination)
2. Applies watched prefilter logic
3. Computes row-level or rollup eligibility
4. Applies guardrails and risk flags
5. Returns explainable results with diagnostics

## Scope behavior

Supported scopes:
- `movie`
- `tv_episode`
- `tv_season`
- `tv_show`

Season/show rollups stay strict: aggregate eligibility depends on underlying episode eligibility.

## Why local index is required

The local index enables:
- deterministic multi-filter candidate rendering
- explainable guardrail evaluation
- better UI latency
- resilient retry behavior when integrations are temporarily unstable

## Observability signals

Use these signals when diagnosing sync/query behavior:
- Runs page live progress
- run status and error code fields
- API error envelopes and correlation IDs
- mapping health metrics in Settings
