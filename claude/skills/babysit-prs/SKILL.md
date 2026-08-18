---
name: babysit-prs
description: One sweep over all my open Bitbucket PRs across ~/work — check CI status and branch freshness, lint/format and regenerate drifted artifacts, then dispatch my pr-swarm skill (via a spawned agent per PR) for anything with a new commit or new comment. Tracks state so reruns skip already-handled work. Designed to be driven by /loop.
argument-hint: "[--workspace <ws>] [--limit <n>] [--dry-run]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill, Agent
model: sonnet
---

# Babysit PRs

Perform **one sweep** over my open Bitbucket pull requests: for each, check CI
(Bitbucket Pipelines) status and branch freshness, run a cheap lint/format
and generated-artifact pass, and dispatch my `pr-swarm` skill — through a
spawned agent, one per PR — for anything with a new commit or new comment
since it last ran. Record what was checked so the next sweep skips quiet
PRs.

This skill does a single iteration on purpose. Run it continuously with the
loop runner:

```text
/loop 20m /babysit-prs
/loop /babysit-prs          # self-paced
```

`pr-swarm` has its own internal loop (it re-triages a single PR until only
ambiguous items remain). This skill's loop is one level up: it decides,
sweep to sweep, *which* PRs are worth handing to `pr-swarm` at all.

## Arguments

- `--workspace <ws>`: only sweep repos whose origin remote is under this
  Bitbucket workspace (repeatable). Default: every workspace found among
  the local clones (in practice, just `hunt-hen`).
- `--limit <n>`: max PRs to process this sweep (default: 10, most recently
  updated first).
- `--dry-run`: report what would be done; take no fix/push actions and
  don't update state.

## Setup (one-time, per machine)

- Everything `pr-swarm` needs (`BITBUCKET_API_TOKEN`, `jq`, `git`, `curl`) —
  see its SKILL.md.
- **`BITBUCKET_ACCOUNT_ID`** — your Bitbucket `account_id`, used to filter
  "my" PRs. Your token's scopes (`read:pullrequest`, `write:pullrequest`)
  can't call `/user` to look this up directly; instead read it off the
  `author.account_id` field of any PR you've authored (`gh`-less
  equivalent: `bb_curl .../pullrequests/<id> | jq .author.account_id`).
  Already discovered for this machine: `712020:656a4fac-5b57-40c0-9b86-b517b4f6b5cd`.
- **`BABYSIT_PRS_BASE_DIR`** — where your repo clones live. Default
  `~/work`. The sweep only considers repos actually cloned here with a
  `bitbucket.org` origin remote — it never sweeps a repo it can't check out
  a worktree for.

### API helper

Reuse `pr-swarm`'s `bb_curl` helper (`$BB_API`, `Authorization: Bearer
$BITBUCKET_API_TOKEN`). This skill adds one more endpoint family:
build/pipeline statuses, at
`$BB_API/repositories/{workspace}/{repo}/pullrequests/{id}/statuses`.

## State

State lives in `~/.local/state/babysit-prs/state.json`, keyed by PR URL:

```json
{
  "https://bitbucket.org/hunt-hen/hen-trader-portal-api/pull-requests/1300": {
    "updated_on": "2026-08-12T11:21:40.725879+00:00",
    "head_sha": "4874cce3d3d9",
    "ci_conclusion": "SUCCESSFUL",
    "last_comment_at": "2026-08-12T10:00:00Z",
    "branch_behind_count": 0,
    "pr_swarm_head_sha": "4874cce3d3d9",
    "lint_autofix_head_sha": "4874cce3d3d9",
    "artifact_regen_head_sha": "4874cce3d3d9"
  }
}
```

A PR is **quiet** (skip everything but the cheapest re-check) when its
current `updated_on` matches the stored value AND `ci_conclusion` is
terminal (`SUCCESSFUL`, `FAILED`, or `STOPPED` — not `INPROGRESS`) AND it
has no comments newer than `last_comment_at`. An absent key is never quiet —
first sight of a PR always does a full fetch.

A quiet PR is **still active for `pr-swarm`** only if `head_sha !=
pr_swarm_head_sha` or there's a newer comment than `last_comment_at` — i.e.
even on a repeat sweep where nothing new happened, don't re-dispatch
`pr-swarm` against a PR it already finished reviewing at the current head.

## Your Task

### Step 1: Enumerate my open PRs

Bitbucket Cloud has no cross-repo PR search, so enumerate local clones
instead of querying the workspace:

```bash
for d in "$BABYSIT_PRS_BASE_DIR"/*; do
  [ -d "$d/.git" ] || continue
  remote=$(git -C "$d" remote get-url origin 2>/dev/null)
  # keep only bitbucket.org remotes, optionally filtered to --workspace
done
```

For each matching repo, fetch open PRs authored by me:

```bash
bb_curl -G --data-urlencode 'q=state="OPEN" AND author.account_id="'"$BITBUCKET_ACCOUNT_ID"'"' \
  "$BB_API/repositories/<workspace>/<repo>/pullrequests"
```

**Always pipe API responses to `jq` via `printf '%s' "$out" | jq ...`, never
`echo "$out" | jq ...`** — PR descriptions containing `\n` can trip an
`echo` with backslash-interpretation enabled and corrupt the JSON before it
reaches `jq`.

Sort all results across all repos by `updated_on` descending, keep the
first `--limit`. Read the state file (missing file = `{}`).

### Step 2: Classify each PR

If `updated_on` matches state and both settle conditions from **State**
hold, mark quiet — but still check `head_sha` and `last_comment_at` against
`pr_swarm_head_sha` to decide whether `pr-swarm` itself is owed a dispatch
(see **State**). A quiet PR needing no `pr-swarm` dispatch gets no further
calls this sweep beyond its summary row.

For everything else, fetch:

```bash
bb_curl "$BB_API/repositories/<ws>/<repo>/pullrequests/<id>" \
  --jq '{state, updated_on, head_sha: .source.commit.hash, source_branch: .source.branch.name, dest_branch: .destination.branch.name}'
bb_curl "$BB_API/repositories/<ws>/<repo>/pullrequests/<id>/statuses?pagelen=20"
bb_curl "$BB_API/repositories/<ws>/<repo>/pullrequests/<id>/comments?pagelen=50"
```

- **CI status**: reduce the `statuses` list to one conclusion —
  `FAILED` if any entry is `FAILED`, else `INPROGRESS` if any is
  `INPROGRESS`/`STOPPED` is ambiguous-treat-as-pending, else `SUCCESSFUL` if
  all are `SUCCESSFUL`, else `unknown` if the list is empty (no pipeline
  configured, or none run yet on this commit).
- **Comments**: take the max `created_on` across all (deleted or not,
  human or bot — this is just the activity signal, not the triage itself;
  `pr-swarm` does its own human/bot classification when it actually runs).
- **Branch freshness** (read-only, never gates anything):
  ```bash
  git -C <checkout> fetch origin "<dest_branch>" "<source_branch>"
  git -C <checkout> rev-list --count "origin/<source_branch>..origin/<dest_branch>"
  ```
  A non-zero count means the source branch is behind. This needs *a*
  checkout to run `git rev-list` from — use the main clone at
  `$BABYSIT_PRS_BASE_DIR/<repo>` for this read-only check; it doesn't
  require the PR's branch to be checked out there, just fetched refs.

If PR `state != "OPEN"` (merged/declined since last sweep), drop its state
key and skip it — nothing left to babysit.

### Step 3: Locate or create a worktree (only for PRs getting a `pr-swarm` dispatch)

No worktree helper exists in this setup, so use a fixed convention:

```bash
worktree_path="$BABYSIT_PRS_BASE_DIR/.worktrees/<repo>/<source_branch>"
git -C "$BABYSIT_PRS_BASE_DIR/<repo>" worktree list  # check it doesn't already exist
```

If it doesn't exist:

```bash
git -C "$BABYSIT_PRS_BASE_DIR/<repo>" fetch origin "<source_branch>"
git -C "$BABYSIT_PRS_BASE_DIR/<repo>" worktree add "$worktree_path" "<source_branch>"
```

If it already exists, `git -C "$worktree_path" pull --ff-only` to bring it
to the current head before dispatching. This worktree is dedicated to this
PR's branch — never reused for another branch, never the main clone's own
working tree.

### Step 4: Cheap per-PR passes (before any `pr-swarm` dispatch)

Run these in the PR's worktree, only for PRs that are active (Step 2) and
have a worktree (Step 3) — skip entirely for quiet PRs, and skip the
push half (but still report drift) for repos where **Step 4a** can't
detect a Node toolchain, per the non-Node handling rule below.

**Node-toolchain detection**: a `package.json` at the worktree root with a
lockfile determining the package manager (`package-lock.json` → npm,
`yarn.lock` → yarn, `pnpm-lock.yaml` → pnpm). No `package.json` → this repo
has no Node toolchain; skip 4a and 4b entirely (report nothing — "not
applicable" isn't drift) and note in the PR's summary row that pr-swarm
will review-only, never push, there (Step 5's gate, restated here since 4a
uses the same detection).

**4a. Lint/format autofix.** If `package.json` has a `lint` script with a
`--fix`-capable form (or a separate `lint:fix`) or a `format` script, run
it. If it produces a non-empty diff, commit (`chore: lint/format autofix`)
and push directly — no review needed for a formatter's own output. Record
`lint_autofix_head_sha` as the new head.

**4b. Regenerate drifted artifacts.** If `package.json` has a script
literally named `generate`, `codegen`, or `gen`, run it. If the diff is
non-empty, commit (`chore: regenerate drifted artifacts`) and push. Record
`artifact_regen_head_sha`. Skip silently if no such script exists — most
repos won't have one, and that's not drift, just "not applicable."

Both 4a and 4b can each push a commit before `pr-swarm` ever runs; refetch
`head_sha` after them so Step 5 dispatches `pr-swarm` against the fully
cleaned-up diff, not the pre-autofix one.

### Step 5: Dispatch `pr-swarm`

For every PR whose `head_sha` (post-Step-4) differs from stored
`pr_swarm_head_sha`, or which has a comment newer than `last_comment_at`:

Dispatch one Agent per such PR. Batch all of this sweep's dispatches into a
**single message with multiple Agent tool calls** so they run concurrently
— one PR's review shouldn't block another's.

Resolve `pr-swarm`'s instructions local-first: read
`~/.claude/skills/pr-swarm/SKILL.md` and pass its full content into the
agent's prompt (don't rely on the agent being able to call
`Skill("pr-swarm")` itself — a skill created this session isn't
registered for the Skill tool until the next session start, and a spawned
agent has no more guarantee of it than this one does). Tell the agent:

- Its working directory is `<worktree_path>` for this PR.
- Follow the pasted `pr-swarm` instructions end-to-end for PR `<url>`
  (`workspace`/`repo_slug`/`pr_id` already known — skip its own Step 1
  PR-detection, it's redundant here).
- **Non-Node override**: if no Node toolchain was detected in Step 4, tell
  the agent explicitly not to attempt verification or pushes at all — every
  otherwise-actionable finding gets downgraded to ambiguous and reported
  only. This is an unattended sweep; there's no one to answer a "what's
  your test command?" prompt.
- Return its final sticky-summary content and ambiguous-item table so this
  sweep can fold them into its own report.

### Step 6: Update state and summarize

For every PR from Step 1, write back `updated_on`, `head_sha`,
`ci_conclusion`, `last_comment_at`, `branch_behind_count`, and — only for
PRs actually touched this sweep — `pr_swarm_head_sha`,
`lint_autofix_head_sha`, `artifact_regen_head_sha`. A PR the pre-filter
marked fully quiet keeps every stored value verbatim; don't overwrite a
field you didn't actually re-derive this sweep. Drop any state key whose PR
is no longer in Step 1's results (closed/merged, or no longer mine).

Skip all of this under `--dry-run`.

End with a summary table:

| PR | CI | Branch | Toolchain | Action taken |
| --- | --- | --- | --- | --- |
| [hen-trader-portal-api#1300](…) | ✅ passing | up to date | node | quiet — pr-swarm already reviewed @ 4874cce |
| [hen-ercotapi#173](…) | ❌ failing (`build`) | 3 behind `main` | none (Java) | dispatched pr-swarm — review only, no push (no Node toolchain) |
| [hen-trader-portal#910](…) | ✅ passing | up to date | node | lint autofix pushed `a1b2c3d`; pr-swarm: 1 fixed, 2 ambiguous |

Below the table, list every ambiguous item any dispatched `pr-swarm` agent
returned, grouped by PR — this is the actual "needs you" backlog, same as
`pr-swarm`'s own report, just rolled up across every PR this sweep touched.

If every PR was quiet: `All <n> open PRs quiet; nothing to do.`

## Graceful degradation

- **`BITBUCKET_API_TOKEN` or `BITBUCKET_ACCOUNT_ID` missing:** stop
  immediately, name which one and how to get it (see Setup).
- **A repo's worktree can't be created** (e.g. dirty main clone blocking a
  fetch, disk issue): skip that PR, flag it in the summary rather than
  retrying.
- **Bitbucket API error on one repo:** skip that repo for this sweep,
  continue with the rest, note the failure in the summary.
- **A dispatched `pr-swarm` agent fails or times out:** record it in the
  summary as failed, don't retry within the sweep, leave its state
  untouched so the next sweep retries it (don't write a `pr_swarm_head_sha`
  for a dispatch that didn't actually complete).
- **No PRs found at all:** print `No open PRs found under <workspace>.` and
  stop — not an error.
