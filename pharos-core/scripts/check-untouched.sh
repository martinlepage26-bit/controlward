#!/usr/bin/env bash
# Fails if the diff against the base touches any Kairos or EMERAULD path (acceptance criterion 6).
# usage: check-untouched.sh [base-ref]   (default origin/main)
set -euo pipefail
base="${1:-origin/main}"
changed="$(git diff --name-only "${base}...HEAD")"
total="$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')"
hits="$(printf '%s\n' "$changed" | grep -Ei 'kairos|emerauld' || true)"
n="$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "check-untouched: base=${base} files_changed=${total} kairos_or_emerauld=${n}"
if [ "$n" != "0" ]; then
  printf '%s\n' "$hits" | sed 's/^/  TOUCHED /'
  exit 1
fi
