#!/bin/bash
# Capture the raw response of Claude Code's OAuth usage endpoint.
#
# This endpoint is undocumented, so ClaudeProvider decodes a schema that was
# pinned down by measurement rather than by a spec (docs/feasibility.md §2).
# Run this to re-check the live response whenever a Claude Code update is
# suspected of having changed it.
#
# The User-Agent header is not optional: without it the request lands in an
# aggressively rate-limited bucket and returns persistent 429s.
# https://github.com/anthropics/claude-code/issues/31637

set -euo pipefail

raw=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null) || {
  echo "could not read the 'Claude Code-credentials' keychain item." >&2
  echo "macOS will prompt for permission the first time; approve it and re-run." >&2
  exit 1
}

echo "--- keychain payload shape (values redacted) ---"
printf '%s' "$raw" | jq '
  def redact: if type == "string" and length > 20 then "<\(length) chars>" else . end;
  walk(redact)
' 2>/dev/null || echo "(not JSON — inspect manually)"

token=$(printf '%s' "$raw" | jq -r '
  .claudeAiOauth.accessToken // .accessToken // .access_token // empty
' 2>/dev/null)

if [[ -z "$token" ]]; then
  echo >&2
  echo "no access token found at a known path. Adjust the jq filter using the" >&2
  echo "shape printed above, then re-run." >&2
  exit 1
fi

version=$(claude --version 2>/dev/null | awk '{print $1}')

echo
echo "--- GET /api/oauth/usage (User-Agent: claude-code/$version) ---"
curl -sS -w '\nHTTP %{http_code}\n' https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $token" \
  -H "User-Agent: claude-code/$version" | jq . 2>/dev/null || true
