import Foundation
import Security
import AskaraCore

struct PasswordStore {
    private let service: String

    init(profileID: UUID) {
        service = (Bundle.main.bundleIdentifier ?? "dev.adityadarma.askara")
            + ".passwords." + profileID.uuidString
    }

    func credentials(for origin: PasswordOrigin? = nil) throws -> [PasswordCredential] {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
        let rows = result as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let data = row[kSecAttrGeneric as String] as? Data else { return nil }
            return try? decoder.decode(PasswordCredential.self, from: data)
        }
        .filter { origin == nil || $0.origin == origin }
        .sorted {
            if $0.origin.displayName != $1.origin.displayName {
                return $0.origin.displayName < $1.origin.displayName
            }
            return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }
    }

    func password(for id: UUID) throws -> String {
        var query = itemQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw PasswordStoreError.keychain(status)
        }
        return password
    }

    @discardableResult
    func save(origin: PasswordOrigin, username: String, password: String) throws -> PasswordCredential {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else { throw PasswordStoreError.emptyCredential }
        let existing = try credentials(for: origin).first {
            $0.username.compare(cleanUsername, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let now = Date()
        let credential = PasswordCredential(id: existing?.id ?? UUID(), origin: origin,
                                            username: cleanUsername,
                                            createdAt: existing?.createdAt ?? now, modifiedAt: now)
        let metadata = try encoder.encode(credential)
        let secret = Data(password.utf8)
        if existing != nil {
            let values: [String: Any] = [
                kSecValueData as String: secret,
                kSecAttrGeneric as String: metadata,
                kSecAttrLabel as String: "Askara password for \(origin.host)",
            ]
            let status = SecItemUpdate(itemQuery(credential.id) as CFDictionary, values as CFDictionary)
            guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
        } else {
            var query = itemQuery(credential.id)
            query[kSecValueData as String] = secret
            query[kSecAttrGeneric as String] = metadata
            query[kSecAttrLabel as String] = "Askara password for \(origin.host)"
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
        }
        return credential
    }

    func delete(_ id: UUID) throws {
        let status = SecItemDelete(itemQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError.keychain(status)
        }
    }

    func deleteAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private func itemQuery(_ id: UUID) -> [String: Any] {
        var query = baseQuery
        query[kSecAttrAccount as String] = id.uuidString
        return query
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

enum PasswordStoreError: LocalizedError {
    case emptyCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyCredential: String(localized: "Username and password are required.")
        case .keychain(let status):
            String(localized: "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
        }
    }
}
