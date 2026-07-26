#!/bin/bash
# Build a "Thanks" section for the release notes: the authors of the issues
# closed by the PRs in this release range. GitHub's auto-generated notes
# credit PR authors only — the people who filed the bug reports and feature
# requests deserve the mention (and the notification) too.
#
# Usage: release-thanks.sh <tag-or-ref>       (repo root, needs GH_TOKEN/gh auth)
# Prints the section to stdout; prints nothing when there is nobody to thank.
set -euo pipefail

TAG="$1"
PREV=$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)
RANGE="${PREV:+${PREV}..}${TAG}"
OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER=${OWNER_REPO%%/*}
REPO=${OWNER_REPO##*/}

# PR numbers from merge commits in the range — this repo merges PRs with
# merge commits, so every landed PR shows up here.
prs=$(git log --merges --format=%s "$RANGE" | sed -n 's/^Merge pull request #\([0-9]*\).*/\1/p')
[ -n "$prs" ] || exit 0

entries=""
for pr in $prs; do
    rows=$(gh api graphql \
        -F owner="$OWNER" -F repo="$REPO" -F pr="$pr" \
        -f query='
          query($owner: String!, $repo: String!, $pr: Int!) {
            repository(owner: $owner, name: $repo) {
              pullRequest(number: $pr) {
                closingIssuesReferences(first: 10) {
                  nodes { number title author { login } }
                }
              }
            }
          }' \
        --jq '.data.repository.pullRequest.closingIssuesReferences.nodes[]
              | "\(.author.login)\t\(.number)\t\(.title)"' 2>/dev/null || true)
    [ -n "$rows" ] && entries+="$rows"$'\n'
done

# Skip the repo owner's own reports, dedupe by issue number.
thanks=$(printf '%s' "$entries" | awk -F'\t' -v owner="$OWNER" \
    '$1 != "" && $1 != owner && !seen[$2]++ {
        printf "- @%s for reporting #%s — %s\n", $1, $2, $3
    }')
[ -n "$thanks" ] || exit 0

printf '\n## Thanks\n\n%s\n' "$thanks"
