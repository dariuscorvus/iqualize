#!/usr/bin/env bash
# Count unique compiler warnings in a build log and compare against the
# committed baseline. The build log is passed as $1.
#
# Warnings are counted by their unique "file:line:col: warning: message" line —
# the same warning emitted once per compilation unit counts once. The baseline
# lives in .github/warning-baseline.txt and only ever goes down.
set -euo pipefail

log=${1:?usage: check-warnings.sh <build.log>}
baseline_file="$(dirname "$0")/../warning-baseline.txt"
baseline=$(tr -d '[:space:]' < "$baseline_file")

# Strip the repo prefix so the list is stable across checkout paths.
warnings=$(grep -E '^/.*: warning: ' "$log" | sed "s|$PWD/||" | sort -u || true)
count=$(printf '%s' "$warnings" | grep -c . || true)

echo "Unique warnings: $count (baseline $baseline)"
echo
printf '%s\n' "$warnings"

if [ "$count" -gt "$baseline" ]; then
  echo
  echo "::error::Warning count rose from $baseline to $count. Fix the new warnings, or raise the baseline deliberately with a reason." >&2
  exit 1
fi

if [ "$count" -lt "$baseline" ]; then
  echo
  echo "::notice::Warning count fell from $baseline to $count — lower .github/warning-baseline.txt to lock it in."
fi
