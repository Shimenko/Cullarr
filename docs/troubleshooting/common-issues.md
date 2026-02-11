# Troubleshooting Common Issues

Use this page when Cullarr starts, but behavior is not what you expect.

## Start here first

1. Confirm the app is running:

```bash
curl -i http://localhost:3000/up
```

2. If you changed `.env` values recently, restart the app before continuing.

3. If you run with Docker Compose, confirm containers are up:

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> ps
```

4. Remember that `/api/v1/*` requires sign-in.

Example:

```bash
curl -i http://localhost:3000/api/v1/health
```

`401` here usually means you are not authenticated.

## Integration check fails with `integration_unreachable`

What it means:
- Cullarr could not reach the service URL (network, DNS, protocol, or service-down issue).

Common causes:
- wrong host or port
- wrong protocol (`http` vs `https`)
- DNS can’t resolve host
- service is down

What to do:
1. Verify the integration URL from the machine running Cullarr.
2. Confirm service is reachable on that host/port.
3. If using HTTPS, verify certificate handling and `verify_ssl` setting.
4. If host/network allowlists are enabled, make sure URL and resolved IP are allowed:
   - `CULLARR_ALLOWED_INTEGRATION_HOSTS`
   - `CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES`

`CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES` uses IP-range notation (sometimes called CIDR), for example:
- `192.168.1.0/24` (range `192.168.1.0` through `192.168.1.255`)
- `10.0.0.0/16` (range `10.0.0.0` through `10.0.255.255`)

## Integration check fails with `integration_auth_failed`

What it means:
- Cullarr reached the integration, but the API key was rejected.

What to do:
1. Generate/copy a fresh API key from Sonarr/Radarr/Tautulli.
2. Update integration settings.
3. Run **Check** again.

## Integration check fails with `integration_contract_mismatch`

What it means:
- Cullarr reached the integration, but the response shape/status is not what Cullarr expects.

Common causes:
- upstream API behavior changed
- integration version is too old/new for expected behavior

What to do:
1. Confirm integration version.
2. Update integration to a supported version.
3. Re-run integration check.

## Integration check fails with `unsupported_integration_version`

What it means:
- integration version is below Cullarr’s supported minimum for delete-capable operation.

Minimum supported versions:
- Sonarr: `4.0.0`
- Radarr: `6.0.0`
- Tautulli: `2.13.0`

Compatibility mode behavior:
- `strict_latest`: unsupported version is blocked
- `warn_only_read_only`: sync/read can continue with warning, delete support remains disabled

## Image proxy errors (`image_proxy_disallowed_host`, `image_proxy_redirect_blocked`)

What it means:
- Cullarr blocked the image source host or a redirect target host based on allowlist policy.

What to do:
1. Verify requested image URL host.
2. Check `CULLARR_IMAGE_PROXY_ALLOWED_HOSTS`.
3. If this variable is unset, Cullarr uses integration hosts as defaults.
4. Restart app services after any `.env` changes.

## Sync trigger returns `sync_already_running` or `sync_queued_next`

What it means:
- Cullarr does not run overlapping syncs.

What to do:
1. Open `/runs`.
2. Wait for active run to finish.
3. Trigger again if needed.

## Candidate page is empty

Common reasons:
- no successful sync yet
- selected filters are too strict
- watched prefilter removed all rows before scoring

What to do:
1. Run a sync from `/runs`.
2. In `/candidates`, broaden filters.
3. Try watched mode `any` with fewer selected users.
4. Enable **Include blocked candidates** to inspect blocker reasons.

## Many rows show mapping or ownership blockers

Blockers you may see:
- `ambiguous_mapping`
- `ambiguous_ownership`

What they mean:
- Cullarr is not confident enough about path linkage or ownership across integrations.

What to do:
1. Review integration path mappings.
2. Make sure mappings translate from integration-reported paths to real disk paths used by Cullarr.
3. Re-run sync.
4. Re-check candidates.

## Delete mode errors (`delete_mode_disabled`, unlock errors)

What they mean:
- delete execution is gated by env + unlock token checks.

Checklist:
1. `CULLARR_DELETE_MODE_ENABLED=true` only when intentionally enabled.
2. `CULLARR_DELETE_MODE_SECRET` is set.
3. Request a new unlock token if token is missing/expired/invalid.
4. Re-authenticate if prompted.

## `guardrail_*` errors during planning/execution

Common codes:
- `guardrail_path_excluded`
- `guardrail_keep_marker`
- `guardrail_in_progress`
- `guardrail_ambiguous_mapping`
- `guardrail_ambiguous_ownership`

What they mean:
- Cullarr blocked the action for safety.

How to proceed:
1. Read the blocker code.
2. Fix the underlying condition (path mapping, keep marker, active playback, ownership ambiguity).
3. Re-run sync and plan again.

## Boot fails with database URL group/uniqueness error

What it means:
- DB URL role config is incomplete or duplicated.

Rules:
- if one URL in a 4-role group is set, all four must be set
- URLs must be unique within a group
- blank assignments like `KEY=` count as set and fail validation

What to do:
1. Set all four role URLs, or unset all four.
2. Ensure each URL is unique.
3. Run DB prepare.

Local app run:

```bash
cd /path/to/cullarr
bin/rails db:prepare
```

Docker Compose:

```bash
cd /path/to/cullarr
docker compose --profile <sqlite|postgres> --env-file <env-file> run --rm web bin/rails db:prepare
```

## Boot fails with encryption key error in production

What it means:
- required encryption env vars are missing.

Required vars:
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

What to do:
1. Set all required values.
2. Restart app processes.

## Sensitive action says re-authentication is required

What it means:
- your sign-in session is still valid, but this action needs a recent password check.

Sensitive actions include:
- integration create/update/delete
- integration history-state reset
- destructive retention setting changes
- delete-mode unlock requests

What to do:
1. Open Settings -> Security.
2. Re-authenticate with your current password.
3. Retry the action.

## API request fails with `csrf_invalid`

What it means:
- a mutating browser request was sent without a valid CSRF token.

What to do:
1. Refresh the page and retry.
2. Sign in again if your session changed.
3. Avoid replaying stale browser requests from old tabs.

## Rate limiting and retry behavior

Cullarr already retries integration calls with exponential backoff and jitter.

If you still see `rate_limited`:
1. wait briefly
2. retry the action
3. reduce request pressure (for example lower parallel workers)

## Logs and console (local and Docker)

Local app run logs:

```bash
cd /path/to/cullarr
tail -f log/development.log
```

Docker logs:

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> logs -f web worker
```

Retention prune and run observability logs to look for:
- `retention_prune_completed`
- `sync_run_*` entries with `correlation_id=...`
- `deletion_run_*` and `deletion_action_*` entries with `correlation_id=...`

Local Rails console:

```bash
cd /path/to/cullarr
bin/rails console
```

Docker Rails console:

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> exec web bin/rails console
```

## When asking for help

Capture these details:
- exact page or API endpoint
- full `error.code` and `error.message`
- `X-Correlation-Id` response header
- timestamp
- relevant app logs around that timestamp
