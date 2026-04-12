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
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AppSettings.self,
            LLMProviderProfile.self,
            LLMModelProfile.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }
}
