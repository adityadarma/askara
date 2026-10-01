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
server_pid=""
cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    # Helpers of a failed run may still write into the cache; stop them before deleting it.
    pkill -KILL -f "$work" 2>/dev/null || true
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
    sleep 0.2
    rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$work/site"
cat > "$work/site/index.html" <<'HTML'
<!doctype html><title>base</title>
<script>
window.pageRan = true;
Promise.all([
  navigator.mediaDevices.getUserMedia({video:true}),
  navigator.mediaDevices.getUserMedia({audio:true}),
  navigator.mediaDevices.getUserMedia({video:true,audio:true}),
  new Promise((resolve, reject) => navigator.geolocation.getCurrentPosition(resolve, reject)),
].map(p => p.then(() => false, () => true))).then(results => {
  if (results.every(Boolean)) {
    window.permissionsDenied = true;
    if (window.customApplied) document.title = 'permissions-denied';
  }
});
</script>
<script src="http://localhost:8765/ad.js"></script>
HTML
cat > "$work/site/ad.js" <<'JS'
window.adLoaded = true;
JS
cat > "$work/site/popup-source.html" <<'HTML'
<!doctype html><title>popup-source</title>
<button onclick="window.open('/popup-child.html', '_blank')"
        style="position:fixed;left:0;top:0;width:300px;height:200px">Open</button>
HTML
cat > "$work/site/popup-child.html" <<'HTML'
<!doctype html><script>document.title = window.opener ? 'opener-ok' : 'opener-missing'</script>
HTML
cat > "$work/server.py" <<'PY'
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import os

root = os.environ["ASKARA_SMOKE_SITE"]
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)
    def do_GET(self):
        if self.path == "/download.bin":
            body = b"Askara Blink download smoke\n"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="blink-smoke.bin"')
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

ThreadingHTTPServer(("0.0.0.0", 8765), Handler).serve_forever()
PY
ASKARA_SMOKE_SITE="$work/site" python3 "$work/server.py" > "$work/server.log" 2>&1 &
server_pid=$!

ASKARA_CEF_SMOKE_FILE="$marker" \
ASKARA_CEF_SMOKE_URL="http://127.0.0.1:8765/index.html" \
ASKARA_CEF_SMOKE_BLOCK_DOMAIN="localhost" \
"build/Askara.app/Contents/MacOS/Askara" > "$log" 2>&1 &
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
print "Blink navigation, policies, permissions, downloads, popup opener, browser release, and shutdown passed."
