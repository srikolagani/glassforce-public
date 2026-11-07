#!/usr/bin/env bash
# Checks whether CONSUMER_KEY is accepted by an org's OAuth authorize endpoint, signed in as the CLI's user there,
# without clicking anything: the result is either the "Allow access?" consent page (key accepted for that org)
# or a redirect to the callback with an OAuth error (e.g. cross-org flows not supported).
#   CONSUMER_KEY=... scripts/check-authorize.sh <org alias>
# Reads nothing and writes nothing in the org. Never prints the key or the session.
set -euo pipefail
ORG="${1:?org alias}"; : "${CONSUMER_KEY:?set CONSUMER_KEY}"
CB="dev.glassforce.app://oauth/callback"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
INSTANCE=$(sf org display -o "$ORG" --json | jq -r '.result.instanceUrl')
FRONTDOOR=$(sf org open -o "$ORG" --url-only --json 2>/dev/null | jq -r '.result.url')
curl -s -L -c "$JAR" -b "$JAR" -o /dev/null "$FRONTDOOR"          # establishes the browser session cookie
CHALLENGE=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM               # RFC 7636 example; nothing is exchanged
URL="$INSTANCE/services/oauth2/authorize?response_type=code&client_id=$CONSUMER_KEY&redirect_uri=$(jq -rn --arg u "$CB" '$u|@uri')&code_challenge=$CHALLENGE&code_challenge_method=S256&prompt=consent"
for hop in 1 2 3 4 5 6; do
  read -r CODE LOC < <(curl -s -b "$JAR" -c "$JAR" -o "$JAR.body" -w '%{http_code} %{redirect_url}\n' "$URL")
  if [[ "$LOC" == dev.glassforce.app://* ]]; then
    if [[ "$LOC" == *error=* ]]; then
      echo "FAIL: authorize redirected to the callback with an error: $(sed -E 's/.*[?&](error=[^&]*)(&error_description=([^&]*))?.*/\1 \3/' <<<"$LOC" | sed 's/+/ /g; s/%20/ /g')"; rm -f "$JAR.body"; exit 1
    fi
    echo "PASS (already approved): authorize returned a code to the callback"; rm -f "$JAR.body"; exit 0
  fi
  if [[ "$CODE" == 30* && -n "$LOC" ]]; then
    echo "    hop $hop: $CODE -> $(sed -E 's#^(https://[^/?]+[^?]*).*#\1#' <<<"$LOC")"; URL="$LOC"; continue
  fi
  break
done
BODY="$JAR.body"; TITLE=$(sed -n 's:.*<title>\([^<]*\)</title>.*:\1:p' "$BODY" | head -1)
ERR=$(grep -o -i -E 'cross-org[^<"]*|OAUTH_[A-Z_]+|error=[a-z_]+|invalid[_ ]client[^<"]*' "$BODY" | head -3 | tr '\n' ';' || true)
echo "    final: http $CODE, title: ${TITLE:-none}"
if [[ -n "$ERR" ]]; then echo "FAIL: $ERR"; rm -f "$BODY"; exit 1; fi
if grep -q 'ChangePassword?retURL=%2F_ui%2Fidentity%2Foauth%2Fui%2FAuthorizationPage' "$BODY"; then
  echo "PASS (key accepted, no cross-org error): Salesforce is sending this user to the consent page, but first to Change Password (the org's password policy). A person has to change the password, then click Allow."; rm -f "$BODY"; exit 0
fi
if grep -q -i -E 'oaapprove|Allow Access|RemoteAccessAuthorization' "$BODY"; then
  echo "PASS: consent page shown for $ORG (key accepted; a person still has to click Allow)"; rm -f "$BODY"; exit 0
fi
echo "UNKNOWN: page text: $(sed -e 's/<[^>]*>//g' "$BODY" | tr -s ' \n' ' ' | sed -E 's/[A-Za-z0-9._]{40,}/…/g' | cut -c1-400)"; rm -f "$BODY"; exit 2
