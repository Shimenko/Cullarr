# Startup and Maintenance Checklist

Use this checklist after restarts/rollouts and after restore drills.

## Before restart or rollout

- [ ] Confirm `.env`/secret changes are intentional.
- [ ] Confirm backup path has enough space.
- [ ] Confirm latest backup completed successfully.

## Immediately after restart or rollout

## Service health

- [ ] `GET /up` returns `200`.
- [ ] web process is running.
- [ ] worker process is running.
- [ ] database init/prep step completed.

## Login and core pages

- [ ] sign-in works (`/session/new`).
- [ ] `/runs` loads.
- [ ] `/candidates` loads.
- [ ] `/settings` loads.

## API checks (authenticated)

- [ ] `GET /api/v1/health` returns `200` in an authenticated session.
- [ ] no unexpected `401` responses after login.

## Integration checks

- [ ] each integration returns a healthy or expected warning status.
- [ ] no new `integration_unreachable` or `integration_auth_failed` errors.

## Candidate and sync sanity

- [ ] trigger one sync and confirm run reaches completion.
- [ ] candidates load with expected scope/filter behavior.

## Database safety

- [ ] backup job is configured and observed.
- [ ] restore has been tested at least once (real drill, not just documented).

## Minimal restore drill acceptance

- [ ] stop app services
- [ ] restore database from known backup
- [ ] start app services
- [ ] sign in and verify `/runs`, `/candidates`, `/settings`
- [ ] run authenticated `GET /api/v1/health`

## Docker Compose quick commands

Check service state:

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> ps
```

Tail logs:

```bash
docker compose --profile <sqlite|postgres> --env-file <env-file> logs -f web worker
```

## Local app quick commands

Run DB prep check:

```bash
cd /path/to/cullarr
bin/rails db:prepare
```

Tail local log:

```bash
cd /path/to/cullarr
tail -f log/development.log
```

## Related docs

- `/path/to/cullarr/docs/guides/deploy-with-docker-compose.md`
- `/path/to/cullarr/docs/guides/backup-and-restore.md`
- `/path/to/cullarr/docs/troubleshooting/common-issues.md`
