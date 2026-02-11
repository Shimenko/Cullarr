# Cullarr Documentation

Cullarr helps you safely review media deletion candidates from Sonarr and Radarr using watch history from Tautulli.

This documentation is written for a new operator who wants to get running quickly, then understand each setting and behavior without guessing.

> [!IMPORTANT]
> Deletion mode is disabled by default. You can run Cullarr safely for review and sync workflows without enabling deletion execution.

## Start Here

If this is your first time using Cullarr, read these in order:

1. [Local setup](getting-started/local-setup.md)
2. [Connect integrations and run your first sync](guides/connect-integrations-and-run-sync.md)
3. [Review candidates safely](guides/review-candidates-safely.md)

## Choose By Task

| I want to... | Read this |
| --- | --- |
| Run Cullarr locally | [getting-started/local-setup.md](getting-started/local-setup.md) |
| Understand every environment variable | [configuration/environment-variables.md](configuration/environment-variables.md) |
| Understand runtime settings from the Settings page | [configuration/application-settings.md](configuration/application-settings.md) |
| Deploy with Docker Compose | [guides/deploy-with-docker-compose.md](guides/deploy-with-docker-compose.md) |
| Back up and restore data | [guides/backup-and-restore.md](guides/backup-and-restore.md) |
| Rotate encryption keys safely | [guides/rotate-encryption-keys.md](guides/rotate-encryption-keys.md) |
| Troubleshoot errors | [troubleshooting/common-issues.md](troubleshooting/common-issues.md) |
| Use the API directly | [reference/api.md](reference/api.md) |
| Map API error codes to fixes | [reference/error-codes.md](reference/error-codes.md) |
| Understand data entities | [reference/data-model.md](reference/data-model.md) |
| Run a post-deploy checklist | [reference/deployment-checklist.md](reference/deployment-checklist.md) |
| Understand system design decisions | [concepts/architecture.md](concepts/architecture.md) |

## Documentation Map

### Getting started

- [Local setup](getting-started/local-setup.md)

### Guides

- [Connect integrations and run your first sync](guides/connect-integrations-and-run-sync.md)
- [Review candidates safely](guides/review-candidates-safely.md)
- [Deploy with Docker Compose](guides/deploy-with-docker-compose.md)
- [Back up and restore](guides/backup-and-restore.md)
- [Rotate encryption keys](guides/rotate-encryption-keys.md)

### Configuration

- [Environment variables](configuration/environment-variables.md)
- [Application settings](configuration/application-settings.md)

### Reference

- [API reference](reference/api.md)
- [Error codes](reference/error-codes.md)
- [Data model](reference/data-model.md)
- [Deployment checklist](reference/deployment-checklist.md)

### Troubleshooting

- [Common issues](troubleshooting/common-issues.md)

### Concepts

- [Architecture](concepts/architecture.md)
- [Safety model](concepts/safety-model.md)
- [Sync and query flow](concepts/sync-and-query-flow.md)
- [Candidate policy](concepts/candidate-policy.md)
