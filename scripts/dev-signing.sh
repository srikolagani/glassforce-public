#!/usr/bin/env bash
# Stable local code-signing identity for Glassforce builds.
#
# Why: an ad-hoc signature's designated requirement is the build's cdhash, so every rebuild looks
# like a new app to the Keychain and macOS asks again for the saved Salesforce sign-in. Signing every
# build with the same certificate keeps the requirement identical, so one "Always Allow" sticks.
#
# What it does (idempotent; safe to run again):
#   - creates a self-signed "Glassforce Local Dev" certificate with the codeSigning extended key usage
#   - keeps it in its own keychain (~/Library/Application Support/Glassforce-DevSigning), not the login
#     keychain, so codesign can use the key without a password dialog (we know that keychain's
#     password, so we can set its key partition list non-interactively), and adds that keychain to
#     your keychain search list so codesign can find it
#
# Usage: scripts/dev-signing.sh            create if missing, print the identity
#        scripts/dev-signing.sh --keychain print the keychain path if the identity exists (for build-app.sh)
#        scripts/dev-signing.sh --unlock   unlock the keychain for a build (no-op if missing)
set -euo pipefail

NAME="Glassforce Local Dev"
DIR="$HOME/Library/Application Support/Glassforce-DevSigning"
KC="$DIR/glassforce-dev.keychain-db"
PASS_FILE="$DIR/keychain-password"
OPENSSL=/usr/bin/openssl   # system LibreSSL: its .p12 files import cleanly with `security`

has_identity() {
  [[ -f "$KC" && -f "$PASS_FILE" ]] || return 1
  security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$NAME\""
}

unlock() {
  security unlock-keychain -p "$(cat "$PASS_FILE")" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock timeout
  # codesign only finds identities in the user's keychain search list; append ours once, keep the rest.
  local current=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
    [[ -n "$line" ]] && current+=("$line")
  done < <(security list-keychains -d user)
  local entry
  for entry in "${current[@]}"; do [[ "$entry" == "$KC" ]] && return 0; done
  security list-keychains -d user -s "${current[@]}" "$KC"
}

case "${1:-}" in
  --keychain) has_identity && echo "$KC"; exit 0 ;;
  --unlock) has_identity && unlock; exit 0 ;;
esac

if has_identity; then
  unlock
else
  mkdir -p "$DIR"; chmod 700 "$DIR"
  if [[ ! -f "$PASS_FILE" ]]; then
    (umask 077; "$OPENSSL" rand -hex 24 > "$PASS_FILE")
  fi
  PASS="$(cat "$PASS_FILE")"
  [[ -f "$KC" ]] || security create-keychain -p "$PASS" "$KC"
  unlock

  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  P12PASS="$("$OPENSSL" rand -hex 16)"
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -passout "pass:$P12PASS" -out "$TMP/id.p12"
  security import "$TMP/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
  # Let Apple tools (codesign) use the key without prompting.
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
  echo "Created signing identity \"$NAME\" in $KC"
fi

security find-identity -p codesigning "$KC" | grep "\"$NAME\"" | head -1
