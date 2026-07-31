#!/usr/bin/env bash
# Verify the Cloudflare account can actually deploy Containers.
#
# This exists because `wrangler deploy` builds the entire image and uploads the
# Worker BEFORE it discovers the account is not entitled, and then reports a bare
# "Unauthorized" that reads like a credentials problem.
set -uo pipefail

CFG="${HOME}/Library/Preferences/.wrangler/config/default.toml"
[ -f "$CFG" ] || CFG="${HOME}/.config/.wrangler/config/default.toml"

if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  TOKEN="$CLOUDFLARE_API_TOKEN"
elif [ -f "$CFG" ]; then
  TOKEN=$(grep -E '^oauth_token' "$CFG" | sed 's/.*= *"\(.*\)"/\1/')
else
  echo "  no credentials found. Run: npx wrangler login" >&2
  exit 1
fi
[ -n "$TOKEN" ] || { echo "  empty token. Run: npx wrangler login" >&2; exit 1; }

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
if [ -z "$ACCOUNT_ID" ]; then
  # Retry: a single transient failure here used to abort the whole deploy before
  # anything was built, which is a bad trade for a check that only exists to
  # produce a nicer error message.
  for attempt in 1 2 3; do
    ACCOUNT_ID=$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" \
      "https://api.cloudflare.com/client/v4/accounts" 2>/dev/null \
      | sed -n 's/.*"id":"\([0-9a-f]\{32\}\)".*/\1/p' | head -1)
    [ -n "$ACCOUNT_ID" ] && break
    sleep $((attempt * 2))
  done
fi
if [ -z "$ACCOUNT_ID" ]; then
  # Warn rather than fail. This script is an early-warning convenience; refusing
  # to deploy because we could not *check* entitlement is worse than letting
  # wrangler try and report for itself.
  echo "  WARNING: could not determine the account (transient API failure?)." >&2
  echo "  Skipping the entitlement check; set CLOUDFLARE_ACCOUNT_ID to silence this." >&2
  exit 0
fi

body=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/containers/me")

if echo "$body" | grep -q '"success":true'; then
  echo "  account ${ACCOUNT_ID} can deploy Containers"
  exit 0
fi

echo "  Containers are unavailable on account ${ACCOUNT_ID}:" >&2
echo "$body" | sed -n 's/.*"message":"\(.*\)".*/  \1/p' | head -3 >&2
echo >&2
echo "  Cloudflare Containers require the Workers Paid plan (\$5/month)." >&2
echo "  https://dash.cloudflare.com/${ACCOUNT_ID}/workers/plans" >&2
exit 1
