# Review Candidates Safely

This guide focuses on candidate review only.

It does not execute deletion flows.

> [!IMPORTANT]
> Keep deletion mode disabled unless you intentionally need destructive execution and have completed your own safety sign-off.

## Goal

By the end of this guide, you should be able to:
- filter candidates by scope and watched semantics
- understand why rows are eligible or blocked
- use mapping, blocker, and risk signals to validate trust in results

## Step 1: Open the Candidates page

Go to `http://localhost:3000/candidates`.

At the top, review filter controls:
- **Scope**
- **Watched Match** (`all`, `any`, `none` semantics)
- **Include blocked candidates**
- Plex user checkboxes

## Step 2: Start with strict defaults

Recommended first pass:
- Scope: `movie`
- Watched Match: default
- Include blocked candidates: unchecked
- Plex users: leave blank to include all synced users

Click **Apply Filters**.

## Step 3: Read diagnostics first

The diagnostics cards explain what Cullarr filtered out:
- Rows scanned
- Filtered by watched rule
- Filtered by blockers
- Active watched mode

Use this to understand whether your filters are too strict or data is still incomplete.

## Step 4: Inspect row status signals

Each row includes status chips and flags.

### Eligibility state

- `Eligible`: actionable for planning
- `Blocked`: prevented by one or more guardrails

### Mapping state

Look for mapping chips and hints such as:
- mapped
- needs review
- unmapped
- rollup conflict indicators

### Risk flags

Risk flags indicate rows that need extra human review before action.

### Blockers

Common blocker classes:
- path excluded
- keep marker present
- in-progress playback
- ambiguous mapping
- ambiguous ownership

## Step 5: Use include-blocked mode to audit guardrails

Enable **Include blocked candidates** and apply filters again.

This view is useful for validating that guardrails are blocking the right content.

Questions to ask:
- Are protected paths blocked as expected?
- Are in-progress items blocked as expected?
- Are mapping conflicts visible and explainable?

## Step 6: Inspect reasons and media file context

Expand **Reasons and file context** for any row.

Use this section to trace:
- why the row was scored that way
- which media file IDs are associated
- whether the scope rollup is behaving as expected

## Step 7: Stop before deletion actions

For safe review-only workflow:
- do not enter delete mode password
- do not unlock delete mode
- do not run deletion plan or execution

You can still fully validate candidate quality without performing destructive operations.

## Common interpretation patterns

### "No candidates available"

Potential causes:
- watch filters too strict
- blockers filtering everything
- data not synced yet

Actions:
1. run sync again
2. broaden watched match mode
3. include blocked candidates to inspect why rows were removed

### Many rows marked "needs review"

This often indicates path mapping quality issues.

Actions:
1. open Settings -> Mapping Health
2. review ambiguous canonical path metrics
3. add/fix integration path mappings
4. re-run sync

## Next step

If candidate output looks wrong, use [troubleshooting/common-issues.md](../troubleshooting/common-issues.md).
