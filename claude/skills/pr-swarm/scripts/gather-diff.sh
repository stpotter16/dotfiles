#!/usr/bin/env bash
# Gather the local diff for pr-swarm (SKILL.md Step 2).
#
# Usage: gather-diff.sh <destination-branch> <source-branch>
#
# Fetches both branches and prints delimited sections to stdout:
#   ===BASE===       merge-base sha
#   ===CHANGED_FILES===
#   ===DIFF===
#   ===LOG===
set -euo pipefail
dest="$1"
source_branch="$2"

git fetch origin "$dest" "$source_branch" --quiet
base=$(git merge-base "origin/$dest" "origin/$source_branch")

echo "===BASE==="
echo "$base"

echo "===CHANGED_FILES==="
git diff "$base...origin/$source_branch" --name-only

echo "===DIFF==="
git diff "$base...origin/$source_branch"

echo "===LOG==="
git log "$base..origin/$source_branch" --oneline
