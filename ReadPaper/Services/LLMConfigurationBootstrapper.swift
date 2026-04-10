import Foundation
import SwiftData

@MainActor
struct LLMConfigurationBootstrapper {
    private static let bootstrappedProviderName = "Default Provider"
    private static let bootstrappedModelProfiles = [
        ("Primary Model", \AppSettings.heavyModelName),
        ("Balanced Model", \AppSettings.normalModelName),
        ("Fast Model", \AppSettings.quickModelName)
    ]

    let keychainStore: KeychainStore
    let validator: LLMProviderValidationUseCase

    init(
        keychainStore: KeychainStore = KeychainStore(),
        validator: LLMProviderValidationUseCase = LLMProviderValidationUseCase()
    ) {
        self.keychainStore = keychainStore
        self.validator = validator
    }

    @discardableResult
    func ensureBootstrap(modelContext: ModelContext) throws -> AppSettings {
        let settings = try ensureSettingsRow(modelContext: modelContext)
        let providers = try modelContext.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try modelContext.fetch(FetchDescriptor<LLMModelProfile>())

        if providers.isEmpty == false || models.isEmpty == false {
            if settings.didBootstrapLLMProfiles == false {
                settings.didBootstrapLLMProfiles = true
                settings.modifiedAt = Date()
                try modelContext.save()
            }
            return settings
        }

        guard settings.didBootstrapLLMProfiles == false else {
            return settings
        }

        let normalizedBaseURL = try validator.normalizedBaseURL(settings.openAIBaseURL)
        let providerID = UUID()
        let providerAPIKeyRef = Self.makeAPIKeyRef(providerID: providerID)
        let provider = LLMProviderProfile(
            id: providerID,
            name: Self.bootstrappedProviderName,
            baseURL: normalizedBaseURL,
            apiKeyRef: providerAPIKeyRef,
            testModel: settings.heavyModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? settings.normalModelName : settings.heavyModelName
        )
        modelContext.insert(provider)

        var createdModelIDsByName: [String: UUID] = [:]
        for (profileName, keyPath) in Self.bootstrappedModelProfiles {
            let rawModelName = settings[keyPath: keyPath]
            let trimmed = rawModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            guard createdModelIDsByName[trimmed] == nil else { continue }
            let model = LLMModelProfile(
                providerID: providerID,
                name: profileName,
                modelName: trimmed
            )
            modelContext.insert(model)
            createdModelIDsByName[trimmed] = model.id
        }

        let heavyModelName = settings.heavyModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultModelID = createdModelIDsByName[heavyModelName] ?? createdModelIDsByName.values.first

        settings.selectedHTMLModelProfileID = defaultModelID
        settings.selectedPDFModelProfileID = defaultModelID
        settings.didBootstrapLLMProfiles = true
        settings.modifiedAt = Date()

        if let legacyAPIKey = try keychainStore.load(account: KeychainStore.legacyOpenAIAPIKeyAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           legacyAPIKey.isEmpty == false {
            try keychainStore.save(legacyAPIKey, account: providerAPIKeyRef)
        }

        try modelContext.save()
        return settings
    }

    private func ensureSettingsRow(modelContext: ModelContext) throws -> AppSettings {
        let rows = try modelContext.fetch(FetchDescriptor<AppSettings>())
        if let settings = rows.first {
            return settings
        }
        let settings = AppSettings()
        modelContext.insert(settings)
        try modelContext.save()
        return settings
    }

    static func makeAPIKeyRef(providerID: UUID) -> String {
        "llm-provider-\(providerID.uuidString.lowercased())"
    }
}
