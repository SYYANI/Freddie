import AppKit
import SwiftData
import SwiftUI

private enum SettingsTab: String, Hashable {
    case general
    case reader
    case latex
    case digest
    case providers
    case models
}

private struct NativeBabelDocSettingsProbe: Sendable {
    let isAvailable: Bool
    let installedVersion: String?
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
    @Query(sort: [SortDescriptor(\LLMProviderProfile.modifiedAt, order: .reverse)]) private var providers: [LLMProviderProfile]
    @Query(sort: [SortDescriptor(\LLMModelProfile.modifiedAt, order: .reverse)]) private var models: [LLMModelProfile]
    @State private var paperCount = 0

    var body: some View {
        Group {
            if let settings = settingsRows.first {
                SettingsForm(
                    settings: settings,
                    providers: providers,
                    models: models,
                    paperCount: paperCount
                )
            } else {
                ProgressView()
                    .task {
                        _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
                        try? LLMDefaultProfileSeeder().ensureDefaults(modelContext: modelContext)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            AppWindowBackdrop(role: .settings)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .task {
            paperCount = (try? modelContext.fetchCount(FetchDescriptor<Paper>())) ?? 0
        }
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
    @AppStorage(PDFDisplayAppearance.userDefaultsKey)
    private var pdfDisplayAppearanceRawValue = PDFDisplayAppearance.defaultValue.rawValue
    @AppStorage(PDFTranslationBatchPreference.userDefaultsKey)
    private var pdfTranslationBatchSizeRawValue = PDFTranslationBatchPreference.defaultValue
    @AppStorage(HTMLReaderTypography.fontSizeUserDefaultsKey)
    private var htmlReaderFontSize = HTMLReaderTypography.defaultFontSize
    @AppStorage(TranslationGlossaryPreference.userDefaultsKey)
    private var translationGlossary = ""
    @AppStorage(BabelDocSemanticHintPreference.userDefaultsKey)
    private var babelDocSemanticHintsEnabled = BabelDocSemanticHintPreference.defaultValue
    @AppStorage(LaTeXIntegrationPreferences.translationEnabledKey)
    private var latexTranslationEnabled = false
    @AppStorage(LaTeXIntegrationPreferences.toolchainDirectoryKey)
    private var latexToolchainDirectoryPath = ""
    @AppStorage(PaperDigestExportConfiguration.templateKey) private var digestExportTemplate = PaperDigestExportPolicy.defaultMarkdownTemplate
    @AppStorage(PaperDigestExportConfiguration.directoryDisplayPathKey) private var digestExportDirectoryPath = ""
    @AppStorage(SelectionAssistantPreferences.selectedModelProfileIDKey)
    private var selectedAssistantModelProfileIDRawValue = ""
    @AppStorage(SelectionAssistantPreferences.externalSearchEnabledKey)
    private var externalAssistantSearchEnabled = false

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
    @State private var providerWebSearchStatusMessage: String?
    @State private var providerWebSearchOutputPreview: String?
    @State private var providerWebSearchSources: [LLMWebSearchSource] = []
    @State private var webSearchTrace = WebSearchTraceStore()
    @State private var showsProviderWebSearchTrace = false
    @State private var isTestingProviderWebSearch = false

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
    @State private var glossaryInsertion: String?
    @State private var detectedLaTeXInstallations: [ReadPaperLaTeXInstallation] = []
    @State private var providerIDsWithStoredAPIKeys: Set<UUID> = []

    private let keychainStore = KeychainStore()
    private let apiStyleStore = LLMProviderAPIStyleStore()
    private let defaultProfileDeletionStore = LLMDefaultProfileDeletionStore()
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
            provider.isEnabled && providerIDsWithStoredAPIKeys.contains(provider.id)
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

    private var selectedAssistantModelProfileIDBinding: Binding<UUID?> {
        Binding(
            get: { UUID(uuidString: selectedAssistantModelProfileIDRawValue) },
            set: { selectedAssistantModelProfileIDRawValue = $0?.uuidString ?? "" }
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

    private var pdfDisplayAppearanceBinding: Binding<PDFDisplayAppearance> {
        Binding(
            get: { PDFDisplayAppearance.resolve(rawValue: pdfDisplayAppearanceRawValue) },
            set: { pdfDisplayAppearanceRawValue = $0.rawValue }
        )
    }

    private var pdfTranslationBatchSizeBinding: Binding<Int> {
        Binding(
            get: { PDFTranslationBatchPreference.normalized(pdfTranslationBatchSizeRawValue) },
            set: { pdfTranslationBatchSizeRawValue = PDFTranslationBatchPreference.normalized($0) }
        )
    }

    private var htmlReaderFontSizeBinding: Binding<Double> {
        Binding(
            get: { HTMLReaderTypography.clampFontSize(htmlReaderFontSize) },
            set: { htmlReaderFontSize = HTMLReaderTypography.clampFontSize($0) }
        )
    }

    private var htmlReaderFontSizeValue: Int {
        Int(HTMLReaderTypography.clampFontSize(htmlReaderFontSize).rounded())
    }

    private var selectedLaTeXDirectoryURL: URL? {
        guard !latexToolchainDirectoryPath.isEmpty else { return nil }
        return URL(fileURLWithPath: latexToolchainDirectoryPath, isDirectory: true).standardizedFileURL
    }

    private var activeLaTeXInstallation: ReadPaperLaTeXInstallation? {
        if let selectedLaTeXDirectoryURL {
            return ReadPaperLaTeXToolchain.installation(at: selectedLaTeXDirectoryURL)
        }
        guard let toolchain = ReadPaperLaTeXToolchain.detect() else { return nil }
        return ReadPaperLaTeXToolchain.installation(
            at: toolchain.latexmkURL.deletingLastPathComponent()
        )
    }

    private var automaticLaTeXLocation: String? {
        ReadPaperLaTeXToolchain.detect()?.latexmkURL.deletingLastPathComponent().path
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
            tabContent(for: .general) {
                generalTab
            }
                .tag(SettingsTab.general)
                .tabItem {
                    Label(String(localized: "General", bundle: bundle), systemImage: "gearshape")
                }

            tabContent(for: .reader) {
                readerTab
            }
                .tag(SettingsTab.reader)
                .tabItem {
                    Label(String(localized: "Reader", bundle: bundle), systemImage: "book.closed")
                }

            tabContent(for: .latex) {
                latexTab
            }
                .tag(SettingsTab.latex)
                .tabItem {
                    Label(String(localized: "LaTeX", bundle: bundle), systemImage: "text.document")
                }

            tabContent(for: .digest) {
                digestTab
            }
                .tag(SettingsTab.digest)
                .tabItem {
                    Label(String(localized: "Digest", bundle: bundle), systemImage: "doc.plaintext")
                }

            tabContent(for: .providers) {
                providerTab
            }
                .tag(SettingsTab.providers)
                .tabItem {
                    Label(String(localized: "Providers", bundle: bundle), systemImage: "network")
                }

            tabContent(for: .models) {
                modelTab
            }
                .tag(SettingsTab.models)
                .tabItem {
                    Label(String(localized: "Models", bundle: bundle), systemImage: "sparkles.rectangle.stack")
                }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            loadInitialSelectionIfNeeded()
            await Task.yield()
            refreshStoredAPIKeyAvailability()
            async let latexRefresh: Void = refreshLaTeXInstallations()
            async let babelDocRefresh: Void = refreshInstalledBabelDOCVersion()
            _ = await (latexRefresh, babelDocRefresh)
        }
        .onChange(of: selectedProviderID) { _, _ in
            applySelectedProvider()
        }
        .onChange(of: selectedModelID) { _, _ in
            applySelectedModel()
        }
        .onChange(of: providers.map(\.id)) { _, _ in
            refreshStoredAPIKeyAvailability()
            loadInitialSelectionIfNeeded()
        }
        .onChange(of: models.map(\.id)) { _, _ in
            loadInitialSelectionIfNeeded()
        }
        .onChange(of: latexToolchainDirectoryPath) { _, _ in
            Task {
                await refreshLaTeXInstallations()
            }
        }
    }

    @ViewBuilder
    private func tabContent<Content: View>(
        for tab: SettingsTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if selectedTab == tab {
            content()
        } else {
            Color.clear
        }
    }

    private var selectedTab: SettingsTab {
        SettingsTab(rawValue: selectedTabRawValue) ?? .general
    }

    private var selectedTabBinding: Binding<SettingsTab> {
        Binding(
            get: { selectedTab },
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
                }

                Section(String(localized: "Translation", bundle: bundle)) {
                    Picker(String(localized: "Target language", bundle: bundle), selection: targetLanguageBinding) {
                        ForEach(TranslationTargetLanguage.supported) { option in
                            Text(option.nativeName).tag(option.code)
                        }
                    }
                    .pickerStyle(.menu)

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
                        in: 1...50
                    )
                    Stepper(
                        String(
                            format: String(localized: "PDF pages per batch: %d", bundle: bundle),
                            PDFTranslationBatchPreference.normalized(pdfTranslationBatchSizeRawValue)
                        ),
                        value: pdfTranslationBatchSizeBinding,
                        in: PDFTranslationBatchPreference.allowedRange
                    )

                    Text(
                        "Controls the default translation target, HTML concurrency, BabelDOC request rate, and incremental PDF page batch size. Supported languages: English and Simplified Chinese.",
                        bundle: bundle
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional glossary", bundle: bundle)
                        SettingsTemplateTextEditor(
                            text: $translationGlossary,
                            pendingInsertion: $glossaryInsertion
                        )
                        .frame(minHeight: 110)
                    }

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
                    LabeledContent("Native runtime") {
                        if isLoadingInstalledBabelDocVersion {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(installedBabelDocVersion ?? String(localized: "Not installed", bundle: bundle))
                                .foregroundStyle(installedBabelDocVersion == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }

                    if let generalStatusMessage = generalStatus.message {
                        statusLabel(generalStatusMessage)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var readerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section(String(localized: "HTML Typography", bundle: bundle)) {
                    Stepper(value: htmlReaderFontSizeBinding, in: HTMLReaderTypography.fontSizeRange, step: 1) {
                        HStack {
                            Text("HTML Font Size", bundle: bundle)
                            Spacer()
                            Text("\(htmlReaderFontSizeValue)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(String(localized: "Reset Font Size", bundle: bundle)) {
                        htmlReaderFontSize = HTMLReaderTypography.defaultFontSize
                    }
                    .disabled(htmlReaderFontSizeValue == Int(HTMLReaderTypography.defaultFontSize))

                    Text("Controls the base font size used for localized HTML reader content and translations.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                    Text("System appearance changes automatically select Default for Light Mode and Paper Tone for Dark Mode. You can switch either option manually afterward.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                    Picker(
                        String(localized: "Reading Assistant Model", bundle: bundle),
                        selection: selectedAssistantModelProfileIDBinding
                    ) {
                        Text("Use HTML Model", bundle: bundle).tag(Optional<UUID>.none)
                        ForEach(sortedModels, id: \.id) { model in
                            Text(modelDisplayName(model)).tag(Optional(model.id))
                        }
                    }

                    Toggle(
                        String(localized: "Allow external search for the reading assistant", bundle: bundle),
                        isOn: $externalAssistantSearchEnabled
                    )

                    Text("Choose separate saved model profiles for translation and reading assistance. When enabled, external questions are answered through the selected model's server-side web search (Responses API), instead of calling academic search services directly.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var latexTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section(String(localized: "LaTeX Translation", bundle: bundle)) {
                    Toggle(
                        String(localized: "Enable arXiv LaTeX translation", bundle: bundle),
                        isOn: $latexTranslationEnabled
                    )

                    Text(
                        "When enabled, Translate arXiv LaTeX appears in the reader's Translate menu. It downloads the paper source, translates its semantic units, and uses the selected external TeX distribution to compile the translated PDF.",
                        bundle: bundle
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if latexTranslationEnabled, activeLaTeXInstallation?.isHealthy != true {
                        Label {
                            Text(
                                "LaTeX translation is enabled, but the selected toolchain is not ready. Install MacTeX or choose a directory that contains latexmk and a PDF engine.",
                                bundle: bundle
                            )
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(String(localized: "MacTeX", bundle: bundle)) {
                    Text(
                        "If you do not have a TeX distribution installed, MacTeX is recommended. The distribution is installed and maintained separately from Freddie.",
                        bundle: bundle
                    )
                    .fixedSize(horizontal: false, vertical: true)

                    Link(
                        String(localized: "Download MacTeX", bundle: bundle),
                        destination: URL(string: "https://tug.org/mactex/mactex-download.html")!
                    )
                }

                Section(String(localized: "LaTeX Installation", bundle: bundle)) {
                    Picker(
                        String(localized: "Toolchain directory", bundle: bundle),
                        selection: $latexToolchainDirectoryPath
                    ) {
                        if let automaticLaTeXLocation {
                            Text(
                                String(
                                    format: String(localized: "Automatic (%@)", bundle: bundle),
                                    automaticLaTeXLocation
                                )
                            )
                            .tag("")
                        } else {
                            Text("Automatic (not found)", bundle: bundle)
                                .tag("")
                        }

                        ForEach(detectedLaTeXInstallations) { installation in
                            Text(verbatim: installation.directoryURL.path)
                                .tag(installation.directoryURL.path)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 10) {
                        Button(String(localized: "Refresh", bundle: bundle)) {
                            Task {
                                await refreshLaTeXInstallations()
                            }
                        }

                        Button(String(localized: "Choose Folder", bundle: bundle)) {
                            chooseLaTeXToolchainDirectory()
                        }

                        Button(String(localized: "Use Automatic Detection", bundle: bundle)) {
                            latexToolchainDirectoryPath = ""
                        }
                        .disabled(latexToolchainDirectoryPath.isEmpty)
                    }

                    Text(
                        "Automatic detection checks the app's PATH and common MacTeX, Homebrew, and /usr/local locations. A manually selected directory takes precedence and must contain an executable latexmk.",
                        bundle: bundle
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Section(String(localized: "Current LaTeX Toolchain", bundle: bundle)) {
                    LabeledContent(String(localized: "Location on Disk", bundle: bundle)) {
                        Text(
                            activeLaTeXInstallation?.directoryURL.path
                                ?? String(localized: "Not found", bundle: bundle)
                        )
                        .foregroundStyle(activeLaTeXInstallation == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                    }

                    if let installation = activeLaTeXInstallation {
                        Label {
                            Text(
                                installation.isHealthy
                                    ? String(localized: "Basic health check passed", bundle: bundle)
                                    : String(localized: "Basic health check failed", bundle: bundle)
                            )
                        } icon: {
                            Image(systemName: installation.isHealthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                        }
                        .foregroundStyle(installation.isHealthy ? .green : .red)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(installation.executables) { executable in
                                Label(
                                    executable.name,
                                    systemImage: executable.isAvailable
                                        ? "checkmark.circle.fill"
                                        : "xmark.circle"
                                )
                                .foregroundStyle(executable.isAvailable ? .green : .secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text(
                            "No usable LaTeX installation was found. Install MacTeX, refresh detection, or choose the TeX binary directory manually.",
                            bundle: bundle
                        )
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

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
            .scrollContentBackground(.hidden)

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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedProviders, id: \.id) { provider in
                        entityListRow(isSelected: selectedProviderID == provider.id) {
                            providerListRow(provider)
                        }
                        .onTapGesture {
                            selectedProviderID = provider.id
                        }

                        if provider.id != sortedProviders.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .background(Color.clear)
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
                Text("OpenAI and DeepSeek are ready to use after you save an API key. You can also add custom providers and choose either the Responses API or Chat Completions.", bundle: bundle)
                    .fixedSize(horizontal: false, vertical: true)

                Text("API keys are protected with Touch ID or your device password. After the first approval, this Freddie installation stays authorized until the app is updated or the key changes. Leaving the API key field blank while editing keeps the saved key.", bundle: bundle)
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
                SettingsFieldRow(String(localized: "API protocol", bundle: bundle)) {
                    Picker(String(localized: "API protocol", bundle: bundle), selection: $providerAPIStyle) {
                        ForEach(LLMAPIStyle.allCases, id: \.self) { style in
                            Text(apiStyleLabel(style)).tag(style)
                        }
                    }
                    .labelsHidden()
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
                    .disabled(isTestingProvider || isTestingProviderWebSearch)

                    Button(
                        isTestingProviderWebSearch
                            ? String(localized: "Testing web search...", bundle: bundle)
                            : String(localized: "Test Web Search", bundle: bundle)
                    ) {
                        testProviderWebSearch()
                    }
                    .disabled(
                        isTestingProvider
                            || isTestingProviderWebSearch
                            || providerAPIStyle != .responses
                    )
                    .help(
                        providerAPIStyle == .responses
                            ? String(localized: "Test server-side web search and capture its complete trace.", bundle: bundle)
                            : String(localized: "Web search testing requires the Responses API.", bundle: bundle)
                    )
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

                if let providerWebSearchStatusMessage {
                    statusLabel(providerWebSearchStatusMessage)
                }

                if let providerWebSearchOutputPreview,
                   providerWebSearchOutputPreview.isEmpty == false {
                    Text(providerWebSearchOutputPreview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if providerWebSearchSources.isEmpty == false {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(providerWebSearchSources, id: \.urlString) { source in
                                Button {
                                    guard let url = URL(string: source.urlString) else { return }
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label(
                                        URL(string: source.urlString)?.host ?? source.urlString,
                                        systemImage: "network"
                                    )
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(source.title ?? source.urlString)
                            }
                        }
                    }
                }

                WebSearchTracePanel(
                    store: webSearchTrace,
                    isExpanded: $showsProviderWebSearchTrace
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var modelListPanel: some View {
        entityListPanel(
            title: String(localized: "Models", bundle: bundle),
            count: sortedModels.count
        ) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedModels, id: \.id) { model in
                        entityListRow(isSelected: selectedModelID == model.id) {
                            modelListRow(model)
                        }
                        .onTapGesture {
                            selectedModelID = model.id
                        }

                        if model.id != sortedModels.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .background(Color.clear)
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
                Text("A model profile points to one provider and stores the exact model name plus optional sampling parameters. You can create separate profiles for fast HTML translation and heavier PDF work.", bundle: bundle)
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
                        SettingsFieldRow(String(localized: "Thinking Mode", bundle: bundle)) {
                            Picker(String(localized: "Thinking Mode", bundle: bundle), selection: $modelThinkingMode) {
                                Text(String(localized: "Default", bundle: bundle))
                                    .tag(Optional<LLMThinkingMode>.none)
                                ForEach(LLMThinkingMode.allCases, id: \.self) { mode in
                                    Text(thinkingModeLabel(mode))
                                        .tag(Optional(mode))
                                }
                            }
                            .labelsHidden()
                        }
                        SettingsFieldRow(String(localized: "Reasoning Effort", bundle: bundle)) {
                            Picker(String(localized: "Reasoning Effort", bundle: bundle), selection: $modelReasoningEffort) {
                                Text(String(localized: "Default", bundle: bundle))
                                    .tag(Optional<LLMReasoningEffort>.none)
                                ForEach(LLMReasoningEffort.allCases, id: \.self) { effort in
                                    Text(reasoningEffortLabel(effort))
                                        .tag(Optional(effort))
                                }
                            }
                            .labelsHidden()
                            .disabled(modelThinkingMode == .disabled)
                        }
                        Text("Thinking mode controls whether the model outputs a chain of thought before answering (for example DeepSeek V4). Reasoning effort is omitted while thinking is disabled.", bundle: bundle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
        .scrollContentBackground(.hidden)
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
            .frame(height: 28)
            .padding(.horizontal, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    private func entityListRow<RowContent: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> RowContent
    ) -> some View {
        content()
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.18))
                }
            }
    }

    private func providerListRow(_ provider: LLMProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(provider.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if providerIDsWithStoredAPIKeys.contains(provider.id) {
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

            Text(apiStyleLabel(apiStyleStore.apiStyle(for: provider.id)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                    : String(localized: "Open Providers, choose OpenAI or DeepSeek, and save an API key.", bundle: bundle),
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
                    : String(localized: "Default OpenAI and DeepSeek model profiles are ready when their provider has a saved API key.", bundle: bundle),
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
        if let assistantModelID = UUID(uuidString: selectedAssistantModelProfileIDRawValue),
           models.contains(where: { $0.id == assistantModelID }) == false {
            selectedAssistantModelProfileIDRawValue = ""
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
        resetProviderWebSearchTestState()
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
        resetProviderWebSearchTestState()
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

    private func saveProvider() {
        do {
            let normalizedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedName.isEmpty == false else {
                throw SettingsValidationError.message(String(localized: "Provider name cannot be empty.", bundle: bundle))
            }

            let normalizedBaseURL = try validator.normalizedBaseURL(providerBaseURL)
            let normalizedTestModel = try validator.validateModelName(providerTestModel)
            let normalizedAPIStyle = providerAPIStyle
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
            apiStyleStore.setAPIStyle(normalizedAPIStyle, for: provider.id)

            let trimmedAPIKey = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAPIKey.isEmpty == false {
                try keychainStore.save(trimmedAPIKey, account: provider.apiKeyRef)
            } else {
                guard try keychainStore.migrateToUserPresenceIfNeeded(account: provider.apiKeyRef) else {
                    throw LLMProviderValidationError.emptyAPIKey
                }
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
            providerIDsWithStoredAPIKeys.insert(provider.id)
            providerStatusMessage = String(localized: "Provider saved.", bundle: bundle)
            providerOutputPreview = nil
            resetProviderWebSearchTestState()
        } catch {
            providerStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        }
    }

    private func deleteSelectedProvider() {
        guard let provider = selectedProvider else { return }
        let providerID = provider.id
        let isBuiltInProvider = LLMDefaultProfiles.isBuiltInProvider(providerID)

        let relatedModelIDs = Set(models.filter { $0.providerID == provider.id }.map(\.id))
        let relatedBuiltInModelIDs = relatedModelIDs.filter(LLMDefaultProfiles.isBuiltInModel)
        for model in models where relatedModelIDs.contains(model.id) {
            modelContext.delete(model)
        }
        if let htmlModelID = settings.selectedHTMLModelProfileID, relatedModelIDs.contains(htmlModelID) {
            settings.selectedHTMLModelProfileID = nil
        }
        if let pdfModelID = settings.selectedPDFModelProfileID, relatedModelIDs.contains(pdfModelID) {
            settings.selectedPDFModelProfileID = nil
        }
        if let assistantModelID = UUID(uuidString: selectedAssistantModelProfileIDRawValue),
           relatedModelIDs.contains(assistantModelID) {
            selectedAssistantModelProfileIDRawValue = ""
        }
        modelContext.delete(provider)
        apiStyleStore.removeAPIStyle(for: provider.id)

        do {
            settings.modifiedAt = Date()
            try modelContext.save()
            try? keychainStore.delete(account: provider.apiKeyRef)
            providerIDsWithStoredAPIKeys.remove(providerID)
            if isBuiltInProvider {
                defaultProfileDeletionStore.markProviderDeleted(providerID)
            }
            for modelID in relatedBuiltInModelIDs {
                defaultProfileDeletionStore.markModelDeleted(modelID)
            }
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
                providerOutputPreview = nil
            }
        }
    }

    private func testProviderWebSearch() {
        isTestingProviderWebSearch = true
        providerWebSearchStatusMessage = String(localized: "Testing web search...", bundle: bundle)
        providerWebSearchOutputPreview = nil
        providerWebSearchSources = []
        webSearchTrace.reset()
        showsProviderWebSearchTrace = true

        Task { @MainActor in
            defer { isTestingProviderWebSearch = false }

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

                let result = try await validator.testWebSearch(
                    baseURL: providerBaseURL,
                    apiStyle: providerAPIStyle,
                    apiKey: apiKey,
                    model: providerTestModel,
                    onTraceUpdated: { appendedEntries in
                        await webSearchTrace.append(appendedEntries)
                    }
                )

                providerWebSearchStatusMessage = AppLocalization.format(
                    "Web search test passed in %d ms with %d source URLs.",
                    bundle: bundle,
                    result.latencyMs,
                    result.sources.count
                )
                providerWebSearchOutputPreview = result.outputPreview
                providerWebSearchSources = result.sources
            } catch {
                providerWebSearchStatusMessage = AppLocalization.errorMessage(error, bundle: bundle)
                providerWebSearchOutputPreview = nil
                providerWebSearchSources = []
            }
        }
    }

    private func resetProviderWebSearchTestState() {
        providerWebSearchStatusMessage = nil
        providerWebSearchOutputPreview = nil
        providerWebSearchSources = []
        webSearchTrace.reset()
        showsProviderWebSearchTrace = false
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
            let thinkingMode = modelThinkingMode
            let reasoningEffort = modelReasoningEffort
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
                    thinkingMode: thinkingMode,
                    reasoningEffort: reasoningEffort,
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
            model.thinkingModeValue = thinkingMode
            model.reasoningEffortValue = reasoningEffort
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
        let modelID = model.id
        let isBuiltInModel = LLMDefaultProfiles.isBuiltInModel(modelID)
        if settings.selectedHTMLModelProfileID == model.id {
            settings.selectedHTMLModelProfileID = nil
        }
        if settings.selectedPDFModelProfileID == model.id {
            settings.selectedPDFModelProfileID = nil
        }
        if UUID(uuidString: selectedAssistantModelProfileIDRawValue) == model.id {
            selectedAssistantModelProfileIDRawValue = ""
        }
        modelContext.delete(model)

        do {
            settings.modifiedAt = Date()
            try modelContext.save()
            if isBuiltInModel {
                defaultProfileDeletionStore.markModelDeleted(modelID)
            }
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
                    apiStyle: apiStyleStore.apiStyle(for: provider.id),
                    apiKey: apiKey,
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

        let probe = await Task.detached(priority: .utility) {
            do {
                let paths = try BabelDocToolManager().nativeToolPaths()
                return NativeBabelDocSettingsProbe(
                    isAvailable: true,
                    installedVersion: paths.runtimeVersion
                )
            } catch {
                return NativeBabelDocSettingsProbe(
                    isAvailable: false,
                    installedVersion: nil
                )
            }
        }.value
        hasManagedBabelDOCFiles = probe.isAvailable
        installedBabelDocVersion = probe.installedVersion

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

    private func refreshLaTeXInstallations() async {
        let selectedDirectories = selectedLaTeXDirectoryURL.map { [$0] } ?? []
        let selectedDirectory = selectedLaTeXDirectoryURL
        let installations = await Task.detached(priority: .utility) {
            var detected = ReadPaperLaTeXToolchain.installations(
                additionalSearchDirectories: selectedDirectories
            )
            if let selectedDirectory,
               !detected.contains(where: { $0.directoryURL == selectedDirectory }) {
                detected.append(
                    ReadPaperLaTeXToolchain.installation(at: selectedDirectory)
                )
            }
            return detected
        }.value
        detectedLaTeXInstallations = installations.sorted {
            $0.directoryURL.path.localizedStandardCompare($1.directoryURL.path) == .orderedAscending
        }
    }

    private func chooseLaTeXToolchainDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", bundle: bundle)
        panel.message = String(
            localized: "Choose the directory that contains latexmk and your TeX engines.",
            bundle: bundle
        )
        panel.directoryURL = selectedLaTeXDirectoryURL
            ?? activeLaTeXInstallation?.directoryURL
            ?? URL(fileURLWithPath: "/Library/TeX/texbin", isDirectory: true)

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        latexToolchainDirectoryPath = directoryURL.standardizedFileURL.path
        Task {
            await refreshLaTeXInstallations()
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
        (try? keychainStore.contains(account: ref)) == true
    }

    private func refreshStoredAPIKeyAvailability() {
        providerIDsWithStoredAPIKeys = Set(
            providers.compactMap { provider in
                hasStoredAPIKey(ref: provider.apiKeyRef) ? provider.id : nil
            }
        )
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
        case .enabled:
            return String(localized: "Enabled", bundle: bundle)
        case .disabled:
            return String(localized: "Disabled", bundle: bundle)
        }
    }

    private func reasoningEffortLabel(_ effort: LLMReasoningEffort) -> String {
        switch effort {
        case .low:
            return String(localized: "Low", bundle: bundle)
        case .high:
            return String(localized: "High", bundle: bundle)
        case .max:
            return String(localized: "Max", bundle: bundle)
        }
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
