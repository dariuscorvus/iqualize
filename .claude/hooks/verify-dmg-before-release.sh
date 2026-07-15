#!/bin/bash
# PreToolUse(Bash) guard: block a `gh release create`/`gh release upload` that
# attaches a .dmg unless the image passes verify-dmg.sh (valid signature, not
# "damaged" — issue #115). Any other command is allowed through untouched.
#
# Reads the PreToolUse JSON on stdin; exit 0 allows, exit 2 blocks and shows the
# reason to Claude. Detection and extraction run in python so that a mere
# *mention* of "gh release create" inside another command's text (e.g. a PR body
# describing this very hook) does not trigger it — the release invocation must
# sit at a real shell-command boundary.
input=$(cat)

dmg=$(printf '%s' "$input" | /usr/bin/python3 -c '
import sys, json, re

command = json.load(sys.stdin).get("tool_input", {}).get("command", "")

# Match "gh release create|upload" only at the start of a command or right after
# a shell separator (optionally behind a `cd ... &&`), never mid-string.
trigger = re.compile(
    r"(?:^|[\n;&|(])\s*(?:cd\s+[^\n;&|]*?&&\s*)?gh\s+release\s+(?:create|upload)\b"
)
if not trigger.search(command):
    sys.exit(0)

# Pull the first .dmg argument (a bare-word path, not one buried in a quoted
# heredoc body). Good enough: a real release names the artifact positionally.
m = re.search(r"(?<![\"'\''`])(\S+\.dmg)\b", command)
if m:
    print(m.group(1))
' 2>/dev/null) || exit 0

[ -z "$dmg" ] && exit 0

proj="${CLAUDE_PROJECT_DIR:-$(pwd)}"
case "$dmg" in
    /*) dmg_path="$dmg" ;;
    *)  dmg_path="$proj/$dmg" ;;
esac

if ! output=$(bash "$proj/verify-dmg.sh" "$dmg_path" 2>&1); then
    echo "Blocked: $dmg failed pre-release verification (macOS would report it as \"damaged\")." >&2
    echo "$output" >&2
    echo "Rebuild with 'bash create-dmg.sh' (which now verifies) before releasing." >&2
    exit 2
fi

exit 0
