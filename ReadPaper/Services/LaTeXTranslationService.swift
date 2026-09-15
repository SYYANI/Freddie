import Foundation
import LaTeXTransKit

protocol ReadPaperLLMCompleting: Sendable {
    func complete(request: LLMCompletionRequest) async throws -> LLMCompletionResponse
}

extension OpenAICompatibleLLMProvider: ReadPaperLLMCompleting {}

struct ReadPaperLaTeXPromptClient: LaTeXPromptCompleting {
    static let promptVersion = "latextranskit-v1"

    private let route: LLMModelRouteSnapshot
    private let apiKey: String
    private let provider: any ReadPaperLLMCompleting

    init(
        route: LLMModelRouteSnapshot,
        apiKey: String,
        provider: any ReadPaperLLMCompleting = OpenAICompatibleLLMProvider()
    ) {
        self.route = route
        self.apiKey = apiKey
        self.provider = provider
    }

    func complete(_ request: LaTeXPromptRequest) async throws -> String {
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
            messages: request.messages.map { message in
                LLMCompletionMessage(role: message.role.rawValue, content: message.content)
            },
            temperature: route.temperature ?? request.temperature,
            topP: route.topP,
            maxTokens: route.maxTokens ?? request.maximumOutputTokens,
            thinkingMode: route.thinkingMode,
            reasoningEffort: route.reasoningEffort,
            timeoutProfile: .translationDefault
        ))
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw LLMProviderError.emptyResponse
        }
        return text
    }
}

struct ReadPaperLaTeXTranslationRequest: Sendable {
    var paperID: UUID
    var arxivIdentifier: String
    var targetLanguage: String
    var maximumConcurrency: Int
    var glossary: String
    var documentSummary: String?
    var route: LLMModelRouteSnapshot
    var apiKey: String

    init(
        paperID: UUID,
        arxivIdentifier: String,
        targetLanguage: String,
        maximumConcurrency: Int,
        glossary: String,
        documentSummary: String?,
        route: LLMModelRouteSnapshot,
        apiKey: String
    ) {
        self.paperID = paperID
        self.arxivIdentifier = arxivIdentifier
        self.targetLanguage = targetLanguage
        self.maximumConcurrency = max(1, maximumConcurrency)
        self.glossary = TranslationGlossaryPreference.normalized(glossary)
        self.documentSummary = documentSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.route = route
        self.apiKey = apiKey
    }
}

struct ReadPaperLaTeXTranslationOutput: Sendable {
    var artifact: TranslationArtifact
    var pdfCompilationFailed: Bool
    var failedCompilationAttempts: [CompilationAttempt]
}

enum ReadPaperLaTeXToolchainError: Error {
    case latexmkNotFound
}

enum LaTeXIntegrationPreferences {
    static let translationEnabledKey = "ReadPaper.LaTeX.TranslationEnabled"
    static let toolchainDirectoryKey = "ReadPaper.LaTeX.ToolchainDirectory"

    static func selectedToolchainDirectory(
        userDefaults: UserDefaults = .standard
    ) -> URL? {
        guard let path = userDefaults.string(forKey: toolchainDirectoryKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

struct ReadPaperLaTeXInstallation: Equatable, Identifiable, Sendable {
    struct Executable: Equatable, Identifiable, Sendable {
        let name: String
        let isAvailable: Bool

        var id: String { name }
    }

    let directoryURL: URL
    let executables: [Executable]

    var id: String { directoryURL.path }

    var hasLatexmk: Bool {
        executables.first(where: { $0.name == "latexmk" })?.isAvailable == true
    }

    var hasPDFEngine: Bool {
        ["xelatex", "pdflatex", "lualatex"].contains { name in
            executables.first(where: { $0.name == name })?.isAvailable == true
        }
    }

    var isHealthy: Bool {
        hasLatexmk && hasPDFEngine
    }
}

struct ReadPaperLaTeXToolchain: Equatable, Sendable {
    let latexmkURL: URL

    static let inspectedExecutableNames = [
        "latexmk",
        "latex",
        "pdflatex",
        "xelatex",
        "lualatex",
        "bibtex",
        "biber",
        "makeindex",
    ]

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalSearchDirectories: [URL] = [],
        fileManager: FileManager = .default
    ) -> ReadPaperLaTeXToolchain? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let conventionalDirectories = [
            URL(fileURLWithPath: "/Library/TeX/texbin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
        var visited: Set<String> = []
        for directory in additionalSearchDirectories + pathDirectories + conventionalDirectories {
            let candidate = directory
                .appendingPathComponent("latexmk", isDirectory: false)
                .standardizedFileURL
            guard visited.insert(candidate.path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return ReadPaperLaTeXToolchain(latexmkURL: candidate)
            }
        }
        return nil
    }

    static func detectConfigured(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ReadPaperLaTeXToolchain? {
        if let directory = LaTeXIntegrationPreferences.selectedToolchainDirectory(
            userDefaults: userDefaults
        ) {
            let latexmkURL = directory
                .appendingPathComponent("latexmk", isDirectory: false)
                .standardizedFileURL
            guard fileManager.isExecutableFile(atPath: latexmkURL.path) else {
                return nil
            }
            return ReadPaperLaTeXToolchain(latexmkURL: latexmkURL)
        }
        return detect(environment: environment, fileManager: fileManager)
    }

    static func installations(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalSearchDirectories: [URL] = [],
        fileManager: FileManager = .default
    ) -> [ReadPaperLaTeXInstallation] {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let conventionalDirectories = [
            URL(fileURLWithPath: "/Library/TeX/texbin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
        var visited: Set<String> = []
        return (additionalSearchDirectories + pathDirectories + conventionalDirectories)
            .compactMap { directory -> ReadPaperLaTeXInstallation? in
                let normalized = directory.standardizedFileURL
                guard visited.insert(normalized.path).inserted else { return nil }
                let installation = installation(at: normalized, fileManager: fileManager)
                guard installation.executables.contains(where: \.isAvailable) else {
                    return nil
                }
                return installation
            }
            .sorted { $0.directoryURL.path.localizedStandardCompare($1.directoryURL.path) == .orderedAscending }
    }

    static func installation(
        at directoryURL: URL,
        fileManager: FileManager = .default
    ) -> ReadPaperLaTeXInstallation {
        let normalized = directoryURL.standardizedFileURL
        return ReadPaperLaTeXInstallation(
            directoryURL: normalized,
            executables: inspectedExecutableNames.map { name in
                let executableURL = normalized.appendingPathComponent(name, isDirectory: false)
                return ReadPaperLaTeXInstallation.Executable(
                    name: name,
                    isAvailable: fileManager.isExecutableFile(atPath: executableURL.path)
                )
            }
        )
    }
}

struct ReadPaperResolvedLaTeXProcessRunner: LaTeXProcessRunning {
    private let toolchain: ReadPaperLaTeXToolchain
    private let runner: any LaTeXProcessRunning

    init(
        toolchain: ReadPaperLaTeXToolchain,
        runner: any LaTeXProcessRunning = FoundationLaTeXProcessRunner()
    ) {
        self.toolchain = toolchain
        self.runner = runner
    }

    func run(_ request: LaTeXProcessRequest) async throws -> LaTeXProcessResult {
        let arguments = request.arguments.first == "latexmk"
            ? Array(request.arguments.dropFirst())
            : request.arguments
        var environment = request.environment ?? ProcessInfo.processInfo.environment
        let executableDirectory = toolchain.latexmkURL.deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = existingPath.isEmpty
            ? executableDirectory
            : executableDirectory + ":" + existingPath
        return try await runner.run(LaTeXProcessRequest(
            executableURL: toolchain.latexmkURL,
            arguments: arguments,
            workingDirectory: request.workingDirectory,
            environment: environment,
            standardOutputURL: request.standardOutputURL,
            standardErrorURL: request.standardErrorURL
        ))
    }
}

enum ReadPaperLaTeXCompilationDiagnostics {
    static func preferredLogURL(
        from attempts: [CompilationAttempt],
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = attempts.reversed().flatMap { attempt in
            attempt.logURLs.sorted { logPriority($0) < logPriority($1) }
        }
        return candidates.first {
            guard fileManager.fileExists(atPath: $0.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: $0.path),
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.int64Value > 0
        } ?? candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    static func indicatesMissingLatexmk(_ attempts: [CompilationAttempt]) -> Bool {
        attempts
            .flatMap(\.logURLs)
            .contains { url in
                guard let data = try? Data(contentsOf: url), data.count <= 64 * 1_024,
                      let contents = String(data: data, encoding: .utf8) else {
                    return false
                }
                return contents.localizedCaseInsensitiveContains("latexmk: No such file or directory")
                    || contents.localizedCaseInsensitiveContains("latexmk: command not found")
            }
    }

    static func indicatesFrozenMintedCacheFailure(_ attempts: [CompilationAttempt]) -> Bool {
        attempts
            .flatMap(\.logURLs)
            .contains { url in
                guard let data = try? Data(contentsOf: url), data.count <= 2 * 1_024 * 1_024,
                      let contents = String(data: data, encoding: .utf8) else {
                    return false
                }
                return contents.range(
                    of: #"Cannot\s+highlight\s+code\s*\(\s*frozencache\s*=\s*true\s*\)"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
    }

    static func failureStatusMessage(for attempts: [CompilationAttempt], bundle: Bundle) -> String {
        if indicatesMissingLatexmk(attempts) {
            return AppLocalization.localized(
                "LaTeX source translation completed, but PDF compilation requires a TeX distribution that includes latexmk.",
                bundle: bundle
            )
        }
        return AppLocalization.localized(
            "LaTeX source translation completed, but PDF compilation failed.",
            bundle: bundle
        )
    }

    private static func logPriority(_ url: URL) -> Int {
        switch url.lastPathComponent.lowercased() {
        case "stderr.log":
            return 0
        case "stdout.log":
            return 2
        default:
            return url.pathExtension.lowercased() == "log" ? 1 : 3
        }
    }
}

enum ReadPaperArXivIdentifier {
    static func resolving(id: String, version: String?) -> String {
        let identifier = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.range(of: #"v\d+$"#, options: .regularExpression) == nil,
              let rawVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVersion.isEmpty else {
            return identifier
        }
        if rawVersion.range(of: #"^v\d+$"#, options: .regularExpression) != nil {
            return identifier + rawVersion
        }
        if rawVersion.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            return identifier + "v" + rawVersion
        }
        return identifier
    }
}

enum ReadPaperLaTeXErrorPresentation {
    static func message(for error: Error, bundle: Bundle) -> String {
        let description: String
        switch error {
        case is ProjectPreparationError,
             is TarGzipArchiveReaderError,
             is ZipArchiveReaderError:
            description = AppLocalization.localized(
                "Could not prepare the arXiv LaTeX source.",
                bundle: bundle
            )
        case is LaTeXParserError:
            description = AppLocalization.localized(
                "Could not parse the LaTeX source.",
                bundle: bundle
            )
        case is TranslationRuntimeError:
            description = AppLocalization.localized(
                "The model returned an invalid LaTeX translation.",
                bundle: bundle
            )
        case is ReconstructionError:
            description = AppLocalization.localized(
                "Could not reconstruct the translated LaTeX source.",
                bundle: bundle
            )
        case is ReadPaperLaTeXToolchainError:
            description = AppLocalization.localized(
                "PDF compilation requires a TeX distribution that includes latexmk.",
                bundle: bundle
            )
        case let pipelineError as TranslationPipelineError:
            switch pipelineError {
            case let .validationFailed(issues):
                let affectedUnits = Dictionary(grouping: issues.filter { $0.severity == .error }, by: \.unitID)
                    .map { unitID, unitIssues in
                        let codes = Set(unitIssues.map(\.code)).sorted().joined(separator: ", ")
                        return codes.isEmpty ? unitID : "\(unitID) [\(codes)]"
                    }
                    .sorted()
                if affectedUnits.isEmpty {
                    description = AppLocalization.localized(
                        "The LaTeX translation failed structural validation.",
                        bundle: bundle
                    )
                } else {
                    description = AppLocalization.format(
                        "The LaTeX translation failed structural validation: %@",
                        bundle: bundle,
                        affectedUnits.joined(separator: "; ")
                    )
                }
            case .invalidTranslationResponse:
                description = AppLocalization.localized(
                    "The model returned an invalid LaTeX translation.",
                    bundle: bundle
                )
            case .missingCompiler:
                description = AppLocalization.localized(
                    "Could not compile the translated LaTeX source.",
                    bundle: bundle
                )
            case .unsupportedSource, .invalidProject:
                description = AppLocalization.localized(
                    "Could not prepare the arXiv LaTeX source.",
                    bundle: bundle
                )
            }
        default:
            return AppLocalization.errorMessage(error, bundle: bundle)
        }
        return AppLocalization.format("Error: %@", bundle: bundle, description)
    }
}

struct ReadPaperLaTeXProgressUpdate: Equatable, Sendable {
    var stage: PipelineStage
    var completedUnits: Int?
    var totalUnits: Int?
    var fractionCompleted: Double

    func statusMessage(bundle: Bundle) -> String {
        switch stage {
        case .preparing:
            return String(localized: "Preparing arXiv LaTeX source...", bundle: bundle)
        case .parsing:
            return String(localized: "Parsing LaTeX source...", bundle: bundle)
        case .translating:
            return String(localized: "Translating LaTeX source...", bundle: bundle)
        case .validating:
            return String(localized: "Validating LaTeX translation...", bundle: bundle)
        case .reconstructing:
            return String(localized: "Reconstructing translated LaTeX...", bundle: bundle)
        case .compiling:
            return String(localized: "Compiling translated LaTeX...", bundle: bundle)
        case .finished:
            return String(localized: "LaTeX translation completed.", bundle: bundle)
        }
    }
}

enum ReadPaperLaTeXProgressMapper {
    static func update(for event: PipelineEvent) -> ReadPaperLaTeXProgressUpdate {
        let unitFraction: Double = {
            guard let completed = event.completedUnitCount,
                  let total = event.totalUnitCount,
                  total > 0 else {
                return 0
            }
            return min(max(Double(completed) / Double(total), 0), 1)
        }()
        let fraction: Double
        switch event.stage {
        case .preparing:
            fraction = 0.03
        case .parsing:
            fraction = 0.10
        case .translating:
            fraction = 0.15 + (0.55 * unitFraction)
        case .validating:
            fraction = 0.74
        case .reconstructing:
            fraction = 0.82
        case .compiling:
            fraction = 0.92
        case .finished:
            fraction = 1
        }
        return ReadPaperLaTeXProgressUpdate(
            stage: event.stage,
            completedUnits: event.completedUnitCount,
            totalUnits: event.totalUnitCount,
            fractionCompleted: fraction
        )
    }
}

actor ReadPaperArXivProjectAcquirer: ArXivProjectAcquiring {
    static let maximumArchiveByteCount: Int64 = 512 * 1_024 * 1_024
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func acquireProject(
        identifier: String,
        workspaceDirectory: URL
    ) async throws -> TranslationProjectSource {
        let normalized = try ArxivClient.normalizeIdentifier(identifier)
        let downloads = workspaceDirectory.appendingPathComponent("downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let filename = normalized.queryID.replacingOccurrences(of: "/", with: "_") + ".tar"
        let destination = downloads.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            if try isPlausibleSourceArchive(destination) {
                return .localArchive(destination)
            }
            try fileManager.removeItem(at: destination)
        }

        guard let sourceURL = URL(string: "https://export.arxiv.org/e-print/\(normalized.queryID)") else {
            throw PaperImportError.invalidArxivIdentifier(identifier)
        }
        let request = BrowserRequestHeaders.request(for: sourceURL, accept: .resource)
        let (temporaryURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PaperImportError.arxivHTTPError(statusCode: http.statusCode)
        }
        if response.expectedContentLength > Self.maximumArchiveByteCount {
            throw ReadPaperArXivSourceError.archiveTooLarge(
                maximumBytes: Self.maximumArchiveByteCount
            )
        }
        if let mimeType = response.mimeType?.lowercased(),
           mimeType == "text/html" || mimeType == "application/xhtml+xml" {
            throw ReadPaperArXivSourceError.invalidArchiveResponse
        }
        try Task.checkCancellation()
        guard try isPlausibleSourceArchive(temporaryURL) else {
            throw ReadPaperArXivSourceError.invalidArchiveResponse
        }
        let partial = downloads.appendingPathComponent(
            ".\(filename).\(UUID().uuidString).partial"
        )
        do {
            try fileManager.copyItem(at: temporaryURL, to: partial)
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        return .localArchive(destination)
    }

    private func isPlausibleSourceArchive(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              Int64(size) <= Self.maximumArchiveByteCount else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        guard !prefix.isEmpty else { return false }
        let text = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !text.hasPrefix("<!doctype html") && !text.hasPrefix("<html")
    }
}

enum ReadPaperArXivSourceError: Error, LocalizedError, Equatable {
    case invalidArchiveResponse
    case archiveTooLarge(maximumBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidArchiveResponse:
            AppLocalization.localized("The arXiv source response is not a valid archive.")
        case let .archiveTooLarge(maximumBytes):
            AppLocalization.format(
                "The arXiv source archive exceeds the %lld-byte safety limit.",
                maximumBytes
            )
        }
    }
}

actor FileLaTeXTranslationCheckpointStore: TranslationCheckpointStoring {
    private let fileURL: URL
    private var translations: [String: String]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            translations = decoded
        } else {
            translations = [:]
        }
    }

    func translation(unitID: String, fingerprint: String) -> String? {
        translations[key(unitID: unitID, fingerprint: fingerprint)]
    }

    func saveTranslation(_ translation: String, unitID: String, fingerprint: String) throws {
        translations[key(unitID: unitID, fingerprint: fingerprint)] = translation
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(translations)
        try data.write(to: fileURL, options: .atomic)
    }

    private func key(unitID: String, fingerprint: String) -> String {
        unitID + "\u{1F}" + fingerprint
    }
}

enum ReadPaperLaTeXTerminology {
    static func entries(from glossary: String) -> [TerminologyEntry] {
        TranslationGlossaryPreference.normalized(glossary)
            .split(separator: "\n")
            .compactMap { line in
                let text = String(line)
                for separator in ["=>", "→", "=", "\t"] {
                    let parts = text.components(separatedBy: separator)
                    guard parts.count == 2 else { continue }
                    let source = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let target = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !source.isEmpty, !target.isEmpty {
                        return TerminologyEntry(source: source, target: target)
                    }
                }
                return nil
            }
    }
}

struct ReadPaperLaTeXEngineCompatibilityPreamblePolicy: LaTeXPreambleTransforming {
    private let base: any LaTeXPreambleTransforming

    init(base: any LaTeXPreambleTransforming = ReferenceLanguagePreamblePolicy()) {
        self.base = base
    }

    func transform(_ source: String, targetLanguage: TranslationLanguage) throws -> String {
        let transformed = try base.transform(source, targetLanguage: targetLanguage)
        return Self.normalizeEngineSpecificSource(transformed)
    }

    static func normalizeEngineSpecificSource(_ source: String) -> String {
        var result = source
        // Repair translated projects produced by the short-lived buggy rewrite that
        // emitted a literal "n" where the command separator should have been.
        result = replacingLines(
            matching: #"(?m)^([ \t]*)\\providecommand\{\\chinese\}\{\}n\\renewcommand\{\\chinese\}([^\r\n]*)$"#,
            with: #"$1\\providecommand{\\chinese}{}"#
                + "\n"
                + #"$1\\renewcommand{\\chinese}$2"#,
            in: result
        )
        // ctex owns \chinese as a numeral command. Legacy projects sometimes use the
        // same name as a CJK text wrapper, so make their definition safe to override.
        result = replacingLines(
            matching: #"(?m)^([ \t]*)\\newcommand[ \t]*(?:\{[ \t]*\\chinese[ \t]*\}|\\chinese)([^\r\n]*)$"#,
            with: #"$1\\providecommand{\\chinese}{}"#
                + "\n"
                + #"$1\\renewcommand{\\chinese}$2"#,
            in: result
        )
        result = replacingLines(
            matching: #"(?m)^([ \t]*)\\(pdfoutput|pdfsuppresswarningpagegroup|pdfminorversion|pdfcompresslevel|pdfobjcompresslevel|pdfinclusioncopyfonts|pdfgentounicode)[ \t]*=[ \t]*([+-]?\d+)([ \t]*(?:%[^\r\n]*)?)$"#,
            with: #"$1\\ifdefined\\$2\\$2=$3\\fi$4"#,
            in: result
        )
        result = replacingLines(
            matching: #"(?m)^([ \t]*)(\\(pdfmapline|pdfmapfile|pdfglyphtounicode)[^%\r\n]*)([ \t]*(?:%[^\r\n]*)?)$"#,
            with: #"$1\\ifdefined\\$3$2\\fi$4"#,
            in: result
        )
        result = replacingLines(
            matching: #"(?m)^([ \t]*)(\\DisableLigatures[^%\r\n]*)([ \t]*(?:%[^\r\n]*)?)$"#,
            with: #"$1\\ifdefined\\pdftexversion$2\\fi$3"#,
            in: result
        )
        return replacingLines(
            matching: #"(?m)^([ \t]*)(\\(?:usepackage|RequirePackage))[ \t]*(?:\[[^\]]*\])?[ \t]*\{inputenc\}([ \t]*(?:%[^\r\n]*)?)$"#,
            with: #"$1\\ifdefined\\pdftexversion$2[utf8]{inputenc}\\fi$3"#,
            in: result
        )
    }

    private static func replacingLines(
        matching pattern: String,
        with replacement: String,
        in source: String
    ) -> String {
        source.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
    }
}

enum ReadPaperLaTeXProjectCompatibilityNormalizer {
    private static let sourceExtensions: Set<String> = [
        "tex", "cls", "sty", "ltx", "def", "cfg",
    ]

    static func normalizeProject(
        at projectDirectory: URL,
        literalPercentMarker: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: projectDirectory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard sourceExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            var normalized = ReadPaperLaTeXEngineCompatibilityPreamblePolicy
                .normalizeEngineSpecificSource(source)
            if let literalPercentMarker {
                normalized = normalized.replacingOccurrences(
                    of: literalPercentMarker,
                    with: "%"
                )
            }
            if normalized != source {
                try normalized.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    @discardableResult
    static func enableDraftModeForFrozenMintedCaches(
        at projectDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: projectDirectory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var changed = false
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard sourceExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let normalized = replacingFrozenMintedCacheOption(in: source)
            guard normalized != source else { continue }
            try normalized.write(to: fileURL, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed
    }

    private static func replacingFrozenMintedCacheOption(in source: String) -> String {
        let pattern = #"(?m)(\\(?:usepackage|RequirePackage)\s*\[)([^\]\r\n]*)(\]\s*\{minted\})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        let matches = expression.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range, in: result),
                  let optionsRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            let options = result[optionsRange]
                .split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            guard options.contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("frozencache") == .orderedSame
            }) else {
                continue
            }
            let replacementOptions = options.map { option in
                if option.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("frozencache") == .orderedSame {
                    return "draft"
                }
                return option
            }.joined(separator: ",")
            let whole = String(result[wholeRange])
            let originalOptions = String(result[optionsRange])
            result.replaceSubrange(
                wholeRange,
                with: whole.replacingOccurrences(of: originalOptions, with: replacementOptions)
            )
        }
        return result
    }
}

/// `StructuredLaTeXParser` removes TeX comments before it discovers protected
/// environments. A literal percent sign inside `minted`, `lstlisting`, or
/// `verbatim` is data rather than a TeX comment, so protect it while parsing and
/// restore it in the reconstructed project before compilation.
struct ReadPaperLiteralPercentPreservingLaTeXParser: LaTeXProjectParsing {
    private static let sourceExtensions: Set<String> = [
        "tex", "cls", "sty", "ltx", "def", "cfg",
    ]
    private static let verbatimEnvironmentPattern =
        #"(?s)\\begin\s*\{(minted\*?|lstlisting\*?|verbatim\*?)\}.*?\\end\s*\{\1\}"#

    private let marker: String
    private let base: any LaTeXProjectParsing

    init(
        marker: String,
        base: any LaTeXProjectParsing = StructuredLaTeXParser()
    ) {
        self.marker = marker
        self.base = base
    }

    func parse(_ project: PreparedProject) async throws -> ParsedLaTeXProject {
        let snapshots = try protectLiteralPercents(in: project.sourceDirectory)
        do {
            let parsed = try await base.parse(project)
            try restore(snapshots)
            return parsed
        } catch {
            try? restore(snapshots)
            throw error
        }
    }

    private func protectLiteralPercents(in projectDirectory: URL) throws -> [SourceSnapshot] {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: projectDirectory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var snapshots: [SourceSnapshot] = []
        do {
            for case let fileURL as URL in enumerator {
                try Task.checkCancellation()
                guard Self.sourceExtensions.contains(fileURL.pathExtension.lowercased()) else {
                    continue
                }
                let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    continue
                }
                guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    continue
                }
                let protected = Self.protectingLiteralPercents(in: source, marker: marker)
                guard protected != source else { continue }
                snapshots.append(SourceSnapshot(fileURL: fileURL, source: source))
                try protected.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            return snapshots
        } catch {
            try? restore(snapshots)
            throw error
        }
    }

    private func restore(_ snapshots: [SourceSnapshot]) throws {
        for snapshot in snapshots {
            try snapshot.source.write(
                to: snapshot.fileURL,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private static func protectingLiteralPercents(in source: String, marker: String) -> String {
        guard source.contains("%"),
              let expression = try? NSRegularExpression(
                  pattern: verbatimEnvironmentPattern
              ) else {
            return source
        }
        var result = source
        let matches = expression.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let environment = result[range].replacingOccurrences(of: "%", with: marker)
            result.replaceSubrange(range, with: environment)
        }
        return result
    }

    private struct SourceSnapshot {
        let fileURL: URL
        let source: String
    }
}

actor ReadPaperLaTeXTranslationService {
    typealias ProgressHandler = @Sendable (ReadPaperLaTeXProgressUpdate) -> Void

    private let fileStore: PaperFileStore
    private let acquirer: any ArXivProjectAcquiring
    private let archiveReader: any TranslationArchiveReading
    private let provider: any ReadPaperLLMCompleting
    private let compiler: (any LaTeXProjectCompiling)?

    init(
        fileStore: PaperFileStore = PaperFileStore(),
        acquirer: any ArXivProjectAcquiring = ReadPaperArXivProjectAcquirer(),
        archiveReader: any TranslationArchiveReading = AutomaticTranslationArchiveReader(),
        provider: any ReadPaperLLMCompleting = OpenAICompatibleLLMProvider(),
        compiler: (any LaTeXProjectCompiling)? = ReadPaperLaTeXTranslationService.defaultCompiler
    ) {
        self.fileStore = fileStore
        self.acquirer = acquirer
        self.archiveReader = archiveReader
        self.provider = provider
        self.compiler = compiler
    }

    func translate(
        _ request: ReadPaperLaTeXTranslationRequest,
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> ReadPaperLaTeXTranslationOutput {
        let cacheIdentity = [
            request.route.translationCacheIdentity,
            ReadPaperLaTeXPromptClient.promptVersion,
            request.targetLanguage,
            Hashing.sha256Hex(request.glossary),
        ].joined(separator: "|")
        let workspace = try fileStore.latexTranslationDirectory(
            for: request.paperID,
            targetLanguage: request.targetLanguage,
            cacheIdentity: cacheIdentity
        )
        let promptClient = ReadPaperLaTeXPromptClient(
            route: request.route,
            apiKey: request.apiKey,
            provider: provider
        )
        let checkpointStore = FileLaTeXTranslationCheckpointStore(
            fileURL: workspace.appendingPathComponent("checkpoints.json")
        )
        let translator = PromptingLaTeXTranslator(
            client: promptClient,
            summarizer: PromptLaTeXDocumentSummarizer(client: promptClient),
            checkpointStore: checkpointStore
        )
        let preparer = RoutedProjectPreparer(arXiv: ArXivProjectPreparer(
            acquirer: acquirer,
            archiveReader: archiveReader
        ))
        let markerID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let literalPercentMarker = "READPAPERLITERALPERCENT\(markerID)"
        let pipeline = LaTeXTranslationPipeline(
            preparer: preparer,
            parser: ReadPaperLiteralPercentPreservingLaTeXParser(
                marker: literalPercentMarker
            ),
            translator: translator,
            validator: StructuralLaTeXValidator(),
            reconstructor: StructuredLaTeXReconstructor(
                preamblePolicy: ReadPaperLaTeXEngineCompatibilityPreamblePolicy()
            )
        )
        let configuration = TranslationConfiguration(
            sourceLanguage: .english,
            targetLanguage: targetLanguage(for: request.targetLanguage),
            maximumValidationRetries: 3,
            compilationPolicy: .sourceOnly,
            validationFailurePolicy: .fail,
            maximumConcurrentTranslations: request.maximumConcurrency,
            previousContextUnitCount: 1,
            terminology: ReadPaperLaTeXTerminology.entries(from: request.glossary),
            documentSummary: request.documentSummary
        )
        let artifact = try await pipeline.run(TranslationRequest(
            source: .arxiv(identifier: request.arxivIdentifier),
            workspaceDirectory: workspace,
            configuration: configuration
        )) { event in
            if event.stage != .finished {
                onProgress(ReadPaperLaTeXProgressMapper.update(for: event))
            }
        }
        try ReadPaperLaTeXProjectCompatibilityNormalizer.normalizeProject(
            at: artifact.projectDirectory,
            literalPercentMarker: literalPercentMarker
        )

        guard let compiler else {
            onProgress(ReadPaperLaTeXProgressMapper.update(for: PipelineEvent(stage: .finished)))
            return ReadPaperLaTeXTranslationOutput(
                artifact: artifact,
                pdfCompilationFailed: false,
                failedCompilationAttempts: []
            )
        }

        onProgress(ReadPaperLaTeXProgressMapper.update(for: PipelineEvent(stage: .compiling)))
        do {
            let compilation = try await compiler.compile(
                projectDirectory: artifact.projectDirectory,
                configuration: configuration
            )
            onProgress(ReadPaperLaTeXProgressMapper.update(for: PipelineEvent(stage: .finished)))
            return ReadPaperLaTeXTranslationOutput(
                artifact: TranslationArtifact(
                    projectDirectory: artifact.projectDirectory,
                    pdfURL: compilation.pdfURL,
                    compilation: compilation,
                    units: artifact.units,
                    validationIssues: artifact.validationIssues
                ),
                pdfCompilationFailed: false,
                failedCompilationAttempts: []
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let LaTeXCompilationError.allAttemptsFailed(attempts) {
            if ReadPaperLaTeXCompilationDiagnostics.indicatesFrozenMintedCacheFailure(attempts),
               (try? ReadPaperLaTeXProjectCompatibilityNormalizer
                   .enableDraftModeForFrozenMintedCaches(at: artifact.projectDirectory)) == true {
                do {
                    let compilation = try await compiler.compile(
                        projectDirectory: artifact.projectDirectory,
                        configuration: configuration
                    )
                    onProgress(ReadPaperLaTeXProgressMapper.update(
                        for: PipelineEvent(stage: .finished)
                    ))
                    return ReadPaperLaTeXTranslationOutput(
                        artifact: TranslationArtifact(
                            projectDirectory: artifact.projectDirectory,
                            pdfURL: compilation.pdfURL,
                            compilation: compilation,
                            units: artifact.units,
                            validationIssues: artifact.validationIssues
                        ),
                        pdfCompilationFailed: false,
                        failedCompilationAttempts: []
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let LaTeXCompilationError.allAttemptsFailed(retryAttempts) {
                    onProgress(ReadPaperLaTeXProgressMapper.update(
                        for: PipelineEvent(stage: .finished)
                    ))
                    return ReadPaperLaTeXTranslationOutput(
                        artifact: artifact,
                        pdfCompilationFailed: true,
                        failedCompilationAttempts: attempts + retryAttempts
                    )
                } catch {
                    // Fall through to the original structured failure below.
                }
            }
            onProgress(ReadPaperLaTeXProgressMapper.update(for: PipelineEvent(stage: .finished)))
            return ReadPaperLaTeXTranslationOutput(
                artifact: artifact,
                pdfCompilationFailed: true,
                failedCompilationAttempts: attempts
            )
        } catch {
            onProgress(ReadPaperLaTeXProgressMapper.update(for: PipelineEvent(stage: .finished)))
            return ReadPaperLaTeXTranslationOutput(
                artifact: artifact,
                pdfCompilationFailed: true,
                failedCompilationAttempts: []
            )
        }
    }

    private func targetLanguage(for code: String) -> TranslationLanguage {
        switch code.lowercased() {
        case "en":
            return .english
        case "ja", "ja-jp":
            return .japanese
        default:
            return .simplifiedChinese
        }
    }

    private static var defaultCompiler: (any LaTeXProjectCompiling)? {
        #if os(macOS)
        guard let toolchain = ReadPaperLaTeXToolchain.detectConfigured() else { return nil }
        return MacOSLaTeXCompiler(
            runner: ReadPaperResolvedLaTeXProcessRunner(toolchain: toolchain),
            engines: [.xeLaTeX, .pdfLaTeX, .luaLaTeX]
        )
        #else
        nil
        #endif
    }
}
