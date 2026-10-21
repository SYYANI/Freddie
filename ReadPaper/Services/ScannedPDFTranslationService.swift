import Foundation

/// The model that reads scanned pages is chosen per purpose like the reading assistant's,
/// in UserDefaults rather than `AppSettings`, so older app versions can still open the store.
enum ScannedPDFTranslationPreferences {
    static let transcriptionModelProfileIDKey = "ReadPaper.ScannedPDF.TranscriptionModelProfileID"
    /// The page-image and cost notice is acknowledged once across papers and launches.
    static let didConfirmTranslationKey = "ReadPaper.ScannedPDF.DidConfirmTranslation"

    /// Translated scans are typeset with Simplified Chinese fonts and prompts only.
    static func supports(targetLanguage: String) -> Bool {
        targetLanguage == TranslationTargetLanguage.simplifiedChinese.code
    }
}

/// The corrected transcription that scanned-PDF translation typesets next to the translation:
/// the proofread original-language pages, page for page like the scan, with real text.
enum ScannedPDFTranscription {
    /// Papers whose original is shown as the transcription instead of the scan.
    static let displayedPaperIDsKey = "ReadPaper.ScannedPDF.TranscriptionPaperIDs"

    static func attachment(in attachments: [PaperAttachment]) -> PaperAttachment? {
        attachments
            .filter { $0.kind == .resource && $0.source == .scanRebuild }
            .max { $0.createdAt < $1.createdAt }
    }

    static func decode(_ storage: String) -> Set<UUID> {
        Set(storage.split(separator: "\n").compactMap { UUID(uuidString: String($0)) })
    }

    static func encode(_ paperIDs: Set<UUID>) -> String {
        paperIDs.map(\.uuidString).sorted().joined(separator: "\n")
    }
}

#if os(macOS)
import PDFKit
import RebuildPDFKit

/// Sends RebuildPDFKit's requests through a resolved provider route.
struct ReadPaperRebuildModelClient: RebuildModelClient {
    let route: LLMModelRouteSnapshot
    let apiKey: String
    let provider: any ReadPaperLLMCompleting

    init(route: LLMModelRouteSnapshot, apiKey: String, provider: any ReadPaperLLMCompleting = OpenAICompatibleLLMProvider()) {
        self.route = route
        self.apiKey = apiKey
        self.provider = provider
    }

    /// Endpoint, model and sampling settings; changing any of them re-requests cached pages.
    var identity: String {
        [
            "url=\(route.baseURL)",
            "api=\(route.apiStyle.rawValue)",
            "model=\(route.modelName)",
            "temperature=\(route.temperature.map { String($0) } ?? "default")",
            "topP=\(route.topP.map { String($0) } ?? "default")",
            "thinking=\(route.thinkingMode?.rawValue ?? "default")",
            "reasoning=\(route.reasoningEffort?.rawValue ?? "default")",
        ].joined(separator: "|")
    }

    func complete(_ request: RebuildCompletionRequest) async throws -> RebuildCompletion {
        guard let baseURL = URL(string: route.baseURL) else {
            throw LLMProviderError.invalidConfiguration(
                AppLocalization.format("Invalid provider base URL: %@", route.baseURL)
            )
        }
        let response = try await provider.complete(request: LLMCompletionRequest(
            baseURL: baseURL,
            apiStyle: route.apiStyle,
            apiKey: apiKey,
            model: route.modelName,
            messages: request.messages.map(Self.message),
            temperature: route.temperature,
            topP: route.topP,
            maxTokens: request.maxTokens,
            thinkingMode: route.thinkingMode,
            reasoningEffort: route.reasoningEffort,
            timeoutProfile: .scannedPage,
            allowsTruncatedOutput: true
        ))
        let usage = response.usage.map {
            RebuildUsage(promptTokens: $0.inputTokens, completionTokens: $0.outputTokens, totalTokens: $0.totalTokens)
        } ?? RebuildUsage()
        let finishReason: RebuildCompletion.FinishReason
        switch response.finishReason {
        case .length:
            finishReason = .length
        case .other:
            finishReason = .other
        case .stop, nil:
            // Providers that do not report a reason only answer when the model finished.
            finishReason = .stop
        }
        return RebuildCompletion(text: response.text, usage: usage, finishReason: finishReason)
    }

    /// Text-only messages, such as earlier answers and corrections, stay plain strings.
    static func message(_ message: RebuildMessage) -> LLMCompletionMessage {
        if let text = message.plainText {
            return LLMCompletionMessage(role: message.role, content: text)
        }
        return LLMCompletionMessage(role: message.role, parts: message.parts.map { part in
            switch part {
            case .text(let text):
                return .text(text)
            case .jpeg(let data):
                return .image(data: data, mediaType: "image/jpeg")
            }
        })
    }
}

struct ScannedPDFTranslationRequest: Sendable {
    var paperID: UUID
    var inputPDF: URL
    /// 1-based pages to translate; nil translates every page. Skipped pages before the last
    /// chosen one stay as scanned; the translation ends at the last chosen page.
    var pages: [Int]?
    /// Reads the page images; needs a model that accepts images.
    var transcriptionRoute: ResolvedLLMModelRoute
    /// Translates the transcribed text.
    var translationRoute: ResolvedLLMModelRoute
    var maximumConcurrentPages: Int = 4
}

struct ScannedPDFTranslationOutput: Sendable {
    var outputPDF: URL
    /// The last page of a translation that stops before the end of the scan, like a partial
    /// BabelDOC translation; nil when it covers every page.
    var translatedLastPage: Int?
    /// The corrected transcription; pages that could not be transcribed show the scan.
    var transcriptionPDF: URL?
    var rebuiltPages: [Int]
    /// Pages within the translation that kept the scanned page, with the reason.
    var fallbacks: [Int: String]
    /// Failed pages at the end of the run, left out of the translation so that continuing
    /// tries them again, with the reason.
    var unfinishedPages: [Int: String] = [:]
    var totalTokens: Int
}

/// What a scanned-PDF translation is doing, for the reader's progress capsule.
struct ScannedPDFTranslationProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case checkingTeX
        case rebuilding(RebuildProgress.Stage)
    }

    var stage: Stage
    var fractionCompleted: Double
    var completedSteps: Int
    var totalSteps: Int

    func statusMessage(bundle: Bundle) -> String {
        switch stage {
        case .checkingTeX:
            return String(localized: "Checking XeLaTeX...", bundle: bundle)
        case .rebuilding(.rendering):
            return String(localized: "Rendering scanned pages...", bundle: bundle)
        case .rebuilding(.transcribing):
            return String(localized: "Reading scanned pages with the vision model...", bundle: bundle)
        case .rebuilding(.reviewing):
            return String(localized: "Proofreading rebuilt pages against the scan...", bundle: bundle)
        case .rebuilding(.translating):
            return String(localized: "Translating rebuilt pages...", bundle: bundle)
        case .rebuilding(.typesetting):
            return String(localized: "Typesetting translated pages...", bundle: bundle)
        case .rebuilding(.assembling):
            return String(localized: "Assembling the translated PDF...", bundle: bundle)
        }
    }
}

enum ScannedPDFTranslationError: LocalizedError, Equatable {
    case xelatexNotFound
    case unsupportedTargetLanguage
    /// XeLaTeX is installed but cannot typeset the probe page; carries its message.
    case incompleteTeXInstallation(String)
    case unreadablePDF
    case renderingFailed(page: Int)
    case noPagesRebuilt(String)
    case outputNotWritten

    var errorDescription: String? {
        switch self {
        case .xelatexNotFound:
            return AppLocalization.localized(
                "Scanned PDF translation needs XeLaTeX. Install MacTeX, or choose its folder in Settings > LaTeX."
            )
        case .unsupportedTargetLanguage:
            return AppLocalization.localized(
                "Scanned PDF translation currently translates into Simplified Chinese only. Change the target language in Settings."
            )
        case .incompleteTeXInstallation(let detail):
            return AppLocalization.format(
                "XeLaTeX is missing a package or font that scanned PDF translation needs. Install the full MacTeX, or add the package with tlmgr. %@",
                detail
            )
        case .unreadablePDF:
            return AppLocalization.localized("The PDF could not be opened.")
        case .renderingFailed(let page):
            return AppLocalization.format("Page %d of the PDF could not be rendered.", page)
        case .noPagesRebuilt(let detail):
            return AppLocalization.format("No page of the scan could be rebuilt. %@", detail)
        case .outputNotWritten:
            return AppLocalization.localized("The translated PDF could not be saved.")
        }
    }

    init?(_ error: RebuildError) {
        switch error {
        case .unreadableInput:
            self = .unreadablePDF
        case .renderingFailed(let page):
            self = .renderingFailed(page: page)
        case .noPagesRebuilt(let detail):
            self = .noPagesRebuilt(detail)
        case .outputNotWritten:
            self = .outputNotWritten
        case .unusableModelOutput, .incompleteModelOutput:
            return nil
        }
    }
}

/// Translates scanned PDFs (and PDFs with an unreliable text layer) by rebuilding each page
/// with RebuildPDFKit: a vision model transcribes the page as LaTeX, the text model
/// translates it, and XeLaTeX typesets it on the original page geometry. The result has the
/// same pages as the original, so it opens side by side like any translated PDF. The
/// proofread transcription is typeset too, as an alternative original with selectable text.
///
/// Checkpoints live in the paper's `Resources/ScanRebuild` folder: an interrupted or
/// repeated run reuses every page already transcribed or translated.
struct ScannedPDFTranslationService {
    static let outputFilename = "scan-rebuild.zh.pdf"
    static let transcriptionFilename = "transcription.pdf"

    var fileStore = PaperFileStore()
    var recognizer: any TextRecognizing = VisionTextRecognizer()
    var provider: any ReadPaperLLMCompleting = OpenAICompatibleLLMProvider()
    var compiler: (any TeXCompiling)?

    /// XeLaTeX from the LaTeX toolchain chosen in Settings, else the usual MacTeX and Homebrew places.
    static func locateXeLaTeX(userDefaults: UserDefaults = .standard) -> URL? {
        let selected = LaTeXIntegrationPreferences.selectedToolchainDirectory(userDefaults: userDefaults)
        return XeLaTeXCompiler.locate(in: [selected].compactMap { $0 })
    }

    func artifactsDirectory(for paperID: UUID) throws -> URL {
        let directory = try fileStore.directory(for: paperID)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ScanRebuild", isDirectory: true)
        try fileStore.ensureDirectory(directory)
        return directory
    }

    func translate(
        _ request: ScannedPDFTranslationRequest,
        progress: @escaping @Sendable (ScannedPDFTranslationProgress) -> Void
    ) async throws -> ScannedPDFTranslationOutput {
        let compiler: any TeXCompiling
        if let configured = self.compiler {
            compiler = configured
        } else if let executable = Self.locateXeLaTeX() {
            compiler = XeLaTeXCompiler(executable: executable)
        } else {
            throw ScannedPDFTranslationError.xelatexNotFound
        }
        let artifacts = try artifactsDirectory(for: request.paperID)
        progress(ScannedPDFTranslationProgress(stage: .checkingTeX, fractionCompleted: 0, completedSteps: 0, totalSteps: 0))
        do {
            try await TeXInstallationCheck.verify(
                compiler: compiler, directory: artifacts.appendingPathComponent("tex-check", isDirectory: true)
            )
        } catch let error as LatexError {
            throw ScannedPDFTranslationError.incompleteTeXInstallation(error.message)
        }

        let output = try fileStore.translationsDirectory(for: request.paperID)
            .appendingPathComponent(Self.outputFilename)
        let pipeline = RebuildPipeline(
            transcriber: ReadPaperRebuildModelClient(
                route: request.transcriptionRoute.snapshot, apiKey: request.transcriptionRoute.apiKey, provider: provider
            ),
            translator: ReadPaperRebuildModelClient(
                route: request.translationRoute.snapshot, apiKey: request.translationRoute.apiKey, provider: provider
            ),
            recognizer: recognizer,
            compiler: compiler,
            configuration: RebuildConfiguration(
                maximumConcurrentPages: request.maximumConcurrentPages,
                pages: request.pages,
                translation: .simplifiedChinese
            )
        )
        do {
            let result = try await pipeline.run(
                input: request.inputPDF,
                output: output,
                artifacts: artifacts,
                sourceOutput: artifacts.appendingPathComponent(Self.transcriptionFilename)
            ) { update in
                progress(ScannedPDFTranslationProgress(
                    stage: .rebuilding(update.stage),
                    fractionCompleted: update.fractionCompleted,
                    completedSteps: update.completedSteps,
                    totalSteps: update.totalSteps
                ))
            }
            // RebuildPDFKit fills the pages it did not rebuild with the scan. Past the last chosen
            // page, or on failed pages at the end, that would pass untranslated pages off as
            // translation, so the output ends at the last rebuilt page.
            let pageCount = PDFDocument(url: result.output)?.pageCount ?? 0
            let failedPages = Set(result.fallbacks.keys)
            guard let lastPage = Self.lastRebuiltPage(pages: request.pages, pageCount: pageCount, failedPages: failedPages) else {
                throw ScannedPDFTranslationError.noPagesRebuilt(
                    result.fallbacks.sorted { $0.key < $1.key }.first?.value ?? ""
                )
            }
            let translatedLastPage = lastPage < pageCount ? lastPage : nil
            if let translatedLastPage {
                try Self.keepFirstPages(translatedLastPage, of: result.output)
            }
            return ScannedPDFTranslationOutput(
                outputPDF: result.output,
                translatedLastPage: translatedLastPage,
                transcriptionPDF: result.sourceRebuiltPages.isEmpty ? nil : result.sourceOutput,
                rebuiltPages: result.rebuiltPages,
                fallbacks: result.fallbacks.filter { $0.key <= lastPage },
                unfinishedPages: result.fallbacks.filter { $0.key > lastPage },
                totalTokens: result.usage.totalTokens
            )
        } catch let error as RebuildError {
            throw ScannedPDFTranslationError(error) ?? error
        }
    }

    /// The last page of a run over the first pages of a longer PDF, which the reader can continue;
    /// nil when the run covers every page.
    static func translatedLastPage(pages: [Int]?, pageCount: Int, failedPages: Set<Int> = []) -> Int? {
        guard let lastPage = lastRebuiltPage(pages: pages, pageCount: pageCount, failedPages: failedPages),
              lastPage < pageCount
        else { return nil }
        return lastPage
    }

    /// The last chosen page before any failed pages at the end of the run; nil when none is left.
    private static func lastRebuiltPage(pages: [Int]?, pageCount: Int, failedPages: Set<Int>) -> Int? {
        var lastPage = min(pages?.max() ?? pageCount, pageCount)
        while lastPage > 0, failedPages.contains(lastPage) {
            lastPage -= 1
        }
        return lastPage > 0 ? lastPage : nil
    }

    private static func keepFirstPages(_ count: Int, of url: URL) throws {
        guard let document = PDFDocument(url: url) else { throw ScannedPDFTranslationError.outputNotWritten }
        while document.pageCount > count {
            document.removePage(at: document.pageCount - 1)
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard document.write(to: temporary) else { throw ScannedPDFTranslationError.outputNotWritten }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ScannedPDFTranslationError.outputNotWritten
        }
    }

    /// The status line after a run that kept some scanned pages or stopped before failed pages;
    /// nil when every page was rebuilt.
    static func failureMessage(for output: ScannedPDFTranslationOutput, bundle: Bundle) -> String? {
        var messages: [String] = []
        if !output.fallbacks.isEmpty {
            messages.append(fallbackMessage(count: output.fallbacks.count, bundle: bundle))
        }
        if !output.unfinishedPages.isEmpty {
            messages.append(AppLocalization.format(
                "Pages %@ could not be rebuilt and were not added to the translation. Continue translating to try them again.",
                bundle: bundle,
                output.unfinishedPages.keys.sorted().map(String.init).joined(separator: ", ")
            ))
        }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    /// The status line after a run that kept some scanned pages.
    static func fallbackMessage(count: Int, bundle: Bundle) -> String {
        AppLocalization.format(
            "%d pages could not be rebuilt and show the scan. Translate the scanned PDF again to retry them; finished pages are reused.",
            bundle: bundle,
            count
        )
    }
}
#endif
