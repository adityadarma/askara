import AppKit
import AskaraCore

/// "Clear Browsing Data": pick how far back and what to remove. Shared by the History window and the
/// History menu (⇧⌘⌫).
@MainActor
enum ClearDataDialog {
    static func present(for profile: ProfileData, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Clear browsing data")
        alert.informativeText = String(localized: "Bookmarks and downloaded files are not removed. This can’t be undone.")

        let rangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for range in ClearRange.allCases {
            rangePopup.addItem(withTitle: title(for: range))
            rangePopup.lastItem?.tag = range.rawValue
        }
        rangePopup.selectItem(withTag: ClearRange.lastHour.rawValue)
        rangePopup.setAccessibilityLabel(String(localized: "Time range"))
        let rangeLabel = NSTextField(labelWithString: String(localized: "Time range:"))
        let rangeRow = NSStackView(views: [rangeLabel, rangePopup])
        rangeRow.spacing = 8

        let historyBox = NSButton(checkboxWithTitle: String(localized: "History and recently closed tabs"),
                                  target: nil, action: nil)
        let cookiesBox = NSButton(checkboxWithTitle: String(localized: "Cookies and site data (signs you out of websites)"),
                                  target: nil, action: nil)
        let cacheBox = NSButton(checkboxWithTitle: String(localized: "Cached images and files"), target: nil, action: nil)
        [historyBox, cookiesBox, cacheBox].forEach { $0.state = .on }

        let column = NSStackView(views: [rangeRow, historyBox, cookiesBox, cacheBox])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.frame = NSRect(x: 0, y: 0, width: 360, height: 112)
        alert.accessoryView = column

        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true

        let handler: (NSApplication.ModalResponse) -> Void = { [weak profile] response in
            guard response == .alertFirstButtonReturn, let profile else { return }
            var kinds: BrowsingDataKinds = []
            if historyBox.state == .on { kinds.insert(.history) }
            if cookiesBox.state == .on { kinds.insert(.cookiesAndSiteData) }
            if cacheBox.state == .on { kinds.insert(.cache) }
            guard !kinds.isEmpty, let range = ClearRange(rawValue: rangePopup.selectedTag()) else { return }
            profile.clearBrowsingData(range: range, kinds: kinds) {
                BrowserServices.shared.keyBrowserWindow?.showToast(String(localized: "Browsing data cleared"), duration: 2)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    static func title(for range: ClearRange) -> String {
        switch range {
        case .lastHour: String(localized: "Last hour")
        case .lastDay: String(localized: "Last 24 hours")
        case .lastWeek: String(localized: "Last 7 days")
        case .lastFourWeeks: String(localized: "Last 4 weeks")
        case .allTime: String(localized: "All time")
        }
    }
}
