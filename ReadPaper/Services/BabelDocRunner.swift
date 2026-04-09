import Foundation

struct BabelDocRunner {
    let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func translatePDF(
        inputPDF: URL,
        outputDirectory: URL,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        babelDocExecutable: URL,
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        if !FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        let startedAt = Date()
        let result = try await processRunner.run(
            executableURL: babelDocExecutable,
            arguments: Self.arguments(
                inputPDF: inputPDF,
                outputDirectory: outputDirectory,
                preferences: preferences,
                route: route,
                apiKey: apiKey
            ),
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
            currentDirectoryURL: outputDirectory,
            onOutput: { event in
                guard let status = Self.statusMessage(from: event, apiKey: apiKey) else { return }
                onStatusUpdate?(status)
            }
        )
        guard result.exitCode == 0 else {
            throw BabelDocRunError.failed(Self.redact(result.combinedOutput, apiKey: apiKey))
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
        apiKey: String
    ) -> [String] {
        [
            "--openai",
            "--openai-model", route.modelName,
            "--openai-base-url", route.baseURL,
            "--openai-api-key", apiKey,
            "--files", inputPDF.path,
            "--output", outputDirectory.path,
            "--lang-in", "en",
            "--lang-out", preferences.targetLanguage,
            "--qps", "\(preferences.babelDocQPS)",
            "--no-dual",
            "--watermark-output-mode", "no_watermark"
        ]
    }

    static func redactedArguments(
        inputPDF: URL,
        outputDirectory: URL,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot
    ) -> [String] {
        arguments(
            inputPDF: inputPDF,
            outputDirectory: outputDirectory,
            preferences: preferences,
            route: route,
            apiKey: "<redacted>"
        )
    }

    static func redact(_ value: String, apiKey: String) -> String {
        guard !apiKey.isEmpty else { return value }
        return value.replacingOccurrences(of: apiKey, with: "<redacted>")
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

        let prefix = event.channel == .standardError ? "BabelDOC error" : "BabelDOC"
        return "\(prefix): \(line.truncatedForStatus)"
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
            "BabelDOC failed: \(output)"
        }
    }
}
