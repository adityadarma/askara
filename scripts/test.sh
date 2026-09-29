#!/bin/zsh
# Runs the tests. With only Command Line Tools (no Xcode),
# the Swift Testing framework must be pointed to manually.
set -euo pipefail
cd "${0:A:h}/.."

F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [[ -d "$F/Testing.framework" ]]; then
    swift test -Xswiftc -F -Xswiftc "$F" \
        -Xlinker -F -Xlinker "$F" \
        -Xlinker -rpath -Xlinker "$F" \
        -Xlinker -rpath -Xlinker "$L" "$@"
else
    swift test "$@"
fi
