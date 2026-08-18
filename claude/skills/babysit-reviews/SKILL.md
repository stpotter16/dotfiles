---
name: babysit-reviews
description: One sweep over every open Bitbucket PR where I'm tagged as reviewer (not author) — flags any that need my attention (never reviewed, an approval that predates new commits, or a changes-request the author may have since addressed) and dispatches pr-swarm, via a spawned agent per flagged PR, to leave automated review feedback. pr-swarm auto-detects it isn't my PR and never pushes to the branch. Tracks state so reruns skip PRs that haven't changed. Designed to be driven by /loop.
argument-hint: "[--workspace <ws>] [--limit <n>] [--dry-run]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill, Agent
model: sonnet
---

# Babysit Reviews

`babysit-prs`'s sibling: same sweep/state design, but for PRs I'm tagged as
**reviewer** on rather than PRs I authored. There's no fixing or pushing
here — the only action this skill takes is deciding which PRs need my
review attention, and dispatching `pr-swarm` to leave automated feedback on
those. `pr-swarm` itself refuses to push to a branch it doesn't detect as
mine (see its Step 1a), so this skill doesn't need to re-implement that
safety rule — it just never passes `--allow-push`.

One sweep per invocation. Run under `/loop`:

```text
/loop 20m /babysit-reviews
```

Prefer a fixed interval over self-pacing — "nothing needs my attention this
sweep" is a perfectly valid steady state, not a sign the loop should wind
down.

## Arguments

- `--workspace <ws>`: only sweep repos whose origin remote is under this
  Bitbucket workspace. Default: every workspace found among local clones.
- `--limit <n>`: max PRs to process this sweep (default: 10, most recently
  updated first).
- `--dry-run`: report what would be flagged; don't dispatch `pr-swarm` or
  update state.

## Setup

Same as `pr-swarm`/`babysit-prs`: `BITBUCKET_API_TOKEN`, `BITBUCKET_ACCOUNT_ID`,
`jq`/`git`/`curl` on PATH, repos cloned under `~/work` (or wherever
`babysit-prs` is configured to look). No new setup beyond what those two
already require.

## State

State lives in `~/.local/state/babysit-reviews/state.json`, keyed by PR URL:

```json
{
  "https://bitbucket.org/hunt-hen/hen-trader-portal-api/pull-requests/1302": {
    "updated_on": "2026-08-12T16:46:13.870727+00:00",
    "head_sha": "abc123",
    "my_state": "changes_requested",
    "my_participated_on": "2026-08-11T19:55:25.624203+00:00",
    "ci_conclusion": "FAILED",
    "pr_swarm_head_sha": "abc123"
  }
}
```

A PR is **quiet** (skip everything) when `updated_on` matches the stored
value. An absent key is never quiet — first sight always does a full
fetch. Even on a repeat sweep with nothing new, `pr-swarm` is only
redispatched if `head_sha != pr_swarm_head_sha` (see Step 4) — don't
re-review a head it already left feedback on.

## Your Task

### Step 1: Enumerate PRs where I'm a reviewer

Same local-clone enumeration as `babysit-prs` (no cross-repo search exists
on Bitbucket Cloud), but filter by `reviewers.account_id` instead of
`author.account_id`:

```bash
bb_curl -G --data-urlencode 'q=state="OPEN" AND reviewers.account_id="'"$BITBUCKET_ACCOUNT_ID"'"' \
  "$BB_API/repositories/<workspace>/<repo>/pullrequests"
```

`reviewers` isn't in Bitbucket's documented list of queryable PR fields
(only `participants`/`reviewers` are officially "returned on the `self` URL
only"), but this filter works empirically against the list endpoint — it's
been verified against real data. If a future API change breaks it, fall
back to fetching every open PR in each repo and filtering client-side on
`.participants[] | select(.user.account_id == $me and .role == "REVIEWER")`
from the per-PR fetch in Step 2 — more calls, but correct either way.

Same `printf '%s' "$out" | jq ...` rule as `pr-swarm`/`babysit-prs` — never
pipe through `echo` first, PR descriptions can contain sequences that get
mangled by shell backslash-interpretation.

Sort by `updated_on` descending, keep the first `--limit`. Read the state
file (missing = `{}`).

### Step 2: Decide who needs attention

Skip fully (no fetch) any PR whose `updated_on` matches state. For the
rest, fetch:

```bash
bb_curl "$BB_API/repositories/<ws>/<repo>/pullrequests/<id>"
bb_curl "$BB_API/repositories/<ws>/<repo>/pullrequests/<id>/statuses?pagelen=20"
```

From the PR fetch, pull `.participants[]` and find the entry where
`user.account_id == $BITBUCKET_ACCOUNT_ID` — that's `my_state`
(`approved`/`changes_requested`/`null`), `approved` (bool), and
`participated_on`. Also record the latest commit date (the PR object's
`source.commit` only gives the current head's hash, not its date — fetch
`.../commits?pagelen=1` for the newest commit's `date`) and the latest
comment's `created_on` across the full comment list (paginated, same as
`pr-swarm`'s Step 3).

**Needs attention** when:

- `my_state` is `null` and `participated_on` is `null` — never looked at
  this PR at all. Always flag.
- `my_state` is `null` and `participated_on` is set — commented before but
  never approved or requested changes. Flag if the latest commit date *or*
  latest comment date is newer than `participated_on`.
- `my_state` is `approved` — the approval may be stale. Flag only if the
  latest **commit** date is newer than `participated_on` (a new comment
  alone doesn't invalidate an approval; a new commit might).
- `my_state` is `changes_requested` — flag if the latest commit date *or* a
  comment from the PR's author is newer than `participated_on` (the author
  may have pushed a fix, or explained why they think it's fine, either way
  the ball is back in my court).
- Otherwise: quiet.

**CI status** (report-only, never gates flagging): reduce `statuses` the
same way as `babysit-prs` — `FAILED` if any entry is `FAILED`, else
`INPROGRESS`/pending, else `SUCCESSFUL`, else `unknown` if empty. If a
flagged PR's CI is `FAILED`, note "CI failing — may not be ready" alongside
the flag reason in the summary; still flag it, just with that caveat.

If PR `state != "OPEN"` (merged/declined, or I've been removed as
reviewer since last sweep), drop its state key and skip it.

### Step 3: Locate or create a worktree (only for PRs being dispatched)

Same convention as `babysit-prs` — `pr-swarm` needs a local checkout to
gather the diff even in review-only mode:

```bash
worktree_path="<base_dir>/.worktrees/<repo>/<source_branch>"
```

Reuse an existing worktree if present (`git -C <clone> worktree list`),
`git pull --ff-only` it to the current head; otherwise fetch and
`git worktree add`. Never touch the main clone's own working tree.

### Step 4: Dispatch pr-swarm

For every flagged PR whose `head_sha` differs from stored
`pr_swarm_head_sha` (or which has no stored value — first dispatch):
spawn one Agent per PR, all in a single message so they run concurrently.

Read `~/.claude/skills/pr-swarm/SKILL.md` and paste its full content into
each agent's prompt (same reasoning as `babysit-prs`: don't depend on the
agent being able to call `Skill("pr-swarm")` itself). Tell the agent:

- Working directory is `<worktree_path>` for this PR.
- `workspace`/`repo_slug`/`pr_id` are already known — skip pr-swarm's own
  Step 1 PR-detection.
- **Do not pass `--allow-push`.** This dispatch is expected to land in
  review-only mode via pr-swarm's own auto-detection (the PR's author is
  essentially never me here, by definition of "PRs I'm reviewing") —
  that's the point, not a fallback.
- Return its final sticky-summary content and ambiguous-item table for
  this sweep's own report.

A flagged PR that's quiet on `pr_swarm_head_sha` (already reviewed at this
exact head) still gets its row in the summary — flagged for a human reason
like a stale approval doesn't require a new `pr-swarm` pass if the code
hasn't moved since the last one.

### Step 5: Update state and summarize

Write back `updated_on`, `head_sha`, `my_state`, `my_participated_on`,
`ci_conclusion` for every PR from Step 1. Write `pr_swarm_head_sha` only
for PRs actually dispatched this sweep. Drop state keys for PRs no longer
in Step 1's results. Skip all of this under `--dry-run`.

Summary table:

| PR | Why flagged | CI | pr-swarm | 
| --- | --- | --- | --- |
| [hen-trader-portal-api#1302](…) | changes-requested, author pushed since | ❌ failing (`build`) | dispatched — 1 actionable comment posted | 
| [hen-trader-portal-api#1304](…) | never reviewed | ✅ passing | dispatched — no findings | 
| [hen-trader-portal#910](…) | approved, no new commits | ✅ passing | quiet — nothing to redo | 

Below the table, list every ambiguous item any dispatched `pr-swarm` agent
returned, same as `babysit-prs`'s rollup.

If nothing was flagged: `All <n> reviewer PRs quiet; nothing needs your
attention.`

## Graceful degradation

- **`BITBUCKET_API_TOKEN` or `BITBUCKET_ACCOUNT_ID` missing:** stop
  immediately, name which one and how to get it.
- **The `reviewers.account_id` filter starts erroring:** fall back to the
  client-side filter noted in Step 1, warn once that the shortcut broke.
- **A repo's worktree can't be created:** skip that PR's `pr-swarm`
  dispatch, still show its flag reason in the summary.
- **Bitbucket API error on one repo:** skip that repo this sweep, continue
  with the rest, note the failure.
- **A dispatched `pr-swarm` agent fails or times out:** record it as
  failed, don't retry within the sweep, leave `pr_swarm_head_sha`
  untouched so the next sweep retries it.
- **No reviewer PRs found at all:** print `No open PRs found where I'm
  tagged reviewer.` and stop — not an error.
