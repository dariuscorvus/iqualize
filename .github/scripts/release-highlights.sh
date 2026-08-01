#!/bin/bash
# Curated release highlights, keyed by tag.
#
# A release's hand-written highlights live in
#   .github/release-notes/highlights/<tag>.md
# The first line may be a title directive the workflow uses for the GitHub
# Release title:
#   <!-- title: v0.57.0 — short summary of the release -->
# Everything after that line is the highlights markdown, prepended above the
# install note, thanks, and GitHub's auto-generated "What's Changed" list.
#
# Both the file and the directive are optional. With no file, the release
# falls back to a generic "iQualize <tag>" title and no highlights section,
# exactly as before this script existed.
#
# Usage:
#   release-highlights.sh title <tag>   # prints the release title
#   release-highlights.sh body  <tag>   # prints the highlights body (may be empty)
set -euo pipefail

MODE="${1:?usage: release-highlights.sh <title|body> <tag>}"
TAG="${2:?usage: release-highlights.sh <title|body> <tag>}"
FILE=".github/release-notes/highlights/${TAG}.md"

case "$MODE" in
  title)
    if [ -f "$FILE" ]; then
      title=$(sed -n 's/^<!-- *title: *\(.*[^ ]\) *-->.*/\1/p' "$FILE" | head -n1)
      if [ -n "$title" ]; then
        printf '%s\n' "$title"
        exit 0
      fi
    fi
    printf 'iQualize %s\n' "$TAG"
    ;;
  body)
    # Nothing to print when there's no curated file — the release still gets
    # its install note, thanks, and auto-generated changelog.
    [ -f "$FILE" ] || exit 0
    # Drop the title directive line; keep the rest verbatim. Trailing blank
    # line so the following install heading isn't glued to the last bullet.
    sed '/^<!-- *title:.*-->/d' "$FILE"
    printf '\n'
    ;;
  *)
    echo "unknown mode: $MODE (expected 'title' or 'body')" >&2
    exit 2
    ;;
esac
