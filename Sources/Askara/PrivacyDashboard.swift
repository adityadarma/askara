import AppKit
import WebKit
import AskaraCore

@MainActor
final class PrivacyDashboardController: NSViewController {
    private let profile: ProfileData
    private let host: String
    private let secure: Bool
    private let status = NSTextField(wrappingLabelWithString: String(localized: "Checking site data…"))
    private let permissions = NSTextField(wrappingLabelWithString: "")
    private let clearButton = NSButton(title: String(localized: "Clear Site Data"), target: nil, action: nil)

    init(profile: ProfileData, host: String, secure: Bool) {
        self.profile = profile
        self.host = host
        self.secure = secure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = NSTextField(labelWithString: SiteSettings.key(for: host))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let connection = NSTextField(labelWithString: secure ? String(localized: "Secure HTTPS connection")
                                                                : String(localized: "Connection is not secure"))
        connection.textColor = secure ? .systemGreen : .systemOrange
        let protection = NSTextField(wrappingLabelWithString: String(localized: "Ad and tracker protection is active. WebKit does not expose an exact blocked-request count."))
        protection.textColor = .secondaryLabelColor
        status.textColor = .secondaryLabelColor
        permissions.textColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearSiteData(_:))
        let stack = NSStackView(views: [title, connection, protection, status, permissions, clearButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        [protection, status, permissions].forEach { $0.preferredMaxLayoutWidth = 328 }
        view = stack
        refresh()
    }

    private func refresh() {
        permissions.stringValue = PermissionKind.allCases.map { kind in
            let name = switch kind {
            case .camera: String(localized: "Camera")
            case .microphone: String(localized: "Microphone")
            case .location: String(localized: "Location")
            }
            let choice = switch profile.permissions.choice(kind, host: host) {
            case .allow: String(localized: "Allowed")
            case .block: String(localized: "Blocked")
            case nil: String(localized: "Ask")
            }
            return "\(name): \(choice)"
        }.joined(separator: "  •  ")

        profile.dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let cookieCount = cookies.filter { SiteDataDomain.matches($0.domain, site: self.host) }.count
            self.profile.dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let records = records.filter { SiteDataDomain.matches($0.displayName, site: self.host) }
                MainActor.assumeIsolated {
                    self.status.stringValue = String(localized: "Cookies: \(cookieCount)  •  Storage records: \(records.count)")
                    self.clearButton.isEnabled = cookieCount > 0 || !records.isEmpty
                }
            }
        }
    }

    @objc private func clearSiteData(_ sender: Any?) {
        clearButton.isEnabled = false
        profile.dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            cookies.filter { SiteDataDomain.matches($0.domain, site: self.host) }
                .forEach { self.profile.dataStore.httpCookieStore.delete($0) }
            self.profile.dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let records = records.filter { SiteDataDomain.matches($0.displayName, site: self.host) }
                self.profile.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) { [weak self] in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
    }
}
