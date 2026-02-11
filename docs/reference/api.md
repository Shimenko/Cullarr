# API Reference

Cullarr JSON APIs are versioned under `/api/v1/*`.

## Authentication and headers

### Authentication

All `/api/v1/*` endpoints require an authenticated operator session.

- Unauthenticated request response: `401` with `error.code = "unauthenticated"`
- Use `/session/new` for browser sign-in flow

### Response headers

API responses include:
- `X-Cullarr-Api-Version: v1`
- `X-Correlation-Id: <request-id>`

### Error envelope

All API errors use this shape:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "One or more fields are invalid.",
    "correlation_id": "...",
    "details": {
      "fields": {
        "scope": ["must be one of: movie, tv_episode, tv_season, tv_show"]
      }
    }
  }
}
```

## Endpoint index

### Health

- `GET /api/v1/health`

### Settings

- `GET /api/v1/settings`
- `PATCH /api/v1/settings`

### Integrations

- `GET /api/v1/integrations`
- `POST /api/v1/integrations`
- `PATCH /api/v1/integrations/:id`
- `DELETE /api/v1/integrations/:id`
- `POST /api/v1/integrations/:id/check`
- `POST /api/v1/integrations/:id/reset_history_state`

### Path mappings

- `GET /api/v1/integrations/:integration_id/path_mappings`
- `POST /api/v1/integrations/:integration_id/path_mappings`
- `PATCH /api/v1/integrations/:integration_id/path_mappings/:id`
- `DELETE /api/v1/integrations/:integration_id/path_mappings/:id`

### Path exclusions

- `GET /api/v1/path_exclusions`
- `POST /api/v1/path_exclusions`
- `PATCH /api/v1/path_exclusions/:id`
- `DELETE /api/v1/path_exclusions/:id`

### Keep markers

- `GET /api/v1/keep_markers`
- `POST /api/v1/keep_markers`
- `DELETE /api/v1/keep_markers/:id`

### Sync runs

- `POST /api/v1/sync-runs`
- `GET /api/v1/sync-runs`
- `GET /api/v1/sync-runs/:id`

### Candidates

- `GET /api/v1/candidates`

### Saved views

- `GET /api/v1/saved-views`
- `POST /api/v1/saved-views`
- `PATCH /api/v1/saved-views/:id`

### Security

- `POST /api/v1/security/re-auth`
- `PATCH /api/v1/operator_password`

### Delete mode and deletion runs

- `POST /api/v1/delete-mode/unlock`
- `POST /api/v1/deletion-runs/plan`
- `POST /api/v1/deletion-runs`
- `GET /api/v1/deletion-runs/:id`
- `POST /api/v1/deletion-runs/:id/cancel`

> [!WARNING]
> Deletion endpoints are destructive workflow endpoints. Keep delete mode disabled unless you intentionally need execution.

## Common request/response examples

## `GET /api/v1/health`

Response:

```json
{
  "status": "ok"
}
```

## `POST /api/v1/sync-runs`

Request body (optional trigger):

```json
{
  "trigger": "manual"
}
```

Accepted response when queued:

```json
{
  "sync_run": {
    "id": 42,
    "status": "queued",
    "trigger": "manual",
    "phase": null,
    "phase_counts": {},
    "progress": {
      "total_phases": 8,
      "completed_phases": 0,
      "current_phase": null,
      "current_phase_label": "Starting",
      "current_phase_index": null,
      "current_phase_percent": 0.0,
      "percent_complete": 0.0,
      "phase_states": []
    },
    "queued_next": false,
    "error_code": null,
    "error_message": null
  }
}
```

Conflict response when already active:

```json
{
  "error": {
    "code": "sync_already_running",
    "message": "A sync run is already running or queued.",
    "correlation_id": "...",
    "details": {}
  }
}
```

## `GET /api/v1/candidates`

Example query:

```text
/api/v1/candidates?scope=movie&watched_match_mode=any&include_blocked=false&plex_user_ids[]=1&plex_user_ids[]=2&limit=50
```

Response shape:

```json
{
  "scope": "movie",
  "filters": {
    "plex_user_ids": [1, 2],
    "include_blocked": false,
    "watched_match_mode": "any",
    "saved_view_id": null
  },
  "diagnostics": {
    "rows_scanned": 120,
    "rows_filtered_unwatched": 40,
    "rows_filtered_blocked": 10,
    "content_scope": "arr_managed_only",
    "selected_user_count": 2,
    "effective_selected_user_count": 2
  },
  "items": [],
  "page": {
    "next_cursor": null
  }
}
```

## `POST /api/v1/integrations`

Request:

```json
{
  "integration": {
    "kind": "sonarr",
    "name": "Sonarr Main",
    "base_url": "http://sonarr.local:8989",
    "api_key": "<redacted>",
    "verify_ssl": true,
    "settings": {
      "compatibility_mode": "strict_latest",
      "request_timeout_seconds": 15,
      "retry_max_attempts": 5,
      "sonarr_fetch_workers": 4
    }
  }
}
```

Response includes normalized integration object and tuning values.

## `PATCH /api/v1/settings`

Request:

```json
{
  "settings": {
    "sync_interval_minutes": 30,
    "watched_mode": "play_count",
    "watched_percent_threshold": 90
  }
}
```

Successful response:

```json
{
  "ok": true
}
```

## `POST /api/v1/saved-views`

Request:

```json
{
  "saved_view": {
    "name": "Movies For Family",
    "scope": "movie",
    "filters": {
      "plex_user_ids": [1, 2],
      "include_blocked": false
    }
  }
}
```

Allowed `filters` keys are currently:
- `plex_user_ids`
- `include_blocked`

## Pagination behavior

Cursor-style pagination is used on list endpoints that support it.

Example:
- `GET /api/v1/sync-runs?cursor=100&limit=25`

Validation:
- `cursor` must be a positive integer
- `limit` is clamped between 1 and 100

## Re-authentication requirements

Sensitive endpoints require recent re-authentication.

Typical flow:

1. `POST /api/v1/security/re-auth` with current password
2. perform sensitive action (for example integration mutation)

If missing/expired, expect `forbidden`.
