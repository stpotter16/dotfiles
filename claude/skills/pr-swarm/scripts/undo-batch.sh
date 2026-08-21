#!/usr/bin/env bash
# Undo one apply-batch.sh round: reopen resolved threads, delete posted
# comments, revert commits, push. Best-effort per item — reports what it
# could and couldn't undo rather than stopping at the first failure, since
# a partially-undoable batch is still better than an untouched one.
#
# Usage: undo-batch.sh <round-log.json>
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_token

log_path="$1"
log=$(cat "$log_path")

workspace=$(jq -r '.workspace' <<<"$log")
repo_slug=$(jq -r '.repo_slug' <<<"$log")
pr_id=$(jq -r '.pr_id' <<<"$log")
branch=$(jq -r '.branch' <<<"$log")
comments_url="$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id/comments"

cd "$(git rev-parse --show-toplevel)" || exit 2
current_branch=$(git branch --show-current)
if [ "$current_branch" != "$branch" ]; then
  echo "ERROR: current branch '$current_branch' != round log's branch '$branch'. Check out '$branch' first." >&2
  exit 2
fi

failures=0

echo "== Reopening resolved threads =="
mapfile -t resolved_ids < <(jq -r '.resolved[]' <<<"$log")
for id in "${resolved_ids[@]}"; do
  if bb_call POST "$comments_url/$id/reopen" >/dev/null; then
    echo "  reopened $id"
  else
    echo "  FAILED to reopen $id" >&2
    failures=$((failures + 1))
  fi
done

echo "== Deleting posted comments =="
mapfile -t post_ids < <(jq -r '.posts[].id' <<<"$log")
for id in "${post_ids[@]}"; do
  if bb_call DELETE "$comments_url/$id" >/dev/null; then
    echo "  deleted $id"
  else
    echo "  FAILED to delete $id" >&2
    failures=$((failures + 1))
  fi
done

echo "== Reverting commits =="
mapfile -t shas < <(jq -r '.commits[].sha' <<<"$log")
if [ "${#shas[@]}" -gt 0 ]; then
  # Revert newest-first so each revert applies cleanly against current HEAD.
  for ((i = ${#shas[@]} - 1; i >= 0; i--)); do
    sha="${shas[$i]}"
    if git revert --no-edit "$sha"; then
      echo "  reverted $sha"
    else
      echo "  FAILED to revert $sha — resolve the conflict manually, then push." >&2
      failures=$((failures + 1))
      break
    fi
  done
  if ! git push origin "HEAD:refs/heads/$branch"; then
    echo "  FAILED to push reverts to $branch." >&2
    failures=$((failures + 1))
  fi
fi

echo "== Done: $failures failure(s) =="
[ "$failures" -eq 0 ]
