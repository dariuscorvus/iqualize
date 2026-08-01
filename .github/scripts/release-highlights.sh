#!/bin/bash
# Curated release highlights, keyed by tag.
#
# A release's hand-written highlights live in
#   .github/release-notes/highlights/<tag>.md
# The first lines may carry directives the workflow reads:
#   <!-- title: v0.57.0 — short summary of the release -->
#   <!-- song: Artist — Title — https://link -->
# Everything after the directives is the highlights markdown, prepended above
# the install note, thanks, and GitHub's auto-generated "What's Changed" list.
# The song, when present, renders as a one-line sign-off at the very bottom.
#
# Every directive and the file itself are optional. With no file, the release
# falls back to a generic "iQualize <tag>" title, no highlights, and no song,
# exactly as before this script existed.
#
# Usage:
#   release-highlights.sh title <tag>   # prints the release title
#   release-highlights.sh body  <tag>   # prints the highlights body (may be empty)
#   release-highlights.sh song  <tag>   # prints the song footer (may be empty)
set -euo pipefail

MODE="${1:?usage: release-highlights.sh <title|body|song> <tag>}"
TAG="${2:?usage: release-highlights.sh <title|body|song> <tag>}"
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
    # Drop the directive lines; keep the rest verbatim. Trailing blank line so
    # the following install heading isn't glued to the last bullet. Two plain
    # expressions rather than one alternation — BSD sed (macOS) doesn't support
    # \| in a basic regex, so an alternation silently matches nothing there.
    sed -e '/^<!-- *title:.*-->/d' -e '/^<!-- *song:.*-->/d' "$FILE"
    printf '\n'
    ;;
  song)
    # A release song is optional flavor. When set, render it as an italic
    # sign-off; skip silently otherwise.
    [ -f "$FILE" ] || exit 0
    song=$(sed -n 's/^<!-- *song: *\(.*[^ ]\) *-->.*/\1/p' "$FILE" | head -n1)
    [ -n "$song" ] || exit 0
    printf '\n---\n\n*Release song: %s*\n' "$song"
    ;;
  *)
    echo "unknown mode: $MODE (expected 'title', 'body', or 'song')" >&2
    exit 2
    ;;
esac
