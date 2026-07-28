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
  ACCOUNT_ID=$(curl -sS -H "Authorization: Bearer $TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts" \
    | sed -n 's/.*"id":"\([0-9a-f]\{32\}\)".*/\1/p' | head -1)
fi
[ -n "$ACCOUNT_ID" ] || {
  echo "  could not determine the account. Set CLOUDFLARE_ACCOUNT_ID." >&2; exit 1; }

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
