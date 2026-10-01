#!/bin/zsh
# Builds the CEF bundle, loads a page in a native Blink browser on an isolated profile request
# context, closes the browser, then verifies a clean shutdown.
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
    # Helpers of a failed run may still write into the cache; stop them before deleting it.
    pkill -KILL -f "$work" 2>/dev/null || true
    sleep 0.2
    rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

ASKARA_CEF_SMOKE_FILE="$marker" "build/Askara.app/Contents/MacOS/Askara" > "$log" 2>&1 &
pid=$!
# The marker records each phase (context, attaching, state ..., navigated). Wait for the final
# phase rather than the first write, or for the app to exit, up to 30 seconds.
for _ in {1..300}; do
    [[ -f "$marker" && "$(<"$marker")" == "navigated" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done

if [[ ! -f "$marker" ]] || [[ "$(<"$marker")" != "navigated" ]]; then
    print -u2 "CEF did not initialize and navigate a Blink browser."
    [[ ! -f "$marker" ]] || print -u2 "Last phase: $(<"$marker")"
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
print "Blink profile tabs (normal and private window), navigation, browser release, and shutdown passed."
