# API Reference

Cullarr exposes authenticated JSON APIs under `/api/v1/*`.

This page is for operators and integrators who want exact endpoint behavior with practical examples.

## Before you call the API

## Authentication

All `/api/v1/*` endpoints require an authenticated operator session.

If you are not authenticated, responses return:
- status: `401`
- error code: `unauthenticated`

Sign in through the web UI first (`/session/new`) and reuse the session cookie.

## Response headers

Cullarr includes these headers on API responses:
- `X-Cullarr-Api-Version: v1`
- `X-Correlation-Id: <request-id>`

Use `X-Correlation-Id` when matching API errors to logs.

## Error shape

All API errors use this envelope:

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

Mutating API requests without a valid CSRF token return:
- status: `403`
- error code: `csrf_invalid`

## Endpoint index (v1)

## Health

- `GET /api/v1/health`

## Image proxy

- `GET /api/v1/image-proxy?url=<encoded-image-url>`

## Settings

- `GET /api/v1/settings`
- `PATCH /api/v1/settings`

## Integrations

An integration is one Sonarr, Radarr, or Tautulli instance record.

- `GET /api/v1/integrations`
- `POST /api/v1/integrations`
- `PATCH /api/v1/integrations/:id`
- `DELETE /api/v1/integrations/:id`
- `POST /api/v1/integrations/:id/check`
- `POST /api/v1/integrations/:id/reset_history_state`

## Path mappings

- `GET /api/v1/integrations/:integration_id/path_mappings`
- `POST /api/v1/integrations/:integration_id/path_mappings`
- `PATCH /api/v1/integrations/:integration_id/path_mappings/:id`
- `DELETE /api/v1/integrations/:integration_id/path_mappings/:id`

## Path exclusions

- `GET /api/v1/path_exclusions`
- `POST /api/v1/path_exclusions`
- `PATCH /api/v1/path_exclusions/:id`
- `DELETE /api/v1/path_exclusions/:id`

## Keep markers

- `GET /api/v1/keep_markers`
- `POST /api/v1/keep_markers`
- `DELETE /api/v1/keep_markers/:id`

## Sync runs

- `POST /api/v1/sync-runs`
- `GET /api/v1/sync-runs`
- `GET /api/v1/sync-runs/:id`

## Candidates

- `GET /api/v1/candidates`

## Saved views

Saved views are implemented API-side and persist filter presets.
Current status: API create/list/update is available; UI management is currently limited.

- `GET /api/v1/saved-views`
- `POST /api/v1/saved-views`
- `PATCH /api/v1/saved-views/:id`

## Security

- `POST /api/v1/security/re-auth`
- `PATCH /api/v1/operator_password`

## Delete mode and deletion runs

- `POST /api/v1/delete-mode/unlock`
- `POST /api/v1/deletion-runs/plan`
- `POST /api/v1/deletion-runs`
- `GET /api/v1/deletion-runs/:id`
- `POST /api/v1/deletion-runs/:id/cancel`

> [!WARNING]
> Deletion endpoints are destructive workflow endpoints. Keep delete mode disabled unless you intentionally want execution.

## Sensitive actions that require recent re-auth

These endpoints require recent re-authentication (`POST /api/v1/security/re-auth`):
- integration create/update/delete
- integration history-state reset
- destructive retention updates in settings
- delete-mode unlock flow

If re-auth is stale, API returns:
- status: `403`
- error code: `forbidden`
- message: `Recent re-authentication is required for this action.`

## Request and response examples

## `GET /api/v1/health`

```json
{
  "status": "ok"
}
```

Note: still requires authentication.

## `POST /api/v1/sync-runs`

Request body (optional):

```json
{
  "trigger": "manual"
}
```

Accepted response:

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

If another run is active, expect conflict-style behavior such as `sync_already_running` or queued-next behavior.

## `GET /api/v1/image-proxy`

Example query:

```text
/api/v1/image-proxy?url=https%3A%2F%2Ftautulli.local%2Fimage%2Fposter%2F123
```

Success response:
- status `200`
- response content type mirrors upstream image type (for example `image/png`)

Common error codes:
- `image_proxy_disallowed_host`
- `image_proxy_redirect_blocked`

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

## `PATCH /api/v1/settings`

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

## `POST /api/v1/security/re-auth`

```json
{
  "password": "<current-operator-password>"
}
```

Success response:

```json
{
  "re_authenticated": true,
  "expires_at": "2026-02-11T10:30:00Z"
}
```

## `POST /api/v1/delete-mode/unlock`

```json
{
  "password": "<current-operator-password>"
}
```

Success response:

```json
{
  "unlock": {
    "token": "<opaque-token>",
    "expires_at": "2026-02-11T10:30:00Z"
  }
}
```

## Related docs

- `/path/to/cullarr/docs/reference/error-codes.md`
- `/path/to/cullarr/docs/concepts/candidate-policy.md`
- `/path/to/cullarr/docs/guides/connect-integrations-and-run-sync.md`
