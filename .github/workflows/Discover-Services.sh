#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

# Every directory containing a Dockerfile is a service
services=$(find "$ROOT" -name Dockerfile \
  -not -path '*/.git/*' -not -path '*/vendor/*' \
  -exec dirname {} \; | sed 's|^\./||' | sort -u)

if [ -z "$services" ]; then
  echo "No Dockerfiles found under $ROOT" >&2
  exit 1
fi

# Emit a compact JSON array, e.g. ["services/auth","services/ledger"]
matrix=$(printf '%s\n' "$services" | jq -R -s -c 'split("\n") | map(select(length > 0))')

echo "Discovered: $matrix"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "matrix=$matrix" >> "$GITHUB_OUTPUT"
fi
