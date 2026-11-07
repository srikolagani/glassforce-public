#!/usr/bin/env bash
# Packages Glassforce's External Client App so any org can install it and sign in with one shared consumer key.
# Org-agnostic: every org comes from inputs. Default is an UNLOCKED package (no namespace, one Dev Hub).
#
#   DEVHUB=<devhub alias> CONTACT_EMAIL=<you@example.com> scripts/package-eca.sh
#   PROMOTE=1 ...        also promote the version (irreversible; needed to install in DE/production orgs)
#   TARGET_ORG=<alias>   also install the version there and check the authorize endpoint with the shared key
#   PACKAGE_TYPE=Managed NAMESPACE=<prefix> ...   managed 2GP instead (namespace linked to the Dev Hub)
#
# How it works (flxbl-io/external-client-apps-guide, pattern 1):
#   1. The ECA lives in the Dev Hub (a persistent org) with OAuth on; its global OAuth settings (the consumer
#      key) stay there and are never packaged.
#   2. ExternalClientApplication + ExtlClntAppOauthSettings are retrieved back so they carry the platform's
#      oauthLink, and only those two go in the package. Installing orgs resolve the key through oauthLink.
# Without DEVHUB (or with DRY_RUN=1) it only renders the project and runs syntax checks; nothing touches an org.
# Secrets: the consumer key is written only to config/glassforce.local.env (gitignored, chmod 600), never printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVHUB="${DEVHUB:-}"
PACKAGE_TYPE="${PACKAGE_TYPE:-Unlocked}"
NAMESPACE="${NAMESPACE:-}"
ECA_NAME="${ECA_NAME:-Glassforce_App}"
ECA_LABEL="${ECA_LABEL:-Glassforce}"
PACKAGE_NAME="${PACKAGE_NAME:-Glassforce}"
CONTACT_EMAIL="${CONTACT_EMAIL:-}"
API_VERSION="${API_VERSION:-64.0}"
PROMOTE="${PROMOTE:-}"
TARGET_ORG="${TARGET_ORG:-}"
WORK="${WORK:-$ROOT/build/eca-package}"
OUT="${OUT:-$ROOT/config/glassforce.local.env}"
DRY_RUN="${DRY_RUN:-}"
[[ -z "$DEVHUB" ]] && DRY_RUN=1

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Print a CLI JSON result without anything secret-looking.
brief() { jq -c '{status, name, message, result: (.result | if type=="object" then {Status, Id, SubscriberPackageVersionId, Package2Id, Error} else null end)}' 2>/dev/null || true; }

case "$PACKAGE_TYPE" in
  Unlocked) [[ -z "$NAMESPACE" ]] || die "unlocked packages here are built without a namespace; unset NAMESPACE" ;;
  Managed)  [[ -n "$DRY_RUN" || -n "$NAMESPACE" ]] || die "Managed needs NAMESPACE (linked to $DEVHUB via Namespace Registries)" ;;
  *) die "PACKAGE_TYPE must be Unlocked or Managed" ;;
esac
[[ "$ECA_NAME" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || die "ECA_NAME must be an API name (letters, digits, _)"
[[ -n "$DRY_RUN" || -n "$CONTACT_EMAIL" ]] || die "set CONTACT_EMAIL (shown to admins on the app)"

render() { # $1 = destination dir; renders every template into it
  mkdir -p "$1"; cp -R "$ROOT/scripts/eca-template/." "$1/"
  while IFS= read -r -d '' f; do
    local g="${f//__ECA__/$ECA_NAME}"
    sed -e "s#__ECA__#$ECA_NAME#g" -e "s#__LABEL__#$ECA_LABEL#g" -e "s#__CONTACT_EMAIL__#${CONTACT_EMAIL:-admin@example.com}#g" "$f" > "$g.tmp"
    rm "$f"; mv "$g.tmp" "$g"
  done < <(find "$1" -name '*.xml' -print0)
}
project_json() { # $1 dir, $2 path, $3 package name or empty
  local pkg=""; [[ -n "$3" ]] && pkg=", \"package\": \"$3\", \"versionName\": \"ver 1.0\", \"versionNumber\": \"1.0.0.NEXT\""
  cat > "$1/sfdx-project.json" <<JSON
{ "packageDirectories": [{ "path": "$2", "default": true$pkg }],
  "namespace": "$NAMESPACE", "sourceApiVersion": "$API_VERSION" }
JSON
}

say "1. Render ($PACKAGE_TYPE, namespace ${NAMESPACE:-none}, ECA $ECA_NAME) in $WORK"
rm -rf "$WORK"; mkdir -p "$WORK/hub" "$WORK/pkg/force-app/main/default"
render "$WORK/hub/force-app/main/default"; project_json "$WORK/hub" force-app ""
project_json "$WORK/pkg" force-app "$PACKAGE_NAME"

say "2. Syntax checks"
bash -n "$0"
command -v xmllint >/dev/null && find "$WORK/hub" -name '*.xml' -exec xmllint --noout {} +
command -v jq >/dev/null && jq -e . "$WORK/hub/sfdx-project.json" "$WORK/pkg/sfdx-project.json" >/dev/null
grep -q "<distributionState>Packaged</distributionState>" "$WORK/hub/force-app/main/default/externalClientApps/$ECA_NAME.eca-meta.xml" || die "ECA template is not Packaged"
if [[ -n "$DRY_RUN" ]]; then
  say "Dry run OK. Files:"; (cd "$WORK" && find . -type f | sort)
  echo "To run for real: DEVHUB=<alias> CONTACT_EMAIL=<email> [PROMOTE=1] [TARGET_ORG=<alias>] scripts/package-eca.sh"
  exit 0
fi

command -v sf >/dev/null || die "install the Salesforce CLI"
command -v jq >/dev/null || die "install jq"
sf org display --target-org "$DEVHUB" --json >/dev/null 2>&1 || die "not logged in: sf org login web --alias $DEVHUB --set-default-dev-hub"

has() { sf org list metadata -m "$1" -o "$DEVHUB" --json | jq -e ".result[]? | select(.fullName==\"$2\")" >/dev/null; }
deploy() { # deploy the given hub source paths
  (cd "$WORK/hub" && sf project deploy start -o "$DEVHUB" --ignore-conflicts --wait 20 --json $(printf -- '--source-dir %s ' "$@")) \
    | jq -c '{status, files: [.result.files[]? | {fullName, type, state, error}], failures: [.result.details.componentFailures? // [] | if type=="array" then .[] else . end | {fullName, problem}]}'
}
D=force-app/main/default
say "3. ECA $ECA_NAME in $DEVHUB with OAuth on (skipped if it exists)"
if ! has ExternalClientApplication "$ECA_NAME"; then
  deploy "$D/externalClientApps" "$D/extlClntAppOauthSettings" "$D/extlClntAppGlobalOauthSets"
fi
has ExtlClntAppGlobalOauthSettings "${ECA_NAME}_glbloauth" || die "OAuth consumer ${ECA_NAME}_glbloauth missing in $DEVHUB"
if ! has ExtlClntAppOauthConfigurablePolicies "${ECA_NAME}_oauthPlcy"; then
  deploy "$D/extlClntAppOauthPolicies" || true
fi

say "4. Retrieve header + OAuth settings (carries oauthLink) into the package source"
(cd "$WORK/pkg" && sf project retrieve start -m "ExternalClientApplication:$ECA_NAME" -m "ExtlClntAppOauthSettings:${ECA_NAME}_oauth" -o "$DEVHUB" --json | jq -c '{status, files: [.result.files[]? | {fullName, state}]}')
P="$WORK/pkg/$D"
grep -q "<distributionState>Packaged</distributionState>" "$P/externalClientApps/$ECA_NAME.eca-meta.xml" || die "$ECA_NAME is not Packaged in $DEVHUB"
grep -q "<oauthLink>" "$P/extlClntAppOauthSettings/${ECA_NAME}_oauth.ecaOauth-meta.xml" || die "no oauthLink on ${ECA_NAME}_oauth; installing orgs could not find the consumer"
echo "    package source: $(cd "$WORK/pkg" && find force-app -type f | tr '\n' ' ')"

say "5. $PACKAGE_TYPE package $PACKAGE_NAME (created if missing)"
cd "$WORK/pkg"
PKG_0HO=$(sf package list --target-dev-hub "$DEVHUB" --json | jq -r ".result[]? | select(.Name==\"$PACKAGE_NAME\") | .Id" | head -1)
if [[ -z "$PKG_0HO" ]]; then
  NS_FLAG=(); [[ "$PACKAGE_TYPE" == Unlocked ]] && NS_FLAG=(--no-namespace)
  CJSON=$(sf package create --name "$PACKAGE_NAME" --package-type "$PACKAGE_TYPE" --path force-app "${NS_FLAG[@]}" --target-dev-hub "$DEVHUB" --json || true)
  PKG_0HO=$(jq -r '.result.Id // empty' <<<"$CJSON")
fi
[[ "$PKG_0HO" == 0Ho* ]] || die "no 0Ho package id"
# sf package create rewrites sfdx-project.json (default:false, 0.1.0); put ours back with the alias.
project_json . force-app "$PACKAGE_NAME"
jq --arg n "$PACKAGE_NAME" --arg id "$PKG_0HO" '.packageAliases = {($n): $id}' sfdx-project.json > p.tmp && mv p.tmp sfdx-project.json
echo "    package $PKG_0HO"

say "6. Package version (several minutes)"
VJSON=$(sf package version create --package "$PACKAGE_NAME" --installation-key-bypass --code-coverage --wait 60 --target-dev-hub "$DEVHUB" --json || true)
PKG_04T=$(jq -r '.result.SubscriberPackageVersionId // empty' <<<"$VJSON")
[[ "$PKG_04T" == 04t* ]] || { brief <<<"$VJSON"; die "no 04t id"; }
echo "    version $PKG_04T"

if [[ -n "$PROMOTE" ]]; then
  say "7. Promote $PKG_04T (released; installs in any org)"
  sf package version promote --package "$PKG_04T" --target-dev-hub "$DEVHUB" --no-prompt --json | brief
else
  say "7. Not promoted (beta installs only in scratch orgs and sandboxes). PROMOTE=1 to release."
fi

say "8. Read the consumer key from $DEVHUB (kept in memory, not printed)"
KEYDIR="$(mktemp -d)"; trap 'rm -rf "$KEYDIR"' EXIT
(cd "$KEYDIR" && echo '{"packageDirectories":[{"path":"f","default":true}],"sourceApiVersion":"'"$API_VERSION"'"}' > sfdx-project.json && mkdir f \
  && sf project retrieve start -m "ExtlClntAppGlobalOauthSettings:${ECA_NAME}_glbloauth" -o "$DEVHUB" --json >/dev/null)
CONSUMER_KEY=$(find "$KEYDIR" -name '*.ecaGlblOauth-meta.xml' -exec sed -n 's:.*<consumerKey>\(.*\)</consumerKey>.*:\1:p' {} + | head -1)
[[ -n "$CONSUMER_KEY" ]] || die "could not read the consumer key (Setup > External Client App Manager > $ECA_NAME > Settings > OAuth Settings > Consumer Key and Secret)"

say "9. Write $OUT (gitignored)"
mkdir -p "$(dirname "$OUT")"; umask 077
cat > "$OUT" <<ENV
# Written by scripts/package-eca.sh. Gitignored. Read by scripts/build-app.sh.
GLASSFORCE_PACKAGED_CONSUMER_KEY=$CONSUMER_KEY
GLASSFORCE_PACKAGE_VERSION_ID=$PKG_04T
GLASSFORCE_PACKAGE_ID=$PKG_0HO
ENV
chmod 600 "$OUT"; echo "    key: set, version: $PKG_04T"

if [[ -n "$TARGET_ORG" ]]; then
  say "10. Install into $TARGET_ORG and check the authorize endpoint there"
  sf package install --package "$PKG_04T" --target-org "$TARGET_ORG" --wait 20 --no-prompt --json | brief
  CONSUMER_KEY="$CONSUMER_KEY" "$ROOT/scripts/check-authorize.sh" "$TARGET_ORG"
fi

cat <<DONE

==> Done. Install link (any org; swap the host for test.salesforce.com or a My Domain):
    https://login.salesforce.com/packaging/installPackage.apexp?p0=$PKG_04T
    Rebuild the app: scripts/build-app.sh
DONE
