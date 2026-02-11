# Candidate Policy

This page explains how Cullarr decides whether media appears as an eligible candidate, blocked candidate, or non-candidate.

## Scope model

Cullarr supports four scopes:
- movie
- TV episode
- TV season
- TV show

Rollup scopes (season/show) are strict rollups over episode-level behavior.

## Watched decision model

### Mode: `play_count`

A watch is counted when play count is at least 1.

### Mode: `percent`

A watch is counted when max view offset / duration reaches configured threshold.

`watched_percent_threshold` controls the required percentage.

## User selection semantics

Filters support selecting specific Plex users.

Watched match mode controls how selected users are combined:
- `all`: all selected users must satisfy watched condition
- `any`: at least one selected user must satisfy watched condition
- `none`: user filter is not used for watched match

## Guardrails and blockers

A row is blocked when one or more blocker flags are present, for example:
- path exclusion
- keep marker
- in-progress playback
- ambiguous mapping
- ambiguous ownership

Blocked rows can be included in UI for visibility but stay non-actionable.

## Mapping status and risk

Candidate rows include mapping status and risk cues so operators can judge confidence.

Common mapping states:
- mapped
- unmapped
- needs review

Why this matters:
- mapping uncertainty can produce ownership ambiguity
- ownership ambiguity is a blocker for destructive execution

## Multi-version behavior

Rows with multiple version groups require explicit media file selection before planning execution.

Implicit all-version execution is intentionally rejected.

## Explainability contract

Each row can include:
- human-readable reasons
- risk flags
- blocker flags
- media file IDs

Cullarr prioritizes explainability so policy outcomes are auditable and understandable by humans.
