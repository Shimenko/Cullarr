# Connect Integrations And Run Your First Sync

Use this guide after local setup.

In this guide, **integration** means one Sonarr, Radarr, or Tautulli server. You can add multiple integrations of the same type.

## Before You Start

Run from repo root:

```bash
cd /path/to/cullarr
```

Make sure:
- Cullarr is running (`bin/dev`)
- you can sign in
- you have base URLs + API keys for each integration

Recommended order:
1. Sonarr
2. Radarr
3. Tautulli

## 1) Re-authenticate first

Integration create/update/delete actions require recent re-authentication.

1. Open `http://localhost:3000/settings`
2. In **Security**, enter password and click **Re-authenticate**
3. Confirm message: `Re-authentication successful for sensitive actions.`

## 2) Add Sonarr integration

Settings -> Integrations -> Add Integration:

- Kind: `sonarr`
- Name: `Sonarr Main`
- Base URL: `http://sonarr.local:8989`
- API Key: your Sonarr API key
- Compatibility Mode: `Strict latest`
- Request Timeout: `15`
- Retry Attempts: `5`
- Sonarr Fetch Workers: `4` (or `0` for auto)
- Verify SSL: enabled for trusted HTTPS endpoints

Click **Add Integration**.

## 3) Add Radarr integration

Use same form:

- Kind: `radarr`
- Name: `Radarr Main`
- Base URL: `http://radarr.local:7878`
- API Key: your Radarr API key
- Compatibility Mode: `Strict latest`
- Request Timeout: `15`
- Retry Attempts: `5`
- Radarr MovieFile Workers: `4` (or `0` for auto)
- Verify SSL: enabled for trusted HTTPS endpoints

Click **Add Integration**.

## 4) Add Tautulli integration

- Kind: `tautulli`
- Name: `Tautulli Main`
- Base URL: `http://tautulli.local:8181`
- API Key: your Tautulli API key
- Compatibility Mode: `Strict latest`
- Request Timeout: `15`
- Retry Attempts: `5`
- Tautulli History Page Size: `500`
- Tautulli Metadata Workers: `4` (or `0` for auto)

Click **Add Integration**.

## Compatibility mode explained clearly

Compatibility mode is about the version running on your integration server.

Cullarr checks reported integration version and behavior contract.

- `strict_latest`: if integration version/contract is not supported, Cullarr blocks destructive support.
- `warn_only_read_only`: Cullarr can still read/sync with warning status, but destructive support stays disabled.

Use `warn_only_read_only` only if you intentionally accept reduced guarantees while upgrading integrations.

## 5) Configure path mappings (important)

Path mappings tell Cullarr how to translate paths reported by integrations to the real file locations on disk used in your environment.

Think of it as:
- **From Prefix** = path string reported by integration data
- **To Prefix** = real on-disk path root that should match this environment

Direction matters:
- map from integration-reported path format to your actual local disk path format
- not the other way around

Example 1:
- From Prefix: `/data/media/movies`
- To Prefix: `/mnt/media/movies`

Example 2 (container vs host style):
- From Prefix: `/tv`
- To Prefix: `/media/tv`

If paths are wrong, matching quality drops and you may see source-aware mapping statuses like `unresolved`, `provisional_title_year`, `external_source_not_managed`, or `ambiguous_conflict`.

## 6) Optional integration URL policy

If you set integration allowlist environment variables:
- `CULLARR_ALLOWED_INTEGRATION_HOSTS`
- `CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES`

Cullarr will reject integration base URLs outside policy.

You do **not** set anything extra inside integration records. The policy is global from environment variables.

After changing those env vars, restart app services.

Local app run:

```bash
# stop current local run first (Ctrl+C)
cd /path/to/cullarr
bin/dev
```

Docker Compose:

```bash
cd /path/to/cullarr
docker compose --profile <sqlite|postgres> --env-file <env-file> up -d --build
```

## 7) Run health checks

For each integration row, click **Check**.

Typical statuses:
- `healthy`: endpoint reachable, auth valid, compatibility supports delete path
- `warning`: read/sync allowed, destructive support disabled (usually compatibility mode)
- `unsupported`: integration version/contract not supported for destructive flow

## 8) Trigger first sync

1. Open `http://localhost:3000/runs`
2. Click **Sync Now**
3. Watch progress change from queued -> running -> success/failure

If a sync is already active, additional trigger may return `sync_queued_next`.

## 9) Verify expected results

After successful sync:
- Candidates page loads
- Plex users appear in candidate filters (when Tautulli users were synced)
- integration check metadata is populated

## Troubleshooting shortcuts

- auth errors: [troubleshooting/common-issues.md](../troubleshooting/common-issues.md)
- path mapping confusion: [guides/review-candidates-safely.md](review-candidates-safely.md)
- version mismatch: [reference/error-codes.md](../reference/error-codes.md)
