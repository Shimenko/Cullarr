# Error Codes Reference

This page maps common API error codes to meaning and practical operator action.

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

## Auth and request errors

| Code | Meaning | Typical fix |
| --- | --- | --- |
| `unauthenticated` | No valid operator session | Sign in first (`/session/new`) |
| `forbidden` | Session exists but action gate failed (for example re-auth or password check) | Re-authenticate in Settings and retry |
| `validation_failed` | Input shape or values are invalid | Inspect `details.fields` and fix payload |
| `not_found` | Requested record does not exist | Verify ID and endpoint path |
| `conflict` | Action cannot proceed in current state | Resolve active/conflicting state and retry |
| `internal_error` | Unexpected server error | Use `correlation_id` + logs for diagnosis |

## Integration and sync errors

| Code | Meaning | Typical fix |
| --- | --- | --- |
| `integration_unreachable` | Integration host is unreachable | Verify URL, DNS, network, TLS |
| `integration_auth_failed` | API key/auth failed | Replace API key, verify permissions |
| `integration_contract_mismatch` | API contract shape mismatch | Upgrade integration or review compatibility behavior |
| `unsupported_integration_version` | Integration not supported for delete operations | Upgrade integration version |
| `rate_limited` | Upstream rate limit reached | Retry later with backoff |
| `sync_already_running` | Active or queued sync already exists | Wait for current sync run to finish |
| `sync_queued_next` | Sync request accepted as next run | Wait for current run; no extra action needed |

## Deletion gate and guardrail errors

| Code | Meaning | Typical fix |
| --- | --- | --- |
| `delete_mode_disabled` | Delete mode env gate is disabled or not configured | Keep review-only mode, or intentionally configure delete mode |
| `delete_unlock_required` | Missing unlock token | Request unlock first |
| `delete_unlock_invalid` | Unlock token invalid or wrong operator | Request a new unlock token |
| `delete_unlock_expired` | Unlock token expired | Request a new unlock token |
| `multi_version_selection_required` | Multiple versions exist and explicit selection was missing | Provide explicit media file selection |
| `guardrail_path_excluded` | Path exclusion blocked action | Adjust exclusions only if intentional |
| `guardrail_keep_marker` | Keep marker blocked action | Remove marker only after review |
| `guardrail_in_progress` | In-progress playback blocked action | Retry later or adjust watched context |
| `guardrail_ambiguous_mapping` | Mapping uncertainty blocked action | Improve path mappings and re-sync |
| `guardrail_ambiguous_ownership` | Ownership uncertainty blocked action | Resolve mapping/ownership ambiguity |
| `deletion_confirmation_timeout` | External delete confirmation timed out | Retry and inspect integration health |
| `deletion_action_failed` | Deletion stage failed for non-specific reason | Inspect run/action details and logs |

## Settings and security errors

| Code | Meaning | Typical fix |
| --- | --- | --- |
| `settings_immutable` | Attempted to update env-managed setting through settings API | Move change to environment variables |
| `retention_setting_unsafe` | Unsafe retention update requires explicit confirmation | Re-authenticate and include destructive confirmation |

## Retry guidance

### Usually retryable

- `rate_limited`
- `integration_unreachable`
- `deletion_confirmation_timeout`

### Usually not retryable without change

- `validation_failed`
- `forbidden`
- `settings_immutable`
- `unsupported_integration_version`
- `integration_contract_mismatch`
- `guardrail_*`

## Correlation ID usage

When reporting or debugging an error, capture:
- `error.code`
- `error.message`
- `error.correlation_id`
- request timestamp
