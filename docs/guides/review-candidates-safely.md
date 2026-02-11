# Review Candidates Safely

This guide helps you interpret candidates confidently before any deletion planning.

> [!IMPORTANT]
> This guide is review-only. It does not require delete mode unlock.

## What candidate blockers mean in plain terms

- **Protected path**: file path matches a path exclusion rule
- **Keep marker**: this item was explicitly marked "keep"
- **In progress**: selected user playback is still in progress
- **Ambiguous mapping**: metadata points to conflicting possible matches
- **Ambiguous ownership**: more than one integration appears to claim the same file path

## 1) Open candidates page

Go to:
- `http://localhost:3000/candidates`

Main filters:
- scope (`movie`, `tv_episode`, `tv_season`, `tv_show`)
- watched match mode
- include blocked candidates
- Plex user checkboxes

## 2) Understand user checkbox behavior

If you select Plex users, watched logic uses only that selected user set.

Watched match modes:
- `all`: every selected user must be watched
- `any`: at least one selected user watched
- `none`: none of the selected users should be in watched state

If no users are selected, Cullarr uses all synced users.

## 3) Understand season/show scope behavior

Season/show scope is determined from episode-level data.

Plainly:
- a season/show row represents many underlying episode rows
- if underlying episodes contain blockers, the season/show row can become non-actionable

## 4) Start with strict filters

Suggested first pass:
- scope: `movie`
- watched match: `all` or default
- include blocked: unchecked

Click **Apply Filters**.

## 5) Read the summary cards first

Cards show:
- rows scanned
- filtered by watched rule
- filtered by blockers
- active watched mode

Use these to quickly diagnose “why is list empty?” before changing many settings.

## 6) Interpret candidate rows

Each row shows:
- eligibility state
- mapping status
- risk flags
- blocker flags
- reason list
- media file IDs

### What "needs review" usually means

Most often:
- path mapping mismatch
- conflicting external IDs
- same path reported by multiple sources

## 7) Understand protected paths

Protected paths are configured in **Path Exclusions** (Settings page).

If a candidate path starts with a protected prefix, that item is blocked.

Use protected paths for locations you never want Cullarr to touch (for example family/kids folders).

## 8) Understand keep markers

Keep markers are explicit “never delete this” flags attached to movies/episodes/seasons/series.

If a keep marker exists on the relevant item (or parent where applicable), candidate is blocked.

## 9) Use include-blocked mode as validation tool

Enable **Include blocked candidates** and re-run filters.

Now you can validate that blockers are working exactly as intended.

## 10) If results look wrong

1. Review path mappings in Settings.
2. Run sync again.
3. Compare blocker reasons before/after.
4. Re-check user filter selection and watched match mode.

## Settings that strongly affect candidate output

- `watched_mode`
- `watched_percent_threshold`
- `in_progress_min_offset_ms`
- path exclusions
- keep markers
- integration compatibility status

For details see:
- [configuration/application-settings.md](../configuration/application-settings.md)
