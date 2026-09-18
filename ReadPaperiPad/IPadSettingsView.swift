import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum IPadSettingsTab: String, Hashable {
    case general
    case reader
    case digest
    case providers
    case models
}

struct IPadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Query private var settingsRows: [AppSettings]
    @Query(sort: \LLMProviderProfile.modifiedAt, order: .reverse) private var providers: [LLMProviderProfile]
    @Query(sort: \LLMModelProfile.modifiedAt, order: .reverse) private var models: [LLMModelProfile]

    @AppStorage("ReadPaper.Settings.SelectedTab")
    private var selectedTabRawValue = IPadSettingsTab.general.rawValue
    @AppStorage(PDFDisplayAppearance.userDefaultsKey)
    private var pdfDisplayAppearanceRawValue = PDFDisplayAppearance.defaultValue.rawValue
    @AppStorage(PDFTranslationBatchPreference.userDefaultsKey)
    private var pdfTranslationBatchSize = PDFTranslationBatchPreference.defaultValue
    @AppStorage(HTMLReaderTypography.fontSizeUserDefaultsKey)
    private var htmlReaderFontSize = HTMLReaderTypography.defaultFontSize
    @AppStorage(TranslationGlossaryPreference.userDefaultsKey)
    private var translationGlossary = ""
    @AppStorage(BabelDocSemanticHintPreference.userDefaultsKey)
    private var babelDocSemanticHintsEnabled = BabelDocSemanticHintPreference.defaultValue
    @AppStorage(PaperDigestExportConfiguration.templateKey)
    private var digestExportTemplate = PaperDigestExportPolicy.defaultMarkdownTemplate
    @AppStorage(PaperDigestExportConfiguration.directoryDisplayPathKey)
    private var digestExportDirectoryPath = ""

    @State private var selectedProviderID: UUID?
    @State private var providerName = ""
    @State private var providerBaseURL = "https://api.openai.com/v1"
    @State private var providerAPIKey = ""
    @State private var providerTestModel = ""
    @State private var providerAPIStyle: LLMAPIStyle = .chatCompletions
    @State private var providerEnabled = true
    @State private var providerHasStoredAPIKey = false
    @State private var providerStatusMessage: String?
    @State private var providerOutputPreview: String?
    @State private var isTestingProvider = false
    @State private var showsProviderDeleteConfirmation = false

    @State private var selectedModelID: UUID?
    @State private var modelProviderID: UUID?
    @State private var modelName = ""
    @State private var modelIdentifier = ""
    @State private var modelTemperature = ""
    @State private var modelTopP = ""
    @State private var modelMaxTokens = ""
    @State private var modelThinkingMode: LLMThinkingMode?
    @State private var modelReasoningEffort: LLMReasoningEffort?
    @State private var modelEnabled = true
    @State private var modelStatusMessage: String?
    @State private var modelOutputPreview: String?
    @State private var isTestingModel = false
    @State private var showsModelAdvancedOptions = false
    @State private var showsModelDeleteConfirmation = false

    @State private var showsDigestDirectoryImporter = false
    @State private var digestStatusMessage: String?
    @State private var embeddedRuntimeIsReady: Bool?

    private let keychainStore = KeychainStore()
    private let apiStyleStore = LLMProviderAPIStyleStore()
    private let defaultProfileDeletionStore = LLMDefaultProfileDeletionStore()
    private let validator = LLMProviderValidationUseCase()

    private var settings: AppSettings? { settingsRows.first }

    private var selectedTab: Binding<IPadSettingsTab> {
        Binding(
            get: { IPadSettingsTab(rawValue: selectedTabRawValue) ?? .general },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }

    private var sortedProviders: [LLMProviderProfile] {
        providers.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    private var sortedModels: [LLMModelProfile] {
        models.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    private var selectedProvider: LLMProviderProfile? {
        sortedProviders.first { $0.id == selectedProviderID }
    }

    private var selectedModel: LLMModelProfile? {
        sortedModels.first { $0.id == selectedModelID }
    }

    var body: some View {
        Group {
            if let settings {
                TabView(selection: selectedTab) {
                    generalTab(settings)
                        .tag(IPadSettingsTab.general)
                        .tabItem {
                            Label(String(localized: "General", bundle: bundle), systemImage: "gearshape")
                        }

                    readerTab(settings)
                        .tag(IPadSettingsTab.reader)
                        .tabItem {
                            Label(String(localized: "Reader", bundle: bundle), systemImage: "book.closed")
                        }

                    digestTab
                        .tag(IPadSettingsTab.digest)
                        .tabItem {
                            Label(String(localized: "Digest", bundle: bundle), systemImage: "doc.plaintext")
                        }

                    providerTab(settings)
                        .tag(IPadSettingsTab.providers)
                        .tabItem {
                            Label(String(localized: "Providers", bundle: bundle), systemImage: "network")
                        }

                    modelTab(settings)
                        .tag(IPadSettingsTab.models)
                        .tabItem {
                            Label(String(localized: "Models", bundle: bundle), systemImage: "sparkles.rectangle.stack")
                        }
                }
            } else {
                ProgressView()
                    .task {
                        _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
                        try? LLMDefaultProfileSeeder().ensureDefaults(modelContext: modelContext)
                    }
            }
        }
        .navigationTitle(String(localized: "Settings", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Close", bundle: bundle)) { dismiss() }
            }
        }
        .task {
            _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
            try? LLMDefaultProfileSeeder(apiStyleStore: apiStyleStore).ensureDefaults(modelContext: modelContext)
            loadInitialSelectionIfNeeded()
            embeddedRuntimeIsReady = (try? InProcessBabelDocRunner().embeddedRuntimeAssets()) != nil
        }
        .onChange(of: selectedProviderID) { _, _ in applySelectedProvider() }
        .onChange(of: selectedModelID) { _, _ in applySelectedModel() }
        .onChange(of: providers.map(\.id)) { _, _ in loadInitialSelectionIfNeeded() }
        .onChange(of: models.map(\.id)) { _, _ in loadInitialSelectionIfNeeded() }
        .confirmationDialog(
            String(localized: "Delete", bundle: bundle),
            isPresented: $showsProviderDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                deleteSelectedProvider()
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "Delete", bundle: bundle),
            isPresented: $showsModelDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                deleteSelectedModel()
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showsDigestDirectoryImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleDigestDirectorySelection
        )
    }

    private func generalTab(_ settings: AppSettings) -> some View {
        Form {
            Section(String(localized: "Language", bundle: bundle)) {
                Picker(String(localized: "App language", bundle: bundle), selection: appLanguageBinding) {
                    Text("Follow System", bundle: bundle).tag(Optional<String>.none)
                    ForEach(AppLocalization.supportedLanguages) { language in
                        Text(verbatim: language.displayName).tag(Optional(language.code))
                    }
                }
            }

            Section(String(localized: "Translation", bundle: bundle)) {
                Picker(String(localized: "Target language", bundle: bundle), selection: targetLanguageBinding(settings)) {
                    ForEach(TranslationTargetLanguage.supported) { language in
                        Text(language.nativeName).tag(language.code)
                    }
                }

                Toggle(
                    String(localized: "Use arXiv LaTeX structure for PDF translation", bundle: bundle),
                    isOn: $babelDocSemanticHintsEnabled
                )

                Text(
                    "When enabled, ReadPaper uses available arXiv source to improve BabelDOC structure and translation context. No TeX installation is required, and failures fall back to PDF-only analysis.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Stepper(value: htmlConcurrencyBinding(settings), in: 1...12) {
                    Text(AppLocalization.format(
                        "HTML concurrency: %d",
                        bundle: bundle,
                        settings.htmlTranslationConcurrency
                    ))
                }

                Stepper(value: babelDocQPSBinding(settings), in: 1...20) {
                    Text(AppLocalization.format(
                        "BabelDOC QPS: %d",
                        bundle: bundle,
                        settings.babelDocQPS
                    ))
                }

                Stepper(value: pdfTranslationBatchSizeBinding, in: PDFTranslationBatchPreference.allowedRange) {
                    Text(AppLocalization.format(
                        "PDF pages per batch: %d",
                        bundle: bundle,
                        PDFTranslationBatchPreference.normalized(pdfTranslationBatchSize)
                    ))
                }

                Text(
                    "Controls the default translation target, HTML concurrency, BabelDOC request rate, and incremental PDF page batch size. Supported languages: English and Simplified Chinese.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Text("Optional glossary", bundle: bundle)

                TextEditor(text: $translationGlossary)
                    .frame(minHeight: 110)

                Button(String(localized: "Clear glossary", bundle: bundle), role: .destructive) {
                    translationGlossary = ""
                }
                .disabled(translationGlossary.isEmpty)

                Text(
                    "Enter one preferred term mapping per line, for example “large language model = 大语言模型”. The glossary is optional and is used as reference context by both HTML and PDF translation.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "BabelDOC", bundle: bundle)) {
                HStack(spacing: 12) {
                    Text("BabelDOC", bundle: bundle)

                    Spacer(minLength: 12)

                    if let embeddedRuntimeIsReady {
                        Image(systemName: embeddedRuntimeIsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(embeddedRuntimeIsReady ? .green : .orange)

                        Text(verbatim: embeddedRuntimeIsReady
                            ? "BabelDOCEmbedded"
                            : String(localized: "Unavailable", bundle: bundle))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(minHeight: 24)
            }

        }
    }

    private func readerTab(_ settings: AppSettings) -> some View {
        Form {
            Section(String(localized: "HTML Typography", bundle: bundle)) {
                Stepper(value: htmlReaderFontSizeBinding, in: HTMLReaderTypography.fontSizeRange, step: 1) {
                    HStack {
                        Text("HTML Font Size", bundle: bundle)
                        Spacer()
                        Text("\(Int(HTMLReaderTypography.clampFontSize(htmlReaderFontSize).rounded()))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Button(String(localized: "Reset Font Size", bundle: bundle)) {
                    htmlReaderFontSize = HTMLReaderTypography.defaultFontSize
                }
                .disabled(htmlReaderFontSize == HTMLReaderTypography.defaultFontSize)
            }

            Section(String(localized: "Reader Appearance", bundle: bundle)) {
                Picker(
                    String(localized: "Reader Appearance", bundle: bundle),
                    selection: pdfDisplayAppearanceBinding
                ) {
                    Text("Default", bundle: bundle).tag(PDFDisplayAppearance.defaultMode)
                    Text("Paper Tone", bundle: bundle).tag(PDFDisplayAppearance.paper)
                }
                .pickerStyle(.segmented)

                Text(
                    "System appearance changes automatically select Default for Light Mode and Paper Tone for Dark Mode. You can switch either option manually afterward.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "How to use translation", bundle: bundle)) {
                Text(
                    "After selecting routes here, go back to the main window, import a paper, open it in the reader, and use the Translate button in the toolbar.",
                    bundle: bundle
                )

                Text(
                    "HTML translation works best for arXiv papers with HTML content. PDF translation uses the PDF/BabelDOC route and can produce translated or side-by-side PDF reading modes.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "Translation Routes", bundle: bundle)) {
                Picker(String(localized: "HTML Model", bundle: bundle), selection: htmlModelBinding(settings)) {
                    Text("Not Selected", bundle: bundle).tag(Optional<UUID>.none)
                    ForEach(sortedModels) { model in
                        Text(modelDisplayName(model)).tag(Optional(model.id))
                    }
                }

                Picker(String(localized: "PDF/BabelDOC Model", bundle: bundle), selection: pdfModelBinding(settings)) {
                    Text("Not Selected", bundle: bundle).tag(Optional<UUID>.none)
                    ForEach(sortedModels) { model in
                        Text(modelDisplayName(model)).tag(Optional(model.id))
                    }
                }

                Text(
                    "Choose which saved model profile powers HTML translation and the BabelDOC PDF route inside the reader.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var digestTab: some View {
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
                }

                Button(String(localized: "Choose Folder", bundle: bundle)) {
                    showsDigestDirectoryImporter = true
                }

                Button(String(localized: "Clear", bundle: bundle), role: .destructive) {
                    PaperDigestExportConfiguration().clearExportDirectory()
                    digestExportDirectoryPath = ""
                    digestStatusMessage = nil
                }
                .disabled(digestExportDirectoryPath.isEmpty)

                Text(
                    "Markdown export requires a configured folder. Copy Digest can still use the template without an export folder.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "Markdown Template", bundle: bundle)) {
                TextEditor(text: $digestExportTemplate)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Menu {
                    ForEach(PaperDigestExportPolicy.templatePlaceholderTokens, id: \.self) { token in
                        Button(token) { appendDigestPlaceholder(token) }
                    }
                } label: {
                    Label(String(localized: "Insert Placeholder", bundle: bundle), systemImage: "text.badge.plus")
                }

                Button(String(localized: "Reset Default Template", bundle: bundle)) {
                    digestExportTemplate = PaperDigestExportPolicy.defaultMarkdownTemplate
                    digestStatusMessage = String(localized: "Default digest template restored.", bundle: bundle)
                }

                Text(
                    "Available placeholders: {{dateISO}}, {{title}}, {{slug}}, {{authors}}, {{identifier}}, {{sourceTitle}}, {{sourceURL}}, {{metadataBlock}}, {{abstractBlock}}, {{notesBlock}}, {{generatedBy}}.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let digestStatusMessage {
                    statusLabel(digestStatusMessage)
                }
            }
        }
    }

    private func providerTab(_ settings: AppSettings) -> some View {
        GeometryReader { proxy in
            if proxy.size.width >= 680 {
                llmWorkspace(
                    availableWidth: proxy.size.width,
                    leftPanel: providerListPanel,
                    rightPanel: providerWideDetailPanel(settings)
                )
            } else {
                providerDetailForm(settings, showsSelectionPicker: true)
            }
        }
    }

    private func providerDetailForm(
        _ settings: AppSettings,
        showsSelectionPicker: Bool
    ) -> some View {
        Form {
            Section(String(localized: "Providers", bundle: bundle)) {
                if showsSelectionPicker {
                    Picker(String(localized: "Provider", bundle: bundle), selection: $selectedProviderID) {
                        Text("New Provider", bundle: bundle).tag(Optional<UUID>.none)
                        ForEach(sortedProviders) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }
                }

                Text(
                    "OpenAI and DeepSeek are ready to use after you save an API key. You can also add custom providers and choose either the Responses API or Chat Completions.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Text(
                    "API keys are stored in Keychain. Leaving the API key field blank while editing keeps the saved key.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "Configuration", bundle: bundle)) {
                TextField(String(localized: "Display name", bundle: bundle), text: $providerName)
                TextField(String(localized: "Base URL", bundle: bundle), text: $providerBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker(String(localized: "API protocol", bundle: bundle), selection: $providerAPIStyle) {
                    ForEach(LLMAPIStyle.allCases, id: \.self) { style in
                        Text(apiStyleLabel(style)).tag(style)
                    }
                }
                SecureField(
                    providerHasStoredAPIKey
                        ? String(repeating: "•", count: 12)
                        : String(localized: "API key", bundle: bundle),
                    text: $providerAPIKey
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                TextField(String(localized: "Test model", bundle: bundle), text: $providerTestModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle(String(localized: "Enabled", bundle: bundle), isOn: $providerEnabled)
            }

            Section(String(localized: "Actions", bundle: bundle)) {
                settingsActions(
                    primaryTitle: String(localized: "Save", bundle: bundle),
                    primaryAction: { saveProvider(settings) },
                    testTitle: isTestingProvider
                        ? String(localized: "Testing...", bundle: bundle)
                        : String(localized: "Test", bundle: bundle),
                    testAction: testProvider,
                    isTesting: isTestingProvider,
                    resetAction: {
                        selectedProvider == nil ? resetProviderForm() : applySelectedProvider()
                    },
                    deleteAction: selectedProvider == nil ? nil : {
                        showsProviderDeleteConfirmation = true
                    }
                )

                if let providerStatusMessage { statusLabel(providerStatusMessage) }
                if let providerOutputPreview, providerOutputPreview.isEmpty == false {
                    Text(providerOutputPreview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func modelTab(_ settings: AppSettings) -> some View {
        GeometryReader { proxy in
            if proxy.size.width >= 680 {
                llmWorkspace(
                    availableWidth: proxy.size.width,
                    leftPanel: modelListPanel,
                    rightPanel: modelWideDetailPanel(settings)
                )
            } else {
                modelDetailForm(settings, showsSelectionPicker: true)
            }
        }
    }

    private func modelDetailForm(
        _ settings: AppSettings,
        showsSelectionPicker: Bool
    ) -> some View {
        Form {
            Section(String(localized: "Models", bundle: bundle)) {
                if showsSelectionPicker {
                    Picker(String(localized: "Model Profile", bundle: bundle), selection: $selectedModelID) {
                        Text("New Model", bundle: bundle).tag(Optional<UUID>.none)
                        ForEach(sortedModels) { model in
                            Text(modelDisplayName(model)).tag(Optional(model.id))
                        }
                    }
                }

                Text(
                    "A model profile points to one provider and stores the exact model name plus optional sampling parameters. You can create separate profiles for fast HTML translation and heavier PDF work.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Text(
                    "Profile name is only for display inside ReadPaper. Model name must match the real model identifier accepted by your provider.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "Configuration", bundle: bundle)) {
                Picker(String(localized: "Provider", bundle: bundle), selection: $modelProviderID) {
                    Text("Select Provider", bundle: bundle).tag(Optional<UUID>.none)
                    ForEach(sortedProviders) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }

                TextField(String(localized: "Profile name", bundle: bundle), text: $modelName)
                TextField(String(localized: "Model name", bundle: bundle), text: $modelIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle(String(localized: "Enabled", bundle: bundle), isOn: $modelEnabled)

                DisclosureGroup(isExpanded: $showsModelAdvancedOptions) {
                    Picker(String(localized: "Thinking Mode", bundle: bundle), selection: $modelThinkingMode) {
                        Text("Default", bundle: bundle).tag(Optional<LLMThinkingMode>.none)
                        ForEach(LLMThinkingMode.allCases, id: \.self) { mode in
                            Text(thinkingModeLabel(mode)).tag(Optional(mode))
                        }
                    }
                    Picker(String(localized: "Reasoning Effort", bundle: bundle), selection: $modelReasoningEffort) {
                        Text("Default", bundle: bundle).tag(Optional<LLMReasoningEffort>.none)
                        ForEach(LLMReasoningEffort.allCases, id: \.self) { effort in
                            Text(reasoningEffortLabel(effort)).tag(Optional(effort))
                        }
                    }
                    .disabled(modelThinkingMode == .disabled)
                    Text("Thinking mode controls whether the model outputs a chain of thought before answering (for example DeepSeek V4). Reasoning effort is omitted while thinking is disabled.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "Temperature", bundle: bundle), text: $modelTemperature)
                        .keyboardType(.decimalPad)
                    TextField(String(localized: "Top-P", bundle: bundle), text: $modelTopP)
                        .keyboardType(.decimalPad)
                    TextField(String(localized: "Max tokens", bundle: bundle), text: $modelMaxTokens)
                        .keyboardType(.numberPad)
                } label: {
                    Text("Advanced Parameters", bundle: bundle)
                }
            }

            Section(String(localized: "Actions", bundle: bundle)) {
                settingsActions(
                    primaryTitle: String(localized: "Save", bundle: bundle),
                    primaryAction: { saveModel(settings) },
                    testTitle: isTestingModel
                        ? String(localized: "Testing...", bundle: bundle)
                        : String(localized: "Test", bundle: bundle),
                    testAction: testModel,
                    isTesting: isTestingModel,
                    resetAction: {
                        selectedModel == nil ? resetModelForm() : applySelectedModel()
                    },
                    deleteAction: selectedModel == nil ? nil : {
                        showsModelDeleteConfirmation = true
                    }
                )

                if let lastTestedAt = selectedModel?.lastTestedAt {
                    Text(String(
                        format: String(localized: "Last tested: %@", bundle: bundle),
                        lastTestedAt.formatted(date: .abbreviated, time: .shortened)
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let modelStatusMessage { statusLabel(modelStatusMessage) }
                if let modelOutputPreview, modelOutputPreview.isEmpty == false {
                    Text(modelOutputPreview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var providerListPanel: some View {
        entityListPanel(
            title: String(localized: "Providers", bundle: bundle),
            count: sortedProviders.count
        ) {
            List {
                ForEach(sortedProviders) { provider in
                    Button {
                        selectedProviderID = provider.id
                    } label: {
                        providerListRow(provider)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background {
                                settingsEntityRowBackground(
                                    isSelected: selectedProviderID == provider.id
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        } toolbar: {
            Button {
                resetProviderForm()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(String(localized: "New Provider", bundle: bundle))

            Button(role: .destructive) {
                showsProviderDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedProvider == nil)
            .accessibilityLabel(String(localized: "Delete", bundle: bundle))
        }
    }

    private var modelListPanel: some View {
        entityListPanel(
            title: String(localized: "Models", bundle: bundle),
            count: sortedModels.count
        ) {
            List {
                ForEach(sortedModels) { model in
                    Button {
                        selectedModelID = model.id
                    } label: {
                        modelListRow(model)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background {
                                settingsEntityRowBackground(
                                    isSelected: selectedModelID == model.id
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        } toolbar: {
            Button {
                resetModelForm()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(String(localized: "New Model", bundle: bundle))

            Button(role: .destructive) {
                showsModelDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedModel == nil)
            .accessibilityLabel(String(localized: "Delete", bundle: bundle))
        }
    }

    private func providerWideDetailPanel(_ settings: AppSettings) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsDetailSection(title: String(localized: "Providers", bundle: bundle)) {
                    Text(
                        "OpenAI and DeepSeek are ready to use after you save an API key. You can also add custom providers and choose either the Responses API or Chat Completions.",
                        bundle: bundle
                    )
                    .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "API keys are stored in Keychain. Leaving the API key field blank while editing keeps the saved key.",
                        bundle: bundle
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                settingsDetailSection(title: String(localized: "Configuration", bundle: bundle)) {
                    settingsDetailField(String(localized: "Display name", bundle: bundle)) {
                        TextField("", text: $providerName)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingsDetailField(String(localized: "Base URL", bundle: bundle)) {
                        TextField("", text: $providerBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    settingsDetailField(String(localized: "API protocol", bundle: bundle)) {
                        Picker(String(localized: "API protocol", bundle: bundle), selection: $providerAPIStyle) {
                            ForEach(LLMAPIStyle.allCases, id: \.self) { style in
                                Text(apiStyleLabel(style)).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    settingsDetailField(String(localized: "API key", bundle: bundle)) {
                        SecureField(
                            providerHasStoredAPIKey ? String(repeating: "•", count: 12) : "",
                            text: $providerAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }

                    settingsDetailField(String(localized: "Test model", bundle: bundle)) {
                        TextField("", text: $providerTestModel)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    settingsDetailField(String(localized: "Enabled", bundle: bundle)) {
                        Toggle("", isOn: $providerEnabled)
                            .labelsHidden()
                    }
                }

                settingsDetailSection(title: String(localized: "Actions", bundle: bundle)) {
                    settingsActions(
                        primaryTitle: String(localized: "Save", bundle: bundle),
                        primaryAction: { saveProvider(settings) },
                        testTitle: isTestingProvider
                            ? String(localized: "Testing...", bundle: bundle)
                            : String(localized: "Test", bundle: bundle),
                        testAction: testProvider,
                        isTesting: isTestingProvider,
                        resetAction: {
                            selectedProvider == nil ? resetProviderForm() : applySelectedProvider()
                        },
                        deleteAction: nil
                    )

                    if let providerStatusMessage { statusLabel(providerStatusMessage) }
                    if let providerOutputPreview, providerOutputPreview.isEmpty == false {
                        Text(providerOutputPreview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func modelWideDetailPanel(_ settings: AppSettings) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsDetailSection(title: String(localized: "Models", bundle: bundle)) {
                    Text(
                        "A model profile points to one provider and stores the exact model name plus optional sampling parameters. You can create separate profiles for fast HTML translation and heavier PDF work.",
                        bundle: bundle
                    )
                    .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "Profile name is only for display inside ReadPaper. Model name must match the real model identifier accepted by your provider.",
                        bundle: bundle
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                settingsDetailSection(title: String(localized: "Configuration", bundle: bundle)) {
                    settingsDetailField(String(localized: "Provider", bundle: bundle)) {
                        Picker(String(localized: "Provider", bundle: bundle), selection: $modelProviderID) {
                            Text("Select Provider", bundle: bundle).tag(Optional<UUID>.none)
                            ForEach(sortedProviders) { provider in
                                Text(provider.name).tag(Optional(provider.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    settingsDetailField(String(localized: "Profile name", bundle: bundle)) {
                        TextField("", text: $modelName)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingsDetailField(String(localized: "Model name", bundle: bundle)) {
                        TextField("", text: $modelIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    settingsDetailField(String(localized: "Enabled", bundle: bundle)) {
                        Toggle("", isOn: $modelEnabled)
                            .labelsHidden()
                    }

                    DisclosureGroup(isExpanded: $showsModelAdvancedOptions) {
                        VStack(alignment: .leading, spacing: 14) {
                            settingsDetailField(String(localized: "Thinking Mode", bundle: bundle)) {
                                Picker(String(localized: "Thinking Mode", bundle: bundle), selection: $modelThinkingMode) {
                                    Text("Default", bundle: bundle).tag(Optional<LLMThinkingMode>.none)
                                    ForEach(LLMThinkingMode.allCases, id: \.self) { mode in
                                        Text(thinkingModeLabel(mode)).tag(Optional(mode))
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }

                            settingsDetailField(String(localized: "Reasoning Effort", bundle: bundle)) {
                                Picker(String(localized: "Reasoning Effort", bundle: bundle), selection: $modelReasoningEffort) {
                                    Text("Default", bundle: bundle).tag(Optional<LLMReasoningEffort>.none)
                                    ForEach(LLMReasoningEffort.allCases, id: \.self) { effort in
                                        Text(reasoningEffortLabel(effort)).tag(Optional(effort))
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .disabled(modelThinkingMode == .disabled)
                            }

                            Text("Thinking mode controls whether the model outputs a chain of thought before answering (for example DeepSeek V4). Reasoning effort is omitted while thinking is disabled.", bundle: bundle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            settingsDetailField(String(localized: "Temperature", bundle: bundle)) {
                                TextField("", text: $modelTemperature)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.decimalPad)
                            }

                            settingsDetailField(String(localized: "Top-P", bundle: bundle)) {
                                TextField("", text: $modelTopP)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.decimalPad)
                            }

                            settingsDetailField(String(localized: "Max tokens", bundle: bundle)) {
                                TextField("", text: $modelMaxTokens)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.numberPad)
                            }
                        }
                        .padding(.top, 14)
                    } label: {
                        Text("Advanced Parameters", bundle: bundle)
                            .font(.subheadline.weight(.medium))
                    }
                }

                settingsDetailSection(title: String(localized: "Actions", bundle: bundle)) {
                    settingsActions(
                        primaryTitle: String(localized: "Save", bundle: bundle),
                        primaryAction: { saveModel(settings) },
                        testTitle: isTestingModel
                            ? String(localized: "Testing...", bundle: bundle)
                            : String(localized: "Test", bundle: bundle),
                        testAction: testModel,
                        isTesting: isTestingModel,
                        resetAction: {
                            selectedModel == nil ? resetModelForm() : applySelectedModel()
                        },
                        deleteAction: nil
                    )

                    if let lastTestedAt = selectedModel?.lastTestedAt {
                        Text(String(
                            format: String(localized: "Last tested: %@", bundle: bundle),
                            lastTestedAt.formatted(date: .abbreviated, time: .shortened)
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if let modelStatusMessage { statusLabel(modelStatusMessage) }
                    if let modelOutputPreview, modelOutputPreview.isEmpty == false {
                        Text(modelOutputPreview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func settingsDetailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private func settingsDetailField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 128, alignment: .leading)

                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func llmWorkspace<LeftPanel: View, RightPanel: View>(
        availableWidth: CGFloat,
        leftPanel: LeftPanel,
        rightPanel: RightPanel
    ) -> some View {
        let horizontalPadding: CGFloat = 20
        let panelSpacing: CGFloat = 16
        let usableWidth = availableWidth - (horizontalPadding * 2) - panelSpacing
        let listWidth = min(310, max(250, usableWidth * 0.36))

        return HStack(alignment: .top, spacing: panelSpacing) {
            leftPanel
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)

            rightPanel
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(horizontalPadding)
        .background(Color(uiColor: .systemBackground))
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
                            .fill(Color.secondary.opacity(0.12))
                    )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 14) {
                toolbar()
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(uiColor: .tertiarySystemBackground))
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
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

            Text(apiStyleLabel(apiStyleStore.apiStyle(for: provider.id)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(model.isEnabled ? 1 : 0.68)
    }

    private func settingsEntityRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(0.14)
                    : Color(uiColor: .systemBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(0.24)
                            : Color.secondary.opacity(0.1),
                        lineWidth: 1
                    )
            }
    }

    @ViewBuilder
    private func settingsActions(
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        testTitle: String,
        testAction: @escaping () -> Void,
        isTesting: Bool,
        resetAction: @escaping () -> Void,
        deleteAction: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)

            Button(String(localized: "Reset", bundle: bundle), action: resetAction)
                .buttonStyle(.bordered)

            Button(testTitle, action: testAction)
                .buttonStyle(.bordered)
                .disabled(isTesting)

            if let deleteAction {
                Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                    deleteAction()
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statusLabel(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(AppLocalization.isErrorMessage(message, bundle: bundle) ? .red : .secondary)
            .textSelection(.enabled)
    }

    private var appLanguageBinding: Binding<String?> {
        Binding(
            get: { LanguageManager.shared.languageOverride },
            set: { LanguageManager.shared.setLanguage($0) }
        )
    }

    private var pdfDisplayAppearanceBinding: Binding<PDFDisplayAppearance> {
        Binding(
            get: { PDFDisplayAppearance.resolve(rawValue: pdfDisplayAppearanceRawValue) },
            set: { pdfDisplayAppearanceRawValue = $0.rawValue }
        )
    }

    private var pdfTranslationBatchSizeBinding: Binding<Int> {
        Binding(
            get: { PDFTranslationBatchPreference.normalized(pdfTranslationBatchSize) },
            set: { pdfTranslationBatchSize = PDFTranslationBatchPreference.normalized($0) }
        )
    }

    private var htmlReaderFontSizeBinding: Binding<Double> {
        Binding(
            get: { HTMLReaderTypography.clampFontSize(htmlReaderFontSize) },
            set: { htmlReaderFontSize = HTMLReaderTypography.clampFontSize($0) }
        )
    }

    private func targetLanguageBinding(_ settings: AppSettings) -> Binding<String> {
        persistedBinding(settings, keyPath: \.targetLanguage)
    }

    private func htmlConcurrencyBinding(_ settings: AppSettings) -> Binding<Int> {
        persistedBinding(settings, keyPath: \.htmlTranslationConcurrency)
    }

    private func babelDocQPSBinding(_ settings: AppSettings) -> Binding<Int> {
        persistedBinding(settings, keyPath: \.babelDocQPS)
    }

    private func htmlModelBinding(_ settings: AppSettings) -> Binding<UUID?> {
        persistedBinding(settings, keyPath: \.selectedHTMLModelProfileID)
    }

    private func pdfModelBinding(_ settings: AppSettings) -> Binding<UUID?> {
        persistedBinding(settings, keyPath: \.selectedPDFModelProfileID)
    }

    private func persistedBinding<Value>(
        _ settings: AppSettings,
        keyPath: ReferenceWritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                settings.modifiedAt = Date()
                try? modelContext.save()
            }
        )
    }

    private func loadInitialSelectionIfNeeded() {
        normalizeSelections()
        if selectedProviderID == nil { selectedProviderID = sortedProviders.first?.id }
        if selectedModelID == nil { selectedModelID = sortedModels.first?.id }
        if selectedProviderID == nil { resetProviderForm() } else { applySelectedProvider() }
        if selectedModelID == nil { resetModelForm() } else { applySelectedModel() }
    }

    private func normalizeSelections() {
        if let selectedProviderID, providers.contains(where: { $0.id == selectedProviderID }) == false {
            self.selectedProviderID = nil
        }
        if let selectedModelID, models.contains(where: { $0.id == selectedModelID }) == false {
            self.selectedModelID = nil
        }
        guard let settings else { return }
        if let id = settings.selectedHTMLModelProfileID, models.contains(where: { $0.id == id }) == false {
            settings.selectedHTMLModelProfileID = nil
        }
        if let id = settings.selectedPDFModelProfileID, models.contains(where: { $0.id == id }) == false {
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
        providerAPIStyle = apiStyleStore.apiStyle(for: provider.id)
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
        modelThinkingMode = model.thinkingModeValue
        modelReasoningEffort = model.reasoningEffortValue
        modelEnabled = model.isEnabled
        showsModelAdvancedOptions = model.temperature != nil
            || model.topP != nil
            || model.maxTokens != nil
            || model.thinkingModeValue != nil
            || model.reasoningEffortValue != nil
        modelStatusMessage = nil
        modelOutputPreview = nil
    }

    private func resetProviderForm() {
        selectedProviderID = nil
        providerName = ""
        providerBaseURL = "https://api.openai.com/v1"
        providerAPIKey = ""
        providerTestModel = ""
        providerAPIStyle = .chatCompletions
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
        modelThinkingMode = nil
        modelReasoningEffort = nil
        modelEnabled = true
        showsModelAdvancedOptions = false
        modelStatusMessage = nil
        modelOutputPreview = nil
    }

    private func saveProvider(_ settings: AppSettings) {
        do {
            let normalizedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedName.isEmpty == false else {
                throw IPadSettingsError.message(String(localized: "Provider name cannot be empty.", bundle: bundle))
            }
            let normalizedBaseURL = try validator.normalizedBaseURL(providerBaseURL)
            let normalizedTestModel = try validator.validateModelName(providerTestModel)
            let normalizedAPIStyle = providerAPIStyle
            let now = Date()
            let provider: LLMProviderProfile

            if let selectedProvider {
                provider = selectedProvider
            } else {
                let id = UUID()
                provider = LLMProviderProfile(
                    id: id,
                    name: normalizedName,
                    baseURL: normalizedBaseURL,
                    apiKeyRef: LLMConfigurationBootstrapper.makeAPIKeyRef(providerID: id),
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
            apiStyleStore.setAPIStyle(normalizedAPIStyle, for: provider.id)

            let trimmedAPIKey = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAPIKey.isEmpty == false {
                try keychainStore.save(trimmedAPIKey, account: provider.apiKeyRef)
            } else if hasStoredAPIKey(ref: provider.apiKeyRef) == false {
                throw LLMProviderValidationError.emptyAPIKey
            }

            LLMDefaultRouteActivator().selectRoutesIfNeeded(
                for: provider.id,
                settings: settings,
                providers: providers.contains(where: { $0.id == provider.id }) ? providers : providers + [provider],
                models: models,
                hasStoredAPIKey: hasStoredAPIKey
            )
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
        guard let settings, let provider = selectedProvider else { return }
        let providerID = provider.id
        let isBuiltInProvider = LLMDefaultProfiles.isBuiltInProvider(providerID)
        let relatedModelIDs = Set(models.filter { $0.providerID == provider.id }.map(\.id))
        let relatedBuiltInModelIDs = relatedModelIDs.filter(LLMDefaultProfiles.isBuiltInModel)
        for model in models where relatedModelIDs.contains(model.id) {
            modelContext.delete(model)
        }
        if let id = settings.selectedHTMLModelProfileID, relatedModelIDs.contains(id) {
            settings.selectedHTMLModelProfileID = nil
        }
        if let id = settings.selectedPDFModelProfileID, relatedModelIDs.contains(id) {
            settings.selectedPDFModelProfileID = nil
        }
        modelContext.delete(provider)
        apiStyleStore.removeAPIStyle(for: provider.id)

        do {
            settings.modifiedAt = Date()
            try modelContext.save()
            if isBuiltInProvider {
                defaultProfileDeletionStore.markProviderDeleted(providerID)
            }
            for modelID in relatedBuiltInModelIDs {
                defaultProfileDeletionStore.markModelDeleted(modelID)
            }
            resetProviderForm()
            if let selectedModelID, relatedModelIDs.contains(selectedModelID) { resetModelForm() }
            providerStatusMessage = String(localized: "Provider deleted.", bundle: bundle)
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
                let enteredAPIKey = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let apiKey: String
                if enteredAPIKey.isEmpty == false {
                    apiKey = enteredAPIKey
                } else if let selectedProvider {
                    apiKey = try loadStoredAPIKey(ref: selectedProvider.apiKeyRef)
                } else {
                    throw LLMProviderValidationError.emptyAPIKey
                }

                let result = try await validator.testConnection(
                    baseURL: providerBaseURL,
                    apiStyle: providerAPIStyle,
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
            }
        }
    }

    private func saveModel(_ settings: AppSettings) {
        do {
            guard let modelProviderID else {
                throw IPadSettingsError.message(String(localized: "Select a provider for the model.", bundle: bundle))
            }
            let normalizedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedName.isEmpty == false else {
                throw IPadSettingsError.message(String(localized: "Model profile name cannot be empty.", bundle: bundle))
            }
            let identifier = try validator.validateModelName(modelIdentifier)
            let temperature = try parseOptionalDouble(modelTemperature, label: String(localized: "Temperature", bundle: bundle))
            let topP = try parseOptionalDouble(modelTopP, label: String(localized: "Top-P", bundle: bundle))
            let maxTokens = try parseOptionalInt(modelMaxTokens, label: String(localized: "Max tokens", bundle: bundle))
            let now = Date()
            let model: LLMModelProfile

            if let selectedModel {
                model = selectedModel
            } else {
                model = LLMModelProfile(
                    providerID: modelProviderID,
                    name: normalizedName,
                    modelName: identifier,
                    temperature: temperature,
                    topP: topP,
                    maxTokens: maxTokens,
                    thinkingMode: modelThinkingMode,
                    reasoningEffort: modelReasoningEffort,
                    isEnabled: modelEnabled,
                    createdAt: now,
                    modifiedAt: now
                )
                modelContext.insert(model)
            }

            model.providerID = modelProviderID
            model.name = normalizedName
            model.modelName = identifier
            model.temperature = temperature
            model.topP = topP
            model.maxTokens = maxTokens
            model.thinkingModeValue = modelThinkingMode
            model.reasoningEffortValue = modelReasoningEffort
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
        guard let settings, let model = selectedModel else { return }
        let modelID = model.id
        let isBuiltInModel = LLMDefaultProfiles.isBuiltInModel(modelID)
        if settings.selectedHTMLModelProfileID == model.id { settings.selectedHTMLModelProfileID = nil }
        if settings.selectedPDFModelProfileID == model.id { settings.selectedPDFModelProfileID = nil }
        modelContext.delete(model)

        do {
            settings.modifiedAt = Date()
            try modelContext.save()
            if isBuiltInModel {
                defaultProfileDeletionStore.markModelDeleted(modelID)
            }
            resetModelForm()
            modelStatusMessage = String(localized: "Model deleted.", bundle: bundle)
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
                    throw IPadSettingsError.message(String(localized: "Select a provider for the model.", bundle: bundle))
                }
                guard let provider = providers.first(where: { $0.id == modelProviderID }) else {
                    throw LLMRouteError.providerNotFound
                }
                let result = try await validator.testConnection(
                    baseURL: provider.baseURL,
                    apiStyle: apiStyleStore.apiStyle(for: provider.id),
                    apiKey: try loadStoredAPIKey(ref: provider.apiKeyRef),
                    model: modelIdentifier,
                    temperature: try parseOptionalDouble(modelTemperature, label: String(localized: "Temperature", bundle: bundle)),
                    topP: try parseOptionalDouble(modelTopP, label: String(localized: "Top-P", bundle: bundle)),
                    maxTokens: try parseOptionalInt(modelMaxTokens, label: String(localized: "Max tokens", bundle: bundle)),
                    thinkingMode: modelThinkingMode,
                    reasoningEffort: modelReasoningEffort
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
            }
        }
    }

    private func hasStoredAPIKey(ref: String) -> Bool {
        ((try? keychainStore.load(account: ref)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    private func loadStoredAPIKey(ref: String) throws -> String {
        let value = try keychainStore.load(account: ref)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty == false else { throw LLMProviderValidationError.emptyAPIKey }
        return value
    }

    private func modelDisplayName(_ model: LLMModelProfile) -> String {
        let providerName = providers.first(where: { $0.id == model.providerID })?.name
            ?? String(localized: "Unknown Provider", bundle: bundle)
        return "\(providerName) / \(model.name)"
    }

    private func apiStyleLabel(_ style: LLMAPIStyle) -> String {
        switch style {
        case .responses:
            return String(localized: "Responses API", bundle: bundle)
        case .chatCompletions:
            return String(localized: "Chat Completions", bundle: bundle)
        }
    }

    private func thinkingModeLabel(_ mode: LLMThinkingMode) -> String {
        switch mode {
        case .enabled: String(localized: "Enabled", bundle: bundle)
        case .disabled: String(localized: "Disabled", bundle: bundle)
        }
    }

    private func reasoningEffortLabel(_ effort: LLMReasoningEffort) -> String {
        switch effort {
        case .low: String(localized: "Low", bundle: bundle)
        case .high: String(localized: "High", bundle: bundle)
        case .max: String(localized: "Max", bundle: bundle)
        }
    }

    private func parseOptionalDouble(_ value: String, label: String) throws -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let parsed = Double(trimmed) else {
            throw IPadSettingsError.message(String(
                format: String(localized: "%@ must be a number.", bundle: bundle),
                label
            ))
        }
        return parsed
    }

    private func parseOptionalInt(_ value: String, label: String) throws -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard let parsed = Int(trimmed) else {
            throw IPadSettingsError.message(String(
                format: String(localized: "%@ must be an integer.", bundle: bundle),
                label
            ))
        }
        return parsed
    }

    private func appendDigestPlaceholder(_ token: String) {
        if digestExportTemplate.isEmpty == false, digestExportTemplate.hasSuffix("\n") == false {
            digestExportTemplate.append("\n")
        }
        digestExportTemplate.append(token)
    }

    private func handleDigestDirectorySelection(_ result: Result<[URL], Error>) {
        do {
            guard let directory = try result.get().first else { return }
            try PaperDigestExportConfiguration().saveExportDirectory(directory)
            digestExportDirectoryPath = directory.path
            digestStatusMessage = nil
        } catch {
            digestStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        }
    }
}

private enum IPadSettingsError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
