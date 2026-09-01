import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct SecureAPIKeyVault {
    private struct Envelope: Codable {
        let version: Int
        let secureEnclavePrivateKey: Data
        let ephemeralPublicKey: Data
        let sealedSecret: Data
    }

    private static let envelopeVersion = 2

    let service: String
    let fileManager: FileManager
    private let applicationSupportDirectoryOverride: URL?

    init(
        service: String,
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.service = service
        self.fileManager = fileManager
        self.applicationSupportDirectoryOverride = applicationSupportDirectory
    }

    func save(_ value: String, account: String) throws {
        guard SecureEnclave.isAvailable else {
            throw SecureAPIKeyVaultError.secureEnclaveUnavailable
        }
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            nil
        ) else {
            throw SecureAPIKeyVaultError.cannotCreateAccessControl
        }

        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            accessControl: accessControl
        )
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(
            with: enclaveKey.publicKey
        )
        let symmetricKey = derivedKey(
            from: sharedSecret,
            account: account
        )
        let sealedBox = try AES.GCM.seal(Data(value.utf8), using: symmetricKey)
        guard let combined = sealedBox.combined else {
            throw SecureAPIKeyVaultError.cannotEncodeEnvelope
        }

        let envelope = Envelope(
            version: Self.envelopeVersion,
            secureEnclavePrivateKey: enclaveKey.dataRepresentation,
            ephemeralPublicKey: ephemeralKey.publicKey.x963Representation,
            sealedSecret: combined
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encodedEnvelope = try encoder.encode(envelope)

        let directory = try vaultDirectory()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let destination = try envelopeURL(account: account)
        try encodedEnvelope.write(to: destination, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    @MainActor
    func load(
        account: String,
        authenticationReason: String,
        authenticationContext: LAContext? = nil
    ) throws -> String? {
        let source = try envelopeURL(account: account)
        guard fileManager.fileExists(atPath: source.path) else {
            return nil
        }
        guard SecureEnclave.isAvailable else {
            throw SecureAPIKeyVaultError.secureEnclaveUnavailable
        }

        let encodedEnvelope = try Data(contentsOf: source)
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: encodedEnvelope)
        guard envelope.version == Self.envelopeVersion else {
            throw SecureAPIKeyVaultError.invalidEnvelope
        }

        let usesSharedContext = authenticationContext == nil
        let context = authenticationContext ?? APIKeyAuthenticationSession.shared.context(
            service: service,
            account: account,
            localizedReason: authenticationReason
        )
        context.localizedReason = authenticationReason
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: envelope.secureEnclavePrivateKey,
                authenticationContext: context
            )
            let ephemeralPublicKey = try P256.KeyAgreement.PublicKey(
                x963Representation: envelope.ephemeralPublicKey
            )
            let sharedSecret = try enclaveKey.sharedSecretFromKeyAgreement(
                with: ephemeralPublicKey
            )
            let symmetricKey = derivedKey(from: sharedSecret, account: account)
            let sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedSecret)
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
            guard let value = String(data: plaintext, encoding: .utf8) else {
                throw SecureAPIKeyVaultError.invalidEnvelope
            }
            return value
        } catch {
            if usesSharedContext {
                APIKeyAuthenticationSession.shared.invalidate(
                    service: service,
                    account: account
                )
            }
            throw error
        }
    }

    func contains(account: String) throws -> Bool {
        let source = try envelopeURL(account: account)
        guard fileManager.fileExists(atPath: source.path) else { return false }
        let encodedEnvelope = try Data(contentsOf: source)
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: encodedEnvelope)
        return envelope.version == Self.envelopeVersion
    }

    func delete(account: String) throws {
        let url = try envelopeURL(account: account)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func derivedKey(
        from sharedSecret: SharedSecret,
        account: String
    ) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("\(service)\0\(account)".utf8),
            outputByteCount: 32
        )
    }

    private func envelopeURL(account: String) throws -> URL {
        try vaultDirectory()
            .appendingPathComponent(
                Hashing.sha256Hex("\(service)\0\(account)") + ".vault",
                isDirectory: false
            )
    }

    private func vaultDirectory() throws -> URL {
        let applicationSupportDirectory: URL
        if let applicationSupportDirectoryOverride {
            applicationSupportDirectory = applicationSupportDirectoryOverride
        } else {
            applicationSupportDirectory = try PaperFileStore(
                fileManager: fileManager
            ).applicationSupportDirectory
        }
        return applicationSupportDirectory
            .appendingPathComponent("SecureSecrets", isDirectory: true)
    }
}

@MainActor
final class APIKeyAuthenticationSession {
    static let shared = APIKeyAuthenticationSession()

    private var contexts: [String: LAContext] = [:]

    func context(
        service: String,
        account: String,
        localizedReason: String
    ) -> LAContext {
        let key = cacheKey(service: service, account: account)
        if let context = contexts[key] {
            context.localizedReason = localizedReason
            return context
        }

        let context = LAContext()
        context.localizedReason = localizedReason
        contexts[key] = context
        return context
    }

    func invalidate(service: String, account: String) {
        let key = cacheKey(service: service, account: account)
        contexts.removeValue(forKey: key)?.invalidate()
    }

    private func cacheKey(service: String, account: String) -> String {
        "\(service)\0\(account)"
    }
}

enum SecureAPIKeyVaultError: LocalizedError {
    case secureEnclaveUnavailable
    case cannotCreateAccessControl
    case cannotEncodeEnvelope
    case invalidEnvelope

    var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable:
            return AppLocalization.localized("Secure Enclave is unavailable on this device.")
        case .cannotCreateAccessControl:
            return AppLocalization.localized("Could not create access control for the saved API key.")
        case .cannotEncodeEnvelope:
            return AppLocalization.localized("Could not protect the API key for storage.")
        case .invalidEnvelope:
            return AppLocalization.localized("The protected API key data is invalid.")
        }
    }
}
