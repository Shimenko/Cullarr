# Deployment And Maintenance Checklist

Use this short checklist after deploys and restores.

## Service health

- [ ] `GET /up` returns `200`
- [ ] web and worker processes are running
- [ ] database initialization step completed successfully

## Login and core pages

- [ ] sign-in works
- [ ] `/runs` loads
- [ ] `/candidates` loads

## API health

- [ ] `GET /api/v1/health` returns `200` when authenticated

## Data safety

- [ ] backup job completed for active profile
- [ ] restore drill has been run and logged at least once

## Related guides

- [../guides/deploy-with-docker-compose.md](../guides/deploy-with-docker-compose.md)
- [../guides/backup-and-restore.md](../guides/backup-and-restore.md)
