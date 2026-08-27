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

    static let providers: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: openAIProviderID,
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            testModel: "gpt-5.6-terra",
            apiStyle: .responses,
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
            model: ModelDescriptor(
                id: deepSeekModelID,
                name: "DeepSeek V4 Flash",
                modelName: "deepseek-v4-flash",
                thinkingMode: .disabled,
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
        guard let defaultModelID = LLMDefaultProfiles.defaultModelID(for: providerID),
              providers.contains(where: { $0.id == providerID && $0.isEnabled }),
              models.contains(where: {
                  $0.id == defaultModelID && $0.providerID == providerID && $0.isEnabled
              })
        else { return }

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
