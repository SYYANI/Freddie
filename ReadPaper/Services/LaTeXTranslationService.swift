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

struct ReadPaperLaTeXToolchain: Equatable, Sendable {
    let latexmkURL: URL

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
            return .localArchive(destination)
        }

        guard let sourceURL = URL(string: "https://export.arxiv.org/e-print/\(normalized.queryID)") else {
            throw PaperImportError.invalidArxivIdentifier(identifier)
        }
        let request = BrowserRequestHeaders.request(for: sourceURL, accept: .resource)
        let (temporaryURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PaperImportError.arxivHTTPError(statusCode: http.statusCode)
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return .localArchive(destination)
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
        let pipeline = LaTeXTranslationPipeline(
            preparer: preparer,
            parser: StructuredLaTeXParser(),
            translator: translator,
            validator: StructuralLaTeXValidator(),
            reconstructor: StructuredLaTeXReconstructor()
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
        guard let toolchain = ReadPaperLaTeXToolchain.detect() else { return nil }
        return MacOSLaTeXCompiler(
            runner: ReadPaperResolvedLaTeXProcessRunner(toolchain: toolchain),
            engines: [.xeLaTeX, .pdfLaTeX, .luaLaTeX]
        )
        #else
        nil
        #endif
    }
}
