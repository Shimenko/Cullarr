# Cullarr Documentation

This guide set is for people who want to run Cullarr confidently without reading source code first.

In this docs set:
- **integration** = one Sonarr, Radarr, or Tautulli instance
- multiple integrations of the same type are supported

## Start Here

1. [Local setup](getting-started/local-setup.md)
2. [Connect integrations and run your first sync](guides/connect-integrations-and-run-sync.md)
3. [Review candidates safely](guides/review-candidates-safely.md)

## Common Tasks

| Goal                                                   | Document                                                                         |
|--------------------------------------------------------|----------------------------------------------------------------------------------|
| Get Cullarr running on your machine                    | [getting-started/local-setup.md](getting-started/local-setup.md)                 |
| Understand every `.env` key and when restart is needed | [configuration/environment-variables.md](configuration/environment-variables.md) |
| Understand every Settings page option                  | [configuration/application-settings.md](configuration/application-settings.md)   |
| Run with Docker Compose                                | [guides/deploy-with-docker-compose.md](guides/deploy-with-docker-compose.md)     |
| Run full backup and restore                            | [guides/backup-and-restore.md](guides/backup-and-restore.md)                     |
| Rotate encryption keys safely                          | [guides/rotate-encryption-keys.md](guides/rotate-encryption-keys.md)             |
| Troubleshoot plain-language fixes                      | [troubleshooting/common-issues.md](troubleshooting/common-issues.md)             |
| Use API endpoints directly                             | [reference/api.md](reference/api.md)                                             |
| Understand error codes in plain terms                  | [reference/error-codes.md](reference/error-codes.md)                             |
| Understand data tables and relationships               | [reference/data-model.md](reference/data-model.md)                               |
| Run startup/restore verification checklist             | [reference/deployment-checklist.md](reference/deployment-checklist.md)           |

## Documentation Map

### Getting started
- [Local setup](getting-started/local-setup.md)

### Guides
- [Connect integrations and run your first sync](guides/connect-integrations-and-run-sync.md)
- [Review candidates safely](guides/review-candidates-safely.md)
- [Run with Docker Compose](guides/deploy-with-docker-compose.md)
- [Backup and restore](guides/backup-and-restore.md)
- [Rotate encryption keys](guides/rotate-encryption-keys.md)

### Configuration
- [Environment variables](configuration/environment-variables.md)
- [Application settings](configuration/application-settings.md)

### Reference
- [API reference](reference/api.md)
- [Error codes](reference/error-codes.md)
- [Data model](reference/data-model.md)
- [Startup and maintenance checklist](reference/deployment-checklist.md)

### Troubleshooting
- [Common issues](troubleshooting/common-issues.md)

### How it works
- [How Cullarr works](concepts/architecture.md)
- [Safety model](concepts/safety-model.md)
- [Sync and query flow](concepts/sync-and-query-flow.md)
- [Candidate policy](concepts/candidate-policy.md)
