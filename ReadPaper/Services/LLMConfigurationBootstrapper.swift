import Foundation
import SwiftData

@MainActor
struct LLMConfigurationBootstrapper {
    @discardableResult
    func ensureBootstrap(modelContext: ModelContext) throws -> AppSettings {
        try ensureSettingsRow(modelContext: modelContext)
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

enum LLMDefaultProfiles {
    struct ProviderDescriptor: Sendable {
        let id: UUID
        let name: String
        let baseURL: String
        let testModel: String
        let apiStyle: LLMAPIStyle
        /// Where the quick setup sends people to create an API key.
        let apiKeyPageURL: URL
        let model: ModelDescriptor
    }

    struct ModelDescriptor: Sendable {
        let id: UUID
        let name: String
        let modelName: String
        let thinkingMode: LLMThinkingMode?
        let reasoningEffort: LLMReasoningEffort?
    }

    static let openAIProviderID = UUID(uuidString: "1C613F2B-6209-4E63-B9E1-9DFB415B6CD3")!
    static let openAIModelID = UUID(uuidString: "5B97C710-AB92-48A1-93CB-F31BDF4C79A1")!
    static let deepSeekProviderID = UUID(uuidString: "71C0BB1C-D797-431F-8BD0-96E0A8C579B5")!
    static let deepSeekModelID = UUID(uuidString: "6D6E7DC3-FF41-456A-B04D-30B943130968")!
    static let anthropicProviderID = UUID(uuidString: "E92E2D96-5184-4522-8FB5-DF1FC53621AC")!
    static let anthropicModelID = UUID(uuidString: "6FCEAC56-F86C-4300-915A-45029950510F")!

    static let providers: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: openAIProviderID,
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            testModel: "gpt-5.6-terra",
            apiStyle: .responses,
            apiKeyPageURL: URL(string: "https://platform.openai.com/api-keys")!,
            model: ModelDescriptor(
                id: openAIModelID,
                name: "OpenAI GPT-5.6 Terra",
                modelName: "gpt-5.6-terra",
                thinkingMode: .disabled,
                reasoningEffort: nil
            )
        ),
        ProviderDescriptor(
            id: deepSeekProviderID,
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            testModel: "deepseek-v4-flash",
            apiStyle: .responses,
            apiKeyPageURL: URL(string: "https://platform.deepseek.com/api_keys")!,
            model: ModelDescriptor(
                id: deepSeekModelID,
                name: "DeepSeek V4 Flash",
                modelName: "deepseek-v4-flash",
                thinkingMode: .disabled,
                reasoningEffort: nil
            )
        ),
        ProviderDescriptor(
            id: anthropicProviderID,
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            testModel: "claude-opus-5-5",
            apiStyle: .anthropicMessages,
            apiKeyPageURL: URL(string: "https://console.anthropic.com/settings/keys")!,
            model: ModelDescriptor(
                id: anthropicModelID,
                name: "Claude Opus 5.5",
                modelName: "claude-opus-5-5",
                // Claude Opus 5.5 rejects disabled thinking; leave thinking
                // and effort at the model defaults.
                thinkingMode: nil,
                reasoningEffort: nil
            )
        ),
    ]

    static func provider(for providerID: UUID) -> ProviderDescriptor? {
        providers.first { $0.id == providerID }
    }

    static func provider(forModelID modelID: UUID) -> ProviderDescriptor? {
        providers.first { $0.model.id == modelID }
    }

    static func apiStyle(for providerID: UUID) -> LLMAPIStyle? {
        provider(for: providerID)?.apiStyle
    }

    static func isBuiltInProvider(_ providerID: UUID) -> Bool {
        provider(for: providerID) != nil
    }

    static func isBuiltInModel(_ modelID: UUID) -> Bool {
        provider(forModelID: modelID) != nil
    }

    static func defaultModelID(for providerID: UUID) -> UUID? {
        provider(for: providerID)?.model.id
    }
}

struct LLMDefaultProfileDeletionStore {
    private static let deletedProviderIDsKey = "llm-default-profiles.deleted-provider-ids"
    private static let deletedModelIDsKey = "llm-default-profiles.deleted-model-ids"

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func containsProvider(_ providerID: UUID) -> Bool {
        deletedProviderIDs.contains(providerID.uuidString.lowercased())
    }

    func containsModel(_ modelID: UUID) -> Bool {
        deletedModelIDs.contains(modelID.uuidString.lowercased())
    }

    func markProviderDeleted(_ providerID: UUID) {
        var ids = deletedProviderIDs
        ids.insert(providerID.uuidString.lowercased())
        userDefaults.set(Array(ids).sorted(), forKey: Self.deletedProviderIDsKey)
    }

    func markModelDeleted(_ modelID: UUID) {
        var ids = deletedModelIDs
        ids.insert(modelID.uuidString.lowercased())
        userDefaults.set(Array(ids).sorted(), forKey: Self.deletedModelIDsKey)
    }

    private var deletedProviderIDs: Set<String> {
        Set(userDefaults.stringArray(forKey: Self.deletedProviderIDsKey) ?? [])
    }

    private var deletedModelIDs: Set<String> {
        Set(userDefaults.stringArray(forKey: Self.deletedModelIDsKey) ?? [])
    }
}

@MainActor
struct LLMDefaultProfileSeeder {
    let apiStyleStore: LLMProviderAPIStyleStore
    let deletionStore: LLMDefaultProfileDeletionStore

    init(
        apiStyleStore: LLMProviderAPIStyleStore = LLMProviderAPIStyleStore(),
        deletionStore: LLMDefaultProfileDeletionStore = LLMDefaultProfileDeletionStore()
    ) {
        self.apiStyleStore = apiStyleStore
        self.deletionStore = deletionStore
    }

    func ensureDefaults(modelContext: ModelContext) throws {
        let existingProviders = try modelContext.fetch(FetchDescriptor<LLMProviderProfile>())
        let existingProviderIDs = Set(existingProviders.map(\.id))
        let existingModels = try modelContext.fetch(FetchDescriptor<LLMModelProfile>())
        let existingModelIDs = Set(existingModels.map(\.id))
        let now = Date()
        var changed = false

        for descriptor in LLMDefaultProfiles.providers {
            let providerWasDeleted = deletionStore.containsProvider(descriptor.id)

            if !existingProviderIDs.contains(descriptor.id), !providerWasDeleted {
                modelContext.insert(LLMProviderProfile(
                    id: descriptor.id,
                    name: descriptor.name,
                    baseURL: descriptor.baseURL,
                    apiKeyRef: LLMConfigurationBootstrapper.makeAPIKeyRef(providerID: descriptor.id),
                    testModel: descriptor.testModel,
                    isEnabled: true,
                    createdAt: now,
                    modifiedAt: now
                ))
                apiStyleStore.setAPIStyle(descriptor.apiStyle, for: descriptor.id)
                changed = true
            }

            if !providerWasDeleted,
               !existingModelIDs.contains(descriptor.model.id),
               !deletionStore.containsModel(descriptor.model.id) {
                modelContext.insert(LLMModelProfile(
                    id: descriptor.model.id,
                    providerID: descriptor.id,
                    name: descriptor.model.name,
                    modelName: descriptor.model.modelName,
                    thinkingMode: descriptor.model.thinkingMode,
                    reasoningEffort: descriptor.model.reasoningEffort,
                    isEnabled: true,
                    createdAt: now,
                    modifiedAt: now
                ))
                changed = true
            }
        }

        if changed {
            try modelContext.save()
        }
    }
}

@MainActor
struct LLMDefaultRouteActivator {
    func selectRoutesIfNeeded(
        for providerID: UUID,
        settings: AppSettings,
        providers: [LLMProviderProfile],
        models: [LLMModelProfile],
        hasStoredAPIKey: (String) -> Bool
    ) {
        guard let descriptor = LLMDefaultProfiles.provider(for: providerID),
              providers.contains(where: { $0.id == providerID && $0.isEnabled }),
              models.contains(where: {
                  $0.id == descriptor.model.id && $0.providerID == providerID && $0.isEnabled
              })
        else { return }
        let defaultModelID = descriptor.model.id

        if !routeIsReady(
            settings.selectedHTMLModelProfileID,
            newlyReadyProviderID: providerID,
            providers: providers,
            models: models,
            hasStoredAPIKey: hasStoredAPIKey
        ) {
            settings.selectedHTMLModelProfileID = defaultModelID
        }
        if !routeIsReady(
            settings.selectedPDFModelProfileID,
            newlyReadyProviderID: providerID,
            providers: providers,
            models: models,
            hasStoredAPIKey: hasStoredAPIKey
        ) {
            settings.selectedPDFModelProfileID = defaultModelID
        }
    }

    private func routeIsReady(
        _ modelID: UUID?,
        newlyReadyProviderID: UUID,
        providers: [LLMProviderProfile],
        models: [LLMModelProfile],
        hasStoredAPIKey: (String) -> Bool
    ) -> Bool {
        guard let modelID,
              let model = models.first(where: { $0.id == modelID }),
              model.isEnabled,
              let provider = providers.first(where: { $0.id == model.providerID }),
              provider.isEnabled
        else { return false }
        return provider.id == newlyReadyProviderID || hasStoredAPIKey(provider.apiKeyRef)
    }
}

/// The connection the quick setup tests before it changes anything.
struct LLMQuickSetupTarget: Equatable {
    let baseURL: String
    let apiStyle: LLMAPIStyle
    let modelName: String
    let modelDisplayName: String
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?
    let thinkingMode: LLMThinkingMode?
    let reasoningEffort: LLMReasoningEffort?
}

/// One-step setup for a built-in provider: save its API key and route HTML and
/// PDF translation to its default model. Saved profiles win over the built-in
/// descriptor, so edits such as a proxy base URL or another model name are
/// kept; profiles the user deleted or disabled are restored.
@MainActor
struct LLMQuickSetup {
    let apiStyleStore: LLMProviderAPIStyleStore

    init(apiStyleStore: LLMProviderAPIStyleStore = LLMProviderAPIStyleStore()) {
        self.apiStyleStore = apiStyleStore
    }

    func target(
        for descriptor: LLMDefaultProfiles.ProviderDescriptor,
        providers: [LLMProviderProfile],
        models: [LLMModelProfile]
    ) -> LLMQuickSetupTarget {
        let provider = providers.first { $0.id == descriptor.id }
        let model = models.first { $0.id == descriptor.model.id }
        return LLMQuickSetupTarget(
            baseURL: provider?.baseURL ?? descriptor.baseURL,
            apiStyle: provider == nil ? descriptor.apiStyle : apiStyleStore.apiStyle(for: descriptor.id),
            modelName: model?.modelName ?? descriptor.model.modelName,
            modelDisplayName: model?.name ?? descriptor.model.name,
            temperature: model?.temperature,
            topP: model?.topP,
            maxTokens: model?.maxTokens,
            thinkingMode: model == nil ? descriptor.model.thinkingMode : model?.thinkingModeValue,
            reasoningEffort: model == nil ? descriptor.model.reasoningEffort : model?.reasoningEffortValue
        )
    }

    /// Call only after the connection test passed. A nil `apiKey` keeps the
    /// provider's stored key. The key is saved before any model change, so a
    /// Keychain failure leaves the store untouched.
    @discardableResult
    func apply(
        descriptor: LLMDefaultProfiles.ProviderDescriptor,
        apiKey: String?,
        testedAt: Date,
        settings: AppSettings,
        modelContext: ModelContext,
        saveAPIKey: (_ value: String, _ account: String) throws -> Void
    ) throws -> LLMModelProfile {
        let providerID = descriptor.id
        let modelID = descriptor.model.id
        let existingProvider = try modelContext.fetch(
            FetchDescriptor<LLMProviderProfile>(predicate: #Predicate { $0.id == providerID })
        ).first
        let existingModel = try modelContext.fetch(
            FetchDescriptor<LLMModelProfile>(predicate: #Predicate { $0.id == modelID })
        ).first
        let apiKeyRef = existingProvider?.apiKeyRef
            ?? LLMConfigurationBootstrapper.makeAPIKeyRef(providerID: providerID)

        if let apiKey {
            try saveAPIKey(apiKey, apiKeyRef)
        }

        let provider: LLMProviderProfile
        if let existingProvider {
            provider = existingProvider
        } else {
            provider = LLMProviderProfile(
                id: providerID,
                name: descriptor.name,
                baseURL: descriptor.baseURL,
                apiKeyRef: apiKeyRef,
                testModel: descriptor.testModel,
                createdAt: testedAt,
                modifiedAt: testedAt
            )
            modelContext.insert(provider)
            apiStyleStore.setAPIStyle(descriptor.apiStyle, for: providerID)
        }
        provider.isEnabled = true
        provider.modifiedAt = testedAt

        let model: LLMModelProfile
        if let existingModel {
            model = existingModel
        } else {
            model = LLMModelProfile(
                id: modelID,
                providerID: providerID,
                name: descriptor.model.name,
                modelName: descriptor.model.modelName,
                thinkingMode: descriptor.model.thinkingMode,
                reasoningEffort: descriptor.model.reasoningEffort,
                createdAt: testedAt,
                modifiedAt: testedAt
            )
            modelContext.insert(model)
        }
        model.providerID = providerID
        model.isEnabled = true
        model.lastTestedAt = testedAt
        model.modifiedAt = testedAt

        settings.selectedHTMLModelProfileID = modelID
        settings.selectedPDFModelProfileID = modelID
        settings.modifiedAt = testedAt
        try modelContext.save()
        return model
    }
}

/// Whether HTML or PDF translation can start without a visit to Settings. Judged
/// from what is stored, without reading an API key: reading one asks for Touch ID.
@MainActor
enum LLMTranslationSetupStatus {
    static func hasUsableRoute(
        settings: AppSettings,
        modelContext: ModelContext,
        hasStoredAPIKey: (String) -> Bool
    ) -> Bool {
        let routedModelIDs = [settings.selectedHTMLModelProfileID, settings.selectedPDFModelProfileID]
            .compactMap { $0 }
        guard routedModelIDs.isEmpty == false,
              let providers = try? modelContext.fetch(FetchDescriptor<LLMProviderProfile>()),
              let models = try? modelContext.fetch(FetchDescriptor<LLMModelProfile>())
        else { return false }
        return hasUsableRoute(
            settings: settings,
            providers: providers,
            models: models,
            hasStoredAPIKey: hasStoredAPIKey
        )
    }

    static func hasUsableRoute(
        settings: AppSettings,
        providers: [LLMProviderProfile],
        models: [LLMModelProfile],
        hasStoredAPIKey: (String) -> Bool
    ) -> Bool {
        [settings.selectedHTMLModelProfileID, settings.selectedPDFModelProfileID].contains { modelID in
            guard let modelID,
                  let model = models.first(where: { $0.id == modelID }),
                  model.isEnabled,
                  let provider = providers.first(where: { $0.id == model.providerID }),
                  provider.isEnabled
            else { return false }
            return hasStoredAPIKey(provider.apiKeyRef)
        }
    }
}
