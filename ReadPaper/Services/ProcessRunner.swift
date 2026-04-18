import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var standardOutput: String
    var standardError: String

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum ProcessOutputChannel: Sendable, Equatable {
    case standardOutput
    case standardError
}

struct ProcessOutputEvent: Sendable {
    var channel: ProcessOutputChannel
    var text: String
}

struct ProcessRunner {
    typealias RunImplementation = @Sendable (
        URL,
        [String],
        [String: String],
        URL?,
        (@Sendable (ProcessOutputEvent) -> Void)?
    ) async throws -> ProcessResult

    private let implementation: RunImplementation?

    init(implementation: RunImplementation? = nil) {
        self.implementation = implementation
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        onOutput: (@Sendable (ProcessOutputEvent) -> Void)? = nil
    ) async throws -> ProcessResult {
        if let implementation {
            return try await implementation(
                executableURL,
                arguments,
                environment,
                currentDirectoryURL,
                onOutput
            )
        }

        let cancellation = ProcessRunCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }
                process.currentDirectoryURL = currentDirectoryURL

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                let state = ProcessRunState(
                    process: process,
                    outputPipe: outputPipe,
                    errorPipe: errorPipe,
                    continuation: continuation,
                    onOutput: onOutput
                )
                state.startReading()

                process.terminationHandler = { [state] process in
                    state.finish(exitCode: process.terminationStatus)
                }

                guard cancellation.set(state) else {
                    return
                }
                state.run()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class ProcessRunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessRunState?
    private var isCancelled = false

    func set(_ state: ProcessRunState) -> Bool {
        lock.lock()
        if isCancelled {
            lock.unlock()
            state.cancel()
            return false
        }
        self.state = state
        lock.unlock()
        return true
    }

    func cancel() {
        let state: ProcessRunState?
        lock.lock()
        isCancelled = true
        state = self.state
        lock.unlock()
        state?.cancel()
    }
}

private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private var outputData = Data()
    private var errorData = Data()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private let onOutput: (@Sendable (ProcessOutputEvent) -> Void)?

    init(
        process: Process,
        outputPipe: Pipe,
        errorPipe: Pipe,
        continuation: CheckedContinuation<ProcessResult, Error>,
        onOutput: (@Sendable (ProcessOutputEvent) -> Void)?
    ) {
        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.continuation = continuation
        self.onOutput = onOutput
    }

    func startReading() {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.appendOutput(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.appendError(handle.availableData)
        }
    }

    func run() {
        lock.lock()
        guard continuation != nil, let process else {
            lock.unlock()
            return
        }
        do {
            try process.run()
            lock.unlock()
        } catch {
            lock.unlock()
            fail(error)
        }
    }

    func finish(exitCode: Int32) {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        appendOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
        appendError(errorPipe.fileHandleForReading.readDataToEndOfFile())

        let result: ProcessResult
        let continuation: CheckedContinuation<ProcessResult, Error>?
        lock.lock()
        result = ProcessResult(
            exitCode: exitCode,
            standardOutput: String(data: outputData, encoding: .utf8) ?? "",
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )
        continuation = self.continuation
        self.continuation = nil
        process?.terminationHandler = nil
        process = nil
        lock.unlock()

        continuation?.resume(returning: result)
    }

    func cancel() {
        let process: Process?
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        process = self.process
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
        fail(CancellationError())
    }

    func fail(_ error: Error) {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let continuation: CheckedContinuation<ProcessResult, Error>?
        lock.lock()
        continuation = self.continuation
        self.continuation = nil
        process?.terminationHandler = nil
        process = nil
        lock.unlock()

        continuation?.resume(throwing: error)
    }

    private func appendOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        outputData.append(data)
        lock.unlock()
        report(data, channel: .standardOutput)
    }

    private func appendError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        errorData.append(data)
        lock.unlock()
        report(data, channel: .standardError)
    }

    private func report(_ data: Data, channel: ProcessOutputChannel) {
        guard let onOutput else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }
        onOutput(ProcessOutputEvent(channel: channel, text: text))
    }
}
