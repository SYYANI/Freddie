import BabelDocKit
import Foundation

#if os(iOS)
struct InProcessBabelDocRunner {
    let bundle: Bundle
    let fileManager: FileManager

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        self.bundle = bundle
        self.fileManager = fileManager
    }

    func translatePDF(
        inputPDF: URL,
        outputDirectory: URL,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        pageRange: ClosedRange<Int>? = nil,
        onProgressUpdate: (@Sendable (BabelDocProgressUpdate) -> Void)? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let runtime = try embeddedRuntimeAssets()
        guard let baseURL = URL(string: route.baseURL),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw InProcessBabelDocError.invalidBaseURL(route.baseURL)
        }

        let outputPDF = outputDirectory.appendingPathComponent(
            "babeldoc-ios-\(UUID().uuidString).pdf"
        )
        let request = BabelDocTranslationRequest(
            inputPDF: inputPDF,
            outputPDF: outputPDF,
            pages: pageRange.map(Array.init),
            targetLanguage: preferences.targetLanguage,
            preferCoreML: true,
            onlyIncludeTranslatedPages: pageRange != nil
        )
        let configuration = BabelDocOpenAIConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            model: route.modelName,
            temperature: route.temperature ?? 0.2,
            topP: route.topP,
            maxTokens: route.maxTokens,
            requestsPerSecond: Double(max(preferences.babelDocQPS, 1))
        )

        let worker = Task.detached(priority: .userInitiated) {
            do {
                _ = try await BabelDoc.translate(
                    request: request,
                    runtime: runtime,
                    openAI: configuration,
                    onProgress: { progress in
                        onProgressUpdate?(Self.progressUpdate(progress))
                    }
                )
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: outputPDF.path) else {
                    throw InProcessBabelDocError.noTranslatedPDFProduced
                }
                return outputPDF
            } catch {
                try? FileManager.default.removeItem(at: outputPDF)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func embeddedRuntimeAssets() throws -> BabelDocEmbeddedRuntimeAssets {
        try Self.embeddedRuntimeAssets(bundle: bundle, fileManager: fileManager)
    }

    private static func embeddedRuntimeAssets(
        bundle: Bundle,
        fileManager: FileManager
    ) throws -> BabelDocEmbeddedRuntimeAssets {
        guard let root = bundle.resourceURL?.appendingPathComponent(
            "BabelDOCEmbedded",
            isDirectory: true
        ) else {
            throw InProcessBabelDocError.missingRuntimeDirectory
        }
        let model = root.appendingPathComponent(
            "models/doclayout_yolo_docstructbench_imgsz1024.onnx"
        )
        let fonts = root.appendingPathComponent("fonts", isDirectory: true)
        guard fileManager.fileExists(atPath: model.path) else {
            throw InProcessBabelDocError.missingLayoutModel
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fonts.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw InProcessBabelDocError.missingFontDirectory
        }
        return BabelDocEmbeddedRuntimeAssets(layoutModel: model, fontDirectory: fonts)
    }

    static func progressUpdate(_ progress: BabelDocProgress) -> BabelDocProgressUpdate {
        let completed = min(max(progress.overallPercentage, 0), 100)
        let stageName = statusMessage(for: progress.stage)
        let summary: String
        if progress.total > 0 {
            summary = "\(stageName) \(min(max(progress.completed, 0), progress.total))/\(progress.total)"
        } else {
            summary = stageName
        }
        return BabelDocProgressUpdate(
            completed: completed,
            total: 100,
            summary: summary,
            statusMessage: summary
        )
    }

    static func statusMessage(for stage: BabelDocStage) -> String {
        switch stage {
        case .frontend:
            AppLocalization.localized("Preparing PDF structure")
        case .layout:
            AppLocalization.localized("Analyzing layout")
        case .paragraph:
            AppLocalization.localized("Grouping paragraphs")
        case .styles:
            AppLocalization.localized("Preserving styles and formulas")
        case .translation:
            AppLocalization.localized("Translating text blocks")
        case .typesetting:
            AppLocalization.localized("Applying translated layout")
        case .backend:
            AppLocalization.localized("Generating translated PDF")
        }
    }
}

enum InProcessBabelDocError: Error, LocalizedError, Equatable {
    case invalidBaseURL(String)
    case missingRuntimeDirectory
    case missingLayoutModel
    case missingFontDirectory
    case noTranslatedPDFProduced

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            AppLocalization.format("The provider Base URL is invalid: %@", value)
        case .missingRuntimeDirectory:
            AppLocalization.localized("The embedded BabelDOC runtime is missing.")
        case .missingLayoutModel:
            AppLocalization.localized("The embedded BabelDOC layout model is missing.")
        case .missingFontDirectory:
            AppLocalization.localized("The embedded BabelDOC fonts are missing.")
        case .noTranslatedPDFProduced:
            AppLocalization.localized("BabelDOC finished without producing a translated PDF.")
        }
    }
}
#endif
