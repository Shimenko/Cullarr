# Application Settings

These settings are stored in the `app_settings` table and edited from:
- Settings page (`/settings`)
- `PATCH /api/v1/settings`

This page explains what each setting does and  when you should change it.

## Before changing settings

1. Make sure you are signed in.
2. Re-authenticate first if you are changing sensitive values.
3. Change one group at a time.
4. Run a sync and verify candidate output after major changes.

## Sensitive actions and re-authentication

Cullarr requires recent re-authentication for sensitive actions. In current behavior this includes:

- creating/updating/deleting integrations
- resetting Tautulli history state
- setting `retention_audit_events_days` to `0`
- delete unlock flow

Re-authenticate in Settings -> Security.

## Settings table

| Key                                                | Default          | Valid values                           | Description                                                                |
|----------------------------------------------------|------------------|----------------------------------------|----------------------------------------------------------------------------|
| `sync_enabled`                                     | `true`           | `true`/`false`                         | turns scheduled sync behavior on or off                                    |
| `sync_interval_minutes`                            | `30`             | `1..1440`                              | how often Cullarr checks whether a sync should run                         |
| `watched_mode`                                     | `play_count`     | `play_count`, `percent`                | how “watched” is calculated                                                |
| `watched_percent_threshold`                        | `90`             | `1..100`                               | percent needed when using `watched_mode=percent`                           |
| `in_progress_min_offset_ms`                        | `1`              | `1..86400000`                          | minimum playback progress (ms) that still counts as “in progress”          |
| `culled_tag_name`                                  | `cullarr:culled` | non-empty string                       | tag name used when full-scope cull behavior applies                        |
| `image_cache_enabled`                              | `false`          | `true`/`false`                         | enables local caching for image proxy fetches used by UI image requests    |
| `compatibility_mode_default`                       | `strict_latest`  | `strict_latest`, `warn_only_read_only` | default compatibility mode for new integrations                            |
| `unmonitor_mode`                                   | `selected_scope` | `selected_scope`                       | unmonitor behavior mode (currently fixed to selected scope behavior)       |
| `unmonitor_parent_on_partial_version_delete`       | `false`          | `true`/`false`                         | when true, parent item may be unmonitored even for partial version deletes |
| `retention_sync_runs_days`                         | `180`            | `1..3650`                              | keep sync run history this many days                                       |
| `retention_deletion_runs_days`                     | `730`            | `1..3650`                              | keep deletion run history this many days                                   |
| `retention_audit_events_days`                      | `0`              | `0..36500`                             | keep audit events this many days (`0` means keep forever)                  |
| `image_proxy_timeout_seconds`                      | `10`             | `1..120`                               | upstream timeout for image proxy fetches                                   |
| `image_proxy_max_bytes`                            | `5242880`        | `65536..52428800`                      | max bytes accepted from image proxy upstream response                      |
| `sensitive_action_reauthentication_window_minutes` | `15`             | `1..1440`                              | how long re-auth stays valid for sensitive actions                         |

## Important behavior details

## `compatibility_mode_default`

This controls what happens when an integration version is older than what Cullarr expects.

- `strict_latest`: older/unsupported versions are blocked for destructive operations.
- `warn_only_read_only`: Cullarr allows read/sync behavior with warning state, but delete support remains disabled.

Compatibility is based on the integration's reported version.

## `unmonitor_mode` and parent unmonitor behavior

`unmonitor_mode` is currently `selected_scope` only.

That means unmonitor decisions are based on what you selected for execution scope.

`unmonitor_parent_on_partial_version_delete` changes partial-version behavior:
- `false` (safer default): if only some files are selected, parent unmonitor is usually skipped
- `true`: parent item may still be unmonitored on partial version deletes

Only turn this on if you fully understand how your library should behave after partial file removal.

## `in_progress_min_offset_ms`

This value helps decide whether playback is still “in progress.”

Example:
- `1` means any non-zero progress can count as in-progress (strict)
- `300000` means playback must pass 5 minutes before “in-progress” flag is considered

Lower values are stricter and safer for deletion guardrails.

### How Cullarr retrieves this value

Cullarr reads this setting from `app_settings` via `AppSetting.db_value_for("in_progress_min_offset_ms")`.

It is read by:
- sync aggregation when watch stats are written (`app/services/sync/tautulli_history_sync.rb`)
- candidate evaluation (`app/services/candidates/query.rb`)
- deletion guardrail evaluation (`app/services/deletion/guardrail_evaluator.rb`)

### How Cullarr uses it

`max_view_offset_ms` from watch history retrieved by Tautulli is compared against this threshold.

Practical behavior:
- if playback offset is below threshold, item is not treated as in-progress based on offset
- if playback offset is at/above threshold and item is not considered watched yet, `in_progress` protection can apply
- if a watch record is explicitly marked `in_progress=true`, that still counts as in-progress regardless of threshold

This means the setting influences both candidate blocker visibility and deletion-time safety checks.

### Choosing a value

- `1` to `1000` ms: most conservative, catches almost any started playback
- `60000` ms (1 min): moderate noise reduction for very short accidental starts
- `300000` ms (5 min): less strict, better only if you intentionally want fewer in-progress blocks

If you are unsure, keep the default (`1`).

## Protected paths and keep markers

Protected paths are managed through path exclusions, not this settings table.

Keep markers are explicit per-item “do not delete” flags and are evaluated as blockers.

## Image settings

`image_cache_enabled`, `image_proxy_timeout_seconds`, and `image_proxy_max_bytes` apply to image fetch behavior used for UI image requests.

If you do not need image tuning, keep defaults.

## Retention safety rule

Setting `retention_audit_events_days` to `0` requires:
- recent re-authentication
- explicit confirmation checkbox

If either is missing, the update is rejected.

## Environment-managed keys shown in effective settings

These appear in settings responses but are immutable there. Change them in environment variables.

| Effective key                        | Environment variable                         |
|--------------------------------------|----------------------------------------------|
| `delete_mode_enabled`                | `CULLARR_DELETE_MODE_ENABLED`                |
| `delete_mode_secret_present`         | `CULLARR_DELETE_MODE_SECRET`                 |
| `image_proxy_allowed_hosts`          | `CULLARR_IMAGE_PROXY_ALLOWED_HOSTS`          |
| `integration_allowed_hosts`          | `CULLARR_ALLOWED_INTEGRATION_HOSTS`          |
| `integration_allowed_network_ranges` | `CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES` |

## Safe baseline for new installs

- `sync_enabled=true`
- `sync_interval_minutes=30`
- `watched_mode=play_count`
- `watched_percent_threshold=90`
- `in_progress_min_offset_ms=1`
- `image_cache_enabled=false`
- `unmonitor_parent_on_partial_version_delete=false`
- `retention_audit_events_days=0`

## After changing settings, verify

1. Trigger sync from `/runs`
2. Open `/candidates`
3. Check that eligibility/blocker behavior matches expectation
4. If behavior changed unexpectedly, revert setting and retry with smaller change
