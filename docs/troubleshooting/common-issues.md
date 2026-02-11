# Troubleshooting Common Issues

Use this page when Cullarr is running but behavior is not what you expect.

## Quick checks first

1. Confirm app boot health:

```bash
curl -i http://localhost:3000/up
```

2. Confirm services are running (if using compose):

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> ps
```

3. Confirm you are signed in for API calls that require auth (`/api/v1/*`).

## Integration check fails: unreachable

**Common error code:** `integration_unreachable`

Likely causes:
- base URL typo
- DNS/host resolution failure
- target service down
- TLS mismatch (HTTP vs HTTPS)

What to do:
1. Verify the integration URL from the Cullarr host.
2. Confirm port and protocol.
3. If HTTPS is used, confirm certificate trust or temporarily test with SSL verification disabled.
4. If integration allowlists are configured, confirm host/IP is in policy.

## Integration check fails: auth

**Common error code:** `integration_auth_failed`

Likely causes:
- API key typo
- API key rotated upstream
- insufficient upstream permissions

What to do:
1. Paste a fresh API key from Sonarr/Radarr/Tautulli.
2. Save integration.
3. Run **Check** again.

## Integration check fails: contract mismatch or unsupported version

**Common error codes:** `integration_contract_mismatch`, `unsupported_integration_version`

Likely causes:
- integration version drifted from expected API shape

What to do:
1. Upgrade integration to a supported stable release.
2. Use compatibility mode carefully (`warn_only_read_only`) only when you understand the read-only limitations.

## Sync trigger fails with conflict

**Common error codes:** `sync_already_running`, `sync_queued_next`

What this means:
- Cullarr prevents overlapping sync runs.
- Your trigger is either rejected (`sync_already_running`) or queued as next (`sync_queued_next`).

What to do:
1. Open `/runs`.
2. Wait for current run to finish.
3. Retry if needed.

## Candidate page shows no rows

Possible reasons:
- no successful sync yet
- watched filter is too strict
- blockers filtered all rows

What to do:
1. Run sync from `/runs`.
2. In `/candidates`, broaden watched match settings.
3. Enable **Include blocked candidates** to inspect guardrail reasons.

## Many candidate rows show mapping risk/blockers

Likely cause:
- path mapping quality is incomplete or ambiguous

What to do:
1. Open `/settings` and inspect **Mapping Health** metrics.
2. Add/fix integration path mappings.
3. Run sync again.
4. Re-check candidates.

## API health endpoint returns 401

`/api/v1/health` requires authentication.

Use a browser session after sign-in, or call with a valid authenticated session cookie.

If you only need liveness, use `/up` which is unauthenticated.

## Boot fails with database URL group error

Likely cause:
- one URL set but not all 4 in that environment group
- one or more URLs blank (`KEY=`)

What to do:
1. Set all 4 URLs in group, or unset all 4.
2. Ensure all configured URLs are unique.
3. Re-run:

```bash
bin/rails db:prepare
```

## Boot fails with encryption key error in production

Likely cause:
- one or more required encryption variables missing

Required:
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

What to do:
1. Set all required values.
2. Restart app processes.

## Re-authentication issues for sensitive actions

Likely symptoms:
- integration create/update denied
- destructive retention update denied

What to do:
1. Open `/settings` -> **Security**.
2. Use **Re-authenticate** with current password.
3. Retry action.

## Still blocked?

Capture these details before debugging further:
- exact page and action
- error code and message
- correlation ID (`X-Correlation-Id`)
- recent app logs around the same timestamp
