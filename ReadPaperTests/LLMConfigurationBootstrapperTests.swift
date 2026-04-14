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
