#!/usr/bin/env bash
# Print the git facts a new Glassforce.app may record.
# Never invents a commit. Existing binaries are left untouched.
# Usage: scripts/source-provenance.sh [repo-dir]
# Stdout, two lines:
#   GlassforceSourceSHA <40 lowercase hex, or empty>
#   GlassforceSourceDirty true|false|unknown
set -euo pipefail
cd "${1:-.}"

unknown() {
  printf 'GlassforceSourceSHA \n'
  printf 'GlassforceSourceDirty unknown\n'
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  unknown
  exit 0
fi

sha="$(git rev-parse HEAD 2>/dev/null || true)"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  unknown
  exit 0
fi

if ! porcelain="$(git status --porcelain 2>/dev/null)"; then
  # Same commit, but do not claim the tree is clean if status failed.
  printf 'GlassforceSourceSHA %s\n' "$sha"
  printf 'GlassforceSourceDirty unknown\n'
  exit 0
fi

if [[ -n "$porcelain" ]]; then
  dirty=true
else
  dirty=false
fi
printf 'GlassforceSourceSHA %s\n' "$sha"
printf 'GlassforceSourceDirty %s\n' "$dirty"
