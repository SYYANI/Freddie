import XCTest
import BabelDocKit
@testable import ReadPaper

final class BabelDocRunnerTests: XCTestCase {
    private var originalLanguageOverride: String?

    override func setUp() {
        super.setUp()
        originalLanguageOverride = AppLocalization.currentLanguageOverride()
        AppLocalization.setLanguageOverride("en")
    }

    override func tearDown() {
        AppLocalization.setLanguageOverride(originalLanguageOverride)
        originalLanguageOverride = nil
        super.tearDown()
    }

    func testNativeToolManagerValidatesRuntimeAndKeepsAPIKeyInEnvironment() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let fileStore = PaperFileStore(applicationSupportDirectory: tempRoot)
        let root = try fileStore.toolDirectory.appendingPathComponent("BabelDOCNative", isDirectory: true)
        let manager = BabelDocToolManager(
            fileStore: fileStore,
            nativeHelperURL: root.appendingPathComponent("helper"),
            nativeRuntimeRootURL: root,
            nativeRuntimeResolver: { runtimeRoot, _ in
                BabelDocRuntimeAssets(
                    root: runtimeRoot,
                    manifestVersion: "1.0.0",
                    mupdfLibrary: runtimeRoot.appendingPathComponent("lib/libmupdf.dylib"),
                    zstdLibrary: runtimeRoot.appendingPathComponent("lib/libzstd.dylib"),
                    layoutModel: runtimeRoot.appendingPathComponent("models/layout.mlmodel"),
                    fontDirectory: runtimeRoot.appendingPathComponent("fonts", isDirectory: true)
                )
            },
            nativeHelperVerifier: { _, _ in }
        )
        let files = [
            root.appendingPathComponent("helper"),
            root.appendingPathComponent("lib/libmupdf.dylib"),
            root.appendingPathComponent("lib/libzstd.dylib"),
            root.appendingPathComponent("models/layout.mlmodel"),
        ]
        for file in files {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(fm.createFile(atPath: file.path, contents: Data()))
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files[0].path)
        try fm.createDirectory(at: root.appendingPathComponent("fonts"), withIntermediateDirectories: true)

        let paths = try manager.nativeToolPaths()
        let environment = try manager.nativeEnvironment(apiKey: "sk-secret")
        XCTAssertEqual(paths.executable, files[0])
        XCTAssertEqual(environment["READPAPER_LLM_API_KEY"], "sk-secret")
        XCTAssertNil(environment["BABELDOC_ZSTD_LIBRARY"])
        XCTAssertEqual(paths.runtimeVersion, "1.0.0")
    }

    func testNativeRuntimeDefaultsToApplicationBundleResources() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let fileStore = PaperFileStore(applicationSupportDirectory: tempRoot)
        let manager = BabelDocToolManager(fileStore: fileStore)
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let expected = resources.appendingPathComponent("BabelDOCNative", isDirectory: true)
        let applicationSupportTools = try fileStore.toolDirectory

        XCTAssertEqual(try manager.nativeToolRoot, expected)
        XCTAssertFalse(
            try manager.nativeToolRoot.path.hasPrefix(applicationSupportTools.path + "/")
        )
    }

    func testToolManagerFindsSiblingPythonForShellWrappedLauncher() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let manager = BabelDocToolManager(
            fileStore: PaperFileStore(applicationSupportDirectory: tempRoot)
        )
        let venvBin = try manager.toolRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("babeldoc", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: venvBin, withIntermediateDirectories: true)

        let launcher = venvBin.appendingPathComponent("babeldoc")
        try """
        #!/bin/sh
        '''exec' '\(venvBin.appendingPathComponent("python3").path)' "$0" "$@"
        ' '''
        import sys
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let python = venvBin.appendingPathComponent("python3")
        fm.createFile(atPath: python.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let publicLauncher = try manager.toolBinDirectory.appendingPathComponent("babeldoc")
        try fm.createDirectory(at: publicLauncher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: publicLauncher, withDestinationURL: launcher)

        XCTAssertEqual(try manager.babelDocPythonExecutableURL(), python)
    }

    func testArgumentsAndRedaction() {
        let preferences = TranslationPreferencesSnapshot(
            targetLanguage: "zh-CN",
            htmlTranslationConcurrency: 4,
            babelDocQPS: 7,
            babelDocVersion: "0.5.24"
        )
        let route = LLMModelRouteSnapshot(
            providerProfileID: UUID(),
            providerName: "Test Provider",
            modelProfileID: UUID(),
            modelProfileName: "Paper Model",
            baseURL: "https://api.example.test/v1",
            apiKeyRef: "provider-key",
            modelName: "paper-model",
            temperature: nil,
            topP: nil,
            maxTokens: nil
        )
        let input = URL(fileURLWithPath: "/tmp/paper.pdf")
        let output = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        let arguments = BabelDocRunner.arguments(
            inputPDF: input,
            outputDirectory: output,
            preferences: preferences,
            route: route,
            apiKey: "sk-secret"
        )

        XCTAssertTrue(arguments.contains("--openai"))
        XCTAssertTrue(arguments.contains("paper-model"))
        XCTAssertTrue(arguments.contains("https://api.example.test/v1"))
        XCTAssertTrue(arguments.contains("zh-CN"))
        XCTAssertTrue(arguments.contains("7"))
        XCTAssertTrue(arguments.contains("sk-secret"))
        XCTAssertTrue(arguments.contains("--report-interval"))
        XCTAssertTrue(arguments.contains("0.1"))
        XCTAssertFalse(arguments.contains("--pages"))

        let redacted = BabelDocRunner.redact("token sk-secret leaked", apiKey: "sk-secret")
        XCTAssertEqual(redacted, "token <redacted> leaked")

        let status = BabelDocRunner.statusMessage(
            from: ProcessOutputEvent(channel: .standardOutput, text: "using sk-secret\nworking\n"),
            apiKey: "sk-secret"
        )
        XCTAssertEqual(status, "BabelDOC: working")
    }

    func testArgumentsWithPageRange() {
        let preferences = TranslationPreferencesSnapshot(
            targetLanguage: "zh-CN",
            htmlTranslationConcurrency: 4,
            babelDocQPS: 7,
            babelDocVersion: "0.5.24"
        )
        let route = LLMModelRouteSnapshot(
            providerProfileID: UUID(),
            providerName: "Test Provider",
            modelProfileID: UUID(),
            modelProfileName: "Paper Model",
            baseURL: "https://api.example.test/v1",
            apiKeyRef: "provider-key",
            modelName: "paper-model",
            temperature: nil,
            topP: nil,
            maxTokens: nil
        )
        let input = URL(fileURLWithPath: "/tmp/paper.pdf")
        let output = URL(fileURLWithPath: "/tmp/out", isDirectory: true)

        let argsWithRange = BabelDocRunner.arguments(
            inputPDF: input,
            outputDirectory: output,
            preferences: preferences,
            route: route,
            apiKey: "sk-secret",
            pageRange: 1...10
        )
        XCTAssertTrue(argsWithRange.contains("--pages"))
        let pagesIndex = argsWithRange.firstIndex(of: "--pages")!
        XCTAssertEqual(argsWithRange[pagesIndex + 1], "1-10")
        XCTAssertTrue(argsWithRange.contains("--only-include-translated-page"))

        let argsNoRange = BabelDocRunner.arguments(
            inputPDF: input,
            outputDirectory: output,
            preferences: preferences,
            route: route,
            apiKey: "sk-secret",
            pageRange: nil
        )
        XCTAssertFalse(argsNoRange.contains("--pages"))
        XCTAssertFalse(argsNoRange.contains("--only-include-translated-page"))

        let redacted = BabelDocRunner.redactedArguments(
            inputPDF: input,
            outputDirectory: output,
            preferences: preferences,
            route: route,
            pageRange: 11...20
        )
        XCTAssertTrue(redacted.contains("--pages"))
        let rPagesIndex = redacted.firstIndex(of: "--pages")!
        XCTAssertEqual(redacted[rPagesIndex + 1], "11-20")
        XCTAssertFalse(redacted.contains("sk-secret"))
    }

    func testNativeArgumentsUseLocalAssetsAndNeverContainAPIKey() {
        let tool = NativeBabelDocToolPaths(
            executable: URL(fileURLWithPath: "/native/bin/babeldoc-native"),
            runtimeRoot: URL(fileURLWithPath: "/native", isDirectory: true),
            runtimeManifest: URL(fileURLWithPath: "/app/runtime-manifest.json"),
            runtimeVersion: "1.0.0",
            mupdfLibrary: URL(fileURLWithPath: "/native/lib/libmupdf.dylib"),
            zstdLibrary: URL(fileURLWithPath: "/native/lib/libzstd.dylib"),
            layoutModel: URL(fileURLWithPath: "/native/models/layout.mlmodel"),
            fontDirectory: URL(fileURLWithPath: "/native/fonts", isDirectory: true)
        )
        let output = URL(fileURLWithPath: "/tmp/translated.pdf")
        let arguments = BabelDocRunner.nativeArguments(
            inputPDF: URL(fileURLWithPath: "/tmp/source.pdf"),
            outputPDF: output,
            preferences: Self.preferences,
            route: Self.route,
            tool: tool,
            documentTitle: "Context Paper",
            pageRange: 11...20
        )

        XCTAssertEqual(arguments[arguments.firstIndex(of: "--output")! + 1], output.path)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--runtime-root")! + 1], tool.runtimeRoot.path)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--runtime-manifest")! + 1], tool.runtimeManifest.path)
        XCTAssertFalse(arguments.contains(tool.layoutModel.path))
        XCTAssertFalse(arguments.contains(tool.mupdfLibrary.path))
        XCTAssertTrue(arguments.contains("--only-include-translated-pages"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--pages")! + 1], "11-20")
        XCTAssertFalse(arguments.contains("sk-secret"))
        XCTAssertFalse(arguments.contains("--openai-api-key"))
        XCTAssertEqual(
            arguments[arguments.firstIndex(of: "--system-prompt")! + 1],
            AcademicTranslationPrompt.systemPrompt(targetLanguage: "zh-CN")
        )
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--document-title")! + 1], "Context Paper")
    }

    func testNativeArgumentsIncludeOptionalGlossary() {
        let tool = NativeBabelDocToolPaths(
            executable: URL(fileURLWithPath: "/native/bin/babeldoc-native"),
            runtimeRoot: URL(fileURLWithPath: "/native", isDirectory: true),
            runtimeManifest: URL(fileURLWithPath: "/app/runtime-manifest.json"),
            runtimeVersion: "1.0.0",
            mupdfLibrary: URL(fileURLWithPath: "/native/lib/libmupdf.dylib"),
            zstdLibrary: URL(fileURLWithPath: "/native/lib/libzstd.dylib"),
            layoutModel: URL(fileURLWithPath: "/native/models/layout.mlmodel"),
            fontDirectory: URL(fileURLWithPath: "/native/fonts", isDirectory: true)
        )
        var preferences = Self.preferences
        preferences.translationGlossary = "attention = 注意力"

        let arguments = BabelDocRunner.nativeArguments(
            inputPDF: URL(fileURLWithPath: "/tmp/source.pdf"),
            outputPDF: URL(fileURLWithPath: "/tmp/translated.pdf"),
            preferences: preferences,
            route: Self.route,
            tool: tool
        )

        XCTAssertEqual(arguments[arguments.firstIndex(of: "--glossary")! + 1], "attention = 注意力")
    }

    func testNativeArgumentsIncludeSemanticHintSidecarWithoutEmbeddingContents() {
        let tool = NativeBabelDocToolPaths(
            executable: URL(fileURLWithPath: "/native/bin/babeldoc-native"),
            runtimeRoot: URL(fileURLWithPath: "/native", isDirectory: true),
            runtimeManifest: URL(fileURLWithPath: "/app/runtime-manifest.json"),
            runtimeVersion: "1.0.0",
            mupdfLibrary: URL(fileURLWithPath: "/native/lib/libmupdf.dylib"),
            zstdLibrary: URL(fileURLWithPath: "/native/lib/libzstd.dylib"),
            layoutModel: URL(fileURLWithPath: "/native/models/layout.mlmodel"),
            fontDirectory: URL(fileURLWithPath: "/native/fonts", isDirectory: true)
        )
        let sidecar = URL(fileURLWithPath: "/paper/Resources/LaTeXSemantic/semantic.json")

        let arguments = BabelDocRunner.nativeArguments(
            inputPDF: URL(fileURLWithPath: "/tmp/source.pdf"),
            outputPDF: URL(fileURLWithPath: "/tmp/translated.pdf"),
            preferences: Self.preferences,
            route: Self.route,
            tool: tool,
            semanticHintsURL: sidecar
        )

        XCTAssertEqual(
            arguments[arguments.firstIndex(of: "--semantic-hints")! + 1],
            sidecar.path
        )
    }

    func testNativeArgumentsIncludeThinkingModeAndReasoningEffort() {
        let tool = NativeBabelDocToolPaths(
            executable: URL(fileURLWithPath: "/native/bin/babeldoc-native"),
            runtimeRoot: URL(fileURLWithPath: "/native", isDirectory: true),
            runtimeManifest: URL(fileURLWithPath: "/app/runtime-manifest.json"),
            runtimeVersion: "1.0.0",
            mupdfLibrary: URL(fileURLWithPath: "/native/lib/libmupdf.dylib"),
            zstdLibrary: URL(fileURLWithPath: "/native/lib/libzstd.dylib"),
            layoutModel: URL(fileURLWithPath: "/native/models/layout.mlmodel"),
            fontDirectory: URL(fileURLWithPath: "/native/fonts", isDirectory: true)
        )
        var route = Self.route
        route.thinkingMode = .enabled
        route.reasoningEffort = .max

        let arguments = BabelDocRunner.nativeArguments(
            inputPDF: URL(fileURLWithPath: "/tmp/source.pdf"),
            outputPDF: URL(fileURLWithPath: "/tmp/translated.pdf"),
            preferences: Self.preferences,
            route: route,
            tool: tool
        )

        XCTAssertEqual(arguments[arguments.firstIndex(of: "--thinking-mode")! + 1], "enabled")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--reasoning-effort")! + 1], "max")
        XCTAssertEqual(arguments.filter { $0 == "--reasoning-effort" }.count, 1)
    }

    func testAppSettingsDefaultBabelDocQPSIsConservative() {
        XCTAssertEqual(AppSettings().babelDocQPS, 4)
    }

    func testNativeArgumentsOmitThinkingFlagsByDefault() {
        let tool = NativeBabelDocToolPaths(
            executable: URL(fileURLWithPath: "/native/bin/babeldoc-native"),
            runtimeRoot: URL(fileURLWithPath: "/native", isDirectory: true),
            runtimeManifest: URL(fileURLWithPath: "/app/runtime-manifest.json"),
            runtimeVersion: "1.0.0",
            mupdfLibrary: URL(fileURLWithPath: "/native/lib/libmupdf.dylib"),
            zstdLibrary: URL(fileURLWithPath: "/native/lib/libzstd.dylib"),
            layoutModel: URL(fileURLWithPath: "/native/models/layout.mlmodel"),
            fontDirectory: URL(fileURLWithPath: "/native/fonts", isDirectory: true)
        )

        let arguments = BabelDocRunner.nativeArguments(
            inputPDF: URL(fileURLWithPath: "/tmp/source.pdf"),
            outputPDF: URL(fileURLWithPath: "/tmp/translated.pdf"),
            preferences: Self.preferences,
            route: Self.route,
            tool: tool
        )

        XCTAssertFalse(arguments.contains("--thinking-mode"))
        XCTAssertFalse(arguments.contains("--reasoning-effort"))
    }

    func testOutputParserDecodesStructuredBridgeEventsAcrossChunks() {
        let parser = BabelDocOutputParser(apiKey: "sk-secret")

        let firstChunk = parser.consume(ProcessOutputEvent(
            channel: .standardOutput,
            text: "\(BabelDocRunner.bridgeEventPrefix){\"type\":\"progress_start\",\"stage\":\"LayoutParser\"}\n\(BabelDocRunner.bridgeEventPrefix){\"type\":\"progress_update\""
        ))
        XCTAssertEqual(firstChunk.statusMessages, ["Analyzing layout"])
        XCTAssertTrue(firstChunk.progressUpdates.isEmpty)

        let secondChunk = parser.consume(ProcessOutputEvent(
            channel: .standardOutput,
            text: ",\"stage\":\"LayoutParser\",\"stage_current\":3,\"stage_total\":10,\"overall_progress\":42.4}\n"
        ))
        XCTAssertEqual(
            secondChunk.progressUpdates,
            [
                BabelDocProgressUpdate(
                    completed: 42.4,
                    total: 100,
                    summary: "42%",
                    statusMessage: "Analyzing layout 3/10"
                )
            ]
        )
        XCTAssertTrue(secondChunk.statusMessages.isEmpty)
    }

    func testOutputParserRedactsFallbackLogsAndSanitizedOutputRemovesBridgeEvents() {
        let parser = BabelDocOutputParser(apiKey: "sk-secret")

        let parsed = parser.consume(ProcessOutputEvent(
            channel: .standardError,
            text: "ERROR: using sk-secret\nCRITICAL: still working\n"
        ))
        XCTAssertEqual(
            parsed.statusMessages,
            [
                "BabelDOC error: ERROR: using <redacted>",
                "BabelDOC error: CRITICAL: still working"
            ]
        )

        let sanitized = BabelDocRunner.sanitizedOutput(
            """
            \(BabelDocRunner.bridgeEventPrefix){"type":"progress_update","overall_progress":88}
            visible sk-secret output
            """,
            apiKey: "sk-secret"
        )
        XCTAssertEqual(sanitized, "visible <redacted> output")
    }

    func testOutputParserSurfacesSemanticAndTranslationDiagnostics() {
        let parser = BabelDocOutputParser(apiKey: "sk-secret")
        let parsed = parser.consume(ProcessOutputEvent(
            channel: .standardOutput,
            text: """
            \(BabelDocRunner.bridgeEventPrefix){"type":"translation_diagnostics","semantic_status":"applied","semantic_pdf_paragraphs":12,"semantic_matched_pdf_paragraphs":9,"semantic_matched_pdf_coverage":0.75,"semantic_high_confidence":7,"translation_candidates":10,"translation_completed":9,"translation_failed":1,"provider_failures":2,"placeholder_validation_failures":1,"semantic_translation_fallbacks":1}\n
            """
        ))

        XCTAssertEqual(
            parsed.statusMessages,
            ["LaTeX structure matched 9/12 PDF paragraphs; translated 9/10 text blocks."]
        )
        XCTAssertEqual(
            parsed.diagnostics,
            BabelDocTranslationDiagnostics(
                semanticStatus: "applied",
                candidateCount: 10,
                translatedCount: 9,
                failedCount: 1,
                providerFailureCount: 2,
                placeholderValidationFailureCount: 1,
                semanticFallbackCount: 1,
                continuationGroupCount: 0
            )
        )
        XCTAssertEqual(parser.finish().diagnostics, parsed.diagnostics)

        let fallbackEvent = try! XCTUnwrap(BabelDocRunner.bridgeEvent(
            from: #"{"type":"translation_diagnostics","semantic_status":"pdfFallback"}"#
        ))
        let fallback = BabelDocRunner.structuredStatusMessage(from: fallbackEvent)
        XCTAssertEqual(
            fallback,
            "LaTeX structure could not be applied; translation continued with PDF layout."
        )
    }

    func testGenericTranslationDiagnosticsSurfaceDegradationAndPersistAsSidecar() throws {
        let parser = BabelDocOutputParser(apiKey: "sk-secret")
        let parsed = parser.consume(ProcessOutputEvent(
            channel: .standardOutput,
            text: """
            \(BabelDocRunner.bridgeEventPrefix){"type":"translation_diagnostics","translation_candidates":8,"translation_completed":7,"translation_failed":1,"provider_failures":2,"placeholder_validation_failures":0}\n
            """
        ))
        let diagnostics = try XCTUnwrap(parsed.diagnostics)
        XCTAssertTrue(diagnostics.isDegraded)
        XCTAssertEqual(
            parsed.statusMessages,
            ["Translated 7/8 text blocks; 1 failed and kept their original layout."]
        )

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let outputPDF = tempRoot.appendingPathComponent("translated.pdf")
        let sidecar = try BabelDocRunner.writeDiagnostics(diagnostics, for: outputPDF)

        XCTAssertEqual(sidecar, outputPDF.appendingPathExtension("diagnostics.json"))
        XCTAssertEqual(try BabelDocRunner.readDiagnostics(for: outputPDF), diagnostics)
    }

    func testSafelyPreservedFormulaLayoutDoesNotSurfaceAsTranslationFailure() throws {
        let parser = BabelDocOutputParser(apiKey: "sk-secret")
        let parsed = parser.consume(ProcessOutputEvent(
            channel: .standardOutput,
            text: """
            \(BabelDocRunner.bridgeEventPrefix){"type":"translation_diagnostics","translation_candidates":193,"translation_completed":192,"translation_failed":1,"provider_failures":0,"placeholder_validation_failures":0}\n
            """
        ))
        let diagnostics = try XCTUnwrap(parsed.diagnostics)

        XCTAssertFalse(diagnostics.isDegraded)
        XCTAssertFalse(diagnostics.hasActionableFailures)
        XCTAssertEqual(diagnostics.safelyPreservedLayoutCount, 1)
        XCTAssertEqual(
            parsed.statusMessages,
            ["Translated text blocks: 192; formula-layout blocks safely preserved: 1."]
        )

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let outputPDF = tempRoot.appendingPathComponent("translated.pdf")
        try Data(
            #"{"candidateCount":193,"continuationGroupCount":0,"failedCount":1,"placeholderValidationFailureCount":0,"providerFailureCount":0,"semanticFallbackCount":0,"semanticStatus":"notProvided","translatedCount":192}"#.utf8
        ).write(to: BabelDocRunner.diagnosticsURL(for: outputPDF))

        let restored = try BabelDocRunner.readDiagnostics(for: outputPDF)
        XCTAssertFalse(restored.isDegraded)
        XCTAssertEqual(restored.safelyPreservedLayoutCount, 1)
    }

    func testDismissedDiagnosticsNoticeOnlySuppressesTheSameTranslationResult() throws {
        let suiteName = "PDFTranslationDiagnosticsNoticeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PDFTranslationDiagnosticsNoticeStore(userDefaults: defaults)
        let paperID = UUID()
        let diagnostics = BabelDocTranslationDiagnostics(
            semanticStatus: "applied",
            candidateCount: 140,
            translatedCount: 139,
            failedCount: 1,
            providerFailureCount: 1,
            placeholderValidationFailureCount: 0,
            semanticFallbackCount: 0,
            continuationGroupCount: 0
        )
        let firstOutput = URL(fileURLWithPath: "/tmp/translated-first.pdf")
        let firstNoticeID = store.noticeID(outputPDF: firstOutput, diagnostics: diagnostics)

        XCTAssertFalse(store.isDismissed(paperID: paperID, noticeID: firstNoticeID))
        store.dismiss(paperID: paperID, noticeID: firstNoticeID)
        XCTAssertTrue(store.isDismissed(paperID: paperID, noticeID: firstNoticeID))

        let updatedDiagnostics = BabelDocTranslationDiagnostics(
            semanticStatus: "applied",
            candidateCount: 150,
            translatedCount: 148,
            failedCount: 2,
            providerFailureCount: 2,
            placeholderValidationFailureCount: 0,
            semanticFallbackCount: 0,
            continuationGroupCount: 0
        )
        let updatedNoticeID = store.noticeID(
            outputPDF: firstOutput,
            diagnostics: updatedDiagnostics
        )
        let replacementNoticeID = store.noticeID(
            outputPDF: URL(fileURLWithPath: "/tmp/translated-replacement.pdf"),
            diagnostics: diagnostics
        )

        XCTAssertFalse(store.isDismissed(paperID: paperID, noticeID: updatedNoticeID))
        XCTAssertFalse(store.isDismissed(paperID: paperID, noticeID: replacementNoticeID))
        XCTAssertFalse(store.isDismissed(paperID: UUID(), noticeID: firstNoticeID))
    }

    func testTranslatePDFWritesRedactedFailureLogOnProcessFailure() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputDirectory = tempRoot.appendingPathComponent("translations", isDirectory: true)
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let runner = BabelDocRunner(processRunner: ProcessRunner { _, _, _, _, _ in
            ProcessResult(
                exitCode: 42,
                standardOutput: "stdout mentions sk-secret\n",
                standardError: "stderr mentions sk-secret\n"
            )
        })

        do {
            _ = try await runner.translatePDF(
                inputPDF: tempRoot.appendingPathComponent("paper.pdf"),
                outputDirectory: outputDirectory,
                preferences: Self.preferences,
                route: Self.route,
                apiKey: "sk-secret",
                babelDocPythonExecutable: URL(fileURLWithPath: "/tmp/python"),
                bridgeScript: URL(fileURLWithPath: "/tmp/babeldoc_progress_bridge.py")
            )
            XCTFail("Expected BabelDOC failure.")
        } catch let error as BabelDocRunError {
            guard let logURL = error.logURL else {
                XCTFail("Expected failure log URL.")
                return
            }
            let log = try String(contentsOf: logURL, encoding: .utf8)
            XCTAssertTrue(log.contains("ReadPaper BabelDOC failure log"))
            XCTAssertTrue(log.contains("Exit code: 42"))
            XCTAssertTrue(log.contains("stdout mentions <redacted>"))
            XCTAssertTrue(log.contains("stderr mentions <redacted>"))
            XCTAssertTrue(log.contains("--openai-api-key"))
            XCTAssertFalse(log.contains("sk-secret"))
        } catch {
            XCTFail("Expected BabelDocRunError, got \(error).")
        }
    }

    func testProcessRunnerDrainsLargeOutputWhileProcessRuns() async throws {
        let result = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes output | head -c 1048576; printf '\\nstderr-ready\\n' >&2"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.standardOutput.count, 1_000_000)
        XCTAssertTrue(result.standardError.contains("stderr-ready"))
    }

    func testProcessRunnerReportsOutputWhileProcessRuns() async throws {
        let recorder = ProcessOutputRecorder()
        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'started\\n'; sleep 1; printf 'finished\\n'"],
                onOutput: { event in
                    Task {
                        await recorder.append(event)
                    }
                }
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let outputDuringRun = await recorder.combinedOutput
        XCTAssertTrue(outputDuringRun.contains("started"))

        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("finished"))
    }

    func testProcessRunnerCancelsRunningProcess() async throws {
        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"]
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to throw.")
        } catch is CancellationError {
            // Expected path.
        }
    }
}

private extension BabelDocRunnerTests {
    static var preferences: TranslationPreferencesSnapshot {
        TranslationPreferencesSnapshot(
            targetLanguage: "zh-CN",
            htmlTranslationConcurrency: 4,
            babelDocQPS: 7,
            babelDocVersion: "0.5.24"
        )
    }

    static var route: LLMModelRouteSnapshot {
        LLMModelRouteSnapshot(
            providerProfileID: UUID(),
            providerName: "Test Provider",
            modelProfileID: UUID(),
            modelProfileName: "Paper Model",
            baseURL: "https://api.example.test/v1",
            apiKeyRef: "provider-key",
            modelName: "paper-model",
            temperature: nil,
            topP: nil,
            maxTokens: nil
        )
    }
}

private actor ProcessOutputRecorder {
    private var events: [ProcessOutputEvent] = []

    var combinedOutput: String {
        events.map(\.text).joined()
    }

    func append(_ event: ProcessOutputEvent) {
        events.append(event)
    }
}
