import SwiftData
import SwiftUI

private enum SettingsTab: String, Hashable {
    case general
    case reader
    case providers
    case models
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRows: [AppSettings]
    @Query(sort: [SortDescriptor(\LLMProviderProfile.modifiedAt, order: .reverse)]) private var providers: [LLMProviderProfile]
    @Query(sort: [SortDescriptor(\LLMModelProfile.modifiedAt, order: .reverse)]) private var models: [LLMModelProfile]

    var body: some View {
        Group {
            if let settings = settingsRows.first {
                SettingsForm(
                    settings: settings,
                    providers: providers,
                    models: models
                )
            } else {
                ProgressView()
                    .task {
                        _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsForm: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var settings: AppSettings
    let providers: [LLMProviderProfile]
    let models: [LLMModelProfile]

    @AppStorage("ReadPaper.Settings.SelectedTab") private var selectedTabRawValue = SettingsTab.general.rawValue

    @State private var selectedProviderID: UUID?
    @State private var providerName = ""
    @State private var providerBaseURL = "https://api.openai.com/v1"
    @State private var providerAPIKey = ""
    @State private var providerTestModel = ""
    @State private var providerEnabled = true
    @State private var providerHasStoredAPIKey = false
    @State private var providerStatusMessage: String?
    @State private var providerOutputPreview: String?
    @State private var isTestingProvider = false

    @State private var selectedModelID: UUID?
    @State private var modelProviderID: UUID?
    @State private var modelName = ""
    @State private var modelIdentifier = ""
    @State private var modelTemperature = ""
    @State private var modelTopP = ""
    @State private var modelMaxTokens = ""
    @State private var modelEnabled = true
    @State private var modelStatusMessage: String?
    @State private var modelOutputPreview: String?
    @State private var isTestingModel = false

    @State private var generalStatusMessage: String?
    @State private var isInstallingBabelDOC = false
    @State private var installedBabelDocVersion: String?
    @State private var isLoadingInstalledBabelDocVersion = false

    private let keychainStore = KeychainStore()
    private let validator = LLMProviderValidationUseCase()

    private var sortedProviders: [LLMProviderProfile] {
        providers.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var sortedModels: [LLMModelProfile] {
        models.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var selectedProvider: LLMProviderProfile? {
        sortedProviders.first(where: { $0.id == selectedProviderID })
    }

    private var selectedModel: LLMModelProfile? {
        sortedModels.first(where: { $0.id == selectedModelID })
    }

    private var selectedModelLastTestedAt: Date? {
        selectedModel?.lastTestedAt
    }

    private var providerAPIKeyPrompt: String {
        if providerAPIKey.isEmpty, providerHasStoredAPIKey {
            return String(repeating: "•", count: 12)
        }
        return ""
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
            generalTab
                .tag(SettingsTab.general)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            readerTab
                .tag(SettingsTab.reader)
                .tabItem {
                    Label("Reader", systemImage: "book.closed")
                }

            providerTab
                .tag(SettingsTab.providers)
                .tabItem {
                    Label("Providers", systemImage: "network")
                }

            modelTab
                .tag(SettingsTab.models)
                .tabItem {
                    Label("Models", systemImage: "sparkles.rectangle.stack")
                }
        }
        .formStyle(.grouped)
        .task {
            _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
            loadInitialSelectionIfNeeded()
            await refreshInstalledBabelDOCVersion()
        }
        .onChange(of: selectedProviderID) { _, _ in
            applySelectedProvider()
        }
        .onChange(of: selectedModelID) { _, _ in
            applySelectedModel()
        }
        .onChange(of: providers.map(\.id)) { _, _ in
            normalizeSelections()
        }
        .onChange(of: models.map(\.id)) { _, _ in
            normalizeSelections()
        }
    }

    private var selectedTabBinding: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: selectedTabRawValue) ?? .general },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Translation") {
                    TextField("Target language", text: $settings.targetLanguage)

                    Stepper("HTML concurrency: \(settings.htmlTranslationConcurrency)", value: $settings.htmlTranslationConcurrency, in: 1...12)
                    Stepper("BabelDOC QPS: \(settings.babelDocQPS)", value: $settings.babelDocQPS, in: 1...20)

                    Text("Controls the default translation target and the amount of parallel work used for HTML and BabelDOC translation jobs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("BabelDOC") {
                    LabeledContent("Current installed version") {
                        if isLoadingInstalledBabelDocVersion {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(installedBabelDocVersion ?? "Not installed")
                                .foregroundStyle(installedBabelDocVersion == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }

                    TextField("Target version", text: $settings.babelDocVersion)

                    Button(isInstallingBabelDOC ? "Installing..." : "Install or update BabelDOC") {
                        installBabelDOC()
                    }
                    .disabled(isInstallingBabelDOC)

                    Text("The PDF translation tool is managed separately from the reader. Updating it here keeps the BabelDOC route ready when a paper needs full-PDF translation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let generalStatusMessage {
                        statusLabel(generalStatusMessage)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var readerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Translation Routes") {
                    Picker("HTML Model", selection: $settings.selectedHTMLModelProfileID) {
                        Text("Not Selected").tag(Optional<UUID>.none)
                        ForEach(sortedModels, id: \.id) { model in
                            Text(modelDisplayName(model)).tag(Optional(model.id))
                        }
                    }

                    Picker("PDF/BabelDOC Model", selection: $settings.selectedPDFModelProfileID) {
                        Text("Not Selected").tag(Optional<UUID>.none)
                        ForEach(sortedModels, id: \.id) { model in
                            Text(modelDisplayName(model)).tag(Optional(model.id))
                        }
                    }

                    Text("Choose which saved model profile powers HTML translation and the BabelDOC PDF route inside the reader.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var providerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Selection") {
                    Picker("Selected Provider", selection: $selectedProviderID) {
                        Text("New Provider").tag(Optional<UUID>.none)
                        ForEach(sortedProviders, id: \.id) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Button("New") {
                            resetProviderForm()
                        }

                        Button("Delete", role: .destructive) {
                            deleteSelectedProvider()
                        }
                        .disabled(selectedProvider == nil)
                    }
                }

                Section(selectedProvider == nil ? "New Provider" : "Configuration") {
                    TextField("Display name", text: $providerName)
                    TextField("Base URL", text: $providerBaseURL)
                    SecureField("API key", text: $providerAPIKey, prompt: Text(providerAPIKeyPrompt))
                    TextField("Test model", text: $providerTestModel)
                    Toggle("Enabled", isOn: $providerEnabled)
                        .toggleStyle(.checkbox)
                }

                Section("Actions") {
                    HStack(alignment: .center, spacing: 12) {
                        Button("Save") {
                            saveProvider()
                        }
                        Button(isTestingProvider ? "Testing..." : "Test") {
                            testProvider()
                        }
                        .disabled(isTestingProvider)
                    }

                    if let providerStatusMessage {
                        statusLabel(providerStatusMessage)
                    }

                    if let providerOutputPreview, providerOutputPreview.isEmpty == false {
                        Text(providerOutputPreview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var modelTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Selection") {
                    Picker("Selected Model", selection: $selectedModelID) {
                        Text("New Model").tag(Optional<UUID>.none)
                        ForEach(sortedModels, id: \.id) { model in
                            Text(modelDisplayName(model)).tag(Optional(model.id))
                        }
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Button("New") {
                            resetModelForm()
                        }

                        Button("Delete", role: .destructive) {
                            deleteSelectedModel()
                        }
                        .disabled(selectedModel == nil)
                    }
                }

                Section(selectedModel == nil ? "New Model" : "Configuration") {
                    Picker("Provider", selection: $modelProviderID) {
                        Text("Select Provider").tag(Optional<UUID>.none)
                        ForEach(sortedProviders, id: \.id) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }
                    TextField("Profile name", text: $modelName)
                    TextField("Model name", text: $modelIdentifier)
                    TextField("Temperature", text: $modelTemperature)
                    TextField("Top-P", text: $modelTopP)
                    TextField("Max tokens", text: $modelMaxTokens)
                    Toggle("Enabled", isOn: $modelEnabled)
                        .toggleStyle(.checkbox)
                }

                Section("Actions") {
                    HStack(alignment: .center, spacing: 12) {
                        Button("Save") {
                            saveModel()
                        }
                        Button(isTestingModel ? "Testing..." : "Test") {
                            testModel()
                        }
                        .disabled(isTestingModel)
                    }

                    if let selectedModelLastTestedAt {
                        Text("Last tested: \(selectedModelLastTestedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let modelStatusMessage {
                        statusLabel(modelStatusMessage)
                    }

                    if let modelOutputPreview, modelOutputPreview.isEmpty == false {
                        Text(modelOutputPreview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    @ViewBuilder
    private func statusLabel(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(message.hasPrefix("Error") ? .red : .secondary)
            .textSelection(.enabled)
    }

    private func loadInitialSelectionIfNeeded() {
        normalizeSelections()
        if selectedProviderID == nil {
            selectedProviderID = sortedProviders.first?.id
        }
        if selectedModelID == nil {
            selectedModelID = sortedModels.first?.id
        }
        if selectedProviderID == nil {
            resetProviderForm()
        } else {
            applySelectedProvider()
        }
        if selectedModelID == nil {
            resetModelForm()
        } else {
            applySelectedModel()
        }
    }

    private func normalizeSelections() {
        if let currentProviderID = selectedProviderID,
           providers.contains(where: { $0.id == currentProviderID }) == false {
            selectedProviderID = nil
        }
        if let currentModelID = selectedModelID,
           models.contains(where: { $0.id == currentModelID }) == false {
            selectedModelID = nil
        }
        if let htmlModelID = settings.selectedHTMLModelProfileID,
           models.contains(where: { $0.id == htmlModelID }) == false {
            settings.selectedHTMLModelProfileID = nil
        }
        if let pdfModelID = settings.selectedPDFModelProfileID,
           models.contains(where: { $0.id == pdfModelID }) == false {
            settings.selectedPDFModelProfileID = nil
        }
    }

    private func applySelectedProvider() {
        guard let provider = selectedProvider else {
            resetProviderForm()
            return
        }
        providerName = provider.name
        providerBaseURL = provider.baseURL
        providerAPIKey = ""
        providerTestModel = provider.testModel
        providerEnabled = provider.isEnabled
        providerHasStoredAPIKey = hasStoredAPIKey(ref: provider.apiKeyRef)
    }

    private func applySelectedModel() {
        guard let model = selectedModel else {
            resetModelForm()
            return
        }
        modelProviderID = model.providerID
        modelName = model.name
        modelIdentifier = model.modelName
        modelTemperature = model.temperature.map { String($0) } ?? ""
        modelTopP = model.topP.map { String($0) } ?? ""
        modelMaxTokens = model.maxTokens.map { String($0) } ?? ""
        modelEnabled = model.isEnabled
    }

    private func resetProviderForm() {
        selectedProviderID = nil
        providerName = ""
        providerBaseURL = "https://api.openai.com/v1"
        providerAPIKey = ""
        providerTestModel = ""
        providerEnabled = true
        providerHasStoredAPIKey = false
        providerStatusMessage = nil
        providerOutputPreview = nil
    }

    private func resetModelForm() {
        selectedModelID = nil
        modelProviderID = sortedProviders.first?.id
        modelName = ""
        modelIdentifier = ""
        modelTemperature = ""
        modelTopP = ""
        modelMaxTokens = ""
        modelEnabled = true
        modelStatusMessage = nil
        modelOutputPreview = nil
    }

    private func saveProvider() {
        do {
            let normalizedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedName.isEmpty == false else {
                throw SettingsValidationError.message("Provider name cannot be empty.")
            }

            let normalizedBaseURL = try validator.normalizedBaseURL(providerBaseURL)
            let normalizedTestModel = try validator.validateModelName(providerTestModel)
            let now = Date()

            let provider: LLMProviderProfile
            if let existing = selectedProvider {
                provider = existing
            } else {
                let providerID = UUID()
                provider = LLMProviderProfile(
                    id: providerID,
                    name: normalizedName,
                    baseURL: normalizedBaseURL,
                    apiKeyRef: LLMConfigurationBootstrapper.makeAPIKeyRef(providerID: providerID),
                    testModel: normalizedTestModel,
                    isEnabled: providerEnabled,
                    createdAt: now,
                    modifiedAt: now
                )
                modelContext.insert(provider)
            }

            provider.name = normalizedName
            provider.baseURL = normalizedBaseURL
            provider.testModel = normalizedTestModel
            provider.isEnabled = providerEnabled
            provider.modifiedAt = now

            let trimmedAPIKey = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAPIKey.isEmpty == false {
                try keychainStore.save(trimmedAPIKey, account: provider.apiKeyRef)
            } else if hasStoredAPIKey(ref: provider.apiKeyRef) == false {
                throw LLMProviderValidationError.emptyAPIKey
            }

            settings.didBootstrapLLMProfiles = true
            settings.modifiedAt = now
            try modelContext.save()

            selectedProviderID = provider.id
            providerAPIKey = ""
            providerHasStoredAPIKey = true
            providerStatusMessage = "Provider saved."
            providerOutputPreview = nil
        } catch {
            providerStatusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func deleteSelectedProvider() {
        guard let provider = selectedProvider else { return }

        let relatedModelIDs = Set(models.filter { $0.providerID == provider.id }.map(\.id))
        for model in models where relatedModelIDs.contains(model.id) {
            modelContext.delete(model)
        }
        if let htmlModelID = settings.selectedHTMLModelProfileID, relatedModelIDs.contains(htmlModelID) {
            settings.selectedHTMLModelProfileID = nil
        }
        if let pdfModelID = settings.selectedPDFModelProfileID, relatedModelIDs.contains(pdfModelID) {
            settings.selectedPDFModelProfileID = nil
        }
        modelContext.delete(provider)

        do {
            settings.modifiedAt = Date()
            try modelContext.save()
            resetProviderForm()
            if let selectedModelID, relatedModelIDs.contains(selectedModelID) {
                resetModelForm()
            }
            providerStatusMessage = "Provider deleted."
            providerOutputPreview = nil
        } catch {
            providerStatusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func testProvider() {
        isTestingProvider = true
        providerStatusMessage = "Testing provider..."
        providerOutputPreview = nil

        Task { @MainActor in
            defer { isTestingProvider = false }

            do {
                let apiKey: String
                let trimmedAPIKey = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedAPIKey.isEmpty == false {
                    apiKey = trimmedAPIKey
                } else if let selectedProvider {
                    apiKey = try loadStoredAPIKey(ref: selectedProvider.apiKeyRef)
                } else {
                    throw LLMProviderValidationError.emptyAPIKey
                }

                let result = try await validator.testConnection(
                    baseURL: providerBaseURL,
                    apiKey: apiKey,
                    model: providerTestModel
                )

                providerStatusMessage = "Provider test passed in \(result.latencyMs) ms."
                providerOutputPreview = result.outputPreview
            } catch {
                providerStatusMessage = "Error: \(error.localizedDescription)"
                providerOutputPreview = nil
            }
        }
    }

    private func saveModel() {
        do {
            guard let modelProviderID else {
                throw SettingsValidationError.message("Select a provider for the model.")
            }

            let normalizedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedName.isEmpty == false else {
                throw SettingsValidationError.message("Model profile name cannot be empty.")
            }

            let validatedIdentifier = try validator.validateModelName(modelIdentifier)
            let temperature = try parseOptionalDouble(modelTemperature, label: "Temperature")
            let topP = try parseOptionalDouble(modelTopP, label: "Top-P")
            let maxTokens = try parseOptionalInt(modelMaxTokens, label: "Max tokens")
            let now = Date()

            let model: LLMModelProfile
            if let existing = selectedModel {
                model = existing
            } else {
                model = LLMModelProfile(
                    providerID: modelProviderID,
                    name: normalizedName,
                    modelName: validatedIdentifier,
                    temperature: temperature,
                    topP: topP,
                    maxTokens: maxTokens,
                    isEnabled: modelEnabled,
                    createdAt: now,
                    modifiedAt: now
                )
                modelContext.insert(model)
            }

            model.providerID = modelProviderID
            model.name = normalizedName
            model.modelName = validatedIdentifier
            model.temperature = temperature
            model.topP = topP
            model.maxTokens = maxTokens
            model.isEnabled = modelEnabled
            model.modifiedAt = now

            settings.didBootstrapLLMProfiles = true
            settings.modifiedAt = now
            try modelContext.save()

            selectedModelID = model.id
            modelStatusMessage = "Model saved."
            modelOutputPreview = nil
        } catch {
            modelStatusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func deleteSelectedModel() {
        guard let model = selectedModel else { return }
        if settings.selectedHTMLModelProfileID == model.id {
            settings.selectedHTMLModelProfileID = nil
        }
        if settings.selectedPDFModelProfileID == model.id {
            settings.selectedPDFModelProfileID = nil
        }
        modelContext.delete(model)

        do {
            settings.modifiedAt = Date()
            try modelContext.save()
            resetModelForm()
            modelStatusMessage = "Model deleted."
            modelOutputPreview = nil
        } catch {
            modelStatusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func testModel() {
        isTestingModel = true
        modelStatusMessage = "Testing model..."
        modelOutputPreview = nil

        Task { @MainActor in
            defer { isTestingModel = false }

            do {
                guard let modelProviderID else {
                    throw SettingsValidationError.message("Select a provider for the model.")
                }
                guard let provider = providers.first(where: { $0.id == modelProviderID }) else {
                    throw LLMRouteError.providerNotFound
                }

                let apiKey = try loadStoredAPIKey(ref: provider.apiKeyRef)
                let result = try await validator.testConnection(
                    baseURL: provider.baseURL,
                    apiKey: apiKey,
                    model: modelIdentifier,
                    temperature: try parseOptionalDouble(modelTemperature, label: "Temperature"),
                    topP: try parseOptionalDouble(modelTopP, label: "Top-P"),
                    maxTokens: try parseOptionalInt(modelMaxTokens, label: "Max tokens")
                )

                if let selectedModel {
                    selectedModel.lastTestedAt = Date()
                    selectedModel.modifiedAt = Date()
                    try? modelContext.save()
                }

                modelStatusMessage = "Model test passed in \(result.latencyMs) ms."
                modelOutputPreview = result.outputPreview
            } catch {
                modelStatusMessage = "Error: \(error.localizedDescription)"
                modelOutputPreview = nil
            }
        }
    }

    private func installBabelDOC() {
        isInstallingBabelDOC = true
        generalStatusMessage = "Installing BabelDOC..."

        Task { @MainActor in
            defer { isInstallingBabelDOC = false }

            do {
                let result = try await BabelDocToolManager().installOrUpdateBabelDOC(version: settings.babelDocVersion)
                if result.exitCode == 0 {
                    await refreshInstalledBabelDOCVersion()
                    if let installedBabelDocVersion {
                        generalStatusMessage = "BabelDOC is ready. Installed version: \(installedBabelDocVersion)."
                    } else {
                        generalStatusMessage = "BabelDOC is ready."
                    }
                } else {
                    generalStatusMessage = "Error: \(result.combinedOutput)"
                }
            } catch {
                generalStatusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func refreshInstalledBabelDOCVersion() async {
        isLoadingInstalledBabelDocVersion = true
        defer { isLoadingInstalledBabelDocVersion = false }

        do {
            installedBabelDocVersion = try await BabelDocToolManager().installedVersion()
        } catch {
            installedBabelDocVersion = nil
        }
    }

    private func loadStoredAPIKey(ref: String) throws -> String {
        let value = try keychainStore.load(account: ref)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty == false else {
            throw LLMProviderValidationError.emptyAPIKey
        }
        return value
    }

    private func hasStoredAPIKey(ref: String) -> Bool {
        ((try? keychainStore.load(account: ref)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func modelDisplayName(_ model: LLMModelProfile) -> String {
        let providerName = providers.first(where: { $0.id == model.providerID })?.name ?? "Unknown Provider"
        return "\(providerName) / \(model.name)"
    }

    private func parseOptionalDouble(_ value: String, label: String) throws -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let parsed = Double(trimmed) else {
            throw SettingsValidationError.message("\(label) must be a number.")
        }
        return parsed
    }

    private func parseOptionalInt(_ value: String, label: String) throws -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let parsed = Int(trimmed) else {
            throw SettingsValidationError.message("\(label) must be an integer.")
        }
        return parsed
    }
}

private enum SettingsValidationError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
