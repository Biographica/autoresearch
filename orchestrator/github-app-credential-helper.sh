#!/usr/bin/env bash
# Git credential helper: mint a short-lived GitHub App *installation* token on demand
# and cache it until ~5 min before expiry. Lets a multi-hour brain loop clone/fetch/
# push to bg-ai without ever holding a long-lived PAT — the only stored secret is the
# App private key, and the live git credential is a 1-hour installation token.
#
# Wired in entrypoint.sh via:
#   git config --global credential.https://github.com.helper /app/github-app-credential-helper.sh
# Git calls `<helper> get` and reads `username=`/`password=` from stdout.
#
# Env (from the Deployment + the mounted Secret):
#   GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_PATH
set -euo pipefail

# Only the `get` operation needs credentials; ignore store/erase.
[ "${1:-}" = "get" ] || exit 0

: "${GITHUB_APP_ID:?}" "${GITHUB_APP_INSTALLATION_ID:?}" "${GITHUB_APP_PRIVATE_KEY_PATH:?}"
CACHE="${GITHUB_APP_TOKEN_CACHE:-/tmp/gh-app-token}"
now=$(date +%s)
token=""

# Reuse the cached token if it has >5 min of life left.
if [ -f "$CACHE" ]; then
  exp=$(sed -n '1p' "$CACHE" 2>/dev/null || true)
  cached=$(sed -n '2p' "$CACHE" 2>/dev/null || true)
  if [ -n "${exp:-}" ] && [ "$exp" -gt "$((now + 300))" ] 2>/dev/null; then
    token="$cached"
  fi
fi

if [ -z "$token" ]; then
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  iat=$((now - 60)); jexp=$((now + 540))   # GitHub caps the JWT at 10 min
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$jexp" "$GITHUB_APP_ID" | b64url)
  sig=$(printf '%s' "${header}.${payload}" \
        | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_PATH" -binary | b64url)
  jwt="${header}.${payload}.${sig}"

  resp=$(curl -fsS -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens")
  token=$(printf '%s' "$resp" | jq -r '.token')
  [ -n "$token" ] && [ "$token" != "null" ] || { echo "github-app cred: token mint failed" >&2; exit 1; }

  exp_iso=$(printf '%s' "$resp" | jq -r '.expires_at')
  exp_epoch=$(date -d "$exp_iso" +%s 2>/dev/null || echo $((now + 3600)))
  umask 077; printf '%s\n%s\n' "$exp_epoch" "$token" > "$CACHE"
fi

printf 'username=x-access-token\npassword=%s\n' "$token"
