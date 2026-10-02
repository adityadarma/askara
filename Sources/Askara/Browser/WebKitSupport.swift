import AppKit
import Security
import WebKit

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

    /// Frees pages kept in memory for instant back/forward (private `_clearBackForwardCache`, checked
    /// first). History itself is kept; going back just loads the page again.
    func askaraClearBackForwardCache() {
        let selector = Selector(("_clearBackForwardCache"))
        guard responds(to: selector) else { return }
        perform(selector)
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

enum PasswordFillScript {
    static let source = """
    const visible = (el) => {
      if (!el || el.disabled || el.readOnly || !el.isConnected) return false;
      const rect = el.getBoundingClientRect();
      const style = getComputedStyle(el);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
    };
    const passwords = Array.from(document.querySelectorAll('input[type="password"]')).filter((el) => {
      const autocomplete = (el.autocomplete || '').toLowerCase();
      return visible(el) && autocomplete !== 'new-password';
    });
    if (passwords.length !== 1) return passwords.length ? 'ambiguous' : 'missing';
    const passwordField = passwords[0];
    const scope = passwordField.form || document;
    const usernames = Array.from(scope.querySelectorAll('input')).filter((el) => {
      const type = (el.type || 'text').toLowerCase();
      const autocomplete = (el.autocomplete || '').toLowerCase();
      return visible(el) && (autocomplete === 'username' || type === 'email' || type === 'text');
    });
    const usernameField = usernames.find((el) => (el.autocomplete || '').toLowerCase() === 'username')
      || usernames.find((el) => (el.type || '').toLowerCase() === 'email') || usernames[0];
    const set = (el, value) => {
      if (!el) return;
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      setter.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    set(usernameField, inputUsername);
    set(passwordField, inputPassword);
    passwordField.focus();
    return 'filled';
    """
}

enum PictureInPictureScript {
    static let handlerName = "askaraPiP"

    static let source = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers.askaraPiP;
      if (!handler) return;
      const frame = Math.random().toString(36).slice(2);
      const videos = () => Array.from(document.querySelectorAll('video'));
      // Pick the playing/largest video in one pass. The old sort read every element's layout
      // repeatedly, which was expensive on pages with several players.
      const candidate = (all) => {
        let best = null, bestPlaying = -1, bestArea = -1;
        for (const video of all) {
          if (video.readyState < 2 || video.videoWidth <= 0 || video.videoHeight <= 0) continue;
          const rect = video.getBoundingClientRect();
          const playing = video.paused ? 0 : 1;
          const area = rect.width * rect.height;
          if (!best || playing > bestPlaying || (playing === bestPlaying && area > bestArea)) {
            best = video;
            bestPlaying = playing;
            bestArea = area;
          }
        }
        return best;
      };

      let scheduled = false;
      let pageVisible = true;
      let lastEligible;
      let lastActive;
      const report = (force = false) => {
        scheduled = false;
        if (!pageVisible) return;
        const all = videos();
        const eligible = !!candidate(all);
        const active = !!document.pictureInPictureElement ||
          all.some((video) => video.webkitPresentationMode === 'picture-in-picture');
        // Crossing the WebKit script-message boundary is not free. Only report state changes.
        if (!force && eligible === lastEligible && active === lastActive) return;
        lastEligible = eligible;
        lastActive = active;
        handler.postMessage({ frame, eligible, active });
      };
      const scheduleReport = () => {
        if (scheduled || !pageVisible) return;
        scheduled = true;
        requestAnimationFrame(() => report(false));
      };

      window.__askaraTogglePiP = async () => {
        const all = videos();
        const active = document.pictureInPictureElement ||
          all.find((video) => video.webkitPresentationMode === 'picture-in-picture');
        if (active) {
          if (document.pictureInPictureElement && document.exitPictureInPicture)
            await document.exitPictureInPicture();
          else if (active.webkitSetPresentationMode) active.webkitSetPresentationMode('inline');
          report();
          return true;
        }
        const video = candidate(all);
        if (!video) return false;
        if (video.requestPictureInPicture) await video.requestPictureInPicture();
        else if (video.webkitSupportsPresentationMode && video.webkitSupportsPresentationMode('picture-in-picture'))
          video.webkitSetPresentationMode('picture-in-picture');
        else return false;
        report();
        return true;
      };
      // High-frequency readiness/play events may wait for the next frame. PiP transitions must be
      // immediate because background WebViews can suspend requestAnimationFrame indefinitely.
      for (const event of ['play', 'pause', 'loadedmetadata'])
        document.addEventListener(event, scheduleReport, true);
      for (const event of ['enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged'])
        document.addEventListener(event, () => report(false), true);
      window.addEventListener('pagehide', () => {
        pageVisible = false;
        scheduled = false;
        lastEligible = undefined;
        lastActive = undefined;
        handler.postMessage({ frame, eligible: false, active: false });
      });
      window.addEventListener('pageshow', () => {
        pageVisible = true;
        lastEligible = undefined;
        lastActive = undefined;
        report(true);
      });

      // Dynamic sites can mutate the DOM hundreds of times per frame. Ignore unrelated mutations
      // and collapse video-related bursts into one scan per animation frame.
      const containsVideo = (node) => !!node &&
        (node.nodeName === 'VIDEO' || (node.querySelector && !!node.querySelector('video')));
      new MutationObserver((mutations) => {
        const changed = mutations.some((mutation) => mutation.target?.nodeName === 'VIDEO' ||
          Array.from(mutation.addedNodes || []).some(containsVideo) ||
          Array.from(mutation.removedNodes || []).some(containsVideo));
        if (changed) scheduleReport();
      }).observe(document.documentElement, { childList: true, subtree: true });
      report();
    })();
    """
}
