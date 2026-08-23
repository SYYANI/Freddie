import BabelDocKit
import Foundation

private struct Options {
    var input: String?
    var output: String?
    var runtimeRoot: String?
    var runtimeManifest: String?
    var targetLanguage = "zh-CN"
    var baseURL: String?
    var model: String?
    var apiKeyEnvironment = "READPAPER_LLM_API_KEY"
    var pages: [Int]?
    var qps = 50.0
    var temperature = 0.2
    var topP: Double?
    var maxTokens: Int?
    var thinkingMode: BabelDocThinkingMode?
    var reasoningEffort: BabelDocReasoningEffort?
    var systemPrompt: String?
    var documentTitle: String?
    var glossary: String?
    var semanticHints: String?
    var preferCoreML = true
    var onlySelectedPages = false
    var verifyRuntime = false
}

private enum HelperError: Error, LocalizedError {
    case argument(String)

    var errorDescription: String? {
        switch self {
        case let .argument(message): message
        }
    }
}

private final class EventEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStage: BabelDocStage?

    func summary() { emit(["type": "stage_summary"]) }

    func progress(_ value: BabelDocProgress) {
        lock.lock()
        let isNewStage = lastStage != value.stage
        lastStage = value.stage
        lock.unlock()
        let stage = Self.bridgeStage(value.stage)
        if isNewStage {
            emit(["type": "progress_start", "stage": stage])
        }
        emit([
            "type": value.overallPercentage >= 100 ? "progress_end" : "progress_update",
            "stage": stage,
            "stage_current": value.completed,
            "stage_total": value.total,
            "stage_progress": value.total > 0
                ? Double(value.completed) / Double(value.total) * 100 : 100,
            "overall_progress": value.overallPercentage,
        ])
    }

    func error(_ message: String) { emit(["type": "error", "error": message]) }

    func diagnostics(_ result: BabelDocTranslationResult) {
        var event: [String: Any] = [
            "type": "translation_diagnostics",
            "semantic_status": result.semanticHintStatus.rawValue,
            "translation_candidates": result.translationDiagnostics.candidateCount,
            "translation_completed": result.translationDiagnostics.translatedCount,
            "translation_failed": result.translationDiagnostics.failedCount,
            "provider_failures": result.translationDiagnostics.providerFailureCount,
            "placeholder_validation_failures": result.translationDiagnostics
                .placeholderValidationFailureCount,
            "semantic_translation_fallbacks": result.translationDiagnostics.semanticFallbackCount,
            "continuation_groups": result.translationDiagnostics.continuationGroupCount,
        ]
        if let report = result.semanticEnrichmentReport {
            event["semantic_pdf_paragraphs"] = report.pdfParagraphCount
            event["semantic_matched_pdf_paragraphs"] = report.matchedPDFParagraphCount
            event["semantic_matched_pdf_coverage"] = report.matchedPDFCoverage
            event["semantic_high_confidence"] = report.highConfidenceMatchCount
            event["semantic_medium_confidence"] = report.mediumConfidenceMatchCount
            event["semantic_low_confidence"] = report.lowConfidenceMatchCount
            event["semantic_structural_changes_enabled"] = report.structuralChangesEnabled
            event["semantic_elapsed_ms"] = report.elapsedMilliseconds
        }
        emit(event)
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        lock.lock()
        FileHandle.standardOutput.write(Data("__READPAPER_BABELDOC_EVENT__".utf8))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        lock.unlock()
    }

    private static func bridgeStage(_ stage: BabelDocStage) -> String {
        switch stage {
        case .frontend: "ILCreater"
        case .layout: "LayoutParser"
        case .paragraph: "ParagraphFinder"
        case .styles: "StylesAndFormulas"
        case .semantic: "SemanticHintEnricher"
        case .translation: "ILTranslator"
        case .typesetting: "Typesetting"
        case .backend: "PDFCreater"
        }
    }
}

private func usage() {
    FileHandle.standardError.write(Data("""
    Usage: babeldoc-readpaper-helper --input <pdf> --output <pdf>
           --runtime-root <directory> --runtime-manifest <trusted-json>
           --openai-base-url <url> --openai-model <model> [options]

      --target-language <language>       Default: zh-CN
      --api-key-environment <name>       Default: READPAPER_LLM_API_KEY
      --pages <first-last>               Translate a 1-based inclusive range
      --only-include-translated-pages    Output only selected pages for incremental merge
      --qps <number> --temperature <n> --top-p <n> --max-tokens <n>
      --thinking-mode <enabled|disabled> --reasoning-effort <low|high|max> --cpu
      --system-prompt <text> --document-title <text> --glossary <text>
      --semantic-hints <json>           Optional LaTeX semantic hint document
      --verify-runtime                   Verify runtime assets and exit
    """.utf8))
}

private func value(_ arguments: [String], _ index: inout Int, for option: String) throws -> String {
    index += 1
    guard index < arguments.count else { throw HelperError.argument("\(option) requires a value.") }
    return arguments[index]
}

private func parsePages(_ value: String) throws -> [Int] {
    let pieces = value.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
    guard !pieces.isEmpty, pieces.allSatisfy({ $0 > 0 }) else {
        throw HelperError.argument("--pages requires a positive page or inclusive first-last range.")
    }
    if pieces.count == 1 { return [pieces[0]] }
    guard pieces[0] <= pieces[1] else { throw HelperError.argument("--pages range is reversed.") }
    return Array(pieces[0]...pieces[1])
}

private func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--input": options.input = try value(arguments, &index, for: "--input")
        case "--output": options.output = try value(arguments, &index, for: "--output")
        case "--runtime-root": options.runtimeRoot = try value(arguments, &index, for: "--runtime-root")
        case "--runtime-manifest": options.runtimeManifest = try value(arguments, &index, for: "--runtime-manifest")
        case "--target-language": options.targetLanguage = try value(arguments, &index, for: "--target-language")
        case "--openai-base-url": options.baseURL = try value(arguments, &index, for: "--openai-base-url")
        case "--openai-model": options.model = try value(arguments, &index, for: "--openai-model")
        case "--api-key-environment":
            options.apiKeyEnvironment = try value(arguments, &index, for: "--api-key-environment")
        case "--pages": options.pages = try parsePages(try value(arguments, &index, for: "--pages"))
        case "--qps":
            guard let parsed = Double(try value(arguments, &index, for: "--qps")), parsed > 0 else {
                throw HelperError.argument("--qps requires a positive number.")
            }
            options.qps = parsed
        case "--temperature":
            guard let parsed = Double(try value(arguments, &index, for: "--temperature")) else {
                throw HelperError.argument("--temperature requires a number.")
            }
            options.temperature = parsed
        case "--top-p": options.topP = Double(try value(arguments, &index, for: "--top-p"))
        case "--max-tokens": options.maxTokens = Int(try value(arguments, &index, for: "--max-tokens"))
        case "--thinking-mode":
            let raw = try value(arguments, &index, for: "--thinking-mode")
            guard let mode = BabelDocThinkingMode(rawValue: raw) else {
                throw HelperError.argument("--thinking-mode must be enabled or disabled.")
            }
            options.thinkingMode = mode
        case "--reasoning-effort":
            let raw = try value(arguments, &index, for: "--reasoning-effort")
            guard let effort = BabelDocReasoningEffort(rawValue: raw) else {
                throw HelperError.argument("--reasoning-effort must be low, high, or max.")
            }
            options.reasoningEffort = effort
        case "--system-prompt": options.systemPrompt = try value(arguments, &index, for: "--system-prompt")
        case "--document-title": options.documentTitle = try value(arguments, &index, for: "--document-title")
        case "--glossary": options.glossary = try value(arguments, &index, for: "--glossary")
        case "--semantic-hints":
            options.semanticHints = try value(arguments, &index, for: "--semantic-hints")
        case "--only-include-translated-pages": options.onlySelectedPages = true
        case "--cpu": options.preferCoreML = false
        case "--verify-runtime": options.verifyRuntime = true
        case "--version": print("babeldoc-readpaper-helper 1.0.0 protocol \(BabelDoc.helperProtocolVersion)"); exit(0)
        case "--help", "-h": usage(); exit(0)
        default: throw HelperError.argument("Unknown argument: \(arguments[index])")
        }
        index += 1
    }
    return options
}

@main
private enum ReadPaperBabelDocHelperMain {
    static func main() async {
        let emitter = EventEmitter()
        do {
            let options = try parse(Array(CommandLine.arguments.dropFirst()))
            guard let runtimeRoot = options.runtimeRoot, let runtimeManifest = options.runtimeManifest else {
                usage()
                throw HelperError.argument("Runtime root and trusted runtime manifest are required.")
            }
            guard let bundledManifest = BabelDocRuntimeVerifier.bundledManifestURL else {
                throw HelperError.argument("The helper's bundled runtime manifest is missing.")
            }
            let suppliedManifest = URL(fileURLWithPath: runtimeManifest)
            guard try Data(contentsOf: suppliedManifest) == Data(contentsOf: bundledManifest) else {
                throw HelperError.argument(
                    "The supplied runtime manifest does not match the helper's signed manifest."
                )
            }
            let runtime = try BabelDocRuntimeVerifier.verifyRuntime(
                at: URL(fileURLWithPath: runtimeRoot, isDirectory: true),
                trustedManifestURL: bundledManifest
            )
            if options.verifyRuntime {
                print("BabelDOC runtime \(runtime.manifestVersion) verified at \(runtime.root.path)")
                return
            }
            guard let input = options.input, let output = options.output,
                  let baseURLValue = options.baseURL, let baseURL = URL(string: baseURLValue),
                  let model = options.model else {
                usage()
                throw HelperError.argument("Input, output, base URL, and model are required.")
            }
            guard let apiKey = ProcessInfo.processInfo.environment[options.apiKeyEnvironment], !apiKey.isEmpty else {
                throw HelperError.argument(
                    "API key environment variable \(options.apiKeyEnvironment) is missing."
                )
            }
            let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
            let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            let semanticHints: BabelDocSemanticDocument?
            if let semanticHintsPath = options.semanticHints {
                semanticHints = try JSONDecoder().decode(
                    BabelDocSemanticDocument.self,
                    from: Data(contentsOf: URL(
                        fileURLWithPath: (semanticHintsPath as NSString).expandingTildeInPath
                    ))
                )
                try semanticHints?.validate()
            } else {
                semanticHints = nil
            }
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            emitter.summary()
            let result = try await BabelDoc.translate(
                request: .init(
                    inputPDF: inputURL,
                    outputPDF: outputURL,
                    pages: options.pages,
                    targetLanguage: options.targetLanguage,
                    preferCoreML: options.preferCoreML,
                    onlyIncludeTranslatedPages: options.onlySelectedPages,
                    documentTitle: options.documentTitle,
                    glossary: options.glossary,
                    semanticHints: semanticHints
                ),
                runtime: runtime,
                openAI: .init(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    model: model,
                    temperature: options.temperature,
                    topP: options.topP,
                    maxTokens: options.maxTokens,
                    thinkingMode: options.thinkingMode,
                    reasoningEffort: options.reasoningEffort,
                    requestsPerSecond: options.qps,
                    systemPrompt: options.systemPrompt
                ),
                onProgress: { emitter.progress($0) }
            )
            emitter.diagnostics(result)
        } catch is CancellationError {
            emitter.error("Translation cancelled.")
            exit(130)
        } catch {
            let message = error.localizedDescription
            emitter.error(message)
            FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
            exit(1)
        }
    }
}
