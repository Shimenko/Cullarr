# Error Codes Reference

This page translates Cullarr error codes and gives a practical next step for each one.

## Error response format

```json
{
  "error": {
    "code": "validation_failed",
    "message": "One or more fields are invalid.",
    "correlation_id": "...",
    "details": {}
  }
}
```

## Authentication and request errors

| Code                | What it means                                                           | What to do next                            |
|---------------------|-------------------------------------------------------------------------|--------------------------------------------|
| `unauthenticated`   | You are not signed in or session is missing/expired.                    | Sign in at `/session/new` and retry.       |
| `forbidden`         | You are signed in, but this action is blocked (often re-auth required). | Re-authenticate and retry.                 |
| `validation_failed` | Request fields are missing/invalid.                                     | Read `details.fields`, fix payload, retry. |
| `not_found`         | Target record does not exist.                                           | Verify ID/path and retry.                  |
| `conflict`          | Request is valid, but current state prevents it.                        | Resolve state conflict, then retry.        |
| `internal_error`    | Unexpected server failure.                                              | Capture `correlation_id` and check logs.   |

## Integration and sync errors

| Code                              | What it means                                          | What to do next                                        |
|-----------------------------------|--------------------------------------------------------|--------------------------------------------------------|
| `integration_unreachable`         | Cullarr cannot reach integration URL.                  | Check URL, DNS, network, and service status.           |
| `integration_auth_failed`         | Integration rejected API key/auth.                     | Update API key and run integration check again.        |
| `integration_contract_mismatch`   | Integration returned unexpected response shape/status. | Upgrade integration and verify compatibility settings. |
| `unsupported_integration_version` | Integration version is below supported minimum.        | Upgrade integration version.                           |
| `rate_limited`                    | Integration rate-limited the request.                  | Wait and retry; reduce request pressure if frequent.   |
| `sync_already_running`            | A sync is already active.                              | Wait for current run to finish.                        |
| `sync_queued_next`                | Request accepted as the next run.                      | No action required unless queue stalls.                |

### `integration_contract_mismatch` vs `unsupported_integration_version`

- `unsupported_integration_version` means version check failed.
- `integration_contract_mismatch` means request reached the integration, but response behavior did not match what Cullarr expects.

## Delete mode and guardrail errors

| Code                               | What it means                                                                         | What to do next                                                         |
|------------------------------------|---------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| `delete_mode_disabled`             | Delete execution is disabled or not configured.                                       | Keep review-only mode, or intentionally configure delete mode env vars. |
| `delete_unlock_required`           | Missing unlock token for deletion plan/run.                                           | Request unlock token first.                                             |
| `delete_unlock_invalid`            | Unlock token is invalid (wrong token/operator/secret).                                | Request a fresh unlock token and retry.                                 |
| `delete_unlock_expired`            | Unlock token expired.                                                                 | Request a fresh unlock token and retry.                                 |
| `multi_version_selection_required` | Candidate contains multiple media-file versions; explicit file selection is required. | Provide exact media file selection and retry.                           |
| `guardrail_path_excluded`          | Target path matches a protected exclusion rule.                                       | Adjust exclusions only if intentional and safe.                         |
| `guardrail_keep_marker`            | Keep marker blocks this target.                                                       | Remove keep marker only after review.                                   |
| `guardrail_in_progress`            | Selected user has in-progress playback.                                               | Wait until playback is complete or adjust selection.                    |
| `guardrail_ambiguous_mapping`      | Mapping confidence is too low for safe action.                                        | Improve path mappings and re-sync.                                      |
| `guardrail_ambiguous_ownership`    | Ownership across integrations is ambiguous.                                           | Resolve ownership/mapping ambiguity, then retry.                        |
| `deletion_confirmation_timeout`    | Delete confirmation/resync timed out.                                                 | Retry and check integration health.                                     |
| `deletion_action_failed`           | Deletion stage failed for another reason.                                             | Inspect run/action details and logs with correlation ID.                |

### Ambiguity guardrails

- `guardrail_ambiguous_mapping`: Cullarr cannot confidently map this item between integration and Plex context.
- `guardrail_ambiguous_ownership`: the same path appears to belong to multiple integration owners, so Cullarr blocks execution to avoid deleting the wrong file.

## Settings and security errors

| Code                       | What it means                                                       | What to do next                                                       |
|----------------------------|---------------------------------------------------------------------|-----------------------------------------------------------------------|
| `settings_immutable`       | Setting is env-managed and cannot be changed through API/UI.        | Change the env var and restart the app.                               |
| `retention_setting_unsafe` | Destructive retention change requires explicit safety confirmation. | Re-authenticate and include required destructive confirmation fields. |

## Retry guidance

Usually safe to retry:
- `rate_limited`
- `integration_unreachable`
- `deletion_confirmation_timeout`

Usually not retryable without a change:
- `validation_failed`
- `forbidden`
- `settings_immutable`
- `integration_contract_mismatch`
- `unsupported_integration_version`
- `guardrail_*`

## What to include when reporting an error

Always capture:
- `error.code`
- `error.message`
- `error.correlation_id`
- timestamp
- endpoint + payload summary (without secrets)

## Related docs

- `/path/to/cullarr/docs/reference/api.md`
- `/path/to/cullarr/docs/troubleshooting/common-issues.md`
