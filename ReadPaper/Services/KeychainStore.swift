import Foundation
import LocalAuthentication
import Security

enum KeychainAccessPolicy: Equatable {
    case userPresence
    case unprotected
}

@MainActor
struct KeychainStore {
    static let legacyOpenAIAPIKeyAccount = "openai-compatible-api-key"
    private static let userPresenceProtectionMarker = "Freddie.user-presence.v1"
    // Prefix used by the earlier LocalAuthentication + legacy-keychain
    // fallback. Those items are now read only for one-time migration into the
    // Secure Enclave vault.
    private static let authenticatedLegacyAccountPrefix = "freddie-user-presence:"
    private static let installGrantAccountPrefix = "freddie-install-grant:"

    let service: String
    let accessPolicy: KeychainAccessPolicy
    private let secureVault: SecureAPIKeyVault
    private let grantIdentityStore: APIKeyInstallGrantIdentityStore

    init(
        service: String = "com.yiyan.ReadPaper",
        accessPolicy: KeychainAccessPolicy = .userPresence
    ) {
        self.service = service
        self.accessPolicy = accessPolicy
        self.secureVault = SecureAPIKeyVault(service: service)
        self.grantIdentityStore = APIKeyInstallGrantIdentityStore()
    }

    func save(_ value: String, account: String) throws {
        defer {
            APIKeyAuthenticationSession.shared.invalidate(
                service: service,
                account: account
            )
        }
        let data = Data(value.utf8)

        switch accessPolicy {
        case .userPresence:
            rotateInstallGrant(account: account)
            do {
                try saveProtected(data, account: account)
            } catch where isMissingDataProtectionEntitlement(error) {
                try secureVault.save(value, account: account)
                deleteLegacyItemsBestEffort(account: account)
            }
        case .unprotected:
            try saveUnprotected(data, account: account, usesDataProtectionKeychain: false)
        }
    }

    func load(account: String) throws -> String? {
        switch accessPolicy {
        case .userPresence:
            if let grantedValue = try loadInstallGrant(account: account) {
                return grantedValue
            }

            let value: String?
            do {
                value = try loadProtected(account: account, migrateIfNeeded: true)
            } catch where isMissingDataProtectionEntitlement(error) {
                value = try loadSecureVaultOrLegacy(account: account, migrateIfNeeded: true)
            }
            if let value {
                try? saveInstallGrant(value, account: account)
            }
            return value
        case .unprotected:
            return try loadData(account: account, usesDataProtectionKeychain: false)
        }
    }

    /// Checks for an item without requesting its secret data, so status UI can
    /// be rendered without showing an authentication prompt.
    func contains(account: String) throws -> Bool {
        switch accessPolicy {
        case .userPresence:
            if try installGrantExists(account: account) {
                return true
            }
            do {
                if try dataProtectionItemState(account: account) != .absent {
                    return true
                }
            } catch where isMissingDataProtectionEntitlement(error) {
                return try secureVaultOrLegacyItemExists(account: account)
            }
#if os(macOS)
            return try secureVaultOrLegacyItemExists(account: account)
#else
            return false
#endif
        case .unprotected:
            return try legacyItemExists(account: account)
        }
    }

    /// Moves an item written by older Freddie versions from the legacy macOS
    /// keychain (or from an unprotected data-protection item) into storage
    /// guarded by user presence. A legacy macOS item may show its old password
    /// dialog once while its value is being migrated.
    @discardableResult
    func migrateToUserPresenceIfNeeded(account: String) throws -> Bool {
        guard accessPolicy == .userPresence else {
            return try contains(account: account)
        }

        do {
            switch try dataProtectionItemState(account: account) {
            case .protected:
                return true
            case .unprotected:
                guard let value = try loadData(account: account, usesDataProtectionKeychain: true) else {
                    return false
                }
                try saveProtected(Data(value.utf8), account: account)
                return true
            case .absent:
#if os(macOS)
                guard let value = try loadSecureVaultOrLegacy(account: account, migrateIfNeeded: true) else {
                    return false
                }
                try saveProtected(Data(value.utf8), account: account)
                return true
#else
                return false
#endif
            }
        } catch where isMissingDataProtectionEntitlement(error) {
            return try migrateSecureVaultIfNeeded(account: account)
        }
    }

    func delete(account: String) throws {
        defer {
            APIKeyAuthenticationSession.shared.invalidate(
                service: service,
                account: account
            )
        }
        switch accessPolicy {
        case .userPresence:
            rotateInstallGrant(account: account)
            do {
                try deleteItem(
                    account: account,
                    usesDataProtectionKeychain: true,
                    authenticationContext: makeAuthenticationContext(account: account)
                )
            } catch where isMissingDataProtectionEntitlement(error) {
                try deleteSecureVaultAndLegacy(account: account)
                return
            }
#if os(macOS)
            try deleteSecureVaultAndLegacy(account: account)
#endif
        case .unprotected:
            try deleteItem(account: account, usesDataProtectionKeychain: false)
        }
    }

    private func loadProtected(account: String, migrateIfNeeded: Bool) throws -> String? {
        switch try dataProtectionItemState(account: account) {
        case .protected:
            return try loadData(
                account: account,
                usesDataProtectionKeychain: true,
                authenticationContext: makeAuthenticationContext(account: account)
            )
        case .unprotected:
            let value = try loadData(account: account, usesDataProtectionKeychain: true)
            if migrateIfNeeded, let value {
                try saveProtected(Data(value.utf8), account: account)
            }
            return value
        case .absent:
#if os(macOS)
            let value = try loadSecureVaultOrLegacy(account: account, migrateIfNeeded: true)
            if migrateIfNeeded, let value {
                try saveProtected(Data(value.utf8), account: account)
            }
            return value
#else
            return nil
#endif
        }
    }

    private func secureVaultOrLegacyItemExists(account: String) throws -> Bool {
        if try secureVault.contains(account: account) {
            return true
        }
        if try legacyItemExists(account: authenticatedLegacyAccount(account)) {
            return true
        }
        return try legacyItemExists(account: account)
    }

    func loadInstallGrant(account: String) throws -> String? {
        try loadData(
            account: installGrantAccount(account),
            usesDataProtectionKeychain: false,
            authenticationContext: makeNoninteractiveAuthenticationContext()
        )
    }

    func saveInstallGrant(_ value: String, account: String) throws {
        try saveUnprotected(
            Data(value.utf8),
            account: installGrantAccount(account),
            usesDataProtectionKeychain: false
        )
    }

    func installGrantExists(account: String) throws -> Bool {
        try legacyItemExists(account: installGrantAccount(account))
    }

    private func rotateInstallGrant(account: String) {
        let previousGrantAccount = installGrantAccount(account)
        grantIdentityStore.rotate(service: service, account: account)
        try? deleteItem(
            account: previousGrantAccount,
            usesDataProtectionKeychain: false,
            authenticationContext: makeNoninteractiveAuthenticationContext()
        )
    }

    private func installGrantAccount(_ account: String) -> String {
        let generation = grantIdentityStore.generation(
            service: service,
            account: account
        )
        return Self.installGrantAccountPrefix
            + APIKeyAppBuildIdentity.current
            + ":"
            + generation
            + ":"
            + account
    }

    private func loadSecureVaultOrLegacy(
        account: String,
        migrateIfNeeded: Bool
    ) throws -> String? {
        if try secureVault.contains(account: account) {
            return try secureVault.load(
                account: account,
                authenticationReason: AppLocalization.localized(
                    "Authenticate to access the saved API key."
                )
            )
        }

        for legacyAccount in [authenticatedLegacyAccount(account), account] {
            guard try legacyItemExists(account: legacyAccount) else { continue }

            // Reading an item created by an older ad-hoc build may show the
            // legacy login-keychain password dialog once. Do not request
            // LocalAuthentication first: that would create two prompts.
            let value = try loadData(
                account: legacyAccount,
                usesDataProtectionKeychain: false
            )
            if migrateIfNeeded, let value {
                try secureVault.save(value, account: account)
                deleteLegacyItemsBestEffort(account: account)
            }
            return value
        }
        return nil
    }

    private func migrateSecureVaultIfNeeded(account: String) throws -> Bool {
        if try secureVault.contains(account: account) {
            return true
        }
        return try loadSecureVaultOrLegacy(account: account, migrateIfNeeded: true) != nil
    }

    private func deleteSecureVaultAndLegacy(account: String) throws {
        try secureVault.delete(account: account)
        deleteLegacyItemsBestEffort(account: account)
    }

    private func deleteLegacyItemsBestEffort(account: String) {
        try? deleteItem(
            account: authenticatedLegacyAccount(account),
            usesDataProtectionKeychain: false,
            authenticationContext: makeNoninteractiveAuthenticationContext()
        )
        try? deleteItem(
            account: account,
            usesDataProtectionKeychain: false,
            authenticationContext: makeNoninteractiveAuthenticationContext()
        )
    }

    private func authenticatedLegacyAccount(_ account: String) -> String {
        Self.authenticatedLegacyAccountPrefix + account
    }

    private func isMissingDataProtectionEntitlement(_ error: Error) -> Bool {
        (error as? KeychainError)?.status == errSecMissingEntitlement
    }

    private func saveProtected(_ data: Data, account: String) throws {
        let accessControl = try makeAccessControl()

        switch try dataProtectionItemState(account: account) {
        case .protected:
            var query = itemQuery(account: account, usesDataProtectionKeychain: true)
            query[kSecUseAuthenticationContext as String] = makeAuthenticationContext(account: account)
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw KeychainError(status: status)
            }
        case .unprotected:
            try deleteItem(account: account, usesDataProtectionKeychain: true)
            do {
                try addProtected(data, account: account, accessControl: accessControl)
            } catch {
                // Preserve the caller-supplied secret if installing the new
                // access-control item unexpectedly fails.
                try? saveUnprotected(data, account: account, usesDataProtectionKeychain: true)
                throw error
            }
        case .absent:
            try addProtected(data, account: account, accessControl: accessControl)
        }

#if os(macOS)
        // Only remove fallback copies after the protected item was saved.
        try? secureVault.delete(account: account)
        deleteLegacyItemsBestEffort(account: account)
#endif
    }

    private func addProtected(
        _ data: Data,
        account: String,
        accessControl: SecAccessControl
    ) throws {
        var query = itemQuery(account: account, usesDataProtectionKeychain: true)
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecAttrComment as String] = Self.userPresenceProtectionMarker
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    private func saveUnprotected(
        _ data: Data,
        account: String,
        usesDataProtectionKeychain: Bool
    ) throws {
        let query = itemQuery(
            account: account,
            usesDataProtectionKeychain: usesDataProtectionKeychain
        )
        let attributes = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw KeychainError(status: status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    private func loadData(
        account: String,
        usesDataProtectionKeychain: Bool,
        authenticationContext: LAContext? = nil
    ) throws -> String? {
        var query = itemQuery(
            account: account,
            usesDataProtectionKeychain: usesDataProtectionKeychain
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func legacyItemExists(account: String) throws -> Bool {
        var query = itemQuery(account: account, usesDataProtectionKeychain: false)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let context = makeNoninteractiveAuthenticationContext()
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainError(status: status)
        }
    }

    private enum DataProtectionItemState: Equatable {
        case absent
        case unprotected
        case protected
    }

    private func dataProtectionItemState(account: String) throws -> DataProtectionItemState {
        var query = itemQuery(account: account, usesDataProtectionKeychain: true)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let context = makeNoninteractiveAuthenticationContext()
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return .absent
        case errSecInteractionNotAllowed:
            return .protected
        case errSecSuccess:
            guard let attributes = item as? [String: Any] else {
                return .unprotected
            }
            return attributes[kSecAttrComment as String] as? String == Self.userPresenceProtectionMarker
                ? .protected
                : .unprotected
        default:
            throw KeychainError(status: status)
        }
    }

    private func deleteItem(
        account: String,
        usesDataProtectionKeychain: Bool,
        authenticationContext: LAContext? = nil
    ) throws {
        var query = itemQuery(
            account: account,
            usesDataProtectionKeychain: usesDataProtectionKeychain
        )
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func itemQuery(
        account: String,
        usesDataProtectionKeychain: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            error?.release()
            throw KeychainError(status: errSecParam)
        }
        return accessControl
    }

    private func makeAuthenticationContext(account: String) -> LAContext {
        APIKeyAuthenticationSession.shared.context(
            service: service,
            account: account,
            localizedReason: AppLocalization.localized(
                "Authenticate to access the saved API key."
            )
        )
    }

    private func makeNoninteractiveAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

enum APIKeyAppBuildIdentity {
    static let current: String = {
        if let executableURL = Bundle.main.executableURL,
           let executableData = try? Data(
               contentsOf: executableURL,
               options: .mappedIfSafe
           ) {
            return String(Hashing.sha256Hex(executableData).prefix(32))
        }

        let fallback = [
            Bundle.main.bundleIdentifier ?? "unknown-bundle",
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        ].joined(separator: ":")
        return String(Hashing.sha256Hex(fallback).prefix(32))
    }()
}

struct APIKeyInstallGrantIdentityStore {
    private static let keyPrefix = "ReadPaper.APIKeyInstallGrant."

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func generation(service: String, account: String) -> String {
        let key = defaultsKey(service: service, account: account)
        if let generation = userDefaults.string(forKey: key) {
            return generation
        }

        let generation = UUID().uuidString
        userDefaults.set(generation, forKey: key)
        return generation
    }

    func rotate(service: String, account: String) {
        userDefaults.set(
            UUID().uuidString,
            forKey: defaultsKey(service: service, account: account)
        )
    }

    private func defaultsKey(service: String, account: String) -> String {
        Self.keyPrefix + Hashing.sha256Hex("\(service)\0\(account)")
    }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        AppLocalization.format("Keychain operation failed with status %d.", status)
    }
}
