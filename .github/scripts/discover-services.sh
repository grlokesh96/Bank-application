#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Service / asset discovery for the DevSecOps CI pipeline.
#
# Emits GitHub Actions outputs so every downstream job builds its matrix from
# what is actually on disk. Nothing is hardcoded: adding a service directory
# (with a go.mod or package.json) and a Dockerfile is all that is required for
# it to be linted, built, scanned and reported automatically.
#
# Deliberately POSIX-ish (find -print + sed, no GNU -printf) so it behaves the
# same on ubuntu-latest and on BusyBox.
# ---------------------------------------------------------------------------

# Each pipeline output is written as its own line, so the appends are separate
# by design rather than grouped.
# shellcheck disable=SC2129

set -euo pipefail

# Directories that never contain first-party services.
EXCLUDE='/(node_modules|dist|vendor|\.git|bin|obj)/'

strip_dot_slash() { sed 's|^\./||'; }

# --- 1. Go services ---------------------------------------------------------
# A Go service is a directory under services/ that owns a go.mod.
GO_SVC=$(find ./services -mindepth 2 -maxdepth 2 -name go.mod -not -path "$EXCLUDE" -print 2>/dev/null \
  | sed 's|/go\.mod$||' | strip_dot_slash | sort -u || true)

# --- 2. Node services -------------------------------------------------------
# A Node service is any directory that owns a package.json. Depth 3 covers both
# a top-level app (./frontend) and one nested next to Go services
# (./services/<name>/web), so new Node apps are picked up wherever they land.
NODE_SVC=$(find . -maxdepth 3 -name package.json -not -path "$EXCLUDE" -print 2>/dev/null \
  | sed 's|/package\.json$||' | strip_dot_slash | sed '/^$/d' | sort -u || true)

# --- 3. Dockerfiles ---------------------------------------------------------
DOCKERFILES=$(find . -maxdepth 3 \
  \( -iname 'Dockerfile' -o -iname '*.Dockerfile' -o -iname 'Dockerfile.*' \) \
  -not -path "$EXCLUDE" -print 2>/dev/null | strip_dot_slash | sort -u || true)

# Number of non-empty lines in a newline-separated list.
count_of() {
  if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c . || true; fi
}
# Echo a list back as lines (empty list -> empty output).
lines_of() {
  if [ -z "$1" ]; then echo ""; else printf '%s\n' "$1"; fi
}
# Number of items in a comma-separated list.
count_items() {
  if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | awk -F, '{print NF}'; fi
}

GO_COUNT=$(count_of "$GO_SVC")
NODE_COUNT=$(count_of "$NODE_SVC")
DF_COUNT=$(count_of "$DOCKERFILES")

# --- 4. Resolve each Dockerfile to the services it builds -------------------
# `build/service.Dockerfile` is parameterised by a SERVICE build-arg, so every
# Go service maps to it. Everything else is matched by directory name.
declare -A DF_SERVICES
for df in $(lines_of "$DOCKERFILES"); do
  dir="${df%/*}"
  [ "$dir" = "$df" ] && dir="."
  svcs=$(
    for svc in $(lines_of "$GO_SVC") $(lines_of "$NODE_SVC"); do
      [ -n "$svc" ] || continue
      if [ "$df" = "build/service.Dockerfile" ] && [ "${svc#services/}" != "$svc" ]; then
        echo "$svc"
      elif [ "$dir" = "$svc" ]; then
        echo "$svc"
      fi
    done | sort -u | paste -sd, -
  )
  DF_SERVICES["$df"]="$svcs"
done

jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# --- 5. Emit matrix outputs -------------------------------------------------
# Collect every output first, then write $GITHUB_OUTPUT once.
# services_matrix  -> shared by build / image-scan / push stages
# node_matrix      -> ESLint stage
# hadolint_matrix  -> one entry per Dockerfile, annotated with its services
OUTPUTS=""
# Append one `key=value` line to the collected pipeline outputs.
emit() {
  local fmt="$1"
  shift
  # shellcheck disable=SC2059  # $fmt is a literal from this script; only values are variable
  OUTPUTS+=$(printf "$fmt" "$@")$'\n'
}
svc_include=""
for s in $(lines_of "$GO_SVC") $(lines_of "$NODE_SVC"); do
  [ -n "$s" ] || continue
  svc_include+="${svc_include:+,}{\"service\":\"$(jstr "$s")\",\"name\":\"$(jstr "${s##*/}")\"}"
done
emit 'services_matrix={"service":{"include":[%s]}}\n' "$svc_include"

node_include=""
for s in $(lines_of "$NODE_SVC"); do
  [ -n "$s" ] || continue
  node_include+="${node_include:+,}{\"service\":\"$(jstr "$s")\",\"name\":\"$(jstr "${s##*/}")\"}"
done
emit 'node_matrix={"node":{"include":[%s]}}\n' "$node_include"

df_include=""
for df in $(lines_of "$DOCKERFILES"); do
  [ -n "$df" ] || continue
  svcs="${DF_SERVICES[$df]:-}"
  n=$(count_items "$svcs")
  label="${df//\//_}"
  df_include+="${df_include:+,}{\"file\":\"$(jstr "$df")\",\"label\":\"$(jstr "$label")\",\"services\":\"$(jstr "$svcs")\",\"count\":$n}"
done
emit 'hadolint_matrix={"dockerfile":{"include":[%s]}}\n' "$df_include"

# CodeQL: only run the languages that actually exist in the repository, and pair
# each with a build mode the extractor supports.
#   * go        -> `none` is NOT supported for Go (it aborts with "Go does not
#                  support the none build mode"), so Go must be compiled: autobuild.
#   * js / ts   -> interpreted, no build required.
#   * actions   -> workflow files, no build required.
cql=""
[ "$GO_COUNT" -gt 0 ] && cql+="${cql:+,}{\"language\":\"go\",\"build_mode\":\"autobuild\",\"name\":\"go\"}"
[ "$NODE_COUNT" -gt 0 ] && cql+="${cql:+,}{\"language\":\"javascript-typescript\",\"build_mode\":\"none\",\"name\":\"javascript-typescript\"}"
if [ -d .github/workflows ] && find .github/workflows -maxdepth 1 \
  \( -name '*.yml' -o -name '*.yaml' \) -print -quit 2>/dev/null | grep -q .; then
  cql+="${cql:+,}{\"language\":\"actions\",\"build_mode\":\"none\",\"name\":\"github-actions\"}"
fi
emit 'codeql_matrix={"codeql":{"include":[%s]}}\n' "$cql"

# --- 6. Human-readable outputs + counts ------------------------------------
emit 'go_services=%s\n'     "$GO_COUNT"  
emit 'node_services=%s\n'   "$NODE_COUNT"
emit 'dockerfiles=%s\n'     "$DF_COUNT"  
emit 'service_count=%s\n'   "$((GO_COUNT + NODE_COUNT))"

human_names=""
for s in $(lines_of "$GO_SVC") $(lines_of "$NODE_SVC"); do
  [ -n "$s" ] || continue
  human_names+="${human_names:+,}\`${s##*/}\`"
done
emit 'services_list=%s\n' "$human_names"

# Single atomic write of every pipeline output.
printf '%s' "$OUTPUTS" >> "$GITHUB_OUTPUT"

# --- 7. Run summary --------------------------------------------------------
{
  echo "### Discovered services"
  echo ""
  echo "| Asset | Type | Consumers |"
  echo "| ----- | ---- | --------- |"
  for s in $(lines_of "$GO_SVC"); do
    [ -n "$s" ] || continue
    echo "| \`$s\` | Go service | \`build/service.Dockerfile\` |"
  done
  for s in $(lines_of "$NODE_SVC"); do
    [ -n "$s" ] || continue
    echo "| \`$s\` | Node service | \`$s/Dockerfile\` |"
  done
  for df in $(lines_of "$DOCKERFILES"); do
    [ -n "$df" ] || continue
    svcs="${DF_SERVICES[$df]:-}"
    n=$(count_items "$svcs")
    if [ -n "$svcs" ]; then
      summary="$n service(s) via \`$df\`"
    else
      summary="standalone (no service)"
    fi
    echo "| \`$df\` | Dockerfile | $summary |"
  done
} >> "$GITHUB_STEP_SUMMARY"

echo "Discovered ${GO_COUNT} Go service(s), ${NODE_COUNT} Node service(s), ${DF_COUNT} Dockerfile(s)."