import XCTest
@testable import ReadPaper

final class BabelDocRunnerTests: XCTestCase {
    func testArgumentsAndRedaction() {
        let settings = AppSettingsSnapshot(
            openAIBaseURL: "https://api.example.test/v1",
            normalModelName: "paper-model",
            quickModelName: "paper-model",
            heavyModelName: "paper-model",
            targetLanguage: "zh-CN",
            htmlTranslationConcurrency: 4,
            babelDocQPS: 7,
            babelDocVersion: "0.5.24"
        )
        let input = URL(fileURLWithPath: "/tmp/paper.pdf")
        let output = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        let arguments = BabelDocRunner.arguments(
            inputPDF: input,
            outputDirectory: output,
            settings: settings,
            apiKey: "sk-secret"
        )

        XCTAssertTrue(arguments.contains("--openai"))
        XCTAssertTrue(arguments.contains("paper-model"))
        XCTAssertTrue(arguments.contains("zh-CN"))
        XCTAssertTrue(arguments.contains("7"))
        XCTAssertTrue(arguments.contains("sk-secret"))

        let redacted = BabelDocRunner.redact("token sk-secret leaked", apiKey: "sk-secret")
        XCTAssertEqual(redacted, "token <redacted> leaked")
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
