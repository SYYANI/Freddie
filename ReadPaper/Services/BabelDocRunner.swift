import Foundation

struct BabelDocRunner {
    let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func translatePDF(
        inputPDF: URL,
        outputDirectory: URL,
        settings: AppSettingsSnapshot,
        apiKey: String,
        babelDocExecutable: URL
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
                settings: settings,
                apiKey: apiKey
            ),
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
            currentDirectoryURL: outputDirectory
        )
        guard result.exitCode == 0 else {
            throw BabelDocRunError.failed(Self.redact(result.combinedOutput, apiKey: apiKey))
        }

        guard let translated = try newestPDF(in: outputDirectory, after: startedAt) else {
            throw PaperImportError.noTranslatedPDFProduced
        }
        return translated
    }

    static func arguments(inputPDF: URL, outputDirectory: URL, settings: AppSettingsSnapshot, apiKey: String) -> [String] {
        [
            "--openai",
            "--openai-model", settings.heavyModelName,
            "--openai-base-url", settings.openAIBaseURL,
            "--openai-api-key", apiKey,
            "--files", inputPDF.path,
            "--output", outputDirectory.path,
            "--lang-in", "en",
            "--lang-out", settings.targetLanguage,
            "--qps", "\(settings.babelDocQPS)",
            "--no-dual",
            "--watermark-output-mode", "no_watermark"
        ]
    }

    static func redactedArguments(inputPDF: URL, outputDirectory: URL, settings: AppSettingsSnapshot) -> [String] {
        arguments(inputPDF: inputPDF, outputDirectory: outputDirectory, settings: settings, apiKey: "<redacted>")
    }

    static func redact(_ value: String, apiKey: String) -> String {
        guard !apiKey.isEmpty else { return value }
        return value.replacingOccurrences(of: apiKey, with: "<redacted>")
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

enum BabelDocRunError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let output):
            "BabelDOC failed: \(output)"
        }
    }
}
