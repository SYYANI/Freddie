import CryptoKit
import LocalAuthentication
import XCTest
@testable import ReadPaper

@MainActor
final class SecureAPIKeyVaultTests: XCTestCase {
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
