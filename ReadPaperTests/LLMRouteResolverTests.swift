import SwiftData
import XCTest
@testable import ReadPaper

final class LLMRouteResolverTests: XCTestCase {
    @MainActor
    func testResolverReturnsIndependentHTMLAndPDFRoutes() throws {
        let service = "LLMRouteResolverTests.\(UUID().uuidString)"
        let keychainStore = KeychainStore(service: service)
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let provider = LLMProviderProfile(
            name: "Provider",
            baseURL: "https://api.example.com/v1",
            apiKeyRef: "provider-ref",
            testModel: "gpt-test"
        )
        let htmlModel = LLMModelProfile(providerID: provider.id, name: "HTML", modelName: "html-model")
        let pdfModel = LLMModelProfile(providerID: provider.id, name: "PDF", modelName: "pdf-model")
        let settings = AppSettings(
            selectedHTMLModelProfileID: htmlModel.id,
            selectedPDFModelProfileID: pdfModel.id
        )

        modelContext.insert(provider)
        modelContext.insert(htmlModel)
        modelContext.insert(pdfModel)
        modelContext.insert(settings)
        try modelContext.save()
        try keychainStore.save("sk-test", account: provider.apiKeyRef)

        let resolver = LLMRouteResolver(keychainStore: keychainStore)
        let htmlRoute = try resolver.resolveHTMLRoute(settings: settings, modelContext: modelContext)
        let pdfRoute = try resolver.resolvePDFRoute(settings: settings, modelContext: modelContext)

        XCTAssertEqual(htmlRoute.snapshot.modelProfileID, htmlModel.id)
        XCTAssertEqual(pdfRoute.snapshot.modelProfileID, pdfModel.id)
        XCTAssertEqual(htmlRoute.apiKey, "sk-test")
        XCTAssertEqual(pdfRoute.apiKey, "sk-test")
    }

    @MainActor
    func testResolverRejectsDisabledProviderAndMissingSelection() throws {
        let keychainStore = KeychainStore(service: "LLMRouteResolverTests.\(UUID().uuidString)")
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let provider = LLMProviderProfile(
            name: "Disabled Provider",
            baseURL: "https://api.example.com/v1",
            apiKeyRef: "provider-ref",
            testModel: "gpt-test",
            isEnabled: false
        )
        let model = LLMModelProfile(providerID: provider.id, name: "HTML", modelName: "html-model")
        let settings = AppSettings(
            selectedHTMLModelProfileID: model.id,
            selectedPDFModelProfileID: nil
        )

        modelContext.insert(provider)
        modelContext.insert(model)
        modelContext.insert(settings)
        try modelContext.save()
        try keychainStore.save("sk-test", account: provider.apiKeyRef)

        let resolver = LLMRouteResolver(keychainStore: keychainStore)

        XCTAssertThrowsError(try resolver.resolveHTMLRoute(settings: settings, modelContext: modelContext)) { error in
            XCTAssertEqual(error as? LLMRouteError, .providerDisabled("Disabled Provider"))
        }

        XCTAssertThrowsError(try resolver.resolvePDFRoute(settings: settings, modelContext: modelContext)) { error in
            XCTAssertEqual(error as? LLMRouteError, .pdfModelNotSelected)
        }
    }

    @MainActor
    func testResolverRejectsMissingAPIKey() throws {
        let keychainStore = KeychainStore(service: "LLMRouteResolverTests.\(UUID().uuidString)")
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let provider = LLMProviderProfile(
            name: "Provider",
            baseURL: "https://api.example.com/v1",
            apiKeyRef: "provider-ref",
            testModel: "gpt-test"
        )
        let model = LLMModelProfile(providerID: provider.id, name: "HTML", modelName: "html-model")
        let settings = AppSettings(
            selectedHTMLModelProfileID: model.id,
            selectedPDFModelProfileID: nil
        )

        modelContext.insert(provider)
        modelContext.insert(model)
        modelContext.insert(settings)
        try modelContext.save()

        let resolver = LLMRouteResolver(keychainStore: keychainStore)

        XCTAssertThrowsError(try resolver.resolveHTMLRoute(settings: settings, modelContext: modelContext)) { error in
            XCTAssertEqual(error as? LLMRouteError, .missingAPIKey("Provider"))
        }
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
