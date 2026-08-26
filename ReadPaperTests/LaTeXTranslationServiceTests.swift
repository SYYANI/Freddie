import Foundation
import LaTeXTransKit
import XCTest
@testable import ReadPaper

final class LaTeXTranslationServiceTests: XCTestCase {
    func testPromptClientMapsImmutableRouteAndPromptWithoutPersistingCredentials() async throws {
        let provider = RecordingLLMProvider(response: " translated ")
        let route = makeRoute(
            temperature: 0.35,
            topP: 0.8,
            maxTokens: 777,
            thinkingMode: .enabled,
            reasoningEffort: .high
        )
        let client = ReadPaperLaTeXPromptClient(
            route: route,
            apiKey: "sk-host-owned",
            provider: provider
        )
        let prompt = LaTeXPromptRequest(
            purpose: .translation(unitID: "section-0", kind: .section, attempt: 0),
            messages: [
                LaTeXPromptMessage(role: .system, content: "system"),
                LaTeXPromptMessage(role: .user, content: "source"),
            ],
            temperature: 0.7,
            maximumOutputTokens: 8_192
        )

        let result = try await client.complete(prompt)
        let capturedRequest = await provider.lastRequest()
        let recorded = try XCTUnwrap(capturedRequest)

        XCTAssertEqual(result, "translated")
        XCTAssertEqual(recorded.baseURL.absoluteString, route.baseURL)
        XCTAssertEqual(recorded.apiKey, "sk-host-owned")
        XCTAssertEqual(recorded.model, route.modelName)
        XCTAssertEqual(recorded.messages, [
            LLMCompletionMessage(role: "system", content: "system"),
            LLMCompletionMessage(role: "user", content: "source"),
        ])
        XCTAssertEqual(recorded.temperature, 0.35)
        XCTAssertEqual(recorded.topP, 0.8)
        XCTAssertEqual(recorded.maxTokens, 777)
        XCTAssertEqual(recorded.thinkingMode, .enabled)
        XCTAssertEqual(recorded.reasoningEffort, .high)
    }

    func testProgressMapperProducesMonotonicHostProgress() {
        let events = [
            PipelineEvent(stage: .preparing),
            PipelineEvent(stage: .parsing),
            PipelineEvent(stage: .translating, completedUnitCount: 0, totalUnitCount: 4),
            PipelineEvent(stage: .translating, completedUnitCount: 2, totalUnitCount: 4),
            PipelineEvent(stage: .translating, completedUnitCount: 4, totalUnitCount: 4),
            PipelineEvent(stage: .validating),
            PipelineEvent(stage: .reconstructing),
            PipelineEvent(stage: .compiling),
            PipelineEvent(stage: .finished),
        ]

        let updates = events.map(ReadPaperLaTeXProgressMapper.update)

        XCTAssertEqual(updates.map(\.stage), events.map(\.stage))
        XCTAssertEqual(updates.last?.fractionCompleted, 1)
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy {
            $0.fractionCompleted <= $1.fractionCompleted
        })
        XCTAssertEqual(updates[3].completedUnits, 2)
        XCTAssertEqual(updates[3].totalUnits, 4)
    }

    func testFileCheckpointStorePersistsAtomicModelResponses() async throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        let fileURL = temporary.url.appendingPathComponent("nested/checkpoints.json")
        let first = FileLaTeXTranslationCheckpointStore(fileURL: fileURL)

        try await first.saveTranslation("译文", unitID: "section-0", fingerprint: "abc")
        let restored = FileLaTeXTranslationCheckpointStore(fileURL: fileURL)

        let restoredValue = await restored.translation(unitID: "section-0", fingerprint: "abc")
        XCTAssertEqual(restoredValue, "译文")
    }

    func testEndToEndSourceTranslationLivesUnderManagedPaperDirectory() async throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        let project = temporary.url.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        \\documentclass{article}
        \\pdfoutput=1
        \\pdfsuppresswarningpagegroup=1
        \\usepackage[latin9]{inputenc}
        \\begin{document}
        \\section{Introduction}
        This deterministic fixture contains enough academic prose to become a translatable section. It describes a method, its experimental setting, its measured outcomes, and its limitations while preserving every LaTeX command exactly for the host integration test.
        \\end{document}
        """.write(
            to: project.appendingPathComponent("main.tex"),
            atomically: true,
            encoding: .utf8
        )

        let paperID = UUID()
        let support = temporary.url.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let provider = EchoLLMProvider()
        let service = ReadPaperLaTeXTranslationService(
            fileStore: PaperFileStore(applicationSupportDirectory: support),
            acquirer: StaticArXivAcquirer(source: .localDirectory(project)),
            provider: provider,
            compiler: nil
        )
        let progress = ProgressRecorder()
        let output = try await service.translate(ReadPaperLaTeXTranslationRequest(
            paperID: paperID,
            arxivIdentifier: "2401.00001v1",
            targetLanguage: "zh-CN",
            maximumConcurrency: 2,
            glossary: "method => 方法",
            documentSummary: "A deterministic integration fixture.",
            route: makeRoute(),
            apiKey: "sk-must-not-be-persisted"
        )) { update in
            progress.append(update)
        }

        let managedRoot = support
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(paperID.uuidString, isDirectory: true)
            .appendingPathComponent("translations/latex", isDirectory: true)
            .standardizedFileURL.path
        XCTAssertTrue(output.artifact.projectDirectory.standardizedFileURL.path.hasPrefix(managedRoot + "/"))
        XCTAssertNil(output.artifact.pdfURL)
        XCTAssertFalse(output.pdfCompilationFailed)
        let translatedMain = output.artifact.projectDirectory.appendingPathComponent("main.tex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: translatedMain.path))
        XCTAssertTrue(try String(contentsOf: translatedMain, encoding: .utf8).contains(
            "\\usepackage[UTF8,fontset=fandol]{ctex}"
        ))
        let translatedSource = try String(contentsOf: translatedMain, encoding: .utf8)
        XCTAssertTrue(translatedSource.contains("\\ifdefined\\pdfoutput\\pdfoutput=1\\fi"))
        XCTAssertTrue(translatedSource.contains(
            "\\ifdefined\\pdfsuppresswarningpagegroup\\pdfsuppresswarningpagegroup=1\\fi"
        ))
        XCTAssertTrue(translatedSource.contains(
            "\\ifdefined\\pdftexversion\\usepackage[utf8]{inputenc}\\fi"
        ))
        let managedFiles = try XCTUnwrap(FileManager.default.enumerator(
            at: URL(fileURLWithPath: managedRoot, isDirectory: true),
            includingPropertiesForKeys: nil
        )?.allObjects as? [URL])
        XCTAssertTrue(managedFiles.contains { $0.lastPathComponent == "checkpoints.json" })
        XCTAssertFalse(try allFileContents(under: managedRoot).contains("sk-must-not-be-persisted"))
        let progressValues = progress.values()
        XCTAssertEqual(progressValues.last?.stage, .finished)
    }

    func testCompilationFailureReturnsTranslatedSourceAndStructuredAttempts() async throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        let project = temporary.url.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        \\documentclass{article}
        \\begin{document}
        \\section{Results}
        This fixture contains enough prose to exercise translation before an injected compiler failure. The translated project must remain available to the host even when no engine can produce a PDF artifact.
        \\end{document}
        """.write(
            to: project.appendingPathComponent("main.tex"),
            atomically: true,
            encoding: .utf8
        )
        let logURL = temporary.url.appendingPathComponent("xelatex.stderr.log")
        try Data("compiler failed".utf8).write(to: logURL)
        let attempt = CompilationAttempt(
            engine: .xeLaTeX,
            exitCode: 1,
            succeeded: false,
            durationMilliseconds: 12,
            logURLs: [logURL]
        )
        let service = ReadPaperLaTeXTranslationService(
            fileStore: PaperFileStore(
                applicationSupportDirectory: temporary.url.appendingPathComponent("support")
            ),
            acquirer: StaticArXivAcquirer(source: .localDirectory(project)),
            provider: EchoLLMProvider(),
            compiler: FailingLaTeXCompiler(attempts: [attempt])
        )

        let output = try await service.translate(ReadPaperLaTeXTranslationRequest(
            paperID: UUID(),
            arxivIdentifier: "2401.00002v1",
            targetLanguage: "zh-CN",
            maximumConcurrency: 1,
            glossary: "",
            documentSummary: "A compiler-failure fixture.",
            route: makeRoute(),
            apiKey: "sk-in-memory-only"
        ))

        XCTAssertTrue(output.pdfCompilationFailed)
        XCTAssertNil(output.artifact.pdfURL)
        XCTAssertEqual(output.failedCompilationAttempts, [attempt])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.artifact.projectDirectory.appendingPathComponent("main.tex").path
        ))
    }

    func testToolchainDetectionFindsLatexmkOnProvidedPath() throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        let bin = temporary.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let latexmk = bin.appendingPathComponent("latexmk")
        try Data("#!/bin/sh\n".utf8).write(to: latexmk)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: latexmk.path)

        let toolchain = ReadPaperLaTeXToolchain.detect(environment: ["PATH": bin.path])

        XCTAssertEqual(toolchain?.latexmkURL, latexmk.standardizedFileURL)
    }

    func testConfiguredToolchainDirectoryTakesPrecedenceOverPATH() throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        let automaticBin = temporary.url.appendingPathComponent("automatic", isDirectory: true)
        let configuredBin = temporary.url.appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.createDirectory(at: automaticBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuredBin, withIntermediateDirectories: true)
        try makeExecutable(named: "latexmk", in: automaticBin)
        let configuredLatexmk = try makeExecutable(named: "latexmk", in: configuredBin)

        let suiteName = "LaTeXTranslationServiceTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(configuredBin.path, forKey: LaTeXIntegrationPreferences.toolchainDirectoryKey)

        let toolchain = ReadPaperLaTeXToolchain.detectConfigured(
            userDefaults: defaults,
            environment: ["PATH": automaticBin.path]
        )

        XCTAssertEqual(toolchain?.latexmkURL, configuredLatexmk.standardizedFileURL)
    }

    func testInvalidConfiguredToolchainDoesNotSilentlyFallBackToPATH() throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        let automaticBin = temporary.url.appendingPathComponent("automatic", isDirectory: true)
        let configuredBin = temporary.url.appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.createDirectory(at: automaticBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuredBin, withIntermediateDirectories: true)
        try makeExecutable(named: "latexmk", in: automaticBin)

        let suiteName = "LaTeXTranslationServiceTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(configuredBin.path, forKey: LaTeXIntegrationPreferences.toolchainDirectoryKey)

        XCTAssertNil(ReadPaperLaTeXToolchain.detectConfigured(
            userDefaults: defaults,
            environment: ["PATH": automaticBin.path]
        ))
    }

    func testInstallationHealthRequiresLatexmkAndPDFEngine() throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        try makeExecutable(named: "latexmk", in: temporary.url)

        let incomplete = ReadPaperLaTeXToolchain.installation(at: temporary.url)
        XCTAssertTrue(incomplete.hasLatexmk)
        XCTAssertFalse(incomplete.hasPDFEngine)
        XCTAssertFalse(incomplete.isHealthy)

        try makeExecutable(named: "xelatex", in: temporary.url)
        let healthy = ReadPaperLaTeXToolchain.installation(at: temporary.url)
        XCTAssertTrue(healthy.isHealthy)
    }

    func testResolvedProcessRunnerInvokesDetectedLatexmkDirectly() async throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        let latexmk = temporary.url.appendingPathComponent("texbin/latexmk")
        let baseRunner = RecordingLaTeXProcessRunner()
        let runner = ReadPaperResolvedLaTeXProcessRunner(
            toolchain: ReadPaperLaTeXToolchain(latexmkURL: latexmk),
            runner: baseRunner
        )
        let stdout = temporary.url.appendingPathComponent("stdout.log")
        let stderr = temporary.url.appendingPathComponent("stderr.log")

        _ = try await runner.run(LaTeXProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["latexmk", "-xelatex", "main.tex"],
            workingDirectory: temporary.url,
            environment: ["PATH": "/usr/bin:/bin"],
            standardOutputURL: stdout,
            standardErrorURL: stderr
        ))
        let recordedRequest = await baseRunner.lastRequest()
        let request = try XCTUnwrap(recordedRequest)

        XCTAssertEqual(request.executableURL, latexmk)
        XCTAssertEqual(request.arguments, ["-xelatex", "main.tex"])
        XCTAssertEqual(
            request.environment?["PATH"],
            latexmk.deletingLastPathComponent().path + ":/usr/bin:/bin"
        )
    }

    func testCompilationDiagnosticsPreferNonemptyStderrAndExplainMissingToolchain() throws {
        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        let stdout = temporary.url.appendingPathComponent("stdout.log")
        let stderr = temporary.url.appendingPathComponent("stderr.log")
        try Data().write(to: stdout)
        try Data("env: latexmk: No such file or directory\n".utf8).write(to: stderr)
        let attempt = CompilationAttempt(
            engine: .xeLaTeX,
            exitCode: 127,
            succeeded: false,
            durationMilliseconds: 4,
            logURLs: [stdout, stderr]
        )

        XCTAssertEqual(
            ReadPaperLaTeXCompilationDiagnostics.preferredLogURL(from: [attempt]),
            stderr
        )
        XCTAssertTrue(ReadPaperLaTeXCompilationDiagnostics.indicatesMissingLatexmk([attempt]))
        XCTAssertEqual(
            ReadPaperLaTeXCompilationDiagnostics.failureStatusMessage(
                for: [attempt],
                bundle: AppLocalization.resolveBundle(for: "en")
            ),
            "LaTeX source translation completed, but PDF compilation requires a TeX distribution that includes latexmk."
        )
    }

    func testTerminologyParserAcceptsHostGlossarySyntaxAndIgnoresNotes() {
        let entries = ReadPaperLaTeXTerminology.entries(from: """
        model => 模型
        loss = 损失
        optimizer\t优化器
        keep this as a note
        """)

        XCTAssertEqual(entries, [
            TerminologyEntry(source: "model", target: "模型"),
            TerminologyEntry(source: "loss", target: "损失"),
            TerminologyEntry(source: "optimizer", target: "优化器"),
        ])
    }

    func testLaTeXPreambleNormalizesPDFTeXPrimitivesAndLegacyInputEncoding() throws {
        let source = #"""
        \documentclass{article}
        \pdfoutput=1
        \pdfsuppresswarningpagegroup = 1 % source compatibility
        \usepackage[latin9]{inputenc}
        % \pdfoutput=0
        \begin{document}Text\end{document}
        """#
        let policy = ReadPaperLaTeXEngineCompatibilityPreamblePolicy()

        let transformed = try policy.transform(
            source,
            targetLanguage: .simplifiedChinese
        )
        let transformedTwice = try policy.transform(
            transformed,
            targetLanguage: .simplifiedChinese
        )

        XCTAssertTrue(transformed.contains(#"\ifdefined\pdfoutput\pdfoutput=1\fi"#))
        XCTAssertTrue(transformed.contains(
            #"\ifdefined\pdfsuppresswarningpagegroup\pdfsuppresswarningpagegroup=1\fi % source compatibility"#
        ))
        XCTAssertTrue(transformed.contains(
            #"\ifdefined\pdftexversion\usepackage[utf8]{inputenc}\fi"#
        ))
        XCTAssertTrue(transformed.contains(#"% \pdfoutput=0"#))
        XCTAssertFalse(transformed.contains(#"\usepackage[latin9]{inputenc}"#))
        XCTAssertEqual(transformedTwice, transformed)
    }

    func testArXivIdentifierResolutionDoesNotDuplicateVersions() {
        XCTAssertEqual(
            ReadPaperArXivIdentifier.resolving(id: "2401.00001", version: "v2"),
            "2401.00001v2"
        )
        XCTAssertEqual(
            ReadPaperArXivIdentifier.resolving(id: "2401.00001v2", version: "v2"),
            "2401.00001v2"
        )
        XCTAssertEqual(
            ReadPaperArXivIdentifier.resolving(id: "hep-th/9901001", version: "3"),
            "hep-th/9901001v3"
        )
    }

    func testCoreLaTeXFailuresUseHostLocalizedMessages() {
        let bundle = AppLocalization.resolveBundle(for: "en")
        XCTAssertEqual(
            ReadPaperLaTeXErrorPresentation.message(
                for: LaTeXParserError.mainFileNotFound(projectDirectory: "/private/source"),
                bundle: bundle
            ),
            "Error: Could not parse the LaTeX source."
        )
        XCTAssertEqual(
            ReadPaperLaTeXErrorPresentation.message(
                for: TranslationPipelineError.validationFailed([]),
                bundle: bundle
            ),
            "Error: The LaTeX translation failed structural validation."
        )
        XCTAssertEqual(
            ReadPaperLaTeXErrorPresentation.message(
                for: ReadPaperLaTeXToolchainError.latexmkNotFound,
                bundle: bundle
            ),
            "Error: PDF compilation requires a TeX distribution that includes latexmk."
        )
        XCTAssertEqual(
            ReadPaperLaTeXErrorPresentation.message(
                for: TranslationPipelineError.validationFailed([
                    ValidationIssue(
                        unitID: "section:9",
                        severity: .error,
                        code: "placeholder-mismatch",
                        message: "Missing a placeholder."
                    ),
                    ValidationIssue(
                        unitID: "section:6_2",
                        severity: .error,
                        code: "command-mismatch",
                        message: "Changed a command."
                    ),
                ]),
                bundle: bundle
            ),
            "Error: The LaTeX translation failed structural validation: section:6_2 [command-mismatch]; section:9 [placeholder-mismatch]"
        )
    }

    @discardableResult
    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeRoute(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        thinkingMode: LLMThinkingMode? = nil,
        reasoningEffort: LLMReasoningEffort? = nil
    ) -> LLMModelRouteSnapshot {
        LLMModelRouteSnapshot(
            providerProfileID: UUID(),
            providerName: "Provider",
            modelProfileID: UUID(),
            modelProfileName: "Model",
            baseURL: "https://api.example.com/v1",
            apiKeyRef: "keychain-reference",
            modelName: "model-name",
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            thinkingMode: thinkingMode,
            reasoningEffort: reasoningEffort
        )
    }

    private func allFileContents(under path: String) throws -> String {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return ""
        }
        var result = ""
        for case let url as URL in enumerator {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                result += text
            }
        }
        return result
    }
}

private actor RecordingLLMProvider: ReadPaperLLMCompleting {
    private let response: String
    private var request: LLMCompletionRequest?

    init(response: String) {
        self.response = response
    }

    func complete(request: LLMCompletionRequest) -> LLMCompletionResponse {
        self.request = request
        return LLMCompletionResponse(text: response, resolvedEndpoint: nil)
    }

    func lastRequest() -> LLMCompletionRequest? {
        request
    }
}

private actor EchoLLMProvider: ReadPaperLLMCompleting {
    func complete(request: LLMCompletionRequest) throws -> LLMCompletionResponse {
        guard let source = request.messages.last?.content else {
            throw LLMProviderError.emptyResponse
        }
        return LLMCompletionResponse(text: source, resolvedEndpoint: nil)
    }
}

private struct StaticArXivAcquirer: ArXivProjectAcquiring {
    let source: TranslationProjectSource

    func acquireProject(identifier: String, workspaceDirectory: URL) async throws -> TranslationProjectSource {
        source
    }
}

private struct FailingLaTeXCompiler: LaTeXProjectCompiling {
    let attempts: [CompilationAttempt]

    func compile(
        projectDirectory: URL,
        configuration: TranslationConfiguration
    ) async throws -> CompilationArtifact {
        throw LaTeXCompilationError.allAttemptsFailed(attempts)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ReadPaperLaTeXProgressUpdate] = []

    func append(_ update: ReadPaperLaTeXProgressUpdate) {
        lock.withLock { updates.append(update) }
    }

    func values() -> [ReadPaperLaTeXProgressUpdate] {
        lock.withLock { updates }
    }
}

private actor RecordingLaTeXProcessRunner: LaTeXProcessRunning {
    private var request: LaTeXProcessRequest?

    func run(_ request: LaTeXProcessRequest) -> LaTeXProcessResult {
        self.request = request
        return LaTeXProcessResult(exitCode: 0)
    }

    func lastRequest() -> LaTeXProcessRequest? {
        request
    }
}

private struct TemporaryTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
