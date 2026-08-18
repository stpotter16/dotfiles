---
name: pr-swarm
description: >
  Runs a four-lens reviewer panel against a single Bitbucket Cloud pull
  request, triages every panel finding and every existing PR comment thread
  into actionable / nit / ambiguous, and loops until a pass produces
  nothing new — leaving only ambiguous items and human-participated threads
  for the user to decide. On the user's own PR (author auto-detected),
  actionable fixes are applied, verified, and pushed; on anyone else's PR,
  it auto-switches to review-only mode and posts findings as review
  comments instead of touching the branch. Use when the user asks for
  "pr-swarm", "swarm review", or wants a multi-perspective review with
  auto-triage against a Bitbucket PR. Accepts a PR number or URL as
  argument; without one, detects the PR open for the current branch.
argument-hint: "[<pr-id-or-url>] [--review-only] [--allow-push]"
---

# PR Swarm

Reviews one Bitbucket Cloud pull request from four independent angles, then
triages every finding — plus every pre-existing unresolved comment thread —
into three buckets: fix it now, resolve it as a nit, or flag it as ambiguous
for the user. Loops internally until nothing is left to auto-action; the
final report is the ambiguous backlog.

**Never touches a thread with any human participation.** Those are always
skipped entirely — no fix, no resolve, no reply — and don't even appear in
the ambiguous bucket; they're the user's conversation, not this skill's.

**Never replies inside a thread.** The only mutations this skill makes to
Bitbucket are: posting a brand-new inline comment for a finding, resolving a
thread it fixed or judged a nit, and upserting one sticky summary comment.
Disagreement, reasoning, and rationale live in the report, not in a reply.

**Never pushes to a branch that isn't the user's own, unless explicitly told
to.** See *Step 1a: Determine mode* — on someone else's PR this skill posts
findings as comments only. It is always safe to invoke on a colleague's PR
to leave automated review feedback; it will not touch their branch by
default.

## Bot identifier — required on every posted comment

Every comment this skill posts (inline finding comments, the sticky summary)
must begin with:

```markdown
> [!NOTE]
> 🤖 Automated comment by **PR Swarm** — not written by a human
```

Apply it at the outermost point where a comment body is assembled. Never
skip it.

## Setup (one-time, per machine)

- **`BITBUCKET_API_TOKEN`** — a Bitbucket Cloud scoped API token (Settings →
  API tokens, *not* the deprecated app passwords, which Atlassian is
  switching off). Needs **Pull requests: Read** and **Pull requests: Write**
  scopes. Authenticate as `Authorization: Bearer $BITBUCKET_API_TOKEN` — no
  username needed for a scoped token.
- **`BITBUCKET_ACCOUNT_ID`** — the user's own Bitbucket `account_id`, used
  by Step 1a to detect whether they authored the PR. Same value used by the
  `babysit-prs` skill; get it off the `author.account_id` field of any PR
  they've authored if not already set.
- **`jq`**, **`git`**, **`curl`** on PATH.
- Node/TS repo: package manager auto-detected from the lockfile present at
  the repo root (`package-lock.json` → npm, `yarn.lock` → yarn,
  `pnpm-lock.yaml` → pnpm).

If `BITBUCKET_API_TOKEN` is unset, stop immediately and tell the user how to
create one — don't attempt any Bitbucket call without it.

### API helper

All Bitbucket calls go through:

```bash
BB_API="https://api.bitbucket.org/2.0"
bb_curl() { curl -sS -H "Authorization: Bearer ${BITBUCKET_API_TOKEN}" -H "Accept: application/json" "$@"; }
```

Paginate every list endpoint by following the response's `.next` field until
it's null — comments in particular are paginated at a small page size and
silently truncating them will misclassify threads.

## Workflow

### Step 1: Resolve the PR, workspace, and repo

Derive `workspace`/`repo_slug` from the origin remote:

```bash
git remote get-url origin
# https://bitbucket.org/<workspace>/<repo_slug>.git  or
# git@bitbucket.org:<workspace>/<repo_slug>.git
```

If `$ARGUMENTS` looks like a PR number or a Bitbucket PR URL, use it
directly:

```bash
bb_curl "$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id"
```

Otherwise detect the PR open for the current branch:

```bash
branch=$(git branch --show-current)
bb_curl "$BB_API/repositories/$workspace/$repo_slug/pullrequests?q=source.branch.name%3D%22$branch%22%20AND%20state%3D%22OPEN%22"
```

If none found, ask the user for a PR number/URL and stop.

Record: PR id, `state`, `source.branch.name`, `destination.branch.name`,
`source.commit.hash` (current HEAD). If `state != "OPEN"`, tell the user and
stop — nothing to triage on a merged/declined PR.

### Step 1a: Determine mode — owner or review-only

Compare the PR's `author.account_id` (from the Step 1 fetch) against
`$BITBUCKET_ACCOUNT_ID`:

- **Match, or `--allow-push` was passed** → **owner mode**: Step 6 applies,
  verifies, commits, and pushes actionable fixes as written below.
- **No match, and `--allow-push` was not passed** → **review-only mode**:
  Step 6 instead posts actionable findings as inline comments — the same
  content a fix commit's comment would have had, but describing the
  suggested change in prose rather than applying it — and leaves them
  unresolved for the PR's author to act on. Nothing is ever applied,
  committed, or pushed in this mode, regardless of confidence.
- `--review-only` passed explicitly → review-only mode always, even on the
  user's own PR (useful for a lighter-weight pass that never touches the
  branch).

State which mode is active at the top of the terminal report and in the
sticky summary (see Step 9) — this should never be ambiguous to the user
reading the output. If `BITBUCKET_ACCOUNT_ID` is unset, treat it as
review-only for safety (see *Graceful degradation*) rather than guessing.

### Step 2: Gather the diff locally

```bash
git fetch origin "$destination_branch" "$source_branch"
base=$(git merge-base "origin/$destination_branch" "origin/$source_branch")
git diff "$base"..."origin/$source_branch" --name-only
git diff "$base"..."origin/$source_branch"
git log "$base"..."origin/$source_branch" --oneline
```

Store the changed-file list, full diff, commit log, and current HEAD sha.
Everything after this step operates on this diff until a fix is pushed and
the loop (Step 8) re-gathers it.

### Step 3: Fetch and classify existing comment threads

```bash
bb_curl "$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id/comments?pagelen=50"
```

Follow `.next` until exhausted. Each comment has `id`, `content.raw`,
`user`, `deleted`, `parent` (present on replies, absent on thread roots),
`inline.path` / `inline.to` (absent on top-level PR comments), and
`resolution` (present + non-null means already resolved — skip these
entirely).

Group into threads by root: a comment with no `parent` is a thread root;
comments whose `parent.id` matches it are replies in the same thread. Drop
`deleted: true` comments before classifying (but keep them if they're the
only reason a thread has replies — a deleted root with live replies still
needs handling).

**A comment is automated if either:**
- its author's `user.account_id`/`nickname` matches a known bot account you
  maintain a list of (CI bots, linters), **or**
- its `content.raw` starts with the `🤖 Automated comment by` header — this
  is what marks pr-swarm's own prior comments as automated, since they post
  through your account, not a bot account.

**If any comment in a thread is not automated, the whole thread is human** —
regardless of who opened it. Set it aside permanently: no fix, no resolve,
no mention outside a bare count in the final report ("N threads skipped —
human participation"). If you can't confidently classify a participant,
treat them as human.

Only unresolved, non-human threads carry into Step 5's triage.

### Step 4: Spawn the reviewer panel

Four independent lenses, each blind to the others and to any existing PR
comments — each is told it is the *sole* reviewer for its lens. Launch all
four as parallel Agent calls (single message, four tool uses):

| Lens | Model | Focus |
| --- | --- | --- |
| Correctness | `sonnet` | Logic errors, edge cases, off-by-ones, broken control flow |
| Security | `opus` | Auth, injection, secrets handling, SSRF, unsafe deserialization |
| Performance | `sonnet` | N+1s, unnecessary re-renders/re-computation, inefficient queries or algorithms |
| Style / simplification / tests | `haiku` | Reuse, dead code, unneeded abstraction, readability, missing/weak test coverage for the changed behavior |

This mapping is a starting point, not a constraint — bump a lens to `fable`
if you judge the diff's blast radius warrants a deeper pass (touches auth,
migrations, concurrency, or is unusually large), same rubric as the
`opus`/`fable` choice for security below.

Give each agent: the full diff, changed-file list, and commit log. Tell each
to read ~50 lines of surrounding context per change before judging, and to
end its response with:

```
STRUCTURED_FINDINGS:
- file: <path> | line: <number or "general"> | severity: <CRITICAL|HIGH|MEDIUM|LOW|NIT> | reviewer: <lens> | body: <the review comment text>
...

OVERALL_SUMMARY:
<1 paragraph assessment>
```

or `(none)` under `STRUCTURED_FINDINGS:` if the lens found nothing.

### Step 5: Triage — merge panel findings with existing threads

Combine Step 3's non-human, unresolved threads with Step 4's fresh findings
into one worklist. **Deduplicate** first: if a fresh finding lands on the
same file and within 5 lines of an existing open thread, treat them as the
same item (merge bodies, don't double-post) — note the convergence, it
raises confidence.

Classify each item:

- **Actionable** — all of: severity HIGH or CRITICAL (or MEDIUM+ with 2+
  lenses converging), the fix is concrete enough that a reader knows exactly
  what to change, and the change is confined to a single file. Anything that
  would need multi-file edits, a new dependency, or a design decision is
  **not** actionable here — downgrade it to ambiguous regardless of
  severity. (This is deliberately the conservative end of the autonomy
  spectrum — broad-but-clear findings still get a human's eyes before
  anything touches the branch.)
- **NIT** — style-only, speculative, duplicate, or already addressed
  elsewhere in the diff.
- **Ambiguous** — everything else: architectural judgement calls, multi-file
  scope, or genuine uncertainty about which fix is right.

### Step 6: Act on actionable items — owner mode pushes, review-only comments

Behavior branches on the mode determined in Step 1a.

**Owner mode** — for each actionable item:

1. Apply the fix with `Edit`.
2. Detect and run the repo's verify command:
   - `npm test`/`yarn test`/`pnpm test` plus a `lint` script if one exists in
     `package.json`, chosen by lockfile as described in Setup.
   - If no test/lint script is discoverable, use `AskUserQuestion` once per
     run to ask for the right command rather than pushing unverified — don't
     silently skip verification.
3. If verification fails, **do not commit or push**. Revert the edit,
   downgrade the item to ambiguous with a note ("fix attempted, verification
   failed — needs a human"), and move on.
4. If verification passes: `git add`, `git commit -m "fix: address pr-swarm
   <lens> <short description>"`, `git push` to the PR's source branch.
5. Post an inline comment on the file/line (bot header + `[<lens>]` tag +
   severity + finding body + "Fixed in `<short_sha>`."), then resolve the
   thread — for a pre-existing thread, resolve that thread's root comment
   id; for a fresh finding, resolve the comment you just posted (only valid
   on a top-level, on-diff comment — this qualifies).

**Review-only mode** — for each actionable item: never touch the working
tree, never run the verify command, never commit or push. Post an inline
comment on the file/line (bot header + `[<lens>]` tag + severity + finding
body + a concrete suggested fix written out in prose or a fenced code
snippet — enough that the PR's author could apply it themselves) and leave
the thread **unresolved**. This is left open deliberately — an actionable
finding from a reviewer's automated pass is a request for the author to
act, not a settled matter, and resolving your own review comment would
hide it before they've seen it.

To resolve a thread:

```bash
bb_curl -X POST "$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id/comments/$comment_id/resolve"
```

### Step 7: Resolve nits

- **Fresh NIT findings from the panel:** in both modes, post the inline
  comment (bot header + tag + body), then immediately resolve it. This is
  always safe — resolving your own just-posted comment, not someone else's
  thread — and leaves a record anchored to the diff even though no action
  was needed.
- **Existing NIT threads (owner mode):** resolve directly, no reply. Record
  the one-line reason ("cosmetic — no functional risk", "duplicate of
  <other finding>", "already addressed by <sha>") in the report.
- **Existing NIT threads (review-only mode):** don't resolve — it isn't
  this skill's thread to close on someone else's PR. Just record the
  classification and reason in the report; leave the thread as-is.

Post an inline comment:

```bash
bb_curl -X POST "$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id/comments" \
  -H "Content-Type: application/json" \
  -d '{"content":{"raw":"<comment body>"},"inline":{"path":"<file>","to":<line>}}'
```

### Step 8: Loop

After a pass applies fixes and resolves nits, check whether anything
qualifies as newly actionable or nit:

- If commits were pushed this pass, re-gather the diff (Step 2) against the
  new HEAD and re-run the panel (Step 4) only if the new diff touches a
  non-doc file (skip re-review for pure `.md`/comment-only follow-ups).
- Re-fetch comment threads (Step 3) in case resolving one surfaced a reply
  or a teammate reacted mid-run.
- Re-triage (Step 5) the combined state.

Repeat until a pass produces zero newly-actionable and zero newly-nit items.
Cap at **5 iterations** as a backstop — if still hit, stop anyway and note
in the report that repeated new findings across iterations may indicate a
flaky verify command or a lens surfacing new issues introduced by its own
prior fixes.

### Step 9: Sticky summary + final report

Maintain exactly one top-level PR comment, marked `<!-- pr-swarm-summary -->`.
Find it via:

```bash
bb_curl "$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id/comments?pagelen=50" \
  | jq '[.values[] | select(.content.raw | contains("<!-- pr-swarm-summary -->"))][0].id'
```

`PUT` to that comment id if found, otherwise `POST` a new one. Body shape:

```markdown
<!-- pr-swarm-summary -->
> [!NOTE]
> 🤖 Automated comment by **PR Swarm** — not written by a human
>
> Four-lens panel (correctness, security, performance, style/tests) + triage of existing threads. Round <N> @ <short_sha>. Mode: <OWNER (auto-push) | REVIEW-ONLY>.

## Verdict: <emoji> <VERDICT>

<1-2 sentence assessment>

### This round
- Owner mode: Fixed & pushed: <n> (<short_sha> each, listed below)
- Review-only mode: Suggested fixes posted (unresolved, awaiting author): <n>
- Nits resolved: <n>
- Human-participated threads skipped: <n>

### ⚠️ Needs your call — ambiguous items

| File:Line | Severity | Reviewer | Summary |
| --- | --- | --- | --- |
| ... | ... | ... | ... |

---
*Automated by PR Swarm — not a human review*
```

Verdict tiers (reuse across rounds): CRITICAL finding present → 🚫 BLOCKED;
2+ HIGH or 1 HIGH+2 MEDIUM → ⚠️ REQUEST CHANGES; 1 HIGH or 3+ MEDIUM → 💬
APPROVE WITH NITS; otherwise → ✅ APPROVE. Base this on what's *left*
(ambiguous + deferred), not on what was already fixed this round.

Print the same report to the terminal. This skill does not sleep or
self-loop across separate invocations — Step 8's loop is internal to one
run; re-invoke it later (manually, or wrapped in `/loop`) to pick up new
commits or comments.

## Graceful degradation

- **`BITBUCKET_API_TOKEN` missing or rejected (401/403):** stop immediately,
  tell the user which scopes are needed, don't attempt further calls.
- **`BITBUCKET_ACCOUNT_ID` missing or unresolvable:** don't guess at
  ownership — default to review-only mode and say so plainly in the report,
  even if the PR happens to be the user's own. A wrongly-assumed owner mode
  is the one mistake here that pushes to a branch; a wrongly-assumed
  review-only mode only costs an unresolved comment thread.
- **No PR found for the current branch and no argument given:** ask for a
  PR number/URL, stop.
- **No test/lint command discoverable:** ask once via `AskUserQuestion`
  rather than pushing unverified fixes.
- **Bitbucket API pagination or transient errors:** retry with backoff
  once; if it persists, warn and continue with whatever was fetched,
  flagging in the report that thread state may be incomplete.
- **A lens agent fails or times out:** proceed with the remaining lenses,
  note in the report which lens was unavailable this round.
