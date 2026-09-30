import AppKit
import AskaraCore

/// Avatar colors, indexed by `Profile.colorIndex`. Muted so they sit well in the toolbar.
enum ProfileColors {
    static let all: [NSColor] = [
        NSColor(srgbRed: 0.36, green: 0.42, blue: 0.75, alpha: 1), // indigo
        NSColor(srgbRed: 0.20, green: 0.56, blue: 0.52, alpha: 1), // teal
        NSColor(srgbRed: 0.80, green: 0.45, blue: 0.30, alpha: 1), // terracotta
        NSColor(srgbRed: 0.62, green: 0.40, blue: 0.70, alpha: 1), // purple
        NSColor(srgbRed: 0.40, green: 0.60, blue: 0.32, alpha: 1), // green
        NSColor(srgbRed: 0.78, green: 0.38, blue: 0.52, alpha: 1), // rose
        NSColor(srgbRed: 0.72, green: 0.58, blue: 0.24, alpha: 1), // ochre
        NSColor(srgbRed: 0.45, green: 0.50, blue: 0.56, alpha: 1), // slate
    ]
    static let names = [
        String(localized: "Indigo"), String(localized: "Teal"), String(localized: "Terracotta"),
        String(localized: "Purple"), String(localized: "Green"), String(localized: "Rose"),
        String(localized: "Ochre"), String(localized: "Slate"),
    ]

    static func color(_ index: Int) -> NSColor { all[min(max(0, index), all.count - 1)] }

    /// Round avatar with the profile's initials.
    static func avatar(for profile: Profile, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color(profile.colorIndex).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let text = profile.initials as NSString
            let font = NSFont.systemFont(ofSize: size * (text.length > 1 ? 0.38 : 0.48), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                      withAttributes: attributes)
            return true
        }
        image.accessibilityDescription = profile.name
        return image
    }
}

/// Profile list + actions, used by the toolbar button and File > Profiles.
@MainActor
enum ProfileMenu {
    static func fill(_ menu: NSMenu, current: UUID, target: AppDelegate) {
        let services = BrowserServices.shared
        let header = NSMenuItem(title: String(localized: "Profiles"), action: nil, keyEquivalent: "")
        header.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        header.isEnabled = false
        menu.addItem(header)
        for profile in services.profileList.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(AppDelegate.openProfileAction(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = profile.id
            item.image = ProfileColors.avatar(for: profile, size: 18)
            item.state = profile.id == current ? .on : .off
            item.toolTip = profile.id == current
                ? String(localized: "Profile in use")
                : String(localized: "Open a window for this profile")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: String(localized: "Add Profile…"), action: #selector(AppDelegate.addProfileAction(_:)),
                             keyEquivalent: "")
        add.target = target
        add.image = NSImage(systemSymbolName: "person.crop.circle.badge.plus", accessibilityDescription: nil)
        menu.addItem(add)
        let name = services.profileList.profile(current)?.name ?? ""
        let edit = NSMenuItem(title: String(localized: "Edit “\(name)”…"), action: #selector(AppDelegate.editProfileAction(_:)),
                              keyEquivalent: "")
        edit.target = target
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        menu.addItem(edit)
        let delete = NSMenuItem(title: String(localized: "Delete “\(name)”…"), action: #selector(AppDelegate.deleteProfileAction(_:)),
                                keyEquivalent: "")
        delete.target = target
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(delete)
    }
}

/// Add / edit / delete dialogs.
@MainActor
enum ProfileDialogs {
    private static var services: BrowserServices { .shared }

    static func add() {
        guard let (name, color) = ask(title: String(localized: "Add Profile"),
                                      info: String(localized: "A profile has its own logins, history, bookmarks, site permissions, and extensions. Settings are shared."),
                                      button: String(localized: "Add"), name: "", colorIndex: nil) else { return }
        guard let profile = services.addProfile(name: name) else { return }
        if let color { services.updateProfile(profile.id, name: profile.name, colorIndex: color) }
        services.openProfile(profile.id)
    }

    static func edit(_ id: UUID) {
        guard let profile = services.profileList.profile(id),
              let (name, color) = ask(title: String(localized: "Edit Profile"), info: nil,
                                      button: String(localized: "Save"), name: profile.name,
                                      colorIndex: profile.colorIndex) else { return }
        services.updateProfile(id, name: name, colorIndex: color ?? profile.colorIndex)
    }

    static func delete(_ id: UUID) {
        guard services.profileList.canRemove(id), let profile = services.profileList.profile(id) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete profile “\(profile.name)”?")
        alert.informativeText = String(localized: "Its windows close, and its logins, cookies, history, bookmarks, site permissions, and extension data are removed from this Mac. This can’t be undone.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        services.removeProfile(id)
    }

    /// Name field + color picker. Returns nil when cancelled or the name is empty.
    private static func ask(title: String, info: String?, button: String, name: String,
                            colorIndex: Int?) -> (String, Int?)? {
        let alert = NSAlert()
        alert.messageText = title
        if let info { alert.informativeText = info }
        let field = NSTextField(string: name)
        field.placeholderString = String(localized: "Profile name, e.g. Work")
        field.setAccessibilityLabel(String(localized: "Profile name"))
        let colors = NSPopUpButton()
        for (index, color) in ProfileColors.names.enumerated() {
            colors.addItem(withTitle: color)
            colors.lastItem?.image = ProfileColors.avatar(for: Profile(name: " ", colorIndex: index), size: 14)
        }
        colors.selectItem(at: colorIndex ?? -1)
        if colorIndex == nil {
            // New profile: pre-select the color it would get automatically.
            var preview = services.profileList
            colors.selectItem(at: preview.add(name: "x")?.colorIndex ?? 0)
        }
        colors.setAccessibilityLabel(String(localized: "Profile color"))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Name:")), field],
            [NSTextField(labelWithString: String(localized: "Color:")), colors],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 58)
        field.widthAnchor.constraint(equalToConstant: 230).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let clean = ProfileList.cleanName(field.stringValue) else { return nil }
        return (clean, colors.indexOfSelectedItem)
    }
}
