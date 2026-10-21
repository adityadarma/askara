#!/bin/bash
# Prints release notes (Markdown) built from commit subjects since the previous release tag.
# Usage: scripts/release-notes.sh <new-tag> [previous-tag]
#   previous-tag defaults to the newest v* tag reachable from HEAD that is not <new-tag>.
# Optional env: GITHUB_REPOSITORY (owner/name) adds a "Full Changelog" compare link.
#               NOTES_END (git ref, default HEAD) is where the range ends, for notes of an older release.
#
# Commits follow Conventional Commits: feat -> Features, fix -> Bug fixes, anything else
# (docs, ci, refactor, chore, or a subject without a type) -> Other changes.
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:?Usage: $0 <new-tag> [previous-tag]}"
PREV="${2:-$(git tag --merged HEAD --sort=-v:refname 'v*' | grep -vxF "$NEW" | head -1 || true)}"

END="${NOTES_END:-HEAD}"
RANGE="$END"
[[ -n "$PREV" ]] && RANGE="$PREV..$END"

features=""
fixes=""
others=""
pattern='^([A-Za-z]+)(\(([^)]+)\))?(!)?:[[:space:]]*(.+)$'

while IFS=$'\t' read -r hash subject; do
  [[ -z "$subject" ]] && continue
  type="other"
  scope=""
  desc="$subject"
  if [[ "$subject" =~ $pattern ]]; then
    type="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    scope="${BASH_REMATCH[3]}"
    desc="${BASH_REMATCH[5]}"
  fi
  # Capitalize the first letter (bash 3.2 on macOS has no ${var^}).
  desc="$(printf '%s' "${desc:0:1}" | tr '[:lower:]' '[:upper:]')${desc:1}"
  line="- "
  [[ -n "$scope" ]] && line+="**$scope:** "
  line+="$desc (\`$hash\`)"$'\n'
  case "$type" in
    feat) features+="$line" ;;
    fix) fixes+="$line" ;;
    *) others+="$line" ;;
  esac
done < <(git log --no-merges --pretty=tformat:'%h%x09%s' "$RANGE")

echo "## What's changed"
echo
if [[ -z "$features$fixes$others" ]]; then
  echo "No changes recorded."
  echo
fi
[[ -n "$features" ]] && printf '### Features\n\n%s\n' "$features"
[[ -n "$fixes" ]] && printf '### Bug fixes\n\n%s\n' "$fixes"
[[ -n "$others" ]] && printf '### Other changes\n\n%s\n' "$others"

if [[ -n "$PREV" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  echo "**Full Changelog**: https://github.com/$GITHUB_REPOSITORY/compare/$PREV...$NEW"
fi
