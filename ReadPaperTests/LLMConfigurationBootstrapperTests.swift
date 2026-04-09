import SwiftData
import XCTest
@testable import ReadPaper

final class LLMConfigurationBootstrapperTests: XCTestCase {
    @MainActor
    func testBootstrapMigratesLegacySettingsIntoProviderAndModels() throws {
        let keychainService = "LLMConfigurationBootstrapperTests.\(UUID().uuidString)"
        let keychainStore = KeychainStore(service: keychainService)
        let bootstrapper = LLMConfigurationBootstrapper(keychainStore: keychainStore)
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let settings = AppSettings(
            openAIBaseURL: "https://api.example.com/proxy/v1/",
            normalModelName: "normal-model",
            quickModelName: "quick-model",
            heavyModelName: "heavy-model",
            targetLanguage: "zh-CN",
            htmlTranslationConcurrency: 4,
            babelDocQPS: 4,
            babelDocVersion: "0.5.24"
        )
        modelContext.insert(settings)
        try modelContext.save()
        try keychainStore.save("sk-legacy", account: KeychainStore.legacyOpenAIAPIKeyAccount)

        let bootstrappedSettings = try bootstrapper.ensureBootstrap(modelContext: modelContext)
        let providers = try modelContext.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try modelContext.fetch(FetchDescriptor<LLMModelProfile>())

        XCTAssertTrue(bootstrappedSettings.didBootstrapLLMProfiles)
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(providers.first?.baseURL, "https://api.example.com/proxy/v1")

        let heavyModel = try XCTUnwrap(models.first(where: { $0.modelName == "heavy-model" }))
        XCTAssertEqual(bootstrappedSettings.selectedHTMLModelProfileID, heavyModel.id)
        XCTAssertEqual(bootstrappedSettings.selectedPDFModelProfileID, heavyModel.id)

        let migratedAPIKey = try keychainStore.load(account: try XCTUnwrap(providers.first?.apiKeyRef))
        XCTAssertEqual(migratedAPIKey, "sk-legacy")
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AppSettings.self,
            LLMProviderProfile.self,
            LLMModelProfile.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }
}
