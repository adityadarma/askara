#!/bin/zsh
# Builds the CEF bundle, proves initialization/request-context creation, then quits cleanly.
set -euo pipefail
cd "${0:A:h}/.."

[[ -f Vendor/cef/.version ]] || { print -u2 "Run scripts/install-cef.sh first."; exit 1; }
scripts/bundle.sh --cef

work="$(mktemp -d "${TMPDIR:-/tmp}/askara-cef-smoke.XXXXXX")"
marker="$work/initialized"
log="$work/stderr.log"
pid=""
cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

ASKARA_CEF_SMOKE_FILE="$marker" "build/Askara.app/Contents/MacOS/Askara" > "$log" 2>&1 &
pid=$!
for _ in {1..100}; do
    [[ -f "$marker" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done

if [[ ! -f "$marker" ]] || [[ "$(<"$marker")" != "initialized" ]]; then
    print -u2 "CEF did not initialize."
    [[ ! -s "$log" ]] || command cat "$log" >&2
    exit 1
fi

for _ in {1..150}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then
    print -u2 "Askara did not shut down cleanly after CEF initialization."
    exit 1
fi
exit_code=0
wait "$pid" || exit_code=$?
pid=""
if (( exit_code != 0 )); then
    print -u2 "Askara exited with status $exit_code after CEF shutdown."
    [[ ! -s "$log" ]] || command cat "$log" >&2
    exit 1
fi
print "CEF initialization, profile request context, message loop, and shutdown passed."
