import CryptoKit
import Foundation
import Security
import AskaraCore

private struct SyncSnapshot: Codable {
    var modifiedAt: Date
    var deviceName: String
    var profileID: UUID
    var history: HistoryStore
    var bookmarks: BookmarkStore
    var preferences: BrowserPreferences
    var session: SessionState
}

private struct EncryptedSyncEnvelope: Codable {
    var version = 1
    var sealed: Data
}

/// Stores AES-GCM ciphertext in a user-selected folder, including iCloud Drive or another sync service.
@MainActor
final class SyncCoordinator {
    private static let fileName = "Askara Browser Sync.askara"
    private static let keychainAccount = "encrypted-sync-key-v1"
    private unowned let services: BrowserServices
    private var pending: Task<Void, Never>?
    private var pollTimer: Timer?
    private var applyingRemote = false
    private var lastSeenFileDate: Date?
    private(set) var syncedTabs: [SessionState.SavedTab] = []
    private(set) var syncedDeviceName: String?
    private(set) var status = String(localized: "Sync is off")
    private(set) var lastSync: Date?

    init(services: BrowserServices) { self.services = services }

    var folderURL: URL? {
        let path = services.preferences.syncFolderPath
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    var folderDisplayName: String {
        folderURL?.path(percentEncoded: false) ?? String(localized: "No sync folder selected")
    }

    func start() {
        guard services.preferences.syncEnabled else { return }
        startPolling()
        loadOrCreateFile()
    }

    func setFolder(_ folder: URL) {
        services.updatePreferences {
            $0.syncFolderPath = folder.standardizedFileURL.path
            $0.syncEnabled = true
        }
        startPolling()
        loadOrCreateFile()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != services.preferences.syncEnabled else { return }
        services.updatePreferences { $0.syncEnabled = enabled }
        if enabled {
            guard folderURL != nil else {
                status = String(localized: "Choose a sync folder first")
                changed()
                return
            }
            startPolling()
            loadOrCreateFile()
        } else {
            pending?.cancel()
            pollTimer?.invalidate()
            pollTimer = nil
            status = String(localized: "Sync is off")
            changed()
        }
    }

    func localDataChanged() {
        guard services.preferences.syncEnabled, folderURL != nil, !applyingRemote else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.pushNow()
        }
    }

    func pushNow() {
        pending?.cancel()
        guard services.preferences.syncEnabled, let fileURL else { return }
        do {
            let profile = services.currentProfile
            var preferences = services.preferences
            preferences.syncEnabled = true
            preferences.syncFolderPath = ""
            let snapshot = SyncSnapshot(modifiedAt: Date(), deviceName: Host.current().localizedName ?? "Mac",
                                        profileID: profile.id, history: profile.history, bookmarks: profile.bookmarks,
                                        preferences: preferences, session: profile.syncedSession())
            let plaintext = try encoder.encode(snapshot)
            let box = try AES.GCM.seal(plaintext, using: syncKey(createIfMissing: true))
            guard let combined = box.combined else { throw SyncError.encryptionFailed }
            let data = try encoder.encode(EncryptedSyncEnvelope(sealed: combined))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            lastSeenFileDate = modificationDate(of: fileURL)
            lastSync = snapshot.modifiedAt
            status = String(localized: "Synced with end-to-end encryption")
        } catch {
            status = String(localized: "Sync unavailable: \(error.localizedDescription)")
            Log.error("Askara: encrypted file sync failed: \(error)")
        }
        changed()
    }

    private var fileURL: URL? { folderURL?.appendingPathComponent(Self.fileName) }

    private func loadOrCreateFile() {
        guard let fileURL else {
            status = String(localized: "Choose a sync folder first")
            return changed()
        }
        if FileManager.default.fileExists(atPath: fileURL.path) { pull() } else { pushNow() }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { BrowserServices.shared.sync.pullIfChanged() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pullIfChanged() {
        guard services.preferences.syncEnabled, let fileURL,
              let date = modificationDate(of: fileURL), date != lastSeenFileDate else { return }
        pull()
    }

    private func pull() {
        guard services.preferences.syncEnabled, let fileURL else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try decoder.decode(EncryptedSyncEnvelope.self, from: data)
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            let plaintext = try AES.GCM.open(box, using: syncKey(createIfMissing: false))
            let snapshot = try decoder.decode(SyncSnapshot.self, from: plaintext)
            lastSeenFileDate = modificationDate(of: fileURL)
            guard snapshot.modifiedAt > (lastSync ?? .distantPast) else { return }
            applyingRemote = true
            services.currentProfile.replaceSyncedData(history: snapshot.history, bookmarks: snapshot.bookmarks)
            var preferences = snapshot.preferences
            preferences.syncEnabled = true
            preferences.syncFolderPath = folderURL?.path ?? ""
            services.applySyncedPreferences(preferences)
            syncedTabs = snapshot.session.windows.flatMap(\.tabs)
            syncedDeviceName = snapshot.deviceName
            applyingRemote = false
            lastSync = snapshot.modifiedAt
            status = String(localized: "Synced from \(snapshot.deviceName)")
        } catch {
            applyingRemote = false
            status = error as? SyncError == .syncKeyPending
                ? String(localized: "Waiting for encrypted sync key from iCloud Keychain")
                : String(localized: "Couldn't decrypt synced data")
            Log.error("Askara: encrypted file sync read failed: \(error)")
        }
        changed()
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .secondsSince1970
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .secondsSince1970
        return value
    }

    private func syncKey(createIfMissing: Bool) throws -> SymmetricKey {
        let service = Bundle.main.bundleIdentifier ?? "local.askara.browser"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &item)
        if found == errSecSuccess, let data = item as? Data { return SymmetricKey(data: data) }
        guard found == errSecItemNotFound else { throw SyncError.keychain(found) }
        guard createIfMissing else { throw SyncError.syncKeyPending }

        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let result = SecItemAdd(add as CFDictionary, nil)
        guard result == errSecSuccess else { throw SyncError.keychain(result) }
        return SymmetricKey(data: data)
    }

    private func changed() {
        NotificationCenter.default.post(name: .askaraSyncChanged, object: nil)
    }
}

private enum SyncError: LocalizedError, Equatable {
    case encryptionFailed, syncKeyPending, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed: "Encryption failed"
        case .syncKeyPending: "Encrypted sync key has not arrived from iCloud Keychain"
        case let .keychain(code): "iCloud Keychain error \(code)"
        }
    }
}
