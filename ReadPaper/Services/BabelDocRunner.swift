import Foundation

struct BabelDocBridgeEvent: Decodable, Sendable, Equatable {
    var type: String
    var stage: String?
    var stageCurrent: Int?
    var stageTotal: Int?
    var stageProgress: Double?
    var overallProgress: Double?
    var partIndex: Int?
    var totalParts: Int?
    var error: String?
    var semanticStatus: String?
    var semanticPDFParagraphs: Int?
    var semanticMatchedPDFParagraphs: Int?
    var semanticMatchedPDFCoverage: Double?
    var semanticHighConfidence: Int?
    var semanticMediumConfidence: Int?
    var semanticLowConfidence: Int?
    var semanticStructuralChangesEnabled: Bool?
    var semanticElapsedMilliseconds: Double?
    var translationCandidates: Int?
    var translationCompleted: Int?
    var translationFailed: Int?
    var providerFailures: Int?
    var placeholderValidationFailures: Int?
    var semanticTranslationFallbacks: Int?
    var continuationGroups: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case stage
        case stageCurrent = "stage_current"
        case stageTotal = "stage_total"
        case stageProgress = "stage_progress"
        case overallProgress = "overall_progress"
        case partIndex = "part_index"
        case totalParts = "total_parts"
        case error
        case semanticStatus = "semantic_status"
        case semanticPDFParagraphs = "semantic_pdf_paragraphs"
        case semanticMatchedPDFParagraphs = "semantic_matched_pdf_paragraphs"
        case semanticMatchedPDFCoverage = "semantic_matched_pdf_coverage"
        case semanticHighConfidence = "semantic_high_confidence"
        case semanticMediumConfidence = "semantic_medium_confidence"
        case semanticLowConfidence = "semantic_low_confidence"
        case semanticStructuralChangesEnabled = "semantic_structural_changes_enabled"
        case semanticElapsedMilliseconds = "semantic_elapsed_ms"
        case translationCandidates = "translation_candidates"
        case translationCompleted = "translation_completed"
        case translationFailed = "translation_failed"
        case providerFailures = "provider_failures"
        case placeholderValidationFailures = "placeholder_validation_failures"
        case semanticTranslationFallbacks = "semantic_translation_fallbacks"
        case continuationGroups = "continuation_groups"
    }
}

struct BabelDocTranslationDiagnostics: Codable, Sendable, Equatable {
    var semanticStatus: String?
    var candidateCount: Int
    var translatedCount: Int
    var failedCount: Int
    var providerFailureCount: Int
    var placeholderValidationFailureCount: Int
    var semanticFallbackCount: Int
    var continuationGroupCount: Int

    /// A nonzero `failedCount` does not always mean that translation failed.
    /// BabelDoc also reports formula-dense paragraphs that it deliberately leaves
    /// untouched to protect their geometry as failed candidates. Those paragraphs
    /// have no provider or placeholder-validation failures.
    var hasActionableFailures: Bool {
        failedCount > 0
            && (providerFailureCount > 0 || placeholderValidationFailureCount > 0)
    }

    var safelyPreservedLayoutCount: Int {
        failedCount > 0 && !hasActionableFailures ? failedCount : 0
    }

    var isDegraded: Bool {
        hasActionableFailures
    }

    func merging(_ other: BabelDocTranslationDiagnostics) -> BabelDocTranslationDiagnostics {
        BabelDocTranslationDiagnostics(
            semanticStatus: other.semanticStatus ?? semanticStatus,
            candidateCount: candidateCount + other.candidateCount,
            translatedCount: translatedCount + other.translatedCount,
            failedCount: failedCount + other.failedCount,
            providerFailureCount: providerFailureCount + other.providerFailureCount,
            placeholderValidationFailureCount: placeholderValidationFailureCount + other.placeholderValidationFailureCount,
            semanticFallbackCount: semanticFallbackCount + other.semanticFallbackCount,
            continuationGroupCount: continuationGroupCount + other.continuationGroupCount
        )
    }
}

struct PDFTranslationDiagnosticsNoticeStore {
    static let userDefaultsKey = "ReadPaper.PDFTranslationDiagnosticsDismissals"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func noticeID(
        outputPDF: URL,
        diagnostics: BabelDocTranslationDiagnostics
    ) -> String {
        [
            outputPDF.standardizedFileURL.path,
            diagnostics.semanticStatus ?? "",
            String(diagnostics.candidateCount),
            String(diagnostics.translatedCount),
            String(diagnostics.failedCount),
            String(diagnostics.providerFailureCount),
            String(diagnostics.placeholderValidationFailureCount),
            String(diagnostics.semanticFallbackCount),
            String(diagnostics.continuationGroupCount)
        ].joined(separator: "|")
    }

    func isDismissed(paperID: UUID, noticeID: String) -> Bool {
        dismissedNoticeIDs()[paperID.uuidString] == noticeID
    }

    func dismiss(paperID: UUID, noticeID: String) {
        var noticeIDs = dismissedNoticeIDs()
        noticeIDs[paperID.uuidString] = noticeID
        userDefaults.set(noticeIDs, forKey: Self.userDefaultsKey)
    }

    private func dismissedNoticeIDs() -> [String: String] {
        userDefaults.dictionary(forKey: Self.userDefaultsKey) as? [String: String] ?? [:]
    }
}

struct BabelDocNativeTranslationResult: Sendable, Equatable {
    var outputPDF: URL
    var diagnostics: BabelDocTranslationDiagnostics?
    var diagnosticsLogURL: URL?
}

struct BabelDocOutputParseResult: Sendable {
    var progressUpdates: [BabelDocProgressUpdate] = []
    var statusMessages: [String] = []
    var diagnostics: BabelDocTranslationDiagnostics?

    mutating func append(_ other: BabelDocOutputParseResult) {
        progressUpdates.append(contentsOf: other.progressUpdates)
        statusMessages.append(contentsOf: other.statusMessages)
        if let diagnostics = other.diagnostics {
            self.diagnostics = diagnostics
        }
    }
}

final class BabelDocOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private let apiKey: String
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var lastDiagnostics: BabelDocTranslationDiagnostics?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func consume(_ event: ProcessOutputEvent) -> BabelDocOutputParseResult {
        let lines: [String]
        lock.lock()
        switch event.channel {
        case .standardOutput:
            stdoutBuffer += BabelDocRunner.redact(event.text, apiKey: apiKey)
            let extracted = Self.extractLines(from: stdoutBuffer)
            lines = extracted.lines
            stdoutBuffer = extracted.remainder
        case .standardError:
            stderrBuffer += BabelDocRunner.redact(event.text, apiKey: apiKey)
            let extracted = Self.extractLines(from: stderrBuffer)
            lines = extracted.lines
            stderrBuffer = extracted.remainder
        }
        lock.unlock()

        let result = Self.parseLines(lines, channel: event.channel)
        if let diagnostics = result.diagnostics {
            lock.lock()
            lastDiagnostics = diagnostics
            lock.unlock()
        }
        return result
    }

    func finish() -> BabelDocOutputParseResult {
        let stdoutRemainder: String
        let stderrRemainder: String

        lock.lock()
        stdoutRemainder = stdoutBuffer
        stderrRemainder = stderrBuffer
        stdoutBuffer = ""
        stderrBuffer = ""
        let retainedDiagnostics = lastDiagnostics
        lastDiagnostics = nil
        lock.unlock()

        var result = BabelDocOutputParseResult()
        if stdoutRemainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.append(Self.parseLines([stdoutRemainder], channel: .standardOutput))
        }
        if stderrRemainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.append(Self.parseLines([stderrRemainder], channel: .standardError))
        }
        if result.diagnostics == nil {
            result.diagnostics = retainedDiagnostics
        }
        return result
    }

    private static func extractLines(from buffer: String) -> (lines: [String], remainder: String) {
        let normalized = buffer
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.components(separatedBy: "\n")
        guard normalized.hasSuffix("\n") == false else {
            return (Array(parts.dropLast()), "")
        }
        return (Array(parts.dropLast()), parts.last ?? "")
    }

    private static func parseLines(_ lines: [String], channel: ProcessOutputChannel) -> BabelDocOutputParseResult {
        var result = BabelDocOutputParseResult()

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }

            if channel == .standardOutput, line.hasPrefix(BabelDocRunner.bridgeEventPrefix) {
                let payload = String(line.dropFirst(BabelDocRunner.bridgeEventPrefix.count))
                guard let bridgeEvent = BabelDocRunner.bridgeEvent(from: payload) else { continue }

                if let progress = BabelDocRunner.progressUpdate(from: bridgeEvent) {
                    result.progressUpdates.append(progress)
                }
                if let status = BabelDocRunner.structuredStatusMessage(from: bridgeEvent) {
                    result.statusMessages.append(status)
                }
                if let diagnostics = BabelDocRunner.translationDiagnostics(from: bridgeEvent) {
                    result.diagnostics = diagnostics
                }
                continue
            }

            if let status = BabelDocRunner.statusMessage(forLine: line, channel: channel) {
                result.statusMessages.append(status)
            }
        }

        return result
    }
}

struct BabelDocRunner {
    let processRunner: ProcessRunner

    static let bridgeEventPrefix = "__READPAPER_BABELDOC_EVENT__"

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func translatePDFNative(
        inputPDF: URL,
        outputDirectory: URL,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        tool: NativeBabelDocToolPaths,
        documentTitle: String? = nil,
        semanticHintsURL: URL? = nil,
        pageRange: ClosedRange<Int>? = nil,
        environment: [String: String] = [:],
        onStatusUpdate: (@Sendable (String) -> Void)? = nil,
        onProgressUpdate: (@Sendable (BabelDocProgressUpdate) -> Void)? = nil
    ) async throws -> BabelDocNativeTranslationResult {
        if !FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        let startedAt = Date()
        let outputPDF = outputDirectory.appendingPathComponent(
            "babeldoc-native-\(UUID().uuidString).pdf"
        )
        let arguments = Self.nativeArguments(
            inputPDF: inputPDF,
            outputPDF: outputPDF,
            preferences: preferences,
            route: route,
            tool: tool,
            documentTitle: documentTitle,
            semanticHintsURL: semanticHintsURL,
            pageRange: pageRange
        )
        let outputParser = BabelDocOutputParser(apiKey: apiKey)
        let result = try await processRunner.run(
            executableURL: tool.executable,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: outputDirectory,
            onOutput: { event in
                let parsed = outputParser.consume(event)
                parsed.progressUpdates.forEach { onProgressUpdate?($0) }
                parsed.statusMessages.forEach { onStatusUpdate?($0) }
            }
        )
        let finalParsed = outputParser.finish()
        finalParsed.progressUpdates.forEach { onProgressUpdate?($0) }
        finalParsed.statusMessages.forEach { onStatusUpdate?($0) }
        guard result.exitCode == 0 else {
            let output = Self.sanitizedOutput(result.combinedOutput, apiKey: apiKey)
            let message = output.isEmpty
                ? AppLocalization.format("BabelDOC exited with code %d.", result.exitCode)
                : output
            let logURL = try? Self.writeFailureLog(
                reason: message,
                result: result,
                inputPDF: inputPDF,
                outputDirectory: outputDirectory,
                babelDocPythonExecutable: tool.executable,
                bridgeScript: tool.runtimeManifest,
                arguments: arguments,
                apiKey: apiKey,
                startedAt: startedAt
            )
            if let logURL { throw BabelDocRunError.failedWithLog(message, logURL) }
            throw BabelDocRunError.failed(message)
        }
        guard FileManager.default.fileExists(atPath: outputPDF.path) else {
            throw BabelDocRunError.noTranslatedPDFProduced(nil)
        }
        try TranslatedPDFPageBoundsNormalizer.normalize(at: outputPDF)
        let diagnosticsLogURL: URL?
        if let diagnostics = finalParsed.diagnostics, diagnostics.isDegraded {
            diagnosticsLogURL = try Self.writeDiagnostics(diagnostics, for: outputPDF)
        } else {
            diagnosticsLogURL = nil
        }
        return BabelDocNativeTranslationResult(
            outputPDF: outputPDF,
            diagnostics: finalParsed.diagnostics,
            diagnosticsLogURL: diagnosticsLogURL
        )
    }

    static func nativeArguments(
        inputPDF: URL,
        outputPDF: URL,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot,
        tool: NativeBabelDocToolPaths,
        documentTitle: String? = nil,
        semanticHintsURL: URL? = nil,
        pageRange: ClosedRange<Int>? = nil
    ) -> [String] {
        var arguments = [
            "--input", inputPDF.path,
            "--output", outputPDF.path,
            "--runtime-root", tool.runtimeRoot.path,
            "--runtime-manifest", tool.runtimeManifest.path,
            "--openai-model", route.modelName,
            "--openai-base-url", route.baseURL,
            "--target-language", preferences.targetLanguage,
            "--qps", "\(preferences.babelDocQPS)",
            "--api-key-environment", "READPAPER_LLM_API_KEY",
            "--system-prompt", AcademicTranslationPrompt.systemPrompt(
                targetLanguage: preferences.targetLanguage
            ),
        ]
        if let documentTitle = documentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           documentTitle.isEmpty == false {
            arguments += ["--document-title", documentTitle]
        }
        if preferences.translationGlossary.isEmpty == false {
            arguments += ["--glossary", preferences.translationGlossary]
        }
        if let semanticHintsURL {
            arguments += ["--semantic-hints", semanticHintsURL.path]
        }
        if let temperature = route.temperature {
            arguments += ["--temperature", "\(temperature)"]
        }
        if let topP = route.topP { arguments += ["--top-p", "\(topP)"] }
        if let maxTokens = route.maxTokens { arguments += ["--max-tokens", "\(maxTokens)"] }
        if let thinkingMode = route.thinkingMode {
            arguments += ["--thinking-mode", thinkingMode.rawValue]
        }
        if let reasoningEffort = route.reasoningEffort {
            arguments += ["--reasoning-effort", reasoningEffort.rawValue]
        }
        if let pageRange {
            arguments += ["--pages", "\(pageRange.lowerBound)-\(pageRange.upperBound)"]
            arguments.append("--only-include-translated-pages")
        }
        return arguments
    }

    func translatePDF(
        inputPDF: URL,
        outputDirectory: URL,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        babelDocPythonExecutable: URL,
        bridgeScript: URL,
        pageRange: ClosedRange<Int>? = nil,
        environment: [String: String] = [:],
        onStatusUpdate: (@Sendable (String) -> Void)? = nil,
        onProgressUpdate: (@Sendable (BabelDocProgressUpdate) -> Void)? = nil
    ) async throws -> URL {
        if !FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        let startedAt = Date()
        let babelDocArguments = Self.arguments(
            inputPDF: inputPDF,
            outputDirectory: outputDirectory,
            preferences: preferences,
            route: route,
            apiKey: apiKey,
            pageRange: pageRange
        )
        let outputParser = BabelDocOutputParser(apiKey: apiKey)
        let result = try await processRunner.run(
            executableURL: babelDocPythonExecutable,
            arguments: [bridgeScript.path] + babelDocArguments,
            environment: environment.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new },
            currentDirectoryURL: outputDirectory,
            onOutput: { event in
                let parsed = outputParser.consume(event)
                for progress in parsed.progressUpdates {
                    onProgressUpdate?(progress)
                }
                for status in parsed.statusMessages {
                    onStatusUpdate?(status)
                }
            }
        )
        let finalParsed = outputParser.finish()
        for progress in finalParsed.progressUpdates {
            onProgressUpdate?(progress)
        }
        for status in finalParsed.statusMessages {
            onStatusUpdate?(status)
        }
        guard result.exitCode == 0 else {
            let output = Self.sanitizedOutput(result.combinedOutput, apiKey: apiKey)
            let message = output.isEmpty
                ? AppLocalization.format("BabelDOC exited with code %d.", result.exitCode)
                : output
            let logURL = try? Self.writeFailureLog(
                reason: message,
                result: result,
                inputPDF: inputPDF,
                outputDirectory: outputDirectory,
                babelDocPythonExecutable: babelDocPythonExecutable,
                bridgeScript: bridgeScript,
                arguments: [bridgeScript.path] + babelDocArguments,
                apiKey: apiKey,
                startedAt: startedAt
            )
            if let logURL {
                throw BabelDocRunError.failedWithLog(message, logURL)
            }
            throw BabelDocRunError.failed(message)
        }

        guard let translated = try newestPDF(in: outputDirectory, after: startedAt) else {
            let reason = AppLocalization.localized("BabelDOC finished without producing a translated PDF.")
            let logURL = try? Self.writeFailureLog(
                reason: reason,
                result: result,
                inputPDF: inputPDF,
                outputDirectory: outputDirectory,
                babelDocPythonExecutable: babelDocPythonExecutable,
                bridgeScript: bridgeScript,
                arguments: [bridgeScript.path] + babelDocArguments,
                apiKey: apiKey,
                startedAt: startedAt
            )
            throw BabelDocRunError.noTranslatedPDFProduced(logURL)
        }
        return translated
    }

    static func arguments(
        inputPDF: URL,
        outputDirectory: URL,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        pageRange: ClosedRange<Int>? = nil
    ) -> [String] {
        var args = [
            "--openai",
            "--openai-model", route.modelName,
            "--openai-base-url", route.baseURL,
            "--openai-api-key", apiKey,
            "--files", inputPDF.path,
            "--output", outputDirectory.path,
            "--lang-in", "en",
            "--lang-out", preferences.targetLanguage,
            "--qps", "\(preferences.babelDocQPS)",
            "--report-interval", "0.1",
            "--no-dual",
            "--watermark-output-mode", "no_watermark"
        ]
        if let range = pageRange {
            args += ["--pages", "\(range.lowerBound)-\(range.upperBound)"]
            args += ["--only-include-translated-page"]
        }
        return args
    }

    static func redactedArguments(
        inputPDF: URL,
        outputDirectory: URL,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot,
        pageRange: ClosedRange<Int>? = nil
    ) -> [String] {
        arguments(
            inputPDF: inputPDF,
            outputDirectory: outputDirectory,
            preferences: preferences,
            route: route,
            apiKey: "<redacted>",
            pageRange: pageRange
        )
    }

    static func redact(_ value: String, apiKey: String) -> String {
        guard !apiKey.isEmpty else { return value }
        return value.replacingOccurrences(of: apiKey, with: "<redacted>")
    }

    static func bridgeEvent(from payload: String) -> BabelDocBridgeEvent? {
        let data = Data(payload.utf8)
        return try? JSONDecoder().decode(BabelDocBridgeEvent.self, from: data)
    }

    static func progressUpdate(from event: BabelDocBridgeEvent) -> BabelDocProgressUpdate? {
        guard event.type == "progress_update" || event.type == "progress_end" else {
            return nil
        }
        guard let overallProgress = event.overallProgress else {
            return nil
        }

        let clampedProgress = min(max(overallProgress, 0), 100)
        return BabelDocProgressUpdate(
            completed: clampedProgress,
            total: 100,
            summary: "\(Int(clampedProgress.rounded()))%",
            statusMessage: stageStatusMessage(from: event, includeCounts: true) ?? AppLocalization.localized("Translating PDF with BabelDOC...")
        )
    }

    static func structuredStatusMessage(from event: BabelDocBridgeEvent) -> String? {
        switch event.type {
        case "stage_summary":
            return AppLocalization.localized("Preparing PDF translation...")
        case "progress_start":
            return stageStatusMessage(from: event, includeCounts: false)
        case "error":
            let message = event.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, message.isEmpty == false {
                return AppLocalization.format("BabelDOC error: %@", message.truncatedForStatus)
            }
            return AppLocalization.localized("BabelDOC error.")
        case "translation_diagnostics":
            if event.semanticStatus == "pdfFallback" {
                return AppLocalization.localized(
                    "LaTeX structure could not be applied; translation continued with PDF layout."
                )
            }
            if let matched = event.semanticMatchedPDFParagraphs,
               let total = event.semanticPDFParagraphs,
               let translated = event.translationCompleted,
               let candidates = event.translationCandidates {
                return AppLocalization.format(
                    "LaTeX structure matched %d/%d PDF paragraphs; translated %d/%d text blocks.",
                    matched,
                    total,
                    translated,
                    candidates
                )
            }
            if let translated = event.translationCompleted,
               let candidates = event.translationCandidates {
                let failed = event.translationFailed ?? max(candidates - translated, 0)
                let hasActionableFailures = failed > 0
                    && ((event.providerFailures ?? 0) > 0
                        || (event.placeholderValidationFailures ?? 0) > 0)
                if hasActionableFailures {
                    return AppLocalization.format(
                        "Translated %d/%d text blocks; %d failed and kept their original layout.",
                        translated,
                        candidates,
                        failed
                    )
                }
                if failed > 0 {
                    return AppLocalization.format(
                        "Translated text blocks: %d; formula-layout blocks safely preserved: %d.",
                        translated,
                        failed
                    )
                }
                return AppLocalization.format(
                    "Translated %d/%d text blocks.",
                    translated,
                    candidates
                )
            }
            return nil
        default:
            return nil
        }
    }

    static func translationDiagnostics(from event: BabelDocBridgeEvent) -> BabelDocTranslationDiagnostics? {
        guard event.type == "translation_diagnostics",
              let candidates = event.translationCandidates,
              let translated = event.translationCompleted else {
            return nil
        }
        return BabelDocTranslationDiagnostics(
            semanticStatus: event.semanticStatus,
            candidateCount: candidates,
            translatedCount: translated,
            failedCount: event.translationFailed ?? max(candidates - translated, 0),
            providerFailureCount: event.providerFailures ?? 0,
            placeholderValidationFailureCount: event.placeholderValidationFailures ?? 0,
            semanticFallbackCount: event.semanticTranslationFallbacks ?? 0,
            continuationGroupCount: event.continuationGroups ?? 0
        )
    }

    static func diagnosticsURL(for outputPDF: URL) -> URL {
        outputPDF.appendingPathExtension("diagnostics.json")
    }

    static func writeDiagnostics(
        _ diagnostics: BabelDocTranslationDiagnostics,
        for outputPDF: URL
    ) throws -> URL {
        let url = diagnosticsURL(for: outputPDF)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(diagnostics).write(to: url, options: .atomic)
        return url
    }

    static func readDiagnostics(for outputPDF: URL) throws -> BabelDocTranslationDiagnostics {
        let data = try Data(contentsOf: diagnosticsURL(for: outputPDF))
        return try JSONDecoder().decode(BabelDocTranslationDiagnostics.self, from: data)
    }

    static func statusMessage(from event: ProcessOutputEvent, apiKey: String) -> String? {
        let redacted = redact(event.text, apiKey: apiKey)
        guard let line = redacted
            .split(whereSeparator: \.isNewline)
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { !$0.isEmpty })
        else {
            return nil
        }

        return statusMessage(forLine: line, channel: event.channel)
    }

    static func statusMessage(forLine line: String, channel: ProcessOutputChannel) -> String? {
        if channel == .standardError {
            let isError = line.hasPrefix("ERROR:") || line.hasPrefix("CRITICAL:")
            if !isError {
                return nil
            }
            return AppLocalization.format("BabelDOC error: %@", line.truncatedForStatus)
        }
        return AppLocalization.format("BabelDOC: %@", line.truncatedForStatus)
    }

    static func stageStatusMessage(from event: BabelDocBridgeEvent, includeCounts: Bool) -> String? {
        guard let stage = event.stage, stage.isEmpty == false else {
            return nil
        }

        var message = humanReadableStageName(stage)
        if let totalParts = event.totalParts, totalParts > 1, let partIndex = event.partIndex {
            message += AppLocalization.format(" (part %d/%d)", partIndex, totalParts)
        }
        if includeCounts, let stageTotal = event.stageTotal, stageTotal > 0 {
            let stageCurrent = min(max(event.stageCurrent ?? 0, 0), stageTotal)
            message += AppLocalization.format(" %d/%d", stageCurrent, stageTotal)
        }
        return message
    }

    static func humanReadableStageName(_ stage: String) -> String {
        switch stage {
        case "DetectScannedFile":
            return AppLocalization.localized("Checking PDF content")
        case "ILCreater":
            return AppLocalization.localized("Preparing PDF structure")
        case "LayoutParser":
            return AppLocalization.localized("Analyzing layout")
        case "ParagraphFinder":
            return AppLocalization.localized("Grouping paragraphs")
        case "StylesAndFormulas":
            return AppLocalization.localized("Preserving styles and formulas")
        case "SemanticHintEnricher":
            return AppLocalization.localized("Applying LaTeX structure")
        case "ILTranslator":
            return AppLocalization.localized("Translating text blocks")
        case "Typesetting":
            return AppLocalization.localized("Applying translated layout")
        case "FontMapper":
            return AppLocalization.localized("Matching fonts")
        case "PDFCreater":
            return AppLocalization.localized("Generating translated PDF")
        default:
            return stage.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func sanitizedOutput(_ output: String, apiKey: String) -> String {
        let lines = redact(output, apiKey: apiKey)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.hasPrefix(bridgeEventPrefix) == false }

        return Array(lines.suffix(20)).joined(separator: "\n")
    }

    static func writeFailureLog(
        reason: String,
        result: ProcessResult,
        inputPDF: URL,
        outputDirectory: URL,
        babelDocPythonExecutable: URL,
        bridgeScript: URL,
        arguments: [String],
        apiKey: String,
        startedAt: Date,
        fileManager: FileManager = .default
    ) throws -> URL {
        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        let timestamp = Self.logTimestamp(for: Date())
        let logURL = outputDirectory.appendingPathComponent("babeldoc-error-\(timestamp)-\(UUID().uuidString.prefix(8)).log")
        let content = Self.failureLogContent(
            reason: reason,
            result: result,
            inputPDF: inputPDF,
            outputDirectory: outputDirectory,
            babelDocPythonExecutable: babelDocPythonExecutable,
            bridgeScript: bridgeScript,
            arguments: arguments,
            apiKey: apiKey,
            startedAt: startedAt,
            generatedAt: Date()
        )
        try content.write(to: logURL, atomically: true, encoding: .utf8)
        return logURL
    }

    static func failureLogContent(
        reason: String,
        result: ProcessResult,
        inputPDF: URL,
        outputDirectory: URL,
        babelDocPythonExecutable: URL,
        bridgeScript: URL,
        arguments: [String],
        apiKey: String,
        startedAt: Date,
        generatedAt: Date
    ) -> String {
        let redactedArguments = arguments.map { redact($0, apiKey: apiKey).singleLineForLog }
        let standardOutput = redact(result.standardOutput, apiKey: apiKey)
        let standardError = redact(result.standardError, apiKey: apiKey)
        let lines = [
            "ReadPaper BabelDOC failure log",
            "Generated at: \(Self.isoTimestamp(for: generatedAt))",
            "Started at: \(Self.isoTimestamp(for: startedAt))",
            "Reason: \(redact(reason, apiKey: apiKey).singleLineForLog)",
            "Exit code: \(result.exitCode)",
            "",
            "Input PDF: \(inputPDF.path.singleLineForLog)",
            "Output directory: \(outputDirectory.path.singleLineForLog)",
            "Tool executable: \(babelDocPythonExecutable.path.singleLineForLog)",
            "Support artifact: \(bridgeScript.path.singleLineForLog)",
            "",
            "Arguments:",
            redactedArguments.map { "  \($0)" }.joined(separator: "\n"),
            "",
            "Standard output:",
            standardOutput.isEmpty ? "(empty)" : standardOutput,
            "",
            "Standard error:",
            standardError.isEmpty ? "(empty)" : standardError
        ]
        return lines.joined(separator: "\n")
    }

    private static func isoTimestamp(for date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func logTimestamp(for date: Date) -> String {
        isoTimestamp(for: date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func newestPDF(in directory: URL, after start: Date) throws -> URL? {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .filter {
                let values = try $0.resourceValues(forKeys: [.contentModificationDateKey])
                return (values.contentModificationDate ?? .distantPast) >= start
            }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .first
    }
}

private extension String {
    var truncatedForStatus: String {
        guard count > 160 else { return self }
        let end = index(startIndex, offsetBy: 157)
        return "\(self[..<end])..."
    }
}

enum BabelDocRunError: Error, LocalizedError {
    case failed(String)
    case failedWithLog(String, URL)
    case noTranslatedPDFProduced(URL?)

    var logURL: URL? {
        switch self {
        case .failed:
            return nil
        case .failedWithLog(_, let url):
            return url
        case .noTranslatedPDFProduced(let url):
            return url
        }
    }

    var errorDescription: String? {
        switch self {
        case .failed(let output):
            AppLocalization.format("BabelDOC failed: %@", output)
        case .failedWithLog(let output, _):
            AppLocalization.format("BabelDOC failed: %@", output)
        case .noTranslatedPDFProduced:
            AppLocalization.localized("BabelDOC finished without producing a translated PDF.")
        }
    }
}

private extension String {
    var singleLineForLog: String {
        replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}
