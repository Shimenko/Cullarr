# Application Settings

This page documents settings stored in the `app_settings` table and managed from the **Settings** page.

These settings control sync cadence, watched logic, retention, and several safety-related runtime behaviors.

## How to change settings

### UI

1. Sign in.
2. Open `http://localhost:3000/settings`.
3. Edit values in the **Settings** panel.
4. Click **Save Settings**.

### API

- `GET /api/v1/settings`
- `PATCH /api/v1/settings`

## Settings reference

| Key | Default | Valid values | What it controls |
| --- | --- | --- | --- |
| `sync_enabled` | `true` | `true` or `false` | Enables or pauses scheduled sync behavior |
| `sync_interval_minutes` | `30` | `1..1440` | Interval between scheduled sync checks |
| `watched_mode` | `play_count` | `play_count`, `percent` | Watched decision model |
| `watched_percent_threshold` | `90` | `1..100` | Required percentage when `watched_mode=percent` |
| `in_progress_min_offset_ms` | `1` | `1..86400000` | Minimum in-progress offset that blocks deletion |
| `culled_tag_name` | `cullarr:culled` | non-empty string, max 128 chars | Tag name used for fully-culled semantics |
| `image_cache_enabled` | `false` | `true` or `false` | Enables local caching for proxied images |
| `compatibility_mode_default` | `strict_latest` | `strict_latest`, `warn_only_read_only` | Default integration compatibility mode |
| `unmonitor_mode` | `selected_scope` | `selected_scope` | Unmonitor strategy for deletion side effects |
| `unmonitor_parent_on_partial_version_delete` | `false` | `true` or `false` | Advanced unmonitor behavior for partial version operations |
| `retention_sync_runs_days` | `180` | `1..3650` | Retention window for sync run records |
| `retention_deletion_runs_days` | `730` | `1..3650` | Retention window for deletion run records |
| `retention_audit_events_days` | `0` | `0..36500` | Retention window for audit events (`0` means keep forever) |
| `image_proxy_timeout_seconds` | `10` | `1..120` | Timeout for image proxy upstream fetches |
| `image_proxy_max_bytes` | `5242880` | `65536..52428800` | Maximum allowed proxied image payload size |
| `sensitive_action_reauthentication_window_minutes` | `15` | `1..1440` | Re-authentication validity window for sensitive actions |

## Critical behavior notes

### Retention destructive confirmation

Setting `retention_audit_events_days` to `0` requires:
- recent re-authentication
- explicit destructive confirmation checkbox

Without both, update is rejected.

### Watched mode behavior

`watched_mode=play_count`:
- watched when `play_count >= 1`

`watched_mode=percent`:
- watched when max view offset / duration meets threshold

If watch metadata is missing, behavior fails safe and will not assume a watched state.

### Compatibility mode default

`strict_latest`:
- enforces strict compatibility expectations

`warn_only_read_only`:
- allows read/sync paths with warnings
- still blocks destructive behavior when unsupported

## Environment-managed immutable settings

These are exposed in effective settings but cannot be changed in UI/API setting updates.

| Effective key | Environment variable |
| --- | --- |
| `delete_mode_enabled` | `CULLARR_DELETE_MODE_ENABLED` |
| `delete_mode_secret_present` | `CULLARR_DELETE_MODE_SECRET` |
| `image_proxy_allowed_hosts` | `CULLARR_IMAGE_PROXY_ALLOWED_HOSTS` |
| `integration_allowed_hosts` | `CULLARR_ALLOWED_INTEGRATION_HOSTS` |
| `integration_allowed_network_ranges` | `CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES` |

## Suggested baseline values

If you are new to Cullarr, this baseline is usually sensible:

- `sync_enabled=true`
- `sync_interval_minutes=30`
- `watched_mode=play_count`
- `watched_percent_threshold=90`
- `in_progress_min_offset_ms=1`
- `retention_sync_runs_days=180`
- `retention_deletion_runs_days=730`
- `retention_audit_events_days=0`
- `image_cache_enabled=false`

Adjust only after you have at least one full successful sync and you understand your watch data quality.
