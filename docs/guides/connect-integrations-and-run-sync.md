# Connect Integrations And Run Your First Sync

Use this guide after local setup to connect Sonarr, Radarr, and Tautulli, then run your first sync safely.

## Before you start

You should already have:
- Cullarr running (`bin/dev`)
- an operator account
- URLs and API keys for your integration instances

Recommended order:
1. Sonarr
2. Radarr
3. Tautulli

## Step 1: Re-authenticate for sensitive actions

Integration create/update/delete actions require recent re-authentication.

1. Open `http://localhost:3000/settings`
2. In **Security**, use **Re-authenticate** with your password.
3. Confirm success message: `Re-authentication successful for sensitive actions.`

## Step 2: Add Sonarr

In **Settings** -> **Integrations** -> **Add Integration**:

- Kind: `sonarr`
- Name: `Sonarr Main`
- Base URL: `http://sonarr.local:8989`
- API Key: `<your sonarr api key>`
- Compatibility Mode: `Strict latest`
- Request Timeout (seconds): `15`
- Retry Attempts: `5`
- Sonarr Fetch Workers: `4` (or `0` for auto)
- Verify SSL: enabled when using HTTPS with a valid cert

Click **Add Integration**.

## Step 3: Add Radarr

Use the same form:

- Kind: `radarr`
- Name: `Radarr Main`
- Base URL: `http://radarr.local:7878`
- API Key: `<your radarr api key>`
- Compatibility Mode: `Strict latest`
- Request Timeout (seconds): `15`
- Retry Attempts: `5`
- Radarr MovieFile Workers: `4` (or `0` for auto)
- Verify SSL: enabled when appropriate

Click **Add Integration**.

## Step 4: Add Tautulli

Use the same form:

- Kind: `tautulli`
- Name: `Tautulli Main`
- Base URL: `http://tautulli.local:8181`
- API Key: `<your tautulli api key>`
- Compatibility Mode: `Strict latest`
- Request Timeout (seconds): `15`
- Retry Attempts: `5`
- Tautulli History Page Size: `500`
- Tautulli Metadata Workers: `4` (or `0` for auto)
- Verify SSL: enabled when appropriate

Click **Add Integration**.

## Step 5: Add path mappings when paths differ

If integration-reported file paths do not match your canonical local paths, add mappings per integration.

Example mapping:

- From Prefix: `/data/media`
- To Prefix: `/mnt/media`

Rule of thumb:
- Add the most specific mappings first.
- Use root mapping (`/`) only when you intentionally want a broad global translation.

## Step 6: Run health checks

For each integration row, click **Check**.

Expected outcomes:
- `healthy`: connection + auth + compatibility checks pass
- `warning`: integration can be read, but delete compatibility is restricted
- `unsupported`: version contract does not meet requirements

If you get auth or connectivity errors, use [troubleshooting/common-issues.md](../troubleshooting/common-issues.md).

## Step 7: Trigger a manual sync

1. Open `http://localhost:3000/runs`
2. Click **Sync Now**
3. Watch live progress in the sync panel

Expected behavior:
- Status starts at `queued` then `running`
- Progress phases advance
- Final status becomes `success` or shows an explicit error code

## Step 8: Verify sync output

After first successful sync:

- `Candidates` page loads with either candidate rows or explicit empty-state guidance
- Plex users appear as selectable filters if Tautulli user sync completed
- Integration rows show recent check metadata

## Optional API path

If you are automating setup, use:

- `POST /api/v1/security/re-auth`
- `POST /api/v1/integrations`
- `POST /api/v1/integrations/:id/check`
- `POST /api/v1/sync-runs`
- `GET /api/v1/sync-runs/:id`

See full payload examples in [reference/api.md](../reference/api.md).
