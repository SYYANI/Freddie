import Foundation
import SwiftData

enum LLMRouteError: LocalizedError, Equatable {
    case htmlModelNotSelected
    case pdfModelNotSelected
    case assistantModelNotSelected
    case modelNotFound
    case providerNotFound
    case modelDisabled(String)
    case providerDisabled(String)
    case missingAPIKey(String)
    case invalidBaseURL(String)

    var errorDescription: String? {
        switch self {
        case .htmlModelNotSelected:
            return AppLocalization.localized("Choose an HTML translation model in Settings first.")
        case .pdfModelNotSelected:
            return AppLocalization.localized("Choose a PDF translation model in Settings first.")
        case .assistantModelNotSelected:
            return AppLocalization.localized("Choose a reading assistant model in Settings first.")
        case .modelNotFound:
            return AppLocalization.localized("The selected translation model could not be found.")
        case .providerNotFound:
            return AppLocalization.localized("The selected translation provider could not be found.")
        case .modelDisabled(let name):
            return AppLocalization.format("The selected model “%@” is disabled.", name)
        case .providerDisabled(let name):
            return AppLocalization.format("The selected provider “%@” is disabled.", name)
        case .missingAPIKey(let name):
            return AppLocalization.format("No API key is saved for provider “%@”.", name)
        case .invalidBaseURL(let value):
            return AppLocalization.format("The provider Base URL is invalid: %@", value)
        }
    }
}

@MainActor
struct LLMRouteResolver {
    let keychainStore: KeychainStore
    let apiStyleStore: LLMProviderAPIStyleStore
    let userDefaults: UserDefaults

    init(
        keychainStore: KeychainStore = KeychainStore(),
        apiStyleStore: LLMProviderAPIStyleStore = LLMProviderAPIStyleStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.keychainStore = keychainStore
        self.apiStyleStore = apiStyleStore
        self.userDefaults = userDefaults
    }

    func resolveHTMLRoute(
        settings: AppSettings,
        modelContext: ModelContext
    ) throws -> ResolvedLLMModelRoute {
        try resolve(
            selectedModelID: settings.selectedHTMLModelProfileID,
            missingSelectionError: .htmlModelNotSelected,
            modelContext: modelContext
        )
    }

    func resolvePDFRoute(
        settings: AppSettings,
        modelContext: ModelContext
    ) throws -> ResolvedLLMModelRoute {
        try resolve(
            selectedModelID: settings.selectedPDFModelProfileID,
            missingSelectionError: .pdfModelNotSelected,
            modelContext: modelContext
        )
    }

    func resolveAssistantRoute(
        settings: AppSettings,
        modelContext: ModelContext
    ) throws -> ResolvedLLMModelRoute {
        let storedValue = userDefaults.string(
            forKey: SelectionAssistantPreferences.selectedModelProfileIDKey
        )
        let selectedModelID = storedValue.flatMap(UUID.init(uuidString:))
            ?? settings.selectedHTMLModelProfileID
        return try resolve(
            selectedModelID: selectedModelID,
            missingSelectionError: .assistantModelNotSelected,
            modelContext: modelContext
        )
    }

    private func resolve(
        selectedModelID: UUID?,
        missingSelectionError: LLMRouteError,
        modelContext: ModelContext
    ) throws -> ResolvedLLMModelRoute {
        guard let selectedModelID else {
            throw missingSelectionError
        }

        let models = try modelContext.fetch(FetchDescriptor<LLMModelProfile>())
        guard let model = models.first(where: { $0.id == selectedModelID }) else {
            throw LLMRouteError.modelNotFound
        }
        guard model.isEnabled else {
            throw LLMRouteError.modelDisabled(model.name)
        }

        let providers = try modelContext.fetch(FetchDescriptor<LLMProviderProfile>())
        guard let provider = providers.first(where: { $0.id == model.providerID }) else {
            throw LLMRouteError.providerNotFound
        }
        guard provider.isEnabled else {
            throw LLMRouteError.providerDisabled(provider.name)
        }
        guard URL(string: provider.baseURL) != nil else {
            throw LLMRouteError.invalidBaseURL(provider.baseURL)
        }

        let apiKey = try keychainStore.load(account: provider.apiKeyRef)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard apiKey.isEmpty == false else {
            throw LLMRouteError.missingAPIKey(provider.name)
        }

        return ResolvedLLMModelRoute(
            snapshot: LLMModelRouteSnapshot(
                providerProfileID: provider.id,
                providerName: provider.name,
                modelProfileID: model.id,
                modelProfileName: model.name,
                baseURL: provider.baseURL,
                apiStyle: apiStyleStore.apiStyle(for: provider.id),
                apiKeyRef: provider.apiKeyRef,
                modelName: model.modelName,
                temperature: model.temperature,
                topP: model.topP,
                maxTokens: model.maxTokens,
                thinkingMode: model.thinkingModeValue,
                reasoningEffort: model.reasoningEffortValue
            ),
            apiKey: apiKey
        )
    }
}
