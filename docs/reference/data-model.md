# Data Model Reference

This page explains the main tables you will care about when running and debugging Cullarr.

This is intentionally just for practical understanding, not full schema documentation.

## Mental model

Cullarr keeps a local index of media inventory and watch context so candidate decisions are fast and explainable.

High-level flow:
1. Integrations (Sonarr/Radarr/Tautulli) are synced.
2. Data lands in local tables.
3. Candidate queries read those tables.
4. Deletion planning/execution uses guardrails against the same data.

## Identity and security tables

| Table                 | Why it exists                                 | Important fields                                              |
|-----------------------|-----------------------------------------------|---------------------------------------------------------------|
| `operators`           | App login identity.                           | `email`, `password_digest`, `last_login_at`                   |
| `delete_mode_unlocks` | Short-lived tokens for delete mode execution. | `operator_id`, `token_digest`, `expires_at`, `used_at`        |
| `audit_events`        | Security + workflow trail.                    | `event_name`, `operator_id`, `correlation_id`, `payload_json` |

## Configuration tables

| Table             | Why it exists                                                    | Important fields                                        |
|-------------------|------------------------------------------------------------------|---------------------------------------------------------|
| `app_settings`    | Runtime settings stored in DB (except env-managed keys).         | `key`, `value_json`                                     |
| `integrations`    | One record per Sonarr/Radarr/Tautulli instance.                  | `kind`, `name`, `base_url`, `status`, `settings_json`   |
| `path_mappings`   | Translate integration paths to real disk paths known by Cullarr. | `integration_id`, `from_prefix`, `to_prefix`, `enabled` |
| `path_exclusions` | Paths that should never be deleted through Cullarr.              | `path_prefix`, `enabled`                                |
| `saved_views`     | Saved candidate filter presets.                                  | `name`, `scope`, `filters_json`                         |

## Media inventory tables

| Table         | Why it exists                         | Important fields                                                                  |
|---------------|---------------------------------------|-----------------------------------------------------------------------------------|
| `series`      | Sonarr show records.                  | `integration_id`, `sonarr_series_id`, `title`                                     |
| `seasons`     | Season hierarchy under series.        | `series_id`, `season_number`                                                      |
| `episodes`    | Sonarr episode records.               | `season_id`, `sonarr_episode_id`, `metadata_json`                                 |
| `movies`      | Radarr movie records.                 | `integration_id`, `radarr_movie_id`, `metadata_json`                              |
| `media_files` | File-level delete unit.               | `attachable_type`, `attachable_id`, `arr_file_id`, `path_canonical`, `size_bytes` |
| `arr_tags`    | Tag state mirrored from integrations. | `integration_id`, `name`, `arr_tag_id`                                            |

> [!IMPORTANT]
> Cullarr deletes at file level. `media_files` is the true execution unit.

## Watch and safety context tables

| Table          | Why it exists                               | Important fields                                                                                    |
|----------------|---------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `plex_users`   | Tautulli/Plex users seen by Cullarr.        | `tautulli_user_id`, `friendly_name`, `is_hidden`                                                    |
| `watch_stats`  | Watch progress per user and watchable item. | `plex_user_id`, `watchable_type`, `watchable_id`, `play_count`, `in_progress`, `max_view_offset_ms` |
| `keep_markers` | Explicit keep rules that block deletion.    | `keepable_type`, `keepable_id`, `note`                                                              |

## Workflow tables

| Table              | Why it exists                       | Important fields                                                                                   |
|--------------------|-------------------------------------|----------------------------------------------------------------------------------------------------|
| `sync_runs`        | Tracks sync lifecycle and progress. | `status`, `phase`, `trigger`, `queued_next`, `error_code`, `phase_counts_json`                     |
| `deletion_runs`    | Tracks deletion run lifecycle.      | `operator_id`, `scope`, `status`, `selected_plex_user_ids_json`, `summary_json`                    |
| `deletion_actions` | One action per media file in a run. | `deletion_run_id`, `media_file_id`, `status`, `error_code`, `retry_count`, `stage_timestamps_json` |

## Relationship map (practical)

- `integrations` -> many `series`, `movies`, `path_mappings`, `media_files`
- `series` -> many `seasons` -> many `episodes`
- `movies` and `episodes` -> many `media_files` (polymorphic attachable)
- `watch_stats` -> belongs to `plex_users` + polymorphic watchable (`movies`/`episodes`)
- `deletion_runs` -> many `deletion_actions`
- `deletion_actions` -> belongs to `media_files` + `integrations`

## Why path and ownership ambiguity happens

Cullarr must map integration file paths to local/Plex-visible paths correctly.

If mapping confidence is low or ownership appears split across integrations, guardrails can block execution with:
- `guardrail_ambiguous_mapping`
- `guardrail_ambiguous_ownership`

## TV scope behavior in the data model

- Episode scope reads individual `episodes` + `media_files`.
- Season/show scopes aggregate episode snapshots.
- Season/show are strict: if underlying episode eligibility is mixed, aggregate execution is blocked.

## Data invariants to remember

1. Deletion unit is always a media file.
2. Candidate results are explainable because local state is normalized first.
3. Guardrails are evaluated at list time and checked again at execution time.
4. Settings updates are validated and typed before persistence.

## Related docs

- `/path/to/cullarr/docs/concepts/sync-and-query-flow.md`
- `/path/to/cullarr/docs/concepts/candidate-policy.md`
- `/path/to/cullarr/docs/reference/error-codes.md`
