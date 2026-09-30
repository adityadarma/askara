import AppKit
import Darwin
import Security
import WebKit

/// Reads process memory usage (the same number as the "Memory" column in Activity Monitor).
enum ProcessMemory {
    static func footprint(pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// Reads process CPU time (user + system), the same source as Activity Monitor's "% CPU" column.
/// CPU time only ever increases, so callers must poll twice and diff: see `CPUUsageTracker`.
enum ProcessCPU {
    /// Total CPU time consumed by the process since it started, in nanoseconds.
    static func time(pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_user_time + info.ri_system_time : nil
    }
}

/// Turns cumulative CPU time into a "% CPU" figure, the way Activity Monitor does: it's meaningless
/// as a single reading, so this keeps the previous sample per pid and diffs against wall-clock time.
@MainActor
final class CPUUsageTracker {
    private struct Sample { let cpuTime: UInt64; let wallTime: DispatchTime }
    private var samples: [pid_t: Sample] = [:]

    /// Percent of one core used since the last call for this pid (0 the first time it's seen).
    /// 100 means one full core saturated; can exceed 100 for multi-threaded processes.
    func usage(pid: pid_t) -> Double {
        guard let cpuTime = ProcessCPU.time(pid: pid) else { return 0 }
        let now = DispatchTime.now()
        defer { samples[pid] = Sample(cpuTime: cpuTime, wallTime: now) }
        guard let previous = samples[pid], cpuTime >= previous.cpuTime else { return 0 }
        let wallElapsed = now.uptimeNanoseconds &- previous.wallTime.uptimeNanoseconds
        guard wallElapsed > 0 else { return 0 }
        let cpuElapsed = cpuTime - previous.cpuTime
        return (Double(cpuElapsed) / Double(wallElapsed)) * 100
    }

    /// Drops samples for processes no longer seen, so a reused pid doesn't inherit a stale baseline.
    func prune(keeping pids: Set<pid_t>) {
        samples = samples.filter { pids.contains($0.key) }
    }
}

extension WKWebView {
    /// PID of this tab's WebContent process. Uses a private WebKit property, checked for availability first.
    var askaraProcessID: pid_t? {
        guard responds(to: Selector(("_webProcessIdentifier"))),
              let pid = (value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        return pid
    }

    /// Whether the page is playing sound (private WebKit property, checked first).
    var askaraIsPlayingAudio: Bool {
        guard responds(to: Selector(("_isPlayingAudio"))) else { return false }
        return (value(forKey: "_isPlayingAudio") as? Bool) ?? false
    }

    /// Camera/microphone active (e.g. Google Meet): don't put to sleep.
    var askaraIsCapturingMedia: Bool {
        cameraCaptureState != .none || microphoneCaptureState != .none
    }

    /// Mutes page audio via the private `_setPageMuted:` (the same call Safari uses). Returns false
    /// when unavailable. Only audio is muted; camera/microphone capture is unaffected.
    @discardableResult
    func askaraSetMuted(_ muted: Bool) -> Bool {
        let selector = Selector(("_setPageMuted:"))
        guard responds(to: selector) else { return false }
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        let function = unsafeBitCast(method(for: selector), to: SetMuted.self)
        function(self, selector, muted ? 1 : 0) // _WKMediaAudioMuted = 1 << 0
        return true
    }
}

/// Browser marker in the user agent. WKWebView's default omits "Version/… Safari/…", so
/// some sites serve an old version (e.g. the basic Google homepage) and extensions like Bitwarden
/// fail to identify the browser and get stuck on the loading screen.
enum UserAgent {
    static let applicationName: String = {
        let full = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
        // Safari only reports the major.minor version.
        let version = full.split(separator: ".").prefix(2).joined(separator: ".")
        return "Version/\(version) Safari/605.1.15"
    }()
}

/// Detects unsubmitted form input, so that tab isn't put to sleep and the input isn't lost.
/// The script only reports true/false; Askara never reads form contents.
enum FormGuard {
    static let handlerName = "askaraForm"

    static let script = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers.askaraForm;
      if (!handler) return;
      // Random ID per frame, so a clean iframe doesn't clear the state of another iframe with input.
      const frame = Math.random().toString(36).slice(2);
      const edited = new Set();
      const ignoredTypes = new Set(['hidden', 'submit', 'button', 'reset', 'image', 'file', 'search']);
      let dirty = false;
      let timer = null;

      // Still different from the initial value and still on the page?
      const stillChanged = (el) => {
        if (!el.isConnected) return false;
        if (el.isContentEditable) return el.textContent.trim() !== '';
        if (el.tagName === 'SELECT') return Array.from(el.options).some((o) => o.selected !== o.defaultSelected);
        if (el.type === 'checkbox' || el.type === 'radio') return el.checked !== el.defaultChecked;
        return el.value !== el.defaultValue;
      };

      const evaluate = () => {
        for (const el of edited) if (!stillChanged(el)) edited.delete(el);
        const now = edited.size > 0;
        if (now !== dirty) { dirty = now; handler.postMessage({ frame, dirty: now }); }
        // Recheck periodically only while there is input, to catch forms cleared by the site.
        if (dirty && !timer) timer = setInterval(evaluate, 15000);
        if (!dirty && timer) { clearInterval(timer); timer = null; }
      };

      const track = (event) => {
        let el = event.target;
        if (!el || !el.tagName) return;
        if (el.isContentEditable) {
          while (el.parentElement && el.parentElement.isContentEditable) el = el.parentElement;
        } else if (!['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)) {
          return;
        }
        if (el.tagName === 'INPUT' && ignoredTypes.has((el.type || '').toLowerCase())) return;
        edited.add(el);
        evaluate();
      };

      document.addEventListener('input', track, true);
      document.addEventListener('change', track, true);
      document.addEventListener('reset', () => setTimeout(evaluate, 0), true);
    })();
    """
}

enum Passkey {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    /// WebAuthn/passkeys in WKWebView only work if the app is signed with this entitlement.
    static let isAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        return (value as? Bool) == true
    }()

    /// Detects passkey failures to provide an explanation, without changing page behavior.
    static let detectionScript = """
    (() => {
      const c = navigator.credentials;
      if (!c || !window.webkit || !window.webkit.messageHandlers.askaraPasskey) return;
      for (const name of ['get', 'create']) {
        const original = c[name] && c[name].bind(c);
        if (!original) continue;
        c[name] = function (options) {
          const promise = original(options);
          if (options && options.publicKey) {
            promise.catch((e) => {
              if (e && e.name === 'NotAllowedError') {
                window.webkit.messageHandlers.askaraPasskey.postMessage(name);
              }
            });
          }
          return promise;
        };
      }
    })();
    """
}

enum PictureInPictureScript {
    static let handlerName = "askaraPiP"

    static let source = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers.askaraPiP;
      if (!handler) return;
      const videos = () => Array.from(document.querySelectorAll('video'));
      const candidate = () => videos().filter((v) => v.readyState >= 2 && v.videoWidth > 0 && v.videoHeight > 0)
        .sort((a, b) => ((b.paused ? 0 : 1) - (a.paused ? 0 : 1)) ||
                        (b.getBoundingClientRect().width * b.getBoundingClientRect().height -
                         a.getBoundingClientRect().width * a.getBoundingClientRect().height))[0];
      const report = () => handler.postMessage({
        eligible: !!candidate(),
        active: !!document.pictureInPictureElement || videos().some((v) => v.webkitPresentationMode === 'picture-in-picture')
      });
      window.__askaraTogglePiP = async () => {
        const active = document.pictureInPictureElement || videos().find((v) => v.webkitPresentationMode === 'picture-in-picture');
        if (active) {
          if (document.pictureInPictureElement && document.exitPictureInPicture) await document.exitPictureInPicture();
          else if (active.webkitSetPresentationMode) active.webkitSetPresentationMode('inline');
          report();
          return true;
        }
        const video = candidate();
        if (!video) return false;
        if (video.requestPictureInPicture) await video.requestPictureInPicture();
        else if (video.webkitSupportsPresentationMode && video.webkitSupportsPresentationMode('picture-in-picture'))
          video.webkitSetPresentationMode('picture-in-picture');
        else return false;
        report();
        return true;
      };
      for (const event of ['play', 'pause', 'loadedmetadata', 'enterpictureinpicture', 'leavepictureinpicture',
                           'webkitpresentationmodechanged']) document.addEventListener(event, report, true);
      new MutationObserver(report).observe(document.documentElement, { childList: true, subtree: true });
      report();
    })();
    """
}
