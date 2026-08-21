#!/usr/bin/env bash
# Follow a Bitbucket list endpoint's .next cursor to exhaustion (SKILL.md
# Step 3 comment fetch, Step 9 sticky-summary lookup).
#
# Usage: bb-paginate.sh <first-url>
#
# Prints one JSON object per line (JSONL) — every item from every page's
# .values array, in order. Pipe to `jq -s .` for a single JSON array, or
# filter/reduce directly with `jq`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_token

url="$1"
while [ -n "$url" ] && [ "$url" != "null" ]; do
  resp=$(bb_call GET "$url")
  printf '%s\n' "$resp" | jq -c '.values[]'
  url=$(printf '%s' "$resp" | jq -r '.next // empty')
done
