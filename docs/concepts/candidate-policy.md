# Candidate Policy

This page explains how Cullarr decides whether something is actionable, blocked, or filtered out.

## Supported scopes

Cullarr supports four scopes:
- movie
- TV episode
- TV season
- TV show

TV season/show are strict aggregate scopes built from episode-level decisions.

## Watched decision rules

Cullarr supports two watched modes:

- `play_count`: watched when play count is at least 1
- `percent`: watched when max view offset reaches configured threshold

`watched_percent_threshold` controls the required percent for `percent` mode.

## User checkbox behavior

When you select Plex users in filters, those users become the watched-evaluation set.

`watched_match_mode` controls how that set is evaluated:
- `all`: every selected user must be watched
- `any`: at least one selected user must be watched
- `none`: selected users are used to find not-watched cases

If no users are selected, Cullarr uses all known Plex users as the effective set.

## Watched prefilter behavior

Before full row scoring, Cullarr may apply watched prefiltering.

Current behavior:
- applies to movie and episode scopes
- mainly when watched mode is `play_count`
- can eliminate rows before detailed scoring

If your result set is unexpectedly empty, check diagnostics for `watched_prefilter_applied`.

## Blockers (why rows are non-actionable)

Common blocker flags:
- `path_excluded`
- `keep_marked`
- `in_progress_any`
- `ambiguous_mapping`
- `ambiguous_ownership`
- `rollup_not_strictly_eligible` (season/show)

A blocked row can still be shown when `include_blocked=true`, but Cullarr will not execute it until blockers are resolved.

## Keep markers and protected paths

## Keep marker

A keep marker is an explicit “do not delete” marker attached to a movie/episode/season/series context.

## Protected path

A protected path comes from `path_exclusions` and blocks deletion for matching path prefixes.

Both are hard safety signals.

## Mapping and ownership ambiguity

## Ambiguous mapping

Cullarr cannot confidently map integration/Plex identity for this item.

## Ambiguous ownership

The same normalized path appears to be owned by more than one integration context.

Both ambiguity types are treated as blockers to avoid accidental deletion.

## Multi-version behavior

Some candidates include multiple media files (multiple versions).

Cullarr requires explicit version/file selection in that case.

If you skip explicit selection, planning returns:
- `multi_version_selection_required`

## TV season/show strictness explained

For season/show scope, Cullarr computes eligibility from underlying episodes.

If any episode is blocked or does not meet watched criteria, the season/show aggregate is not considered strictly eligible.

This is intentional: partial eligibility should not look like a clean “delete all.”

## Why these rules exist

Cullarr policy favors explainable safety over silent assumptions.

The objective is predictable behavior you can audit and trust.

## Related docs

- `/path/to/cullarr/docs/concepts/sync-and-query-flow.md`
- `/path/to/cullarr/docs/guides/review-candidates-safely.md`
- `/path/to/cullarr/docs/reference/error-codes.md`
