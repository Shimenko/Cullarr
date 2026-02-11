# Safety Model

Cullarr is designed to protect you from accidental destructive actions.

This page explains what gets blocked, why it gets blocked, and what you can do next.

## Core safety rules

1. You must be signed in.
2. Delete mode is off by default.
3. Sensitive actions require recent re-authentication.
4. Guardrails are checked twice:
   - when candidates are shown
   - again when deletion actions execute

That second check matters because data can change between review and execution.

## What counts as a sensitive action

Cullarr asks for recent re-authentication for actions like:
- integration create/update/delete
- integration history-state reset
- destructive retention setting updates
- delete-mode unlock requests

If re-auth is stale, API returns `forbidden` with a message that recent re-authentication is required.

## Delete mode gate (intentional friction)

Delete execution is allowed only when all checks pass:
- `CULLARR_DELETE_MODE_ENABLED=true`
- `CULLARR_DELETE_MODE_SECRET` is configured
- a valid unlock token is provided
- unlock token is unexpired and tied to valid operator context

Common failures:
- `delete_mode_disabled`
- `delete_unlock_required`
- `delete_unlock_invalid`
- `delete_unlock_expired`

## Guardrails that block deletion

Cullarr blocks actions when any of these safety conditions are present:
- path is excluded (`path_excluded`)
- keep marker exists (`keep_marked`)
- selected users have in-progress playback (`in_progress_any`)
- mapping confidence is ambiguous (`ambiguous_mapping`)
- file ownership appears ambiguous across integrations (`ambiguous_ownership`)

These map to API codes such as `guardrail_keep_marker`, `guardrail_ambiguous_mapping`, and `guardrail_ambiguous_ownership`.

## What ambiguity means

## Ambiguous mapping

Cullarr cannot confidently link integration-side metadata/path context to a stable Plex-linked identity.

## Ambiguous ownership

The same normalized path appears under multiple integration owners, so Cullarr cannot safely decide which owner should drive deletion.

In both cases, Cullarr blocks execution by design.

## Why keep markers and protected paths exist

- Keep markers let you say “never remove this item” even if watch rules would normally make it eligible.
- Path exclusions let you protect entire path prefixes from destructive actions.

These are intentional override rails for library layout realities.

## Explainability and auditing

Cullarr records audit events for key security and workflow transitions.

API errors include:
- stable `error.code`
- readable `error.message`
- `correlation_id` for tracing

This makes blocked behavior easier to debug and safer to operate.

## Related docs

- `/path/to/cullarr/docs/reference/error-codes.md`
- `/path/to/cullarr/docs/guides/review-candidates-safely.md`
- `/path/to/cullarr/docs/troubleshooting/common-issues.md`
