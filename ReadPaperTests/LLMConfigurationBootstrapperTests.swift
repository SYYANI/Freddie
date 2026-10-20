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
    func testSeederCreatesBuiltInProfilesIdempotently() throws {
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
            LLMDefaultProfiles.anthropicProviderID,
        ]))
        XCTAssertEqual(Set(models.map(\.id)), Set([
            LLMDefaultProfiles.openAIModelID,
            LLMDefaultProfiles.deepSeekModelID,
            LLMDefaultProfiles.anthropicModelID,
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
        XCTAssertEqual(
            providers.first(where: { $0.id == LLMDefaultProfiles.anthropicProviderID })?.baseURL,
            "https://api.anthropic.com/v1"
        )
        XCTAssertEqual(
            styleStore.apiStyle(for: LLMDefaultProfiles.anthropicProviderID),
            .anthropicMessages
        )
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
        XCTAssertEqual(providers.count, LLMDefaultProfiles.providers.count + 1)
        XCTAssertEqual(models.count, LLMDefaultProfiles.providers.count + 1)
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
        XCTAssertEqual(Set(remainingModels.map(\.id)), [
            LLMDefaultProfiles.openAIModelID,
            LLMDefaultProfiles.anthropicModelID,
        ])
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
        XCTAssertEqual(Set(remainingProviders.map(\.id)), [
            LLMDefaultProfiles.deepSeekProviderID,
            LLMDefaultProfiles.anthropicProviderID,
        ])
        XCTAssertEqual(Set(remainingModels.map(\.id)), [
            LLMDefaultProfiles.deepSeekModelID,
            LLMDefaultProfiles.anthropicModelID,
        ])
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

    @MainActor
    func testRouteActivatorMakesAnthropicTheHTMLAndPDFDefault() throws {
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
            for: LLMDefaultProfiles.anthropicProviderID,
            settings: settings,
            providers: providers,
            models: models,
            hasStoredAPIKey: { _ in false }
        )

        XCTAssertEqual(settings.selectedHTMLModelProfileID, LLMDefaultProfiles.anthropicModelID)
        XCTAssertEqual(settings.selectedPDFModelProfileID, LLMDefaultProfiles.anthropicModelID)
    }

    @MainActor
    func testQuickSetupTargetKeepsEditedBuiltInProfiles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let styleStore = LLMProviderAPIStyleStore(userDefaults: defaults)
        try LLMDefaultProfileSeeder(
            apiStyleStore: styleStore,
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        ).ensureDefaults(modelContext: context)
        let providers = try context.fetch(FetchDescriptor<LLMProviderProfile>())
        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        let provider = try XCTUnwrap(providers.first { $0.id == LLMDefaultProfiles.deepSeekProviderID })
        let model = try XCTUnwrap(models.first { $0.id == LLMDefaultProfiles.deepSeekModelID })
        provider.baseURL = "https://proxy.example.com/deepseek"
        styleStore.setAPIStyle(.chatCompletions, for: provider.id)
        model.modelName = "deepseek-v4-pro"
        model.thinkingModeValue = .enabled
        let descriptor = try XCTUnwrap(LLMDefaultProfiles.provider(for: LLMDefaultProfiles.deepSeekProviderID))

        let target = LLMQuickSetup(apiStyleStore: styleStore).target(
            for: descriptor,
            providers: providers,
            models: models
        )

        XCTAssertEqual(target.baseURL, "https://proxy.example.com/deepseek")
        XCTAssertEqual(target.apiStyle, .chatCompletions)
        XCTAssertEqual(target.modelName, "deepseek-v4-pro")
        XCTAssertEqual(target.thinkingMode, .enabled)
    }

    @MainActor
    func testQuickSetupTargetUsesDescriptorWhenProfilesWereDeleted() throws {
        let styleStore = LLMProviderAPIStyleStore(userDefaults: defaults)
        let descriptor = try XCTUnwrap(LLMDefaultProfiles.provider(for: LLMDefaultProfiles.anthropicProviderID))

        let target = LLMQuickSetup(apiStyleStore: styleStore).target(
            for: descriptor,
            providers: [],
            models: []
        )

        XCTAssertEqual(target.baseURL, descriptor.baseURL)
        XCTAssertEqual(target.apiStyle, .anthropicMessages)
        XCTAssertEqual(target.modelName, descriptor.model.modelName)
        XCTAssertNil(target.thinkingMode)
    }

    @MainActor
    func testQuickSetupSavesKeyAndRoutesHTMLAndPDFToTheProvider() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let styleStore = LLMProviderAPIStyleStore(userDefaults: defaults)
        try LLMDefaultProfileSeeder(
            apiStyleStore: styleStore,
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        ).ensureDefaults(modelContext: context)
        let settings = AppSettings(
            selectedHTMLModelProfileID: LLMDefaultProfiles.openAIModelID,
            selectedPDFModelProfileID: LLMDefaultProfiles.openAIModelID
        )
        context.insert(settings)
        let models = try context.fetch(FetchDescriptor<LLMModelProfile>())
        try XCTUnwrap(models.first { $0.id == LLMDefaultProfiles.deepSeekModelID }).isEnabled = false
        try context.save()
        let descriptor = try XCTUnwrap(LLMDefaultProfiles.provider(for: LLMDefaultProfiles.deepSeekProviderID))
        let testedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var savedKeys: [String: String] = [:]

        let model = try LLMQuickSetup(apiStyleStore: styleStore).apply(
            descriptor: descriptor,
            apiKey: "sk-test",
            testedAt: testedAt,
            settings: settings,
            modelContext: context,
            saveAPIKey: { savedKeys[$1] = $0 }
        )

        XCTAssertEqual(model.id, LLMDefaultProfiles.deepSeekModelID)
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.lastTestedAt, testedAt)
        XCTAssertEqual(
            savedKeys,
            [LLMConfigurationBootstrapper.makeAPIKeyRef(providerID: LLMDefaultProfiles.deepSeekProviderID): "sk-test"]
        )
        XCTAssertFalse(context.hasChanges)
        let savedSettings = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(savedSettings.selectedHTMLModelProfileID, LLMDefaultProfiles.deepSeekModelID)
        XCTAssertEqual(savedSettings.selectedPDFModelProfileID, LLMDefaultProfiles.deepSeekModelID)
    }

    @MainActor
    func testQuickSetupRestoresDeletedBuiltInProfiles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let styleStore = LLMProviderAPIStyleStore(userDefaults: defaults)
        let settings = AppSettings()
        context.insert(settings)
        try context.save()
        let descriptor = try XCTUnwrap(LLMDefaultProfiles.provider(for: LLMDefaultProfiles.anthropicProviderID))

        try LLMQuickSetup(apiStyleStore: styleStore).apply(
            descriptor: descriptor,
            apiKey: "sk-ant-test",
            testedAt: Date(),
            settings: settings,
            modelContext: context,
            saveAPIKey: { _, _ in }
        )

        let provider = try XCTUnwrap(context.fetch(FetchDescriptor<LLMProviderProfile>()).first)
        let model = try XCTUnwrap(context.fetch(FetchDescriptor<LLMModelProfile>()).first)
        XCTAssertEqual(provider.id, LLMDefaultProfiles.anthropicProviderID)
        XCTAssertEqual(provider.baseURL, descriptor.baseURL)
        XCTAssertEqual(styleStore.apiStyle(for: provider.id), .anthropicMessages)
        XCTAssertEqual(model.id, LLMDefaultProfiles.anthropicModelID)
        XCTAssertEqual(model.providerID, provider.id)
        XCTAssertEqual(settings.selectedHTMLModelProfileID, model.id)
        XCTAssertEqual(settings.selectedPDFModelProfileID, model.id)
    }

    @MainActor
    func testQuickSetupKeepsStoredKeyWhenNoneIsTyped() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let styleStore = LLMProviderAPIStyleStore(userDefaults: defaults)
        let settings = AppSettings()
        context.insert(settings)
        let descriptor = try XCTUnwrap(LLMDefaultProfiles.provider(for: LLMDefaultProfiles.openAIProviderID))
        var saveCount = 0

        try LLMQuickSetup(apiStyleStore: styleStore).apply(
            descriptor: descriptor,
            apiKey: nil,
            testedAt: Date(),
            settings: settings,
            modelContext: context,
            saveAPIKey: { _, _ in saveCount += 1 }
        )

        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(settings.selectedHTMLModelProfileID, LLMDefaultProfiles.openAIModelID)
    }

    @MainActor
    func testQuickSetupLeavesStoreUntouchedWhenSavingTheKeyFails() throws {
        struct KeychainFailure: Error {}
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        context.insert(settings)
        try context.save()
        let descriptor = try XCTUnwrap(LLMDefaultProfiles.provider(for: LLMDefaultProfiles.deepSeekProviderID))

        XCTAssertThrowsError(
            try LLMQuickSetup(apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults)).apply(
                descriptor: descriptor,
                apiKey: "sk-test",
                testedAt: Date(),
                settings: settings,
                modelContext: context,
                saveAPIKey: { _, _ in throw KeychainFailure() }
            )
        )

        XCTAssertFalse(context.hasChanges)
        XCTAssertNil(settings.selectedHTMLModelProfileID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LLMProviderProfile>()).isEmpty)
    }

    @MainActor
    func testSetupStatusNeedsAStoredKeyBehindAnEnabledRoute() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try LLMDefaultProfileSeeder(
            apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults),
            deletionStore: LLMDefaultProfileDeletionStore(userDefaults: defaults)
        ).ensureDefaults(modelContext: context)
        let settings = AppSettings()
        context.insert(settings)
        let deepSeekKeyRef = LLMConfigurationBootstrapper.makeAPIKeyRef(providerID: LLMDefaultProfiles.deepSeekProviderID)
        let hasDeepSeekKey: (String) -> Bool = { $0 == deepSeekKeyRef }

        // Seeded profiles alone are not enough: nothing is routed yet.
        XCTAssertFalse(LLMTranslationSetupStatus.hasUsableRoute(
            settings: settings, modelContext: context, hasStoredAPIKey: hasDeepSeekKey
        ))

        settings.selectedHTMLModelProfileID = LLMDefaultProfiles.openAIModelID
        XCTAssertFalse(LLMTranslationSetupStatus.hasUsableRoute(
            settings: settings, modelContext: context, hasStoredAPIKey: hasDeepSeekKey
        ))

        // Either route is enough to start translating.
        settings.selectedPDFModelProfileID = LLMDefaultProfiles.deepSeekModelID
        XCTAssertTrue(LLMTranslationSetupStatus.hasUsableRoute(
            settings: settings, modelContext: context, hasStoredAPIKey: hasDeepSeekKey
        ))

        let deepSeek = try XCTUnwrap(
            context.fetch(FetchDescriptor<LLMProviderProfile>()).first { $0.id == LLMDefaultProfiles.deepSeekProviderID }
        )
        deepSeek.isEnabled = false
        XCTAssertFalse(LLMTranslationSetupStatus.hasUsableRoute(
            settings: settings, modelContext: context, hasStoredAPIKey: hasDeepSeekKey
        ))
    }

    func testQuickSetupNavigationOpensGeneralAndShowsASkippedGuide() {
        defaults.set("providers", forKey: TranslationSetupNavigation.selectedTabKey)
        defaults.set(true, forKey: TranslationSetupNavigation.didDismissGettingStartedKey)

        TranslationSetupNavigation.prepareQuickSetup(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: TranslationSetupNavigation.selectedTabKey), "general")
        XCTAssertFalse(defaults.bool(forKey: TranslationSetupNavigation.didDismissGettingStartedKey))
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
