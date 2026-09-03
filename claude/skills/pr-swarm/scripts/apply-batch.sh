#!/usr/bin/env bash
# Apply one pr-swarm round's write operations in a single call (SKILL.md
# Steps 6/7/9) — commits+push, inline comment posts, thread resolves, and
# the sticky summary upsert. Every mutation is appended to a round log as
# it happens, so a partial failure still leaves an accurate, undoable
# record (see undo-batch.sh).
#
# Usage: apply-batch.sh <manifest.json> <round-log-out.json>
#
# Manifest schema (kept in sync with SKILL.md Step 7b — update both):
# {
#   "workspace": "...", "repo_slug": "...", "pr_id": 123,
#   "expected_branch": "feature/xyz",
#   "commits":  [ {"message": "...", "files": ["a.ts", "b.ts"]} ],
#   "posts":    [ {"path": "a.ts", "line": 42, "body": "...", "resolve": "self"} ],
#     // "line" omitted/null => top-level comment. "resolve": "self" | <existing comment id> | null
#   "resolve_only": [ {"comment_id": 456} ],
#   "sticky_summary": {"comment_id": 789, "body": "..."}   // comment_id null/absent => create new
# }
#
# Exits 0 if every mutation succeeded, 1 if any failed (log still has
# everything that DID succeed), 2 on a guardrail failure (nothing done).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_token

manifest_path="$1"
log_path="$2"
manifest=$(cat "$manifest_path")

workspace=$(jq -r '.workspace' <<<"$manifest")
repo_slug=$(jq -r '.repo_slug' <<<"$manifest")
pr_id=$(jq -r '.pr_id' <<<"$manifest")
expected_branch=$(jq -r '.expected_branch' <<<"$manifest")
comments_url="$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id/comments"

# --- Guardrails: refuse to act if reality has drifted from the manifest ---
cd "$(git rev-parse --show-toplevel)" || exit 2

current_branch=$(git branch --show-current)
if [ "$current_branch" != "$expected_branch" ]; then
  echo "ERROR: current branch '$current_branch' != manifest's expected_branch '$expected_branch'. Refusing to act." >&2
  exit 2
fi

read -r actual_ws actual_repo < <(resolve_workspace_repo)
if [ "$actual_ws/$actual_repo" != "$workspace/$repo_slug" ]; then
  echo "ERROR: origin remote resolves to '$actual_ws/$actual_repo', manifest says '$workspace/$repo_slug'. Refusing to act." >&2
  exit 2
fi

pr_json=$(bb_call GET "$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id") || { echo "ERROR: could not re-fetch PR $pr_id to verify state." >&2; exit 2; }
pr_state=$(jq -r '.state' <<<"$pr_json")
pr_branch=$(jq -r '.source.branch.name' <<<"$pr_json")
if [ "$pr_state" != "OPEN" ] || [ "$pr_branch" != "$expected_branch" ]; then
  echo "ERROR: PR $pr_id is state=$pr_state source-branch=$pr_branch, expected OPEN/$expected_branch. Refusing to act." >&2
  exit 2
fi

# --- Init log ---
jq -n --arg ws "$workspace" --arg repo "$repo_slug" --argjson pr "$pr_id" --arg br "$expected_branch" \
  '{workspace:$ws, repo_slug:$repo, pr_id:$pr, branch:$br, commits:[], posts:[], resolved:[], sticky_summary_id:null, failures:[]}' \
  > "$log_path"

log_append() { # log_append <jq-filter-updating-$1-into-the-log> <jq-args...>
  local filter="$1"; shift
  jq "$@" "$filter" "$log_path" > "$log_path.tmp" && mv "$log_path.tmp" "$log_path"
}

failures=0

# --- Commits ---
n_commits=$(jq '.commits | length' <<<"$manifest")
for i in $(seq 0 $((n_commits - 1))); do
  msg=$(jq -r ".commits[$i].message" <<<"$manifest")
  mapfile -t files < <(jq -r ".commits[$i].files[]" <<<"$manifest")
  if ! git add -- "${files[@]}" || ! git commit -q -m "$msg"; then
    echo "ERROR: commit '$msg' failed (files: ${files[*]}). Aborting remaining commits/push." >&2
    log_append '.failures += [{stage:"commit", message:$m}]' --arg m "$msg"
    failures=$((failures + 1))
    break
  fi
  sha=$(git rev-parse HEAD)
  log_append '.commits += [{sha:$s, message:$m, files:$f}]' --arg s "$sha" --arg m "$msg" --argjson f "$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)"
done

n_logged_commits=$(jq '.commits | length' "$log_path")
if [ "$n_logged_commits" -gt 0 ]; then
  if ! git push origin "HEAD:refs/heads/$expected_branch"; then
    echo "ERROR: push to $expected_branch failed. Commits are local-only; posts/resolves skipped." >&2
    log_append '.failures += [{stage:"push", branch:$b}]' --arg b "$expected_branch"
    cat "$log_path"
    exit 1
  fi
fi

# --- Posts ---
n_posts=$(jq '.posts | length' <<<"$manifest")
for i in $(seq 0 $((n_posts - 1))); do
  path=$(jq -r ".posts[$i].path" <<<"$manifest")
  line=$(jq -r ".posts[$i].line // empty" <<<"$manifest")
  body=$(jq -r ".posts[$i].body" <<<"$manifest")
  resolve=$(jq -r ".posts[$i].resolve // empty" <<<"$manifest")

  if [ -n "$line" ]; then
    payload=$(jq -n --arg b "$body" --arg p "$path" --argjson l "$line" '{content:{raw:$b}, inline:{path:$p, to:$l}}')
  else
    payload=$(jq -n --arg b "$body" '{content:{raw:$b}}')
  fi

  resp=$(bb_call POST "$comments_url" -H "Content-Type: application/json" -d "$payload")
  if [ -z "$resp" ]; then
    echo "ERROR: posting comment on $path failed." >&2
    log_append '.failures += [{stage:"post", path:$p}]' --arg p "$path"
    failures=$((failures + 1))
    continue
  fi
  new_id=$(jq -r '.id' <<<"$resp")
  log_append '.posts += [{id:$i, path:$p, line:$l}]' --argjson i "$new_id" --arg p "$path" --arg l "${line:-null}"

  resolve_id=""
  if [ "$resolve" = "self" ]; then
    resolve_id="$new_id"
  elif [[ "$resolve" =~ ^[0-9]+$ ]]; then
    resolve_id="$resolve"
  fi
  if [ -n "$resolve_id" ]; then
    if bb_call POST "$comments_url/$resolve_id/resolve" >/dev/null; then
      log_append '.resolved += [$i]' --argjson i "$resolve_id"
    else
      echo "ERROR: resolving comment $resolve_id failed." >&2
      log_append '.failures += [{stage:"resolve", comment_id:$i}]' --argjson i "$resolve_id"
      failures=$((failures + 1))
    fi
  fi
done

# --- resolve_only ---
n_resolve=$(jq '.resolve_only | length' <<<"$manifest")
for i in $(seq 0 $((n_resolve - 1))); do
  cid=$(jq -r ".resolve_only[$i].comment_id" <<<"$manifest")
  if bb_call POST "$comments_url/$cid/resolve" >/dev/null; then
    log_append '.resolved += [$i]' --argjson i "$cid"
  else
    echo "ERROR: resolving existing thread $cid failed." >&2
    log_append '.failures += [{stage:"resolve_only", comment_id:$i}]' --argjson i "$cid"
    failures=$((failures + 1))
  fi
done

# --- Sticky summary ---
has_summary=$(jq 'has("sticky_summary")' <<<"$manifest")
if [ "$has_summary" = "true" ]; then
  summary_body=$(jq -r '.sticky_summary.body' <<<"$manifest")
  summary_id=$(jq -r '.sticky_summary.comment_id // empty' <<<"$manifest")
  payload=$(jq -n --arg b "$summary_body" '{content:{raw:$b}}')
  if [ -n "$summary_id" ]; then
    resp=$(bb_call PUT "$comments_url/$summary_id" -H "Content-Type: application/json" -d "$payload")
  else
    resp=$(bb_call POST "$comments_url" -H "Content-Type: application/json" -d "$payload")
  fi
  if [ -n "$resp" ]; then
    log_append '.sticky_summary_id = $i' --argjson i "$(jq -r '.id' <<<"$resp")"
  else
    echo "ERROR: sticky summary upsert failed." >&2
    log_append '.failures += [{stage:"sticky_summary"}]'
    failures=$((failures + 1))
  fi
fi

cat "$log_path"
[ "$failures" -eq 0 ]
