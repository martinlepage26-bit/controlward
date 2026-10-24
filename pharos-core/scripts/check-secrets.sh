#!/usr/bin/env bash
# Fails if a line ADDED in the diff against the base looks like a secret.
# usage: check-secrets.sh [base-ref]      (default origin/main)
#        check-secrets.sh --self-test     (proves each pattern fires; fixtures are built at runtime)
set -euo pipefail

patterns=(
  'AKIA[0-9A-Z]{16}'                                  # AWS access key id
  'gh[pousr]_[A-Za-z0-9]{36,}'                        # GitHub token
  'github_pat_[A-Za-z0-9_]{40,}'                      # GitHub fine-grained token
  'sk-[A-Za-z0-9_-]{32,}'                             # OpenAI-style secret key
  'xox[abprs]-[A-Za-z0-9-]{10,}'                      # Slack token
  'AIza[0-9A-Za-z_-]{35}'                             # Google API key
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'                # private key block
  '(api[_-]?key|secret|token|password)["'"'"' ]*[:=][ ]*["'"'"'][A-Za-z0-9/+_=-]{24,}["'"'"']'  # assigned literal
)
regex="$(IFS='|'; echo "${patterns[*]}")"

scan() { grep -Ein -e "$regex" || true; }

if [ "${1:-}" = "--self-test" ]; then
  fails=0
  fixtures=(
    "AKIA""ABCDEFGHIJKLMNOP"
    "ghp_""$(printf 'a%.0s' {1..36})"
    "github_pat_""$(printf 'b%.0s' {1..40})"
    "sk-""$(printf 'c%.0s' {1..40})"
    "xoxb-""1234567890-abcdef"
    "AIza""$(printf 'd%.0s' {1..35})"
    "-----BEGIN RSA ""PRIVATE KEY-----"
    "api_key = '""$(printf 'e%.0s' {1..30})""'"
  )
  for f in "${fixtures[@]}"; do
    if [ -z "$(printf '%s\n' "$f" | scan)" ]; then echo "  SELF-TEST MISS: pattern did not fire"; fails=$((fails+1)); fi
  done
  if [ -n "$(printf '%s\n' 'secret_ref = "env:PHAROS_X"' 'payload_hash: "0000"' | scan)" ]; then echo "  SELF-TEST FALSE POSITIVE"; fails=$((fails+1)); fi
  echo "check-secrets self-test: $(( ${#fixtures[@]} + 1 - fails ))/$(( ${#fixtures[@]} + 1 )) passed"
  [ "$fails" = "0" ]
  exit
fi

base="${1:-origin/main}"
added="$(git diff --unified=0 --no-color "${base}...HEAD" -- . ':(exclude)yarn.lock' | grep -E '^\+[^+]' | sed 's/^+//' || true)"
lines="$(printf '%s\n' "$added" | sed '/^$/d' | wc -l | tr -d ' ')"
hits="$(printf '%s\n' "$added" | scan)"
n="$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "check-secrets: base=${base} added_lines=${lines} suspected_secrets=${n}"
if [ "$n" != "0" ]; then
  # print only the line number, never the matched value
  printf '%s\n' "$hits" | cut -d: -f1 | sed 's/^/  SUSPECTED SECRET at added line /'
  exit 1
fi
