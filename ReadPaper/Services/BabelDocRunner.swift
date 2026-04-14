import Foundation

struct BabelDocProgressUpdate: Sendable, Equatable {
    var completed: Double
    var total: Double
    var summary: String
    var statusMessage: String
}

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
    }
}

struct BabelDocOutputParseResult: Sendable {
    var progressUpdates: [BabelDocProgressUpdate] = []
    var statusMessages: [String] = []

    mutating func append(_ other: BabelDocOutputParseResult) {
        progressUpdates.append(contentsOf: other.progressUpdates)
        statusMessages.append(contentsOf: other.statusMessages)
    }
}

final class BabelDocOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private let apiKey: String
    private var stdoutBuffer = ""
    private var stderrBuffer = ""

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

        return Self.parseLines(lines, channel: event.channel)
    }

    func finish() -> BabelDocOutputParseResult {
        let stdoutRemainder: String
        let stderrRemainder: String

        lock.lock()
        stdoutRemainder = stdoutBuffer
        stderrRemainder = stderrBuffer
        stdoutBuffer = ""
        stderrBuffer = ""
        lock.unlock()

        var result = BabelDocOutputParseResult()
        if stdoutRemainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.append(Self.parseLines([stdoutRemainder], channel: .standardOutput))
        }
        if stderrRemainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.append(Self.parseLines([stderrRemainder], channel: .standardError))
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
        let outputParser = BabelDocOutputParser(apiKey: apiKey)
        let result = try await processRunner.run(
            executableURL: babelDocPythonExecutable,
            arguments: [bridgeScript.path] + Self.arguments(
                inputPDF: inputPDF,
                outputDirectory: outputDirectory,
                preferences: preferences,
                route: route,
                apiKey: apiKey,
                pageRange: pageRange
            ),
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
            throw BabelDocRunError.failed(
                output.isEmpty
                    ? AppLocalization.format("BabelDOC exited with code %d.", result.exitCode)
                    : output
            )
        }

        guard let translated = try newestPDF(in: outputDirectory, after: startedAt) else {
            throw PaperImportError.noTranslatedPDFProduced
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
        default:
            return nil
        }
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

    var errorDescription: String? {
        switch self {
        case .failed(let output):
            AppLocalization.format("BabelDOC failed: %@", output)
        }
    }
}
