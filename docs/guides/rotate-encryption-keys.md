# Rotate Active Record Encryption Keys

Cullarr encrypts integration API keys at rest.

This guide rotates encryption keys safely while preserving rollback options.

## Required variables

- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

Production requires all three values.

## Key ring model

`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS` is a comma-separated key ring.

Order matters:
- oldest key first
- newest active key last

Example:

```text
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS=key_v1,key_v2,key_v3
```

In this example, `key_v3` is the active key used for new writes.

## Rotation procedure

### 1) Add a new active primary key

Append a new key to the end of `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS`.
Do not remove old keys yet.

### 2) Deploy and restart app services

Restart with the updated environment so all processes load the new key ring.

### 3) Re-encrypt stored integration API key ciphertext

```bash
bin/rails cullarr:encryption:rotate_integration_api_keys
```

This rewrites stored ciphertext using the currently active encryption key.

### 4) Validate integration behavior

In the Settings page, run **Check** on each integration.

Expected:
- no decryption errors
- health checks continue to work

### 5) Remove retired keys later

After validation and a safe observation window, remove old keys from the front of the ring in a later deploy.

## Rollback approach

If anything fails after rotation:

1. Re-deploy with previous key ring including old keys.
2. Re-run integration checks.
3. Investigate before attempting a second rotation.

## Safety checklist

- [ ] New key added to end of key ring.
- [ ] Old keys kept during first deploy.
- [ ] Re-encryption task completed.
- [ ] Integration health checks pass.
- [ ] Old keys removed only in a later deploy window.

## Never do this

- Never commit real key material to the repository.
- Never drop all old keys in the same deploy where you first introduce a new key.
