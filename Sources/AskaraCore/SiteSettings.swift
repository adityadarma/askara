import Foundation

/// Custom CSS and JavaScript the user wrote for one site (Develop > Custom CSS & JavaScript).
public struct SiteCustomization: Codable, Equatable, Sendable {
    public var css: String
    public var javaScript: String
    public var isEnabled: Bool

    public init(css: String = "", javaScript: String = "", isEnabled: Bool = true) {
        self.css = css
        self.javaScript = javaScript
        self.isEnabled = isEnabled
    }

    public var isEmpty: Bool {
        css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && javaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Per-site settings: JavaScript blocking and custom code.
///
/// Keyed by host without "www.". A setting for "example.com" also covers its subdomains
/// ("docs.example.com"), like Chrome's "[*.]example.com" site patterns.
public struct SiteSettings: Codable, Equatable, Sendable {
    public private(set) var javaScriptBlocked: Set<String> = []
    public private(set) var customizations: [String: SiteCustomization] = [:]
    /// Optional keeps files written before this setting backward compatible.
    private var adBlockDisabled: Set<String>?

    public init() {}

    /// "WWW.Example.com." → "example.com"
    public static func key(for host: String) -> String {
        var result = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if result.hasSuffix(".") { result.removeLast() }
        if result.hasPrefix("www.") { result.removeFirst(4) }
        return result
    }

    /// The host and its parent domains, most specific first. The bare top-level domain is skipped:
    /// "a.b.example.com" → ["a.b.example.com", "b.example.com", "example.com"].
    public static func candidates(for host: String) -> [String] {
        let parts = key(for: host).split(separator: ".").map(String.init)
        guard parts.count > 1 else { return parts } // e.g. "localhost"
        return (0..<(parts.count - 1)).map { parts[$0...].joined(separator: ".") }
    }

    // MARK: JavaScript

    public func isJavaScriptBlocked(host: String) -> Bool {
        Self.candidates(for: host).contains(where: javaScriptBlocked.contains)
    }

    public func isAdBlockDisabled(host: String) -> Bool {
        let disabled = adBlockDisabled ?? []
        return Self.candidates(for: host).contains(where: disabled.contains)
    }

    public mutating func setAdBlockDisabled(_ disabled: Bool, host: String) {
        let key = Self.key(for: host)
        guard !key.isEmpty else { return }
        var values = adBlockDisabled ?? []
        if disabled {
            values.insert(key)
        } else {
            Self.candidates(for: host).forEach { values.remove($0) }
        }
        adBlockDisabled = values.isEmpty ? nil : values
    }

    public var adBlockExceptions: [String] { Array(adBlockDisabled ?? []).sorted() }

    /// Unblocking also clears a block set on a parent domain, so the site really runs JavaScript again.
    public mutating func setJavaScriptBlocked(_ blocked: Bool, host: String) {
        let key = Self.key(for: host)
        guard !key.isEmpty else { return }
        if blocked {
            javaScriptBlocked.insert(key)
        } else {
            Self.candidates(for: host).forEach { javaScriptBlocked.remove($0) }
        }
    }

    // MARK: Custom code

    public func customization(for host: String) -> SiteCustomization? { customizations[Self.key(for: host)] }

    /// An empty customization (no CSS, no JavaScript) is removed.
    public mutating func setCustomization(_ customization: SiteCustomization, host: String) {
        let key = Self.key(for: host)
        guard !key.isEmpty else { return }
        customizations[key] = customization.isEmpty ? nil : customization
    }

    /// True when one host is the other or a subdomain of it, i.e. a setting on one can affect the other.
    public static func isRelated(_ a: String, _ b: String) -> Bool {
        let keyA = key(for: a), keyB = key(for: b)
        return candidates(for: a).contains(keyB) || candidates(for: b).contains(keyA)
    }

    /// Enabled customizations that apply to the host. Parent domains come first so the more
    /// specific site's CSS wins and its JavaScript runs last.
    public func customizations(matching host: String) -> [SiteCustomization] {
        Self.candidates(for: host).reversed()
            .compactMap { customizations[$0] }
            .filter { $0.isEnabled && !$0.isEmpty }
    }
}

public enum SiteDataDomain {
    /// Matches the same DNS name or a real subdomain, never `notexample.com`.
    public static func matches(_ candidate: String, site host: String) -> Bool {
        let candidate = normalize(candidate)
        let host = normalize(host)
        return candidate == host || candidate.hasSuffix("." + host) || host.hasSuffix("." + candidate)
    }

    private static func normalize(_ value: String) -> String {
        var value = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }
}

/// Builds the scripts that apply custom site code. The app evaluates them in the page, so they
/// aren't blocked by the site's Content Security Policy or by "Disable JavaScript on This Site".
public enum SiteCodeScript {
    /// Adds the CSS as a constructed stylesheet (not subject to CSP `style-src`), replacing the one
    /// from an earlier run. Falls back to a `<style>` element. nil when there is no CSS.
    public static func css(_ css: String) -> String? {
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return """
        (() => {
          const css = \(jsonString(css));
          const old = document.getElementById('askara-site-css');
          if (old) old.remove();
          try {
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(css);
            sheet.askaraSiteCSS = true;
            document.adoptedStyleSheets = [...document.adoptedStyleSheets.filter((s) => !s.askaraSiteCSS), sheet];
          } catch (e) {
            // Right after navigation the document can still be empty; the app re-applies on load.
            const parent = document.head || document.documentElement;
            if (!parent) return;
            const style = document.createElement('style');
            style.id = 'askara-site-css';
            style.textContent = css;
            parent.appendChild(style);
          }
        })();
        true;
        """
    }

    /// Removes CSS added by `css(_:)`, for when the user deletes a site's CSS while the page is open.
    public static let removeCSS = """
    (() => {
      const old = document.getElementById('askara-site-css');
      if (old) old.remove();
      document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => !s.askaraSiteCSS);
    })();
    true;
    """

    /// Runs the code once the DOM is ready. Runtime errors go to the console; a syntax error makes
    /// the whole evaluation fail, which the app reports.
    public static func javaScript(_ code: String) -> String {
        """
        (() => {
          const run = () => {
            try {
        \(code)
            } catch (e) {
              console.error('[Askara] custom JavaScript failed:', e);
            }
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true });
          else run();
        })();
        true;
        """
    }

    /// A JavaScript string literal (JSON is valid JavaScript).
    static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }
}
