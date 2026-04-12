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
