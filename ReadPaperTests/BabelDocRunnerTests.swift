import XCTest
@testable import ReadPaper

final class BabelDocRunnerTests: XCTestCase {
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

        let argsNoRange = BabelDocRunner.arguments(
            inputPDF: input,
            outputDirectory: output,
            preferences: preferences,
            route: route,
            apiKey: "sk-secret",
            pageRange: nil
        )
        XCTAssertFalse(argsNoRange.contains("--pages"))

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
            text: "using sk-secret\nstill working\n"
        ))
        XCTAssertEqual(
            parsed.statusMessages,
            [
                "BabelDOC error: using <redacted>",
                "BabelDOC error: still working"
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

private actor ProcessOutputRecorder {
    private var events: [ProcessOutputEvent] = []

    var combinedOutput: String {
        events.map(\.text).joined()
    }

    func append(_ event: ProcessOutputEvent) {
        events.append(event)
    }
}
