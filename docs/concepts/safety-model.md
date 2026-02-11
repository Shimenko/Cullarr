# Safety Model

Cullarr is designed to fail closed for destructive workflows.

## Core principles

1. Authentication is required for all meaningful operations.
2. Delete mode is disabled by default.
3. Sensitive actions require recent re-authentication.
4. Guardrails are checked twice:
   - when candidates are listed
   - again when deletion actions execute

## Why double guardrails matter

Candidate lists are snapshots in time.
Data can change between listing and execution (watch progress, mappings, ownership signals).

Re-checking guardrails at execution prevents stale-list unsafe actions.

## Guardrail categories

A target can be blocked when any of these conditions are true:

- path exclusion matches
- keep marker exists
- selected users have in-progress playback
- mapping is ambiguous
- ownership is ambiguous

## Delete mode gate

Delete execution is gated by:
- `CULLARR_DELETE_MODE_ENABLED=true`
- configured `CULLARR_DELETE_MODE_SECRET`
- valid short-lived unlock token
- correct operator identity
- non-expired unlock token

If any gate fails, deletion planning/execution returns explicit error codes such as:
- `delete_mode_disabled`
- `delete_unlock_required`
- `delete_unlock_invalid`
- `delete_unlock_expired`

## Re-authentication gate

Sensitive actions depend on a short re-authentication window (default 15 minutes):
- integration mutation
- destructive retention updates
- delete unlock flow

This limits risk from long-lived unattended sessions.

## Explainability and audit

Cullarr records audit events for key security and workflow transitions.
API error responses include:
- stable `error.code`
- human-readable message
- `correlation_id`

This improves incident tracing and operator confidence.

## Safe-by-default behavior summary

- Review workflows are available without enabling delete mode.
- Guardrail uncertainty is surfaced, not hidden.
- Destructive execution requires explicit, recent, authenticated intent.
