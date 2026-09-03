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
to.** See _Step 1a: Determine mode_ — on someone else's PR this skill posts
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
  API tokens, _not_ the deprecated app passwords, which Atlassian is
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
- **One-time permission rule**, so none of the scripts below need a
  per-call approval prompt: whitelist `bash ~/.claude/skills/pr-swarm/scripts/*.sh`
  (use the `update-config` skill to add it — don't hand-edit
  `settings.json`). Safe to pre-approve wholesale: the read-side scripts
  touch nothing, and the write-side script (`apply-batch.sh`) enforces its
  own repo/branch/PR-state guardrails independent of this rule, so a stale
  or malformed manifest fails closed instead of acting on the wrong PR.

If `BITBUCKET_API_TOKEN` is unset, stop immediately and tell the user how to
create one — don't attempt any Bitbucket call without it.

### Scripts

All Bitbucket/git mechanics for this skill live in
`~/.claude/skills/pr-swarm/scripts/` rather than ad-hoc bash — partly so one
whitelisted invocation replaces what used to be many raw `curl`/`git` calls,
and partly because shell command substitution (`$(...)`, needed for almost
every value capture — a branch name, a merge-base sha, a paginated `.next`
cursor) trips a blanket reject in some approval hooks; hiding it inside a
script avoids that.

| Script                                      | Reads/writes | Purpose                                                                                              |
| ------------------------------------------- | ------------ | ---------------------------------------------------------------------------------------------------- |
| `resolve-target.sh [pr-id-or-url]`          | read         | Step 1: resolve workspace/repo/PR                                                                    |
| `gather-diff.sh <dest> <source>`            | read         | Step 2: fetch + diff + log                                                                           |
| `bb-paginate.sh <url>`                      | read         | Step 3/9: follow `.next`, emit JSONL                                                                 |
| `apply-batch.sh <manifest.json> <log.json>` | **write**    | Steps 6/7/9: commit+push, post comments, resolve threads, upsert sticky summary — one call per round |
| `undo-batch.sh <log.json>`                  | **write**    | Reverts everything one `apply-batch.sh` call did, using its log                                      |

Each script documents its own usage/JSON shape in a header comment, but the
one you'll need every round — `apply-batch.sh`'s manifest — is spelled out in
full in Step 7b below, so you shouldn't need to open the script itself in
normal operation. Only fall back to a script's header comment for shapes not
already spelled out inline in the steps above (e.g. if a script's behavior
changes and this doc drifts).

## Workflow

### Step 1: Resolve the PR, workspace, and repo

```bash
bash ~/.claude/skills/pr-swarm/scripts/resolve-target.sh "$ARGUMENTS"
```

(pass no argument to auto-detect the OPEN PR for the current branch instead).
Prints one JSON object: `workspace`, `repo_slug`, `pr_id`, `state`,
`source_branch`, `destination_branch`, `source_commit`,
`author_account_id`. Record all of it.

- Exit 2 → no PR found / couldn't parse the argument: ask the user for a PR
  number/URL and stop.
- Exit 3 → `BITBUCKET_API_TOKEN` unset: see Setup.
- `state != "OPEN"`: tell the user and stop — nothing to triage on a
  merged/declined PR.

### Step 1a: Determine mode — owner or review-only

Compare `author_account_id` (from the Step 1 output) against
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
review-only for safety (see _Graceful degradation_) rather than guessing.

### Step 2: Gather the diff locally

```bash
bash ~/.claude/skills/pr-swarm/scripts/gather-diff.sh "$destination_branch" "$source_branch"
```

Prints `===BASE===` / `===CHANGED_FILES===` / `===DIFF===` / `===LOG===`
sections. Store the merge-base sha, changed-file list, full diff, and commit
log. Everything after this step operates on this diff until a fix is pushed
and the loop (Step 8) re-gathers it.

### Step 3: Fetch and classify existing comment threads

```bash
bash ~/.claude/skills/pr-swarm/scripts/bb-paginate.sh \
  "https://api.bitbucket.org/2.0/repositories/$workspace/$repo_slug/pullrequests/$pr_id/comments?pagelen=50"
```

Prints one JSON object per line, already flattened across every page. Each
comment has `id`, `content.raw`,
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

**Exception: the sticky summary thread is never skipped, even though the
user's replies under it make it "human."** The thread rooted at the comment
containing `<!-- pr-swarm-summary -->` is this skill's own feedback
channel — the user replies there specifically to answer the "Needs your
call" table from a previous round (accept / decline / defer to a ticket /
fold into other work). Always fetch and read every reply in this thread in
full, regardless of who wrote it. This is a read-only exception: still never
reply inside it, never resolve it, never treat it as a normal actionable/nit
source — just extract the decisions from it for Step 5. A reply typically
contains a markdown table shaped like `| File:Line | Summary | Response |
Follow up ticket |`; parse each row's file:line, the user's response text,
and ticket id (if any) into a lookup keyed by file:line for Step 5. If a
row's phrasing is too loose to map to an exact file:line (e.g. the row was
written against an earlier round's line numbers, which drift as the file
changes), match it by the nearest schema/operation name mentioned instead of
by exact line number.

Only unresolved, non-human threads — plus the sticky summary thread's parsed
decisions — carry into Step 5's triage.

### Step 4: Spawn the reviewer panel

Four independent lenses, each blind to the others and to any existing PR
comments — each is told it is the _sole_ reviewer for its lens. Launch all
four as parallel Agent calls (single message, four tool uses):

| Lens                           | Model    | Focus                                                                                                    |
| ------------------------------ | -------- | -------------------------------------------------------------------------------------------------------- |
| Correctness                    | `sonnet` | Logic errors, edge cases, off-by-ones, broken control flow                                               |
| Security                       | `opus`   | Auth, injection, secrets handling, SSRF, unsafe deserialization                                          |
| Performance                    | `sonnet` | N+1s, unnecessary re-renders/re-computation, inefficient queries or algorithms                           |
| Style / simplification / tests | `haiku`  | Reuse, dead code, unneeded abstraction, readability, missing/weak test coverage for the changed behavior |

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

**Check the sticky summary's parsed decisions next**, before classifying.
For each item in the worklist, check whether its file:line (or nearest
matching schema/operation name) has an entry in the sticky summary's reply
lookup from Step 3:

- If the user's response was a **decline** ("too broad", "not right now",
  "assuming intentional," etc.) or a **defer to a specific ticket/future
  work**: don't classify it as fresh actionable/nit/ambiguous. Carry it into
  the report under a distinct "already triaged by you" bucket instead,
  citing the ticket id or the deferred-to work item verbatim. Never
  re-apply a fix the user already declined, even if it would otherwise
  qualify as actionable.
- If the panel's finding is the **same location but a materially different
  specific claim** than what the user responded to (e.g. they addressed a
  fallback-logic quirk at a line, the panel found a distinct reactivation
  side effect a few lines away in the same function), don't silently fold
  it in — note it as a related-but-new angle and say which existing
  ticket/decision it's adjacent to, so the user can decide whether to
  merge or split it.
- If there's no matching entry, triage normally per the rules below.

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

### Step 6: Act on actionable items — queue into this round's batch

Behavior branches on the mode determined in Step 1a. **Neither mode touches
Bitbucket or the remote branch directly in this step** — every mutation for
the round is queued into an in-memory manifest and fired once, via
`apply-batch.sh`, in Step 7b. This is what turns "one Bitbucket write per
finding" into "one approved call per round."

**Owner mode** — for each actionable item:

1. Apply the fix with `Edit`.
2. Detect and run the repo's verify command:
   - `npm test`/`yarn test`/`pnpm test` plus a `lint` script if one exists in
     `package.json`, chosen by lockfile as described in Setup.
   - If no test/lint script is discoverable, use `AskUserQuestion` once per
     run to ask for the right command rather than pushing unverified — don't
     silently skip verification.
3. If verification fails, **do not queue a commit**. Revert the edit,
   downgrade the item to ambiguous with a note ("fix attempted, verification
   failed — needs a human"), and move on.
4. If verification passes: queue one manifest `commits[]` entry — `{message:
"fix: address pr-swarm <lens> <short description>", files: [...]}`. Keep
   each actionable item as its own commit even though they all land in one
   push; that's what lets `undo-batch.sh` revert a single bad fix later
   without touching the others in the round.
5. Queue one manifest `posts[]` entry for the file/line — bot header +
   `[<lens>]` tag + severity + finding body + `"Fixed in this round's push."`
   (the actual short sha isn't known until `apply-batch.sh` commits it, so
   don't reference one). Set `resolve` to the pre-existing thread's root
   comment id if this fixed an existing thread, or `"self"` if it's a fresh
   finding.

**Review-only mode** — for each actionable item: never touch the working
tree, never run the verify command, never queue a commit. Queue one manifest
`posts[]` entry (bot header + `[<lens>]` tag + severity + finding body + a
concrete suggested fix written out in prose or a fenced code snippet — enough
that the PR's author could apply it themselves) with `resolve: null`. Left
unresolved deliberately — an actionable finding from an automated pass is a
request for the author to act, not a settled matter, and resolving your own
review comment would hide it before they've seen it.

### Step 7: Resolve nits — queue into the same batch

- **Fresh NIT findings from the panel:** in both modes, queue a `posts[]`
  entry (bot header + tag + body) with `resolve: "self"`. Always safe —
  resolving your own just-posted comment, not someone else's thread — and
  leaves a record anchored to the diff even though no action was needed.
- **Existing NIT threads (owner mode):** queue a `resolve_only[]` entry
  `{comment_id}`, no reply. Record the one-line reason ("cosmetic — no
  functional risk", "duplicate of <other finding>", "already addressed by
  <sha>") in the report.
- **Existing NIT threads (review-only mode):** queue nothing — it isn't this
  skill's thread to close on someone else's PR. Just record the
  classification and reason in the report; leave the thread as-is.

### Step 7b: Fire this round's batch

Assemble the manifest (`workspace`, `repo_slug`, `pr_id`, `expected_branch:
source_branch`, plus `commits`/`posts`/`resolve_only` from Steps 6–7 —
**not** `sticky_summary` yet, it's composed in Step 9 from this call's
actual results) and write it to a scratch path, e.g.
`round-<N>-manifest.json`. Full manifest schema (mirrors `apply-batch.sh`'s
header comment, kept here so you don't need to open the script for it):

```jsonc
{
  "workspace": "...",
  "repo_slug": "...",
  "pr_id": 123,
  "expected_branch": "feature/xyz",
  "commits": [{ "message": "...", "files": ["a.ts", "b.ts"] }],
  "posts": [{ "path": "a.ts", "line": 42, "body": "...", "resolve": "self" }],
  // "line" omitted/null => top-level comment. "resolve": "self" | <existing comment id> | null
  "resolve_only": [{ "comment_id": 456 }],
  "sticky_summary": { "comment_id": 789, "body": "..." }, // comment_id null/absent => create new
}
```

**Before calling the script**, print the batch's actual content as plain
chat text — every commit message, every comment body, what's about to be
pushed. This is informational, not a confirmation gate: don't wait for a
reply, proceed immediately after. It's what makes an empty round obviously
different from a 6-item round in the transcript, without costing a prompt.

```bash
bash ~/.claude/skills/pr-swarm/scripts/apply-batch.sh round-<N>-manifest.json round-<N>-log.json
```

- **Exit 0:** everything in the manifest succeeded. Keep `round-<N>-log.json`
  around — it's the undo record (`undo-batch.sh round-<N>-log.json`) if the
  user later wants this round reverted.
- **Exit 1:** partial failure — some mutations landed, some didn't. Read
  `round-<N>-log.json`'s `failures[]` array; for each failed item, downgrade
  it to ambiguous in the report with the failure reason. Everything that did
  succeed is still recorded in the same log and still undoable.
- **Exit 2:** a guardrail tripped (current branch / repo / PR state doesn't
  match what Step 1 recorded) — **nothing was done**. Stop and surface the
  script's error verbatim; this means the PR moved out from under the run
  (merged, branch changed) and needs a fresh Step 1, not a retry.

### Step 8: Loop

After Step 7b's batch lands, check whether anything qualifies as newly
actionable or nit:

- If `round-<N>-log.json` recorded any commits, re-gather the diff (Step 2)
  against the new HEAD and re-run the panel (Step 4) only if the new diff
  touches a non-doc file (skip re-review for pure `.md`/comment-only
  follow-ups).
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
Its id, if it already exists, was already visible in Step 3's `bb-paginate.sh`
output (`content.raw` containing `<!-- pr-swarm-summary -->`) — no extra
fetch needed. Compose this round's body below and set it as
`manifest.sticky_summary` (`{comment_id: <id or null>, body: "..."}`) before
firing Step 7b's batch; `apply-batch.sh` handles the PUT-if-found /
POST-otherwise. Body shape:

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

### Already triaged by you — cross-checked, not re-asked

Only include this section when Step 5 matched items against the sticky
summary's parsed reply decisions. Omit it entirely on a PR's first round.

| File:Line | Severity | Reviewer | Panel finding | Status                                                         |
| --------- | -------- | -------- | ------------- | -------------------------------------------------------------- |
| ...       | ...      | ...      | ...           | Declined / Deferred to \<ticket or work item\>, per your reply |

### New angles worth folding into an existing ticket (not blocking)

Only include when a finding is related-but-distinct from something you
already decided on (see Step 5). Otherwise omit.

| File:Line | Severity | Reviewer | Summary | Suggested home               |
| --------- | -------- | -------- | ------- | ---------------------------- |
| ...       | ...      | ...      | ...     | Fold into \<ticket\>, or new |

### ⚠️ Needs your call — ambiguous items

Genuinely new items only — anything matched in the two sections above does
not belong here too.

| File:Line | Severity | Reviewer | Summary |
| --------- | -------- | -------- | ------- |
| ...       | ...      | ...      | ...     |

---

_Automated by PR Swarm — not a human review_
```

Verdict tiers (reuse across rounds): CRITICAL finding present → 🚫 BLOCKED;
2+ HIGH or 1 HIGH+2 MEDIUM → ⚠️ REQUEST CHANGES; 1 HIGH or 3+ MEDIUM → 💬
APPROVE WITH NITS; otherwise → ✅ APPROVE. Base this on what's _left_ that is
genuinely undecided (the "Needs your call" section) — items you already
declined or deferred don't count against the verdict even though they
remain unfixed in the diff, since blocking on a decision you've already
made doesn't serve you.

Compose this body using `round-<N>-log.json`'s **actual** results (commit
shas, which posts/resolves succeeded, any `failures[]`) — not the manifest's
intended actions, since Step 7b tolerates partial failure. Fire it as its
own tiny `apply-batch.sh` call (empty `commits`/`posts`/`resolve_only`, just
`sticky_summary` set) against a fresh `round-<N>-summary-manifest.json` /
`round-<N>-summary-log.json` pair — this runs every round, right after
Step 7b, before Step 8 decides whether to loop again.

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
- **`apply-batch.sh` exits 2 (guardrail):** see Step 7b — stop, don't retry,
  don't fall back to raw `bb_curl`/`git` calls to route around it. The
  guardrail exists specifically to catch the PR having moved out from under
  the run.
- **The user asks to undo a round after the fact** (they didn't like a fix
  or a comment once they saw it land): run
  `undo-batch.sh round-<N>-log.json` for the round in question — it reverts
  the commits, deletes the posted comments, and reopens anything it
  resolved. It's best-effort per item; report anything it couldn't undo
  (e.g. a revert conflict) rather than silently leaving it half-done.
