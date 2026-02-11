# Rotate Active Record Encryption Keys

Cullarr stores integration API keys encrypted at rest. This guide shows how to rotate keys without breaking existing data.

## What is encrypted

Cullarr encrypts `Integration#api_key_ciphertext` with Active Record Encryption.

In practice, this means:
- your Sonarr/Radarr/Tautulli API keys are not stored as plaintext
- key rotation is an operational task you should test before production use

## Required environment variables

These three environment variables must be present in production:

- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS` is a comma-separated key ring. The last key in the list is used for new writes.

Example:

```text
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS=key_v1,key_v2,key_v3
```

In this example, `key_v3` is the active write key.

> [!IMPORTANT]
> Any `.env` or environment-variable change requires an application restart. If you rotate keys but do not restart, some processes may still use old values.

## Generate new key material

### Recommended command

Use Rails to generate compatible key material.

Local app run:

```bash
cd /path/to/cullarr
bin/rails db:encryption:init
```

Docker Compose:

```bash
cd /path/to/cullarr
docker compose --profile <sqlite|postgres> --env-file <env-file> run --rm web bin/rails db:encryption:init
```

That command prints values you can use for:
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

### Alternate command

If you need one new primary key value only:

```bash
openssl rand -hex 32
```

## Safe rotation flow (primary keys)

Use this for normal key rotation of encrypted integration API keys.

1. Take a database backup first.
2. Append a new key to the end of `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`.
3. Restart all app processes (web + worker) with updated key values.
4. Re-encrypt stored integration API key ciphertext with the active key.
5. Verify integrations still pass health checks.
6. After a stable observation window, remove old keys in a later change window.

### Step 1: Backup first

Follow:
- `/path/to/cullarr/docs/guides/backup-and-restore.md`

### Step 2: Add a new active key

Before:

```text
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS=key_v1,key_v2
```

After:

```text
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS=key_v1,key_v2,key_v3
```

Do not remove `key_v1` and `key_v2` in this first change window.

### Step 3: Restart app services

Restart so all app processes load the same key ring.

Local app run:

```bash
# stop currently running process first (Ctrl+C) if needed
cd /path/to/cullarr
bin/dev
```

Docker Compose:

```bash
cd /path/to/cullarr
docker compose --profile <sqlite|postgres> --env-file <env-file> up -d --build
```

### Step 4: Re-encrypt stored ciphertext

Run the built-in re-encryption task:

Local app run:

```bash
cd /path/to/cullarr
bin/rails cullarr:encryption:rotate_integration_api_keys
```

Docker Compose:

```bash
cd /path/to/cullarr
docker compose --profile <sqlite|postgres> --env-file <env-file> run --rm web bin/rails cullarr:encryption:rotate_integration_api_keys
```

Expected output format:

```text
Integration API key rotation complete. Rotated: <n>, skipped: <n>.
```

### Step 5: Verify integration behavior

In the UI:
1. Open Settings.
2. For each integration, run **Check**.
3. Confirm there are no auth or decryption failures.

Optional API check (authenticated session required):

```bash
curl -i http://localhost:3000/api/v1/health
```

### Step 6: Retire old keys later

After you confirm stable behavior, remove oldest keys in a later change window.

Example follow-up key ring:

```text
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS=key_v2,key_v3
```

## Rollback plan

If anything fails after rotation:

1. Restore previous environment values (including old keys).
2. Restart app processes.
3. Re-run integration checks.
4. If needed, restore database from backup.

## About deterministic key and salt rotation

Routine rotation usually means rotating `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`.

Changing `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` or `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` is a deeper migration task. Treat it as planned maintenance with a tested backup/restore path first.

## Completion checklist

- [ ] Backup completed before rotation.
- [ ] New primary key appended at the end of key ring.
- [ ] App processes restarted after env change.
- [ ] `bin/rails cullarr:encryption:rotate_integration_api_keys` completed.
- [ ] Integration checks pass.
- [ ] Old keys removed only in a later change window.

## Never do this

- Never commit real key material.
- Never replace the key ring with only a new key in one step.
- Never rotate keys without a fresh backup.
