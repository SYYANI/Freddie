import AppKit
import SwiftData
import SwiftUI

private enum SettingsTab: String, Hashable {
    case general
    case reader
    case digest
    case providers
    case models
}

enum SettingsGeneralStatusSource: Equatable {
    case generic
    case babelDocReady
}

struct SettingsGeneralStatus: Equatable {
    var message: String?
    var source: SettingsGeneralStatusSource?

    static func generic(_ message: String?) -> Self {
        Self(message: message, source: message == nil ? nil : .generic)
    }

    static func babelDocReady(installedVersion: String?, bundle: Bundle) -> Self {
        guard let installedVersion else {
            return Self()
        }

        return Self(
            message: String(
                format: String(localized: "BabelDOC is ready. Installed version: %@.", bundle: bundle),
                installedVersion
            ),
            source: .babelDocReady
        )
    }

    mutating func syncInstalledBabelDocVersion(_ installedVersion: String?, bundle: Bundle) {
        guard source == .babelDocReady else { return }

        guard let installedVersion else {
            self = Self()
            return
        }

        self = .babelDocReady(installedVersion: installedVersion, bundle: bundle)
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Query private var settingsRows: [AppSettings]
    @Query private var papers: [Paper]
    @Query(sort: [SortDescriptor(\LLMProviderProfile.modifiedAt, order: .reverse)]) private var providers: [LLMProviderProfile]
    @Query(sort: [SortDescriptor(\LLMModelProfile.modifiedAt, order: .reverse)]) private var models: [LLMModelProfile]

    var body: some View {
        Group {
            if let settings = settingsRows.first {
                SettingsForm(
                    settings: settings,
                    providers: providers,
                    models: models,
                    paperCount: papers.count
                )
            } else {
                ProgressView()
                    .task {
                        _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsWindowCenteringView())
    }
}

private struct SettingsForm: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle

    @Bindable var settings: AppSettings
    let providers: [LLMProviderProfile]
    let models: [LLMModelProfile]
    let paperCount: Int

    @AppStorage("ReadPaper.Settings.SelectedTab") private var selectedTabRawValue = SettingsTab.general.rawValue
    @AppStorage("ReadPaper.Settings.DidDismissGettingStarted") private var didDismissGettingStarted = false
    @AppStorage(BabelDocInstallSource.userDefaultsKey) private var babelDocInstallSourceRawValue = BabelDocInstallSource.official.rawValue
    @AppStorage(PaperDigestExportConfiguration.templateKey) private var digestExportTemplate = PaperDigestExportPolicy.defaultMarkdownTemplate
    @AppStorage(PaperDigestExportConfiguration.directoryDisplayPathKey) private var digestExportDirectoryPath = ""

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
    @State private var showsModelAdvancedOptions = false

    @State private var generalStatus = SettingsGeneralStatus()
    @State private var isInstallingBabelDOC = false
    @State private var isRemovingBabelDOC = false
    @State private var hasManagedBabelDOCFiles = false
    @State private var babelDocInstallTask: Task<Void, Never>?
    @State private var installedBabelDocVersion: String?
    @State private var isLoadingInstalledBabelDocVersion = false
    @State private var latestBabelDocVersion: String?
    @State private var isLoadingLatestBabelDocVersion = false
    @State private var digestTemplateInsertion: String?
    @State private var digestStatusMessage: String?

    private let keychainStore = KeychainStore()
    private let validator = LLMProviderValidationUseCase()

    private var sortedProviders: [LLMProviderProfile] {
        providers.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled
            }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    private var sortedModels: [LLMModelProfile] {
        models.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled
            }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
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

    private var configuredProviderCount: Int {
        readyProviders.count
    }

    private var readyProviders: [LLMProviderProfile] {
        sortedProviders.filter { provider in
            provider.isEnabled && hasStoredAPIKey(ref: provider.apiKeyRef)
        }
    }

    private var readyProviderIDs: Set<UUID> {
        Set(readyProviders.map(\.id))
    }

    private var readyModels: [LLMModelProfile] {
        sortedModels.filter { model in
            model.isEnabled && readyProviderIDs.contains(model.providerID)
        }
    }

    private var readyModelIDs: Set<UUID> {
        Set(readyModels.map(\.id))
    }

    private var readyModelCount: Int {
        readyModels.count
    }

    private var hasHTMLRouteSelection: Bool {
        guard let modelID = settings.selectedHTMLModelProfileID else { return false }
        return readyModelIDs.contains(modelID)
    }

    private var hasPDFRouteSelection: Bool {
        guard let modelID = settings.selectedPDFModelProfileID else { return false }
        return readyModelIDs.contains(modelID)
    }

    private var providerAPIKeyPrompt: String {
        if providerAPIKey.isEmpty, providerHasStoredAPIKey {
            return String(repeating: "•", count: 12)
        }
        return ""
    }

    private var targetLanguageBinding: Binding<String> {
        Binding(
            get: { settings.targetLanguage },
            set: { newValue in
                guard settings.targetLanguage != newValue else { return }
                settings.targetLanguage = newValue
                settings.modifiedAt = Date()
            }
        )
    }

    private var appLanguageBinding: Binding<String?> {
        Binding(
            get: { LanguageManager.shared.languageOverride },
            set: { LanguageManager.shared.setLanguage($0) }
        )
    }

    private var babelDocInstallSourceBinding: Binding<BabelDocInstallSource> {
        Binding(
            get: { BabelDocInstallSource(rawValue: babelDocInstallSourceRawValue) ?? .official },
            set: { babelDocInstallSourceRawValue = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
            generalTab
                .tag(SettingsTab.general)
                .tabItem {
                    Label(String(localized: "General", bundle: bundle), systemImage: "gearshape")
                }

            readerTab
                .tag(SettingsTab.reader)
                .tabItem {
                    Label(String(localized: "Reader", bundle: bundle), systemImage: "book.closed")
                }

            digestTab
                .tag(SettingsTab.digest)
                .tabItem {
                    Label(String(localized: "Digest", bundle: bundle), systemImage: "doc.plaintext")
                }

            providerTab
                .tag(SettingsTab.providers)
                .tabItem {
                    Label(String(localized: "Providers", bundle: bundle), systemImage: "network")
                }

            modelTab
                .tag(SettingsTab.models)
                .tabItem {
                    Label(String(localized: "Models", bundle: bundle), systemImage: "sparkles.rectangle.stack")
                }
        }
        .formStyle(.grouped)
        .task {
            _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
            loadInitialSelectionIfNeeded()
            await refreshInstalledBabelDOCVersion()
            await refreshLatestBabelDOCVersion()
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
        .onChange(of: babelDocInstallSourceRawValue) { _, _ in
            Task { @MainActor in
                await refreshLatestBabelDOCVersion()
            }
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
                Section(String(localized: "Getting Started", bundle: bundle)) {
                    if didDismissGettingStarted {
                        dismissedGettingStartedPanel
                    } else {
                        gettingStartedPanel
                    }
                }

                Section(String(localized: "Language", bundle: bundle)) {
                    Picker(String(localized: "App language", bundle: bundle), selection: appLanguageBinding) {
                        Text("Follow System", bundle: bundle).tag(Optional<String>.none)
                        ForEach(AppLocalization.supportedLanguages) { option in
                            Text(verbatim: option.displayName).tag(Optional(option.code))
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Choose whether ReadPaper follows the macOS language setting or always uses English or Simplified Chinese.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "Translation", bundle: bundle)) {
                    Picker(String(localized: "Target language", bundle: bundle), selection: targetLanguageBinding) {
                        ForEach(TranslationTargetLanguage.supported) { option in
                            Text(option.nativeName).tag(option.code)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(
                        String(
                            format: String(localized: "HTML concurrency: %d", bundle: bundle),
                            settings.htmlTranslationConcurrency
                        ),
                        value: $settings.htmlTranslationConcurrency,
                        in: 1...12
                    )
                    Stepper(
                        String(
                            format: String(localized: "BabelDOC QPS: %d", bundle: bundle),
                            settings.babelDocQPS
                        ),
                        value: $settings.babelDocQPS,
                        in: 1...20
                    )

                    Text("Controls the default translation target and the amount of parallel work used for HTML and BabelDOC translation jobs. Supported languages: English and Simplified Chinese.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "BabelDOC", bundle: bundle)) {
                    LabeledContent(String(localized: "Current installed version", bundle: bundle)) {
                        if isLoadingInstalledBabelDocVersion {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(installedBabelDocVersion ?? String(localized: "Not installed", bundle: bundle))
                                .foregroundStyle(installedBabelDocVersion == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }

                    LabeledContent(String(localized: "Latest available version", bundle: bundle)) {
                        if isLoadingLatestBabelDocVersion {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(latestBabelDocVersion ?? String(localized: "Unavailable", bundle: bundle))
                                .foregroundStyle(latestBabelDocVersion == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }

                    Picker(String(localized: "Install source", bundle: bundle), selection: babelDocInstallSourceBinding) {
                        Text("Official PyPI", bundle: bundle).tag(BabelDocInstallSource.official)
                        Text("Tsinghua mirror", bundle: bundle).tag(BabelDocInstallSource.tsinghua)
                    }
                    .pickerStyle(.segmented)

                    SettingsFieldRow(String(localized: "Target version", bundle: bundle)) {
                        SettingsPlainTextField(text: $settings.babelDocVersion)
                    }

                    HStack(spacing: 10) {
                        Button(
                            isInstallingBabelDOC
                                ? String(localized: "Installing...", bundle: bundle)
                                : String(localized: "Install or update BabelDOC", bundle: bundle)
                        ) {
                            installBabelDOC()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isInstallingBabelDOC || isRemovingBabelDOC)

                        if isInstallingBabelDOC {
                            Button(String(localized: "Cancel", bundle: bundle)) {
                                cancelBabelDOCInstallation()
                            }
                        } else {
                            Button(String(localized: "Remove BabelDOC", bundle: bundle), role: .destructive) {
                                removeBabelDOC()
                            }
                            .disabled(isRemovingBabelDOC || hasManagedBabelDOCFiles == false)
                        }
                    }

                    Text("The PDF translation tool is managed separately from the reader. Updating it here keeps the BabelDOC route ready when a paper needs full-PDF translation.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Set the target version to \"latest\" to resolve the newest BabelDOC release from the selected source when installing. You can still enter a specific version to pin it.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Choose which package index uv uses for BabelDOC installs. Official PyPI uses the default upstream index, while Tsinghua mirror uses the TUNA mirror for faster access in some regions. Latest version lookup follows the selected source.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let generalStatusMessage = generalStatus.message {
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
                Section(String(localized: "How to use translation", bundle: bundle)) {
                    Text("After selecting routes here, go back to the main window, import a paper, open it in the reader, and use the Translate button in the toolbar.", bundle: bundle)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("HTML translation works best for arXiv papers with HTML content. PDF translation uses the PDF/BabelDOC route and can produce translated or side-by-side PDF reading modes.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(String(localized: "Translation Routes", bundle: bundle)) {
                    Picker(String(localized: "HTML Model", bundle: bundle), selection: $settings.selectedHTMLModelProfileID) {
                        Text("Not Selected", bundle: bundle).tag(Optional<UUID>.none)
                        ForEach(sortedModels, id: \.id) { model in
                            Text(modelDisplayName(model)).tag(Optional(model.id))
                        }
                    }

                    Picker(String(localized: "PDF/BabelDOC Model", bundle: bundle), selection: $settings.selectedPDFModelProfileID) {
                        Text("Not Selected", bundle: bundle).tag(Optional<UUID>.none)
                        ForEach(sortedModels, id: \.id) { model in
                            Text(modelDisplayName(model)).tag(Optional(model.id))
                        }
                    }

                    Text("Choose which saved model profile powers HTML translation and the BabelDOC PDF route inside the reader.", bundle: bundle)
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

    private var digestTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section(String(localized: "Digest Export", bundle: bundle)) {
                    LabeledContent(String(localized: "Export directory", bundle: bundle)) {
                        Text(
                            digestExportDirectoryPath.isEmpty
                                ? String(localized: "Not configured", bundle: bundle)
                                : digestExportDirectoryPath
                        )
                        .foregroundStyle(digestExportDirectoryPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    }

                    HStack(spacing: 10) {
                        Button(String(localized: "Choose Folder", bundle: bundle)) {
                            chooseDigestExportDirectory()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(String(localized: "Clear", bundle: bundle), role: .destructive) {
                            clearDigestExportDirectory()
                        }
                        .disabled(digestExportDirectoryPath.isEmpty)
                    }

                    Text("Markdown export requires a configured folder. Copy Digest can still use the template without an export folder.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "Markdown Template", bundle: bundle)) {
                    SettingsTemplateTextEditor(
                        text: $digestExportTemplate,
                        pendingInsertion: $digestTemplateInsertion
                    )
                    .frame(minHeight: 280)

                    HStack(spacing: 10) {
                        Menu {
                            ForEach(PaperDigestExportPolicy.templatePlaceholderTokens, id: \.self) { token in
                                Button(token) {
                                    digestTemplateInsertion = token
                                }
                            }
                        } label: {
                            Label(String(localized: "Insert Placeholder", bundle: bundle), systemImage: "text.badge.plus")
                        }

                        Button(String(localized: "Reset Default Template", bundle: bundle)) {
                            digestExportTemplate = PaperDigestExportPolicy.defaultMarkdownTemplate
                            digestStatusMessage = String(localized: "Default digest template restored.", bundle: bundle)
                        }
                    }

                    Text("Available placeholders: {{dateISO}}, {{title}}, {{slug}}, {{authors}}, {{identifier}}, {{sourceTitle}}, {{sourceURL}}, {{metadataBlock}}, {{abstractBlock}}, {{notesBlock}}, {{generatedBy}}.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let digestStatusMessage {
                        statusLabel(digestStatusMessage)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var providerTab: some View {
        llmWorkspace(
            leftPanel: providerListPanel,
            rightPanel: providerDetailPanel
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var modelTab: some View {
        llmWorkspace(
            leftPanel: modelListPanel,
            rightPanel: modelDetailPanel
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var providerListPanel: some View {
        entityListPanel(
            title: String(localized: "Providers", bundle: bundle),
            count: sortedProviders.count
        ) {
            List(selection: $selectedProviderID) {
                ForEach(sortedProviders, id: \.id) { provider in
                    providerListRow(provider)
                        .tag(Optional(provider.id))
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        } toolbar: {
            Button {
                resetProviderForm()
            } label: {
                Image(systemName: "plus")
            }
            .help(String(localized: "New Provider", bundle: bundle))

            Button(role: .destructive) {
                deleteSelectedProvider()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedProvider == nil)
            .help(String(localized: "Delete", bundle: bundle))
        }
    }

    private var providerDetailPanel: some View {
        Form {
            Section(String(localized: "Providers", bundle: bundle)) {
                Text("Create one provider for each OpenAI-compatible endpoint you want to use. The API key is stored in Keychain, so leaving the API key field blank while editing an existing provider keeps the saved key.", bundle: bundle)
                    .fixedSize(horizontal: false, vertical: true)

                Text("For a typical setup, fill in the service base URL, paste the API key, set a lightweight test model, then click Save and Test.", bundle: bundle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(String(localized: "Configuration", bundle: bundle)) {
                SettingsFieldRow(String(localized: "Display name", bundle: bundle)) {
                    SettingsPlainTextField(text: $providerName)
                }
                SettingsFieldRow(String(localized: "Base URL", bundle: bundle)) {
                    SettingsPlainTextField(text: $providerBaseURL)
                }
                SettingsFieldRow(String(localized: "API key", bundle: bundle)) {
                    SettingsSecureTextField(text: $providerAPIKey, placeholder: providerAPIKeyPrompt)
                }
                SettingsFieldRow(String(localized: "Test model", bundle: bundle)) {
                    SettingsPlainTextField(text: $providerTestModel)
                }
                SettingsFieldRow(String(localized: "Enabled", bundle: bundle)) {
                    Toggle("", isOn: $providerEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }
            }

            Section(String(localized: "Actions", bundle: bundle)) {
                HStack(spacing: 10) {
                    Button(String(localized: "Save", bundle: bundle)) {
                        saveProvider()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(String(localized: "Reset", bundle: bundle)) {
                        if selectedProvider == nil {
                            resetProviderForm()
                        } else {
                            applySelectedProvider()
                        }
                    }

                    Button(
                        isTestingProvider
                            ? String(localized: "Testing...", bundle: bundle)
                            : String(localized: "Test", bundle: bundle)
                    ) {
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
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modelListPanel: some View {
        entityListPanel(
            title: String(localized: "Models", bundle: bundle),
            count: sortedModels.count
        ) {
            List(selection: $selectedModelID) {
                ForEach(sortedModels, id: \.id) { model in
                    modelListRow(model)
                        .tag(Optional(model.id))
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        } toolbar: {
            Button {
                resetModelForm()
            } label: {
                Image(systemName: "plus")
            }
            .help(String(localized: "New Model", bundle: bundle))

            Button(role: .destructive) {
                deleteSelectedModel()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedModel == nil)
            .help(String(localized: "Delete", bundle: bundle))
        }
    }

    private var modelDetailPanel: some View {
        Form {
            Section(String(localized: "Models", bundle: bundle)) {
                Text("A model profile points to one provider and stores the exact chat model name plus optional sampling parameters. You can create separate profiles for fast HTML translation and heavier PDF work.", bundle: bundle)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Profile name is only for display inside ReadPaper. Model name must match the real model identifier accepted by your provider.", bundle: bundle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(String(localized: "Configuration", bundle: bundle)) {
                SettingsFieldRow(String(localized: "Provider", bundle: bundle)) {
                    Picker(String(localized: "Provider", bundle: bundle), selection: $modelProviderID) {
                        Text("Select Provider", bundle: bundle).tag(Optional<UUID>.none)
                        ForEach(sortedProviders, id: \.id) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }
                    .labelsHidden()
                }
                SettingsFieldRow(String(localized: "Profile name", bundle: bundle)) {
                    SettingsPlainTextField(text: $modelName)
                }
                SettingsFieldRow(String(localized: "Model name", bundle: bundle)) {
                    SettingsPlainTextField(text: $modelIdentifier)
                }
                SettingsFieldRow(String(localized: "Enabled", bundle: bundle)) {
                    Toggle("", isOn: $modelEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }

                DisclosureGroup(isExpanded: $showsModelAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsFieldRow(String(localized: "Temperature", bundle: bundle)) {
                            SettingsPlainTextField(text: $modelTemperature)
                        }
                        SettingsFieldRow(String(localized: "Top-P", bundle: bundle)) {
                            SettingsPlainTextField(text: $modelTopP)
                        }
                        SettingsFieldRow(String(localized: "Max tokens", bundle: bundle)) {
                            SettingsPlainTextField(text: $modelMaxTokens)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced Parameters", bundle: bundle)
                        .font(.subheadline.weight(.medium))
                }
            }

            Section(String(localized: "Actions", bundle: bundle)) {
                HStack(spacing: 10) {
                    Button(String(localized: "Save", bundle: bundle)) {
                        saveModel()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(String(localized: "Reset", bundle: bundle)) {
                        if selectedModel == nil {
                            resetModelForm()
                        } else {
                            applySelectedModel()
                        }
                    }

                    Button(
                        isTestingModel
                            ? String(localized: "Testing...", bundle: bundle)
                            : String(localized: "Test", bundle: bundle)
                    ) {
                        testModel()
                    }
                    .disabled(isTestingModel)
                }

                if let selectedModelLastTestedAt {
                    Text(
                        String(
                            format: String(localized: "Last tested: %@", bundle: bundle),
                            selectedModelLastTestedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    )
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
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func statusLabel(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(AppLocalization.isErrorMessage(message, bundle: bundle) ? .red : .secondary)
            .textSelection(.enabled)
    }

    private func llmWorkspace<LeftPanel: View, RightPanel: View>(
        leftPanel: LeftPanel,
        rightPanel: RightPanel
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            leftPanel
                .frame(width: 310)
                .frame(maxHeight: .infinity)

            rightPanel
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func entityListPanel<ListContent: View, ToolbarContent: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> ListContent,
        @ViewBuilder toolbar: () -> ToolbarContent
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.headline)

                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.16))
                    )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                toolbar()
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private func providerListRow(_ provider: LLMProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(provider.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if hasStoredAPIKey(ref: provider.apiKeyRef) {
                    Image(systemName: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: provider.isEnabled ? "checkmark.circle.fill" : "slash.circle")
                    .font(.caption)
                    .foregroundStyle(provider.isEnabled ? .green : .secondary)
            }

            Text(provider.baseURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .opacity(provider.isEnabled ? 1 : 0.68)
    }

    private func modelListRow(_ model: LLMModelProfile) -> some View {
        let providerName = providers.first(where: { $0.id == model.providerID })?.name
            ?? String(localized: "Unknown Provider", bundle: bundle)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(model.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if model.lastTestedAt != nil {
                    Image(systemName: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: model.isEnabled ? "checkmark.circle.fill" : "slash.circle")
                    .font(.caption)
                    .foregroundStyle(model.isEnabled ? .green : .secondary)
            }

            Text(providerName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(model.modelName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .opacity(model.isEnabled ? 1 : 0.68)
    }

    private var gettingStartedPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up your translation route once, then come back to the reader to import papers and translate them.", bundle: bundle)
                .fixedSize(horizontal: false, vertical: true)

            onboardingStep(
                title: String(localized: "1. Save a provider API key", bundle: bundle),
                detail: configuredProviderCount > 0
                    ? String(
                        format: String(localized: "%d provider%@ ready.", bundle: bundle),
                        configuredProviderCount,
                        configuredProviderCount == 1 ? "" : "s"
                    )
                    : String(localized: "Open Providers, fill in the base URL, API key, and test model, then save and test it.", bundle: bundle),
                isComplete: configuredProviderCount > 0,
                actionTitle: String(localized: "Open Providers", bundle: bundle),
                targetTab: .providers
            )

            onboardingStep(
                title: String(localized: "2. Create a model profile", bundle: bundle),
                detail: readyModelCount > 0
                    ? String(
                        format: String(localized: "%d model profile%@ ready to use.", bundle: bundle),
                        readyModelCount,
                        readyModelCount == 1 ? "" : "s"
                    )
                    : String(localized: "Create at least one enabled model profile and attach it to a provider with a saved API key.", bundle: bundle),
                isComplete: readyModelCount > 0,
                actionTitle: String(localized: "Open Models", bundle: bundle),
                targetTab: .models
            )

            onboardingStep(
                title: String(localized: "3. Choose HTML and PDF routes", bundle: bundle),
                detail: hasHTMLRouteSelection && hasPDFRouteSelection
                    ? String(localized: "HTML and PDF routes are both selected.", bundle: bundle)
                    : String(localized: "Choose which model powers HTML translation and which model is used by BabelDOC/PDF translation.", bundle: bundle),
                isComplete: hasHTMLRouteSelection && hasPDFRouteSelection,
                actionTitle: String(localized: "Open Reader", bundle: bundle),
                targetTab: .reader
            )

            onboardingStep(
                title: String(localized: "4. Import and translate papers", bundle: bundle),
                detail: paperCount > 0
                    ? String(
                        format: String(localized: "%d paper%@ already in your library. Use Translate in the reader toolbar.", bundle: bundle),
                        paperCount,
                        paperCount == 1 ? "" : "s"
                    )
                    : String(localized: "Return to the main window, add an arXiv paper or local PDF, then use Translate in the reader toolbar.", bundle: bundle),
                isComplete: paperCount > 0,
                actionTitle: nil,
                targetTab: nil
            )

            Button(String(localized: "Skip", bundle: bundle)) {
                didDismissGettingStarted = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }

    private var dismissedGettingStartedPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)

            Text("Getting started guide is hidden.", bundle: bundle)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(String(localized: "Show Guide Again", bundle: bundle)) {
                didDismissGettingStarted = false
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }

    private func onboardingStep(
        title: String,
        detail: String,
        isComplete: Bool,
        actionTitle: String?,
        targetTab: SettingsTab?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isComplete ? .green : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let actionTitle, let targetTab {
                Button(actionTitle) {
                    selectedTabRawValue = targetTab.rawValue
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
        providerStatusMessage = nil
        providerOutputPreview = nil
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
        showsModelAdvancedOptions = model.temperature != nil || model.topP != nil || model.maxTokens != nil
        modelStatusMessage = nil
        modelOutputPreview = nil
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
        showsModelAdvancedOptions = false
        modelStatusMessage = nil
        modelOutputPreview = nil
    }

    private func saveProvider() {
        do {
            let normalizedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedName.isEmpty == false else {
                throw SettingsValidationError.message(String(localized: "Provider name cannot be empty.", bundle: bundle))
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

            settings.modifiedAt = now
            try modelContext.save()

            selectedProviderID = provider.id
            providerAPIKey = ""
            providerHasStoredAPIKey = true
            providerStatusMessage = String(localized: "Provider saved.", bundle: bundle)
            providerOutputPreview = nil
        } catch {
            providerStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
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
            providerStatusMessage = String(localized: "Provider deleted.", bundle: bundle)
            providerOutputPreview = nil
        } catch {
            providerStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        }
    }

    private func testProvider() {
        isTestingProvider = true
        providerStatusMessage = String(localized: "Testing provider...", bundle: bundle)
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

                providerStatusMessage = String(
                    format: String(localized: "Provider test passed in %d ms.", bundle: bundle),
                    result.latencyMs
                )
                providerOutputPreview = result.outputPreview
            } catch {
                providerStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
                providerOutputPreview = nil
            }
        }
    }

    private func saveModel() {
        do {
            guard let modelProviderID else {
                throw SettingsValidationError.message(String(localized: "Select a provider for the model.", bundle: bundle))
            }

            let normalizedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedName.isEmpty == false else {
                throw SettingsValidationError.message(String(localized: "Model profile name cannot be empty.", bundle: bundle))
            }

            let validatedIdentifier = try validator.validateModelName(modelIdentifier)
            let temperature = try parseOptionalDouble(modelTemperature, label: String(localized: "Temperature", bundle: bundle))
            let topP = try parseOptionalDouble(modelTopP, label: String(localized: "Top-P", bundle: bundle))
            let maxTokens = try parseOptionalInt(modelMaxTokens, label: String(localized: "Max tokens", bundle: bundle))
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

            settings.modifiedAt = now
            try modelContext.save()

            selectedModelID = model.id
            modelStatusMessage = String(localized: "Model saved.", bundle: bundle)
            modelOutputPreview = nil
        } catch {
            modelStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
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
            modelStatusMessage = String(localized: "Model deleted.", bundle: bundle)
            modelOutputPreview = nil
        } catch {
            modelStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        }
    }

    private func testModel() {
        isTestingModel = true
        modelStatusMessage = String(localized: "Testing model...", bundle: bundle)
        modelOutputPreview = nil

        Task { @MainActor in
            defer { isTestingModel = false }

            do {
                guard let modelProviderID else {
                    throw SettingsValidationError.message(String(localized: "Select a provider for the model.", bundle: bundle))
                }
                guard let provider = providers.first(where: { $0.id == modelProviderID }) else {
                    throw LLMRouteError.providerNotFound
                }

                let apiKey = try loadStoredAPIKey(ref: provider.apiKeyRef)
                let result = try await validator.testConnection(
                    baseURL: provider.baseURL,
                    apiKey: apiKey,
                    model: modelIdentifier,
                    temperature: try parseOptionalDouble(modelTemperature, label: String(localized: "Temperature", bundle: bundle)),
                    topP: try parseOptionalDouble(modelTopP, label: String(localized: "Top-P", bundle: bundle)),
                    maxTokens: try parseOptionalInt(modelMaxTokens, label: String(localized: "Max tokens", bundle: bundle))
                )

                if let selectedModel {
                    selectedModel.lastTestedAt = Date()
                    selectedModel.modifiedAt = Date()
                    try? modelContext.save()
                }

                modelStatusMessage = String(
                    format: String(localized: "Model test passed in %d ms.", bundle: bundle),
                    result.latencyMs
                )
                modelOutputPreview = result.outputPreview
            } catch {
                modelStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
                modelOutputPreview = nil
            }
        }
    }

    private func installBabelDOC() {
        guard !isInstallingBabelDOC, !isRemovingBabelDOC else { return }

        isInstallingBabelDOC = true
        generalStatus = .generic(String(localized: "Installing BabelDOC...", bundle: bundle))

        let task = Task { @MainActor in
            defer {
                isInstallingBabelDOC = false
                babelDocInstallTask = nil
            }

            do {
                let result = try await BabelDocToolManager().installOrUpdateBabelDOC(version: settings.babelDocVersion)
                if result.exitCode == 0 {
                    await refreshInstalledBabelDOCVersion()
                    generalStatus = .babelDocReady(installedVersion: installedBabelDocVersion, bundle: bundle)
                } else {
                    generalStatus = .generic(
                        AppLocalization.format("Error: %@", bundle: bundle, result.combinedOutput)
                    )
                }
            } catch is CancellationError {
                await refreshInstalledBabelDOCVersion()
                generalStatus = .generic(
                    String(localized: "Cancelled BabelDOC installation and removed downloaded cache.", bundle: bundle)
                )
            } catch {
                generalStatus = .generic(AppLocalization.errorMessage(error, bundle: bundle))
            }
        }

        babelDocInstallTask = task
    }

    private func cancelBabelDOCInstallation() {
        guard isInstallingBabelDOC else { return }
        generalStatus = .generic(String(localized: "Cancelling BabelDOC installation...", bundle: bundle))
        babelDocInstallTask?.cancel()
    }

    private func removeBabelDOC() {
        guard !isInstallingBabelDOC, !isRemovingBabelDOC else { return }

        isRemovingBabelDOC = true
        generalStatus = .generic(String(localized: "Removing BabelDOC...", bundle: bundle))

        Task { @MainActor in
            defer { isRemovingBabelDOC = false }

            do {
                try BabelDocToolManager().removeBabelDOC()
                await refreshInstalledBabelDOCVersion()
                generalStatus = .generic(String(localized: "Removed BabelDOC.", bundle: bundle))
            } catch {
                generalStatus = .generic(AppLocalization.errorMessage(error, bundle: bundle))
            }
        }
    }

    private func refreshInstalledBabelDOCVersion() async {
        isLoadingInstalledBabelDocVersion = true
        defer { isLoadingInstalledBabelDocVersion = false }

        let manager = BabelDocToolManager()
        hasManagedBabelDOCFiles = (try? manager.hasManagedInstallation()) ?? false

        do {
            installedBabelDocVersion = try await manager.installedVersion()
        } catch {
            installedBabelDocVersion = nil
        }

        generalStatus.syncInstalledBabelDocVersion(installedBabelDocVersion, bundle: bundle)
    }

    private func refreshLatestBabelDOCVersion() async {
        isLoadingLatestBabelDocVersion = true
        defer { isLoadingLatestBabelDocVersion = false }

        do {
            latestBabelDocVersion = try await BabelDocToolManager().latestPublishedVersion()
        } catch {
            latestBabelDocVersion = nil
        }
    }

    private func chooseDigestExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", bundle: bundle)
        panel.message = String(localized: "Choose a folder for Markdown digest exports.", bundle: bundle)
        if digestExportDirectoryPath.isEmpty == false {
            panel.directoryURL = URL(fileURLWithPath: digestExportDirectoryPath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }

        do {
            try PaperDigestExportConfiguration().saveExportDirectory(directoryURL)
            digestExportDirectoryPath = directoryURL.path
            digestStatusMessage = String(localized: "Export directory saved.", bundle: bundle)
        } catch {
            digestStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        }
    }

    private func clearDigestExportDirectory() {
        PaperDigestExportConfiguration().clearExportDirectory()
        digestExportDirectoryPath = ""
        digestStatusMessage = String(localized: "Export directory cleared.", bundle: bundle)
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
        let providerName = providers.first(where: { $0.id == model.providerID })?.name
            ?? String(localized: "Unknown Provider", bundle: bundle)
        return "\(providerName) / \(model.name)"
    }

    private func parseOptionalDouble(_ value: String, label: String) throws -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let parsed = Double(trimmed) else {
            throw SettingsValidationError.message(
                String(format: String(localized: "%@ must be a number.", bundle: bundle), label)
            )
        }
        return parsed
    }

    private func parseOptionalInt(_ value: String, label: String) throws -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let parsed = Int(trimmed) else {
            throw SettingsValidationError.message(
                String(format: String(localized: "%@ must be an integer.", bundle: bundle), label)
            )
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

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            content
                .frame(minWidth: 260, idealWidth: 320, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsPlainTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    init(text: Binding<String>, placeholder: String = "") {
        self.placeholder = placeholder
        _text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        configure(textField, coordinator: context.coordinator)
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.placeholderString = placeholder
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.configureEditorIfNeeded(for: nsView)
    }

    private func configure(_ textField: NSTextField, coordinator: Coordinator) {
        textField.delegate = coordinator
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = true
        textField.isAutomaticTextCompletionEnabled = false
        textField.allowsCharacterPickerTouchBarItem = false
        if #available(macOS 15.2, *) {
            textField.allowsWritingTools = false
        }
        if #available(macOS 15.4, *) {
            textField.allowsWritingToolsAffordance = false
        }
        coordinator.configureEditorIfNeeded(for: textField)
    }
}

private struct SettingsSecureTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>, placeholder displayPlaceholder: String = "") {
        self.placeholder = displayPlaceholder.isEmpty ? placeholder : displayPlaceholder
        _text = text
    }

    init(text: Binding<String>, placeholder: String = "") {
        self.placeholder = placeholder
        _text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let textField = NSSecureTextField()
        configure(textField, coordinator: context.coordinator)
        return textField
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        nsView.placeholderString = placeholder
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.configureEditorIfNeeded(for: nsView)
    }

    private func configure(_ textField: NSSecureTextField, coordinator: Coordinator) {
        textField.delegate = coordinator
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = true
        textField.isAutomaticTextCompletionEnabled = false
        textField.allowsCharacterPickerTouchBarItem = false
        if #available(macOS 15.2, *) {
            textField.allowsWritingTools = false
        }
        if #available(macOS 15.4, *) {
            textField.allowsWritingToolsAffordance = false
        }
        coordinator.configureEditorIfNeeded(for: textField)
    }
}

private struct SettingsTemplateTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var pendingInsertion: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        configure(textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        configure(textView)

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, (textView.string as NSString).length),
                length: 0
            ))
        }

        if let pendingInsertion {
            textView.insertText(pendingInsertion, replacementRange: textView.selectedRange())
            text = textView.string
            let insertion = $pendingInsertion
            DispatchQueue.main.async {
                insertion.wrappedValue = nil
            }
        }
    }

    private func configure(_ textView: NSTextView) {
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textShouldEndEditing(_ textObject: NSText) -> Bool {
            if let textView = textObject as? NSTextView {
                textView.unmarkText()
                textView.inputContext?.discardMarkedText()
            }
            return true
        }
    }
}

private struct SettingsWindowCenteringView: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowCenteringNSView {
        SettingsWindowCenteringNSView()
    }

    func updateNSView(_ nsView: SettingsWindowCenteringNSView, context: Context) {}
}

private final class SettingsWindowCenteringNSView: NSView {
    private weak var observedWindow: NSWindow?
    private var didCenterCurrentWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow else { return }

        observedWindow = window
        didCenterCurrentWindow = false
        scheduleCenteringIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleCenteringIfNeeded()
    }

    private func scheduleCenteringIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            self?.centerWindowIfNeeded()
        }
    }

    private func centerWindowIfNeeded() {
        guard didCenterCurrentWindow == false, let settingsWindow = window else { return }

        let anchorWindow = NSApp.windows.first { candidate in
            candidate !== settingsWindow && candidate.isVisible && (candidate.isMainWindow || candidate.isKeyWindow)
        } ?? NSApp.orderedWindows.first { candidate in
            candidate !== settingsWindow && candidate.isVisible
        }

        let targetScreen = anchorWindow?.screen ?? settingsWindow.screen ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? settingsWindow.frame

        var frame = settingsWindow.frame

        if let anchorFrame = anchorWindow?.frame {
            frame.origin.x = anchorFrame.midX - (frame.width / 2)
            frame.origin.y = anchorFrame.midY - (frame.height / 2)
        } else {
            frame.origin.x = visibleFrame.midX - (frame.width / 2)
            frame.origin.y = visibleFrame.midY - (frame.height / 2)
        }

        let maxOriginX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        let maxOriginY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)

        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), maxOriginX)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), maxOriginY)

        settingsWindow.setFrame(frame, display: false)
        didCenterCurrentWindow = true
    }
}

private final class Coordinator: NSObject, NSTextFieldDelegate {
    @Binding private var text: String

    init(text: Binding<String>) {
        _text = text
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }
        text = textField.stringValue
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }
        configureEditorIfNeeded(for: textField)
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        if let textView = fieldEditor as? NSTextView {
            textView.unmarkText()
            textView.inputContext?.discardMarkedText()
        }
        return true
    }

    @MainActor
    func configureEditorIfNeeded(for textField: NSTextField) {
        guard let editor = textField.currentEditor() as? NSTextView else { return }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        if #available(macOS 15.0, *) {
            editor.writingToolsBehavior = .none
        }
    }
}
