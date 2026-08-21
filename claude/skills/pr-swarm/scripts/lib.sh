#!/usr/bin/env bash
# Shared helpers for pr-swarm scripts. Sourced, not executed directly.

BB_API="https://api.bitbucket.org/2.0"

require_token() {
  if [ -z "${BITBUCKET_API_TOKEN:-}" ]; then
    echo "ERROR: BITBUCKET_API_TOKEN is not set. Create a scoped Bitbucket Cloud API token (Pull requests: Read + Write) and export it." >&2
    exit 3
  fi
}

# bb_call METHOD URL [curl-args...]
# Prints response body to stdout. Retries once on transient (>=500 or curl
# failure) errors. Exits nonzero with a message on stderr for 4xx/persistent
# failures so callers can distinguish auth problems from real errors.
bb_call() {
  local method="$1" url="$2"; shift 2
  local attempt body code
  for attempt in 1 2; do
    body=$(curl -sS -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${BITBUCKET_API_TOKEN}" \
      -H "Accept: application/json" \
      "$@" "$url") || body=""
    code=$(printf '%s' "$body" | tail -n1)
    body=$(printf '%s' "$body" | sed '$d')
    if [[ "$code" =~ ^2 ]]; then
      printf '%s' "$body"
      return 0
    fi
    if [[ "$code" == "401" || "$code" == "403" ]]; then
      echo "ERROR: Bitbucket auth failed (HTTP $code) for $method $url. Check BITBUCKET_API_TOKEN scopes." >&2
      return 1
    fi
    if [ "$attempt" -eq 1 ]; then
      sleep 2
      continue
    fi
    echo "ERROR: Bitbucket call failed (HTTP ${code:-none}) for $method $url: $body" >&2
    return 1
  done
}

# resolve_workspace_repo: prints "workspace repo_slug" derived from origin remote.
resolve_workspace_repo() {
  local origin path
  origin=$(git remote get-url origin) || { echo "ERROR: no 'origin' remote in this git repo." >&2; return 1; }
  path=$(printf '%s' "$origin" | sed -E 's#^(https://[^/]+/|git@[^:]+:)##; s#\.git$##')
  printf '%s\n' "$path" | awk -F/ '{print $1, $2}'
}
