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

extension WKWebView {
    /// PID of this tab's WebContent process. Uses a private WebKit property, checked for availability first.
    var hematProcessID: pid_t? {
        guard responds(to: Selector(("_webProcessIdentifier"))),
              let pid = (value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        return pid
    }

    /// Whether the page is playing sound (private WebKit property, checked first).
    var hematIsPlayingAudio: Bool {
        guard responds(to: Selector(("_isPlayingAudio"))) else { return false }
        return (value(forKey: "_isPlayingAudio") as? Bool) ?? false
    }

    /// Camera/microphone active (e.g. Google Meet): don't put to sleep.
    var hematIsCapturingMedia: Bool {
        cameraCaptureState != .none || microphoneCaptureState != .none
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
/// The script only reports true/false; Hemat never reads form contents.
enum FormGuard {
    static let handlerName = "hematForm"

    static let script = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers.hematForm;
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
      if (!c || !window.webkit || !window.webkit.messageHandlers.hematPasskey) return;
      for (const name of ['get', 'create']) {
        const original = c[name] && c[name].bind(c);
        if (!original) continue;
        c[name] = function (options) {
          const promise = original(options);
          if (options && options.publicKey) {
            promise.catch((e) => {
              if (e && e.name === 'NotAllowedError') {
                window.webkit.messageHandlers.hematPasskey.postMessage(name);
              }
            });
          }
          return promise;
        };
      }
    })();
    """
}
