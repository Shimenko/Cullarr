# Data Model Reference

This page describes the main data entities and how they relate during sync, candidate review, and deletion workflows.

## Entity groups

## Identity and security

| Table | Purpose | Key fields |
| --- | --- | --- |
| `operators` | Single-operator auth identity | `email`, `password_digest`, `last_login_at` |
| `delete_mode_unlocks` | Short-lived unlock tokens for delete mode | `operator_id`, `token_digest`, `expires_at`, `used_at` |
| `audit_events` | Append-only event trail for security and workflow actions | `event_name`, `operator_id`, `correlation_id`, `payload_json` |

## Configuration

| Table | Purpose | Key fields |
| --- | --- | --- |
| `app_settings` | DB-managed runtime settings | `key`, `value_json` |
| `integrations` | Sonarr/Radarr/Tautulli connection records | `kind`, `name`, `base_url`, `status`, `settings_json` |
| `path_mappings` | Integration path prefix translation | `integration_id`, `from_prefix`, `to_prefix`, `enabled` |
| `path_exclusions` | Path prefixes blocked from destructive workflows | `name`, `path_prefix`, `enabled` |
| `saved_views` | Saved candidate filter presets | `name`, `scope`, `filters_json` |

## Media inventory

| Table | Purpose | Key fields |
| --- | --- | --- |
| `series` | Sonarr series inventory | `integration_id`, `sonarr_series_id`, `title`, `metadata_json` |
| `seasons` | Season hierarchy under series | `series_id`, `season_number` |
| `episodes` | Episode inventory | `season_id`, `integration_id`, `sonarr_episode_id`, `metadata_json` |
| `movies` | Radarr movie inventory | `integration_id`, `radarr_movie_id`, `title`, `metadata_json` |
| `media_files` | File-level deletion unit | `attachable_type`, `attachable_id`, `integration_id`, `arr_file_id`, `size_bytes`, `path_canonical` |
| `arr_tags` | Upstream ARR tag references | `integration_id`, `name`, `arr_tag_id` |

## Watch context and safety markers

| Table | Purpose | Key fields |
| --- | --- | --- |
| `plex_users` | Synced Tautulli/Plex users | `tautulli_user_id`, `friendly_name`, `is_hidden` |
| `watch_stats` | Watch status per user and watchable | `plex_user_id`, `watchable_type`, `watchable_id`, `play_count`, `in_progress`, `max_view_offset_ms` |
| `keep_markers` | Explicit keep constraints for media objects | `keepable_type`, `keepable_id`, `note` |

## Workflow execution

| Table | Purpose | Key fields |
| --- | --- | --- |
| `sync_runs` | Sync run lifecycle and progress | `status`, `trigger`, `phase`, `phase_counts_json`, `error_code`, `queued_next` |
| `deletion_runs` | Deletion run lifecycle | `operator_id`, `status`, `scope`, `selected_plex_user_ids_json`, `summary_json`, `error_code` |
| `deletion_actions` | Per-file deletion stage execution | `deletion_run_id`, `media_file_id`, `integration_id`, `status`, `error_code`, `stage_timestamps_json` |

## Core relationships

- `integrations` has many `path_mappings`, `series`, `movies`, and `media_files`
- `series` has many `seasons`
- `seasons` has many `episodes`
- `movies` and `episodes` each have many `media_files` (polymorphic `attachable`)
- `watch_stats` belongs to `plex_users` and polymorphic watchables (`movies`, `episodes`)
- `deletion_runs` belongs to `operators` and has many `deletion_actions`
- `deletion_actions` belongs to `deletion_runs`, `media_files`, and `integrations`

## Important invariants

1. **Deletion unit is always file-level.**
`media_files` are the execution unit for deletion actions.

2. **Run history is explicit and stateful.**
`sync_runs` and `deletion_runs` keep status, timestamps, and error context.

3. **Guardrails depend on normalized path and ownership context.**
`path_mappings`, `path_exclusions`, `keep_markers`, and mapping metadata influence actionability.

4. **Settings are typed and bounded.**
`app_settings` values are validated against known keys, bounds, and enums before updates.
