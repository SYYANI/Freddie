import CryptoKit
import LocalAuthentication
import Security
import XCTest
#if os(iOS)
@testable import ReadPaperiPad
#else
@testable import ReadPaper
#endif

@MainActor
final class SecureAPIKeyVaultTests: XCTestCase {
#if os(macOS)
    // The Secure Enclave vault is the fallback for ad-hoc macOS builds.
    // iPad credentials use the data-protection keychain directly.
    func testSaveContainsAndDeleteEnvelopeWithoutKeychainEntitlements() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave is unavailable on this Mac.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureAPIKeyVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = SecureAPIKeyVault(
            service: "SecureAPIKeyVaultTests",
            applicationSupportDirectory: directory
        )
        let account = "provider-key"

        XCTAssertFalse(try vault.contains(account: account))
        try vault.save("temporary-secret", account: account)
        XCTAssertTrue(try vault.contains(account: account))

        let noninteractiveContext = LAContext()
        noninteractiveContext.interactionNotAllowed = true
        XCTAssertThrowsError(try vault.load(
            account: account,
            authenticationReason: "Test protected key operation",
            authenticationContext: noninteractiveContext
        )) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, LAError.errorDomain)
            XCTAssertEqual(error.code, LAError.Code.notInteractive.rawValue)
        }

        try vault.delete(account: account)
        XCTAssertFalse(try vault.contains(account: account))
    }
#endif

    func testAuthenticationContextIsReusedUntilInvalidated() {
        let session = APIKeyAuthenticationSession()
        let first = session.context(
            service: "service",
            account: "account",
            localizedReason: "First reason"
        )
        let second = session.context(
            service: "service",
            account: "account",
            localizedReason: "Second reason"
        )

        XCTAssertTrue(first === second)
        XCTAssertEqual(second.localizedReason, "Second reason")

        session.invalidate(service: "service", account: "account")
        let replacement = session.context(
            service: "service",
            account: "account",
            localizedReason: "Replacement reason"
        )
        XCTAssertFalse(first === replacement)
    }

    func testServiceAuthenticationIsSharedAcrossProvidersAndIsolatedFromOtherServices() {
        let session = APIKeyAuthenticationSession(scope: .service)
        let first = session.context(service: "app", account: "provider-a", localizedReason: "Unlock")
        let second = session.context(service: "app", account: "provider-b", localizedReason: "Reuse")
        let other = session.context(service: "other-app", account: "provider-a", localizedReason: "Other")

        XCTAssertTrue(first === second)
        XCTAssertFalse(first === other)
        session.invalidate(service: "app", account: "provider-b")
        XCTAssertFalse(first === session.context(service: "app", account: "provider-a", localizedReason: "Retry"))
        XCTAssertTrue(other === session.context(service: "other-app", account: "provider-a", localizedReason: "Reuse"))
    }

#if os(iOS)
    func testPlatformSessionSharesAuthenticationAcrossProviders() {
        let session = APIKeyAuthenticationSession()
        XCTAssertTrue(
            session.context(service: "app", account: "provider-a", localizedReason: "Unlock")
                === session.context(service: "app", account: "provider-b", localizedReason: "Reuse")
        )
    }

    func testSavingProviderKeepsOtherProviderAuthenticationAndGrantsImmediateAccess() throws {
        let service = "APIKeySharedAuthenticationTests.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        defer { try? store.delete(account: "provider-b") }
        let context = APIKeyAuthenticationSession.shared.context(
            service: service, account: "provider-a", localizedReason: "Unlock"
        )

        try store.save("temporary-secret", account: "provider-b")

        XCTAssertTrue(context === APIKeyAuthenticationSession.shared.context(
            service: service, account: "provider-a", localizedReason: "Reuse"
        ))
        XCTAssertEqual(try store.loadInstallGrant(account: "provider-b"), "temporary-secret")
        XCTAssertEqual(try KeychainStore(service: service).load(account: "provider-b"), "temporary-secret")

        try store.delete(account: "provider-b")
        XCTAssertFalse(try store.contains(account: "provider-b"))
        XCTAssertNil(try store.loadInstallGrant(account: "provider-b"))
        XCTAssertTrue(context === APIKeyAuthenticationSession.shared.context(
            service: service, account: "provider-a", localizedReason: "Reuse after deletion"
        ))
    }

    func testLoadingExistingProviderPreparesOtherProvidersForFutureLaunches() throws {
        let service = "APIKeySharedGrantTests.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        let accounts = ["provider-a", "provider-b"]
        defer { for account in accounts { try? store.delete(account: account) } }

        // The production marker drives the legacy-item path; omit user-presence
        // ACLs in these fixtures so this test never requests biometric interaction.
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrComment as String: "Freddie.user-presence.v1",
                kSecUseDataProtectionKeychain as String: true,
                kSecValueData as String: Data("test-\(account)".utf8)
            ]
            XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        }

        XCTAssertEqual(try store.load(account: "provider-a"), "test-provider-a")
        XCTAssertEqual(try store.loadInstallGrant(account: "provider-b"), "test-provider-b")

        APIKeyAuthenticationSession.shared.invalidate(service: service, account: "provider-a")
        let relaunchedStore = KeychainStore(service: service)
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true
            ]
            XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
            XCTAssertEqual(try relaunchedStore.load(account: account), "test-\(account)")
        }
    }
#endif

    func testInstallGrantGenerationPersistsAndRotates() throws {
        let suiteName = "APIKeyInstallGrantIdentityStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = APIKeyInstallGrantIdentityStore(userDefaults: defaults)

        let initial = store.generation(service: "service", account: "account")
        XCTAssertEqual(
            store.generation(service: "service", account: "account"),
            initial
        )

        store.rotate(service: "service", account: "account")
        XCTAssertNotEqual(
            store.generation(service: "service", account: "account"),
            initial
        )
    }

    func testInstallGrantCanBeReadWithoutInteraction() throws {
        let keychainStore = KeychainStore(
            service: "APIKeyInstallGrantTests.\(UUID().uuidString)"
        )
        let account = "provider-key"
        defer { try? keychainStore.delete(account: account) }

        XCTAssertFalse(try keychainStore.installGrantExists(account: account))
        try keychainStore.saveInstallGrant("temporary-secret", account: account)

        XCTAssertTrue(try keychainStore.installGrantExists(account: account))
        XCTAssertEqual(
            try keychainStore.loadInstallGrant(account: account),
            "temporary-secret"
        )
    }
}
