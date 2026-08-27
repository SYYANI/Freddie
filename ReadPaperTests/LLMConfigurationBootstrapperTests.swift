import SwiftData
import XCTest
@testable import ReadPaper

final class LLMConfigurationBootstrapperTests: XCTestCase {
    @MainActor
    func testBootstrapCreatesSettingsRowWhenMissing() throws {
        let bootstrapper = LLMConfigurationBootstrapper()
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let bootstrappedSettings = try bootstrapper.ensureBootstrap(modelContext: modelContext)
        let settingsRows = try modelContext.fetch(FetchDescriptor<AppSettings>())
        let providers = try modelContext.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try modelContext.fetch(FetchDescriptor<LLMModelProfile>())

        XCTAssertEqual(settingsRows.count, 1)
        XCTAssertEqual(bootstrappedSettings.id, settingsRows.first?.id)
        XCTAssertEqual(providers.count, 0)
        XCTAssertEqual(models.count, 0)
    }

    @MainActor
    func testBootstrapReturnsExistingSettingsRow() throws {
        let bootstrapper = LLMConfigurationBootstrapper()
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let settings = AppSettings(targetLanguage: "en")
        let provider = LLMProviderProfile(
            name: "Provider",
            baseURL: "https://api.example.com/v1",
            apiKeyRef: "provider-ref",
            testModel: "gpt-test"
        )
        modelContext.insert(settings)
        modelContext.insert(provider)
        try modelContext.save()

        let bootstrappedSettings = try bootstrapper.ensureBootstrap(modelContext: modelContext)
        let settingsRows = try modelContext.fetch(FetchDescriptor<AppSettings>())

        XCTAssertEqual(settingsRows.count, 1)
        XCTAssertEqual(bootstrappedSettings.id, settings.id)
        XCTAssertEqual(bootstrappedSettings.targetLanguage, "en")
    }

    @MainActor
    func testInspectorCollapsedFieldHasDefaultValue() throws {
        let bootstrapper = LLMConfigurationBootstrapper()
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let settings = try bootstrapper.ensureBootstrap(modelContext: modelContext)
        
        // 新创建的settings应该有nil值，resolvedInspectorCollapsed返回false
        XCTAssertNil(settings.inspectorCollapsed)
        XCTAssertFalse(settings.resolvedInspectorCollapsed)
    }

    @MainActor
    func testInspectorCollapsedFieldCanBeUpdated() throws {
        let bootstrapper = LLMConfigurationBootstrapper()
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let settings = try bootstrapper.ensureBootstrap(modelContext: modelContext)
        
        // 更新inspectorCollapsed字段
        settings.inspectorCollapsed = true
        settings.modifiedAt = Date()
        try modelContext.save()
        
        // 重新获取并验证
        let fetchDescriptor = FetchDescriptor<AppSettings>()
        let fetchedSettings = try modelContext.fetch(fetchDescriptor).first
        XCTAssertNotNil(fetchedSettings)
        XCTAssertEqual(fetchedSettings!.inspectorCollapsed, true)
        XCTAssertTrue(fetchedSettings!.resolvedInspectorCollapsed)
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

final class LLMDefaultProfilesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LLMDefaultProfilesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testSeederCreatesOpenAIAndDeepSeekProfilesIdempotently() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let styleStore = LLMProviderAPIStyleStore(userDefaults: defaults)
        let seeder = LLMDefaultProfileSeeder(
            apiStyleStore: styleStore,
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        )

        try seeder.ensureDefaults(modelContext: context)
        try seeder.ensureDefaults(modelContext: context)

        let providers = try context.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        XCTAssertEqual(Set(providers.map(\.id)), Set([
            LLMDefaultProfiles.openAIProviderID,
            LLMDefaultProfiles.deepSeekProviderID,
        ]))
        XCTAssertEqual(Set(models.map(\.id)), Set([
            LLMDefaultProfiles.openAIModelID,
            LLMDefaultProfiles.deepSeekModelID,
        ]))
        XCTAssertEqual(
            providers.first(where: { $0.id == LLMDefaultProfiles.openAIProviderID })?.baseURL,
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            providers.first(where: { $0.id == LLMDefaultProfiles.deepSeekProviderID })?.testModel,
            "deepseek-v4-flash"
        )
        XCTAssertEqual(styleStore.apiStyle(for: LLMDefaultProfiles.openAIProviderID), .responses)
        XCTAssertEqual(styleStore.apiStyle(for: LLMDefaultProfiles.deepSeekProviderID), .responses)
    }

    @MainActor
    func testSeederPreservesExistingCustomProfiles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customProvider = LLMProviderProfile(
            name: "Custom",
            baseURL: "https://example.com/v1",
            apiKeyRef: "custom-key",
            testModel: "custom-model"
        )
        let customModel = LLMModelProfile(
            providerID: customProvider.id,
            name: "Custom Model",
            modelName: "custom-model"
        )
        context.insert(customProvider)
        context.insert(customModel)
        try context.save()

        try LLMDefaultProfileSeeder(
            apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults),
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        ).ensureDefaults(modelContext: context)

        let providers = try context.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        XCTAssertEqual(providers.count, 3)
        XCTAssertEqual(models.count, 3)
        XCTAssertTrue(providers.contains(where: { $0.id == customProvider.id }))
        XCTAssertTrue(models.contains(where: { $0.id == customModel.id }))
    }

    @MainActor
    func testSeederPreservesEditsToBuiltInModelProfiles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let seeder = LLMDefaultProfileSeeder(
            apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults),
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        )
        try seeder.ensureDefaults(modelContext: context)

        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        let model = try XCTUnwrap(
            models.first(where: { $0.id == LLMDefaultProfiles.openAIModelID })
        )
        model.name = "My OpenAI Model"
        model.modelName = "gpt-custom"
        try context.save()

        try seeder.ensureDefaults(modelContext: context)

        XCTAssertEqual(model.name, "My OpenAI Model")
        XCTAssertEqual(model.modelName, "gpt-custom")
    }

    @MainActor
    func testSeederPreservesEditsToBuiltInProviderProfiles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let styleStore = LLMProviderAPIStyleStore(userDefaults: defaults)
        let seeder = LLMDefaultProfileSeeder(
            apiStyleStore: styleStore,
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        )
        try seeder.ensureDefaults(modelContext: context)

        let providers = try context.fetch(FetchDescriptor<LLMProviderProfile>())
        let provider = try XCTUnwrap(
            providers.first(where: { $0.id == LLMDefaultProfiles.openAIProviderID })
        )
        provider.name = "My Provider"
        provider.baseURL = "https://example.com/v1"
        provider.testModel = "custom-model"
        styleStore.setAPIStyle(.chatCompletions, for: provider.id)
        try context.save()

        try seeder.ensureDefaults(modelContext: context)

        XCTAssertEqual(provider.name, "My Provider")
        XCTAssertEqual(provider.baseURL, "https://example.com/v1")
        XCTAssertEqual(provider.testModel, "custom-model")
        XCTAssertEqual(styleStore.apiStyle(for: provider.id), .chatCompletions)
    }

    @MainActor
    func testSeederDoesNotRecreateDeletedBuiltInModel() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let deletionStore = LLMDefaultProfileDeletionStore(userDefaults: defaults)
        let seeder = LLMDefaultProfileSeeder(
            apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults),
            deletionStore: deletionStore
        )
        try seeder.ensureDefaults(modelContext: context)

        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        let deepSeekModel = try XCTUnwrap(
            models.first(where: { $0.id == LLMDefaultProfiles.deepSeekModelID })
        )
        context.delete(deepSeekModel)
        try context.save()
        deletionStore.markModelDeleted(LLMDefaultProfiles.deepSeekModelID)

        try seeder.ensureDefaults(modelContext: context)

        let remainingModels = try context.fetch(FetchDescriptor<LLMModelProfile>())
        XCTAssertEqual(remainingModels.map(\.id), [LLMDefaultProfiles.openAIModelID])
    }

    @MainActor
    func testSeederDoesNotRecreateDeletedBuiltInProviderOrItsModel() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let deletionStore = LLMDefaultProfileDeletionStore(userDefaults: defaults)
        let seeder = LLMDefaultProfileSeeder(
            apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults),
            deletionStore: deletionStore
        )
        try seeder.ensureDefaults(modelContext: context)

        let providers = try context.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        context.delete(try XCTUnwrap(
            providers.first(where: { $0.id == LLMDefaultProfiles.openAIProviderID })
        ))
        context.delete(try XCTUnwrap(
            models.first(where: { $0.id == LLMDefaultProfiles.openAIModelID })
        ))
        try context.save()
        deletionStore.markProviderDeleted(LLMDefaultProfiles.openAIProviderID)

        try seeder.ensureDefaults(modelContext: context)

        let remainingProviders = try context.fetch(FetchDescriptor<LLMProviderProfile>())
        let remainingModels = try context.fetch(FetchDescriptor<LLMModelProfile>())
        XCTAssertEqual(remainingProviders.map(\.id), [LLMDefaultProfiles.deepSeekProviderID])
        XCTAssertEqual(remainingModels.map(\.id), [LLMDefaultProfiles.deepSeekModelID])
    }

    @MainActor
    func testRouteActivatorSelectsNewlyConfiguredDefaultProvider() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try LLMDefaultProfileSeeder(
            apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults),
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        ).ensureDefaults(modelContext: context)
        let providers = try context.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        let settings = AppSettings()

        LLMDefaultRouteActivator().selectRoutesIfNeeded(
            for: LLMDefaultProfiles.deepSeekProviderID,
            settings: settings,
            providers: providers,
            models: models,
            hasStoredAPIKey: { _ in false }
        )

        XCTAssertEqual(settings.selectedHTMLModelProfileID, LLMDefaultProfiles.deepSeekModelID)
        XCTAssertEqual(settings.selectedPDFModelProfileID, LLMDefaultProfiles.deepSeekModelID)
    }

    @MainActor
    func testRouteActivatorDoesNotSelectBuiltInModelAfterProviderIsEdited() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try LLMDefaultProfileSeeder(
            apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults),
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        ).ensureDefaults(modelContext: context)
        let providers = try context.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        let deepSeekModel = try XCTUnwrap(
            models.first(where: { $0.id == LLMDefaultProfiles.deepSeekModelID })
        )
        deepSeekModel.providerID = LLMDefaultProfiles.openAIProviderID
        let settings = AppSettings()

        LLMDefaultRouteActivator().selectRoutesIfNeeded(
            for: LLMDefaultProfiles.deepSeekProviderID,
            settings: settings,
            providers: providers,
            models: models,
            hasStoredAPIKey: { _ in false }
        )

        XCTAssertNil(settings.selectedHTMLModelProfileID)
        XCTAssertNil(settings.selectedPDFModelProfileID)
    }

    func testUnknownProviderDefaultsToChatCompletions() {
        let store = LLMProviderAPIStyleStore(userDefaults: defaults)
        let providerID = UUID()

        XCTAssertEqual(store.apiStyle(for: providerID), .chatCompletions)
        store.setAPIStyle(.responses, for: providerID)
        XCTAssertEqual(store.apiStyle(for: providerID), .responses)
        store.removeAPIStyle(for: providerID)
        XCTAssertEqual(store.apiStyle(for: providerID), .chatCompletions)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AppSettings.self,
            LLMProviderProfile.self,
            LLMModelProfile.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}
