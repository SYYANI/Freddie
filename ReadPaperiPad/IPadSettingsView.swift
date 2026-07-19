import SwiftData
import SwiftUI

struct IPadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Query private var settingsRows: [AppSettings]
    @Query(sort: \LLMProviderProfile.modifiedAt, order: .reverse) private var providers: [LLMProviderProfile]
    @Query(sort: \LLMModelProfile.modifiedAt, order: .reverse) private var models: [LLMModelProfile]
    @AppStorage(PDFTranslationBatchPreference.userDefaultsKey)
    private var pdfTranslationBatchSize = PDFTranslationBatchPreference.defaultValue

    @State private var selectedProviderID: UUID?
    @State private var providerName = "OpenAI"
    @State private var providerBaseURL = "https://api.openai.com/v1"
    @State private var providerAPIKey = ""
    @State private var selectedModelID: UUID?
    @State private var modelProviderID: UUID?
    @State private var modelName = ""
    @State private var modelIdentifier = ""
    @State private var statusMessage: String?

    private var settings: AppSettings? { settingsRows.first }

    var body: some View {
        Form {
            generalSection
            providerSection
            modelSection
            translationSection

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(AppLocalization.isErrorMessage(statusMessage, bundle: bundle) ? .red : .secondary)
                }
            }
        }
        .navigationTitle(String(localized: "Settings", bundle: bundle))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Close", bundle: bundle)) { dismiss() }
            }
        }
        .onAppear {
            _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
            if selectedProviderID == nil { selectProvider(providers.first) }
            if selectedModelID == nil { selectModel(models.first) }
        }
        .onChange(of: selectedProviderID) { _, id in
            selectProvider(providers.first(where: { $0.id == id }))
        }
        .onChange(of: selectedModelID) { _, id in
            selectModel(models.first(where: { $0.id == id }))
        }
    }

    private var generalSection: some View {
        Section(String(localized: "General", bundle: bundle)) {
            Picker(String(localized: "Application Language", bundle: bundle), selection: appLanguageBinding) {
                Text("Follow System", bundle: bundle).tag(String?.none)
                ForEach(AppLocalization.supportedLanguages) { language in
                    Text(language.displayName).tag(Optional(language.code))
                }
            }
        }
    }

    private var providerSection: some View {
        Section(String(localized: "Providers", bundle: bundle)) {
            if !providers.isEmpty {
                Picker(String(localized: "Provider", bundle: bundle), selection: $selectedProviderID) {
                    Text("New Provider", bundle: bundle).tag(UUID?.none)
                    ForEach(providers) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
            }
            TextField(String(localized: "Provider Name", bundle: bundle), text: $providerName)
            TextField(String(localized: "Base URL", bundle: bundle), text: $providerBaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(String(localized: "API Key", bundle: bundle), text: $providerAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "Save Provider", bundle: bundle), action: saveProvider)
                .buttonStyle(.borderedProminent)
        }
    }

    private var modelSection: some View {
        Section(String(localized: "Models", bundle: bundle)) {
            if !models.isEmpty {
                Picker(String(localized: "Model Profile", bundle: bundle), selection: $selectedModelID) {
                    Text("New Model", bundle: bundle).tag(UUID?.none)
                    ForEach(models) { model in
                        Text(model.name).tag(Optional(model.id))
                    }
                }
            }
            Picker(String(localized: "Provider", bundle: bundle), selection: $modelProviderID) {
                Text("Choose Provider", bundle: bundle).tag(UUID?.none)
                ForEach(providers) { provider in
                    Text(provider.name).tag(Optional(provider.id))
                }
            }
            TextField(String(localized: "Profile Name", bundle: bundle), text: $modelName)
            TextField(String(localized: "Model Name", bundle: bundle), text: $modelIdentifier)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "Save Model", bundle: bundle), action: saveModel)
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var translationSection: some View {
        if let settings {
            Section(String(localized: "Translation", bundle: bundle)) {
                Picker(String(localized: "HTML Model", bundle: bundle), selection: htmlModelBinding(settings)) {
                    Text("Choose Model", bundle: bundle).tag(UUID?.none)
                    ForEach(models.filter(\.isEnabled)) { model in
                        Text(model.name).tag(Optional(model.id))
                    }
                }
                Picker(String(localized: "PDF/BabelDOC Model", bundle: bundle), selection: pdfModelBinding(settings)) {
                    Text("Choose Model", bundle: bundle).tag(UUID?.none)
                    ForEach(models.filter(\.isEnabled)) { model in
                        Text(model.name).tag(Optional(model.id))
                    }
                }
                TextField(String(localized: "Target Language", bundle: bundle), text: targetLanguageBinding(settings))
                    .textInputAutocapitalization(.never)
                Stepper(
                    value: concurrencyBinding(settings),
                    in: 1...12
                ) {
                    Text("HTML concurrency: \(settings.htmlTranslationConcurrency)")
                }
                Stepper(
                    value: Binding(
                        get: { PDFTranslationBatchPreference.normalized(pdfTranslationBatchSize) },
                        set: { pdfTranslationBatchSize = PDFTranslationBatchPreference.normalized($0) }
                    ),
                    in: PDFTranslationBatchPreference.allowedRange
                ) {
                    Text(AppLocalization.format(
                        "PDF pages per batch: %d",
                        bundle: bundle,
                        PDFTranslationBatchPreference.normalized(pdfTranslationBatchSize)
                    ))
                }
            }
        }
    }

    private var appLanguageBinding: Binding<String?> {
        Binding(
            get: { LanguageManager.shared.languageOverride },
            set: { LanguageManager.shared.setLanguage($0) }
        )
    }

    private func htmlModelBinding(_ settings: AppSettings) -> Binding<UUID?> {
        Binding(
            get: { settings.selectedHTMLModelProfileID },
            set: {
                settings.selectedHTMLModelProfileID = $0
                settings.modifiedAt = Date()
                try? modelContext.save()
            }
        )
    }

    private func pdfModelBinding(_ settings: AppSettings) -> Binding<UUID?> {
        Binding(
            get: { settings.selectedPDFModelProfileID },
            set: {
                settings.selectedPDFModelProfileID = $0
                settings.modifiedAt = Date()
                try? modelContext.save()
            }
        )
    }

    private func targetLanguageBinding(_ settings: AppSettings) -> Binding<String> {
        Binding(
            get: { settings.targetLanguage },
            set: {
                settings.targetLanguage = $0
                settings.modifiedAt = Date()
                try? modelContext.save()
            }
        )
    }

    private func concurrencyBinding(_ settings: AppSettings) -> Binding<Int> {
        Binding(
            get: { settings.htmlTranslationConcurrency },
            set: {
                settings.htmlTranslationConcurrency = $0
                settings.modifiedAt = Date()
                try? modelContext.save()
            }
        )
    }

    private func selectProvider(_ provider: LLMProviderProfile?) {
        selectedProviderID = provider?.id
        providerName = provider?.name ?? "OpenAI"
        providerBaseURL = provider?.baseURL ?? "https://api.openai.com/v1"
        providerAPIKey = ""
        if let provider {
            providerAPIKey = (try? KeychainStore().load(account: provider.apiKeyRef)) ?? ""
            if modelProviderID == nil { modelProviderID = provider.id }
        }
    }

    private func saveProvider() {
        do {
            let name = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw IPadSettingsError.missingProviderName }
            let baseURL = try LLMProviderValidationUseCase().normalizedBaseURL(providerBaseURL)
            let provider: LLMProviderProfile
            if let selectedProviderID,
               let existing = providers.first(where: { $0.id == selectedProviderID }) {
                provider = existing
                provider.name = name
                provider.baseURL = baseURL
                provider.modifiedAt = Date()
            } else {
                let id = UUID()
                provider = LLMProviderProfile(
                    id: id,
                    name: name,
                    baseURL: baseURL,
                    apiKeyRef: "llm-provider-\(id.uuidString)",
                    testModel: "",
                    isEnabled: true
                )
                modelContext.insert(provider)
            }
            if !providerAPIKey.isEmpty {
                try KeychainStore().save(providerAPIKey, account: provider.apiKeyRef)
            }
            try modelContext.save()
            selectedProviderID = provider.id
            modelProviderID = provider.id
            statusMessage = String(localized: "Provider saved.", bundle: bundle)
        } catch {
            statusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        }
    }

    private func selectModel(_ model: LLMModelProfile?) {
        selectedModelID = model?.id
        modelProviderID = model?.providerID ?? selectedProviderID ?? providers.first?.id
        modelName = model?.name ?? ""
        modelIdentifier = model?.modelName ?? ""
    }

    private func saveModel() {
        do {
            guard let providerID = modelProviderID else { throw IPadSettingsError.missingProvider }
            let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw IPadSettingsError.missingModelProfileName }
            let identifier = try LLMProviderValidationUseCase().validateModelName(modelIdentifier)
            let model: LLMModelProfile
            if let selectedModelID,
               let existing = models.first(where: { $0.id == selectedModelID }) {
                model = existing
                model.providerID = providerID
                model.name = name
                model.modelName = identifier
                model.modifiedAt = Date()
            } else {
                model = LLMModelProfile(
                    providerID: providerID,
                    name: name,
                    modelName: identifier,
                    isEnabled: true
                )
                modelContext.insert(model)
            }
            try modelContext.save()
            selectedModelID = model.id
            if let settings, settings.selectedHTMLModelProfileID == nil {
                settings.selectedHTMLModelProfileID = model.id
                if settings.selectedPDFModelProfileID == nil {
                    settings.selectedPDFModelProfileID = model.id
                }
                settings.modifiedAt = Date()
                try modelContext.save()
            }
            statusMessage = String(localized: "Model saved.", bundle: bundle)
        } catch {
            statusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        }
    }
}

private enum IPadSettingsError: LocalizedError {
    case missingProviderName
    case missingProvider
    case missingModelProfileName

    var errorDescription: String? {
        switch self {
        case .missingProviderName:
            AppLocalization.localized("Provider name cannot be empty.")
        case .missingProvider:
            AppLocalization.localized("Choose a provider first.")
        case .missingModelProfileName:
            AppLocalization.localized("Model profile name cannot be empty.")
        }
    }
}
