#!/usr/bin/env bash
# Resolve the PR, workspace, and repo for pr-swarm (SKILL.md Step 1).
#
# Usage: resolve-target.sh [<pr-id-or-url>]
#   No arg: detects the OPEN PR for the current branch.
#   Arg: a bare PR number, or a Bitbucket PR URL.
#
# Prints one JSON object on success:
#   {"workspace":..,"repo_slug":..,"pr_id":..,"state":..,
#    "source_branch":..,"destination_branch":..,"source_commit":..,
#    "author_account_id":..}
# Exits 3 if BITBUCKET_API_TOKEN unset, 2 if no PR found/resolvable, 1 on API error.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_token

read -r workspace repo_slug < <(resolve_workspace_repo)

arg="${1:-}"
pr_id=""
if [ -n "$arg" ]; then
  if [[ "$arg" =~ pull-requests/([0-9]+) ]]; then
    pr_id="${BASH_REMATCH[1]}"
  elif [[ "$arg" =~ ^[0-9]+$ ]]; then
    pr_id="$arg"
  else
    echo "ERROR: could not parse a PR id out of '$arg'." >&2
    exit 2
  fi
  pr_json=$(bb_call GET "$BB_API/repositories/$workspace/$repo_slug/pullrequests/$pr_id")
else
  branch=$(git branch --show-current)
  search=$(bb_call GET "$BB_API/repositories/$workspace/$repo_slug/pullrequests" \
    -G --data-urlencode "q=source.branch.name=\"${branch}\" AND state=\"OPEN\"")
  pr_json=$(printf '%s' "$search" | jq -c '.values[0] // empty')
  if [ -z "$pr_json" ]; then
    echo "ERROR: no OPEN PR found for branch '$branch'. Pass a PR id or URL." >&2
    exit 2
  fi
fi

printf '%s' "$pr_json" | jq -c --arg workspace "$workspace" --arg repo_slug "$repo_slug" '{
  workspace: $workspace,
  repo_slug: $repo_slug,
  pr_id: .id,
  state: .state,
  source_branch: .source.branch.name,
  destination_branch: .destination.branch.name,
  source_commit: .source.commit.hash,
  author_account_id: .author.account_id
}'
