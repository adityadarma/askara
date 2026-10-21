#!/bin/bash
# Prints the HTML shown in Sparkle's update window: release notes of the new version and of the
# earlier releases, newest first. Each version is a <section data-sparkle-version="BUILD">.
# Sparkle adds the class `sparkle-installed-version` to the section of the installed build, and the
# CSS below hides that section and every older one. A user several versions behind therefore sees
# every change since the version they run, and nothing they already have.
#
# Usage: scripts/appcast-description.sh <version> <build>
# Env: GH_TOKEN and GITHUB_REPOSITORY let it read the build number of earlier releases from their
#      appcast.xml. Releases without one (made before in-app updates) are skipped.
#      HISTORY (default 10) is how many earlier releases to include.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: $0 <version> <build>}"
BUILD="${2:?Usage: $0 <version> <build>}"
HISTORY="${HISTORY:-10}"
NEW="v$VERSION"

# Markdown from release-notes.sh -> HTML. Commit subjects are untrusted, so everything is escaped.
to_html() {
  python3 -c '
import html, re, sys
out, in_list = [], False
for line in sys.stdin.read().splitlines():
    line = line.rstrip()
    if line.startswith("## ") or not line:
        continue
    text = html.escape(line, quote=True)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    if line.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>" + text[2:] + "</li>")
        continue
    if in_list: out.append("</ul>"); in_list = False
    if line.startswith("### "):
        out.append("<h4>" + text[4:] + "</h4>")
    else:
        out.append("<p>" + text + "</p>")
if in_list: out.append("</ul>")
print("\n".join(out))
'
}

section() { # <tag> <title-version> <build> <previous-tag>
  local tag="$1" version="$2" build="$3" prev="$4"
  echo "<section data-sparkle-version=\"$build\">"
  echo "<h3>Askara $version</h3>"
  NOTES_END="$([[ "$tag" == "$NEW" ]] && echo HEAD || echo "$tag")" \
    ./scripts/release-notes.sh "$tag" ${prev:+"$prev"} | to_html
  echo "</section>"
}

# Newest first: the version being released, then earlier tags (one extra, as the base of the last range).
tags=()
while IFS= read -r tag; do tags+=("$tag"); done < <(
  git tag --merged HEAD --sort=-v:refname 'v*' | grep -vxF "$NEW" | head -n "$((HISTORY + 1))" || true)

cat <<'CSS'
<style>
section { margin-bottom: 1.2em; }
h3 { margin: 0 0 .3em; }
h4 { margin: .8em 0 .2em; }
ul { margin: 0; padding-left: 1.4em; }
.sparkle-installed-version, .sparkle-installed-version ~ section { display: none; }
</style>
CSS

section "$NEW" "$VERSION" "$BUILD" "${tags[0]:-}"
for ((i = 0; i < ${#tags[@]} && i < HISTORY; i++)); do
  tag="${tags[$i]}"
  # The build number comes from that release's own appcast; without one it can't be matched.
  build="$(gh release download "$tag" -p appcast.xml -O - 2>/dev/null \
    | sed -n 's|.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*|\1|p' | head -1 || true)"
  [[ -n "$build" ]] || continue
  section "$tag" "${tag#v}" "$build" "${tags[$((i + 1))]:-}"
done
