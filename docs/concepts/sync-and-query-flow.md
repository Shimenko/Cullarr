# Sync and Candidate Flow

This page explains how data gets into Cullarr and how candidate results are produced.

## Big picture

Cullarr runs in two major loops:
- sync loop: pull and normalize data from integrations
- query loop: evaluate candidates from local tables

Integrations here means Sonarr, Radarr, and Tautulli instances you configured.

## Sync run lifecycle

A sync run moves through these phases:

1. Sonarr inventory
2. Radarr inventory
3. Tautulli users
4. Tautulli library mapping
5. Tautulli history
6. Tautulli metadata
7. Mapping and risk detection
8. Cleanup

Run state is stored in `sync_runs` (status, phase, counts, errors).

`tautulli_library_mapping` phase behavior (v2 mapping contract):
- runs strict matcher order: path -> external IDs -> TV structure -> title/year provisional
- runs a strong-signal consistency check after tentative selection and fails closed on conflicts
- rechecks provisional rows (and unresolved rows) via metadata lookup when eligible
- keeps deterministic recheck outcomes:
  - attempted (metadata call issued)
  - skipped (no call issued)
  - failed (call issued but unusable/failed)

## No overlapping syncs

Cullarr does not run overlapping sync writes.

If you trigger sync while one is active:
- you may get `sync_already_running`
- or request may be accepted as `sync_queued_next`

This prevents concurrent runs from fighting over the same inventory records.

## Integration retry/backoff behavior

Integration requests use retries with exponential backoff + jitter.

When integrations return `429`, Cullarr also considers `Retry-After` before retrying.

This behavior lives in:
- `app/services/integrations/base_adapter.rb`

## Candidate query entry points

Candidate results are produced by:
- UI page `/candidates`
- API endpoint `GET /api/v1/candidates`

Core logic lives in:
- `app/services/candidates/query.rb`

## Candidate query steps

For each request, Cullarr:

1. Validates scope, filter values, cursor, and limits.
2. Resolves selected Plex users.
3. Applies watched prefilter logic when applicable.
4. Builds row data with watched summary, mapping status, risk flags, and blocker flags.
5. Applies watched match rules (`all`, `any`, `none`).
6. Applies blocked filtering unless `include_blocked=true`.
7. Returns rows + diagnostics.

## Watched prefilter logic (what it is)

Watched prefilter is an early SQL-level narrowing step used to reduce scan size before detailed row scoring.

Current behavior:
- used for movie and episode scopes
- enabled for `watched_mode=play_count`
- not applied for season/show scopes

Why this matters:
- stricter filters can remove all rows early
- diagnostics include `watched_prefilter_applied` so you can tell when this happened

## Where `in_progress_min_offset_ms` is used

`in_progress_min_offset_ms` is a shared threshold used in three places:
- during sync write/merge of watch stats (`app/services/sync/tautulli_history_sync.rb`)
- during candidate query blocker evaluation (`app/services/candidates/query.rb`)
- during deletion-time guardrail checks (`app/services/deletion/guardrail_evaluator.rb`)

In plain terms:
- it decides when playback offset is high enough to treat an item as still in progress (if not already watched)
- this can block candidate actionability (`in_progress_any`)
- the same protection is re-checked at execution time

## Scope behavior for TV season/show

Supported scopes:
- `movie`
- `tv_episode`
- `tv_season`
- `tv_show`

For `tv_season` and `tv_show`, Cullarr aggregates episode snapshots.

Strict aggregate behavior:
- if even one underlying episode is not eligible, season/show scope gets blocker `rollup_not_strictly_eligible`
- this prevents “partially eligible season/show” from being treated as cleanly actionable

## User selection and watched match

You can filter by selected Plex users and choose watched match mode:
- `all`: all selected users must be watched
- `any`: at least one selected user must be watched
- `none`: watched requirement is inverted (unwatched)

If no users are selected, Cullarr uses all known Plex users as effective selection.

## Why this design exists

The local index + staged evaluation gives:
- better response time
- stable, explainable blockers
- safer destructive planning
- reduced dependence on live integration latency per page load

## Related docs

- `/path/to/cullarr/docs/concepts/candidate-policy.md`
- `/path/to/cullarr/docs/reference/data-model.md`
- `/path/to/cullarr/docs/reference/error-codes.md`
