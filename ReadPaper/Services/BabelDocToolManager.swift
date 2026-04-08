import Foundation
import OSLog

struct BabelDocToolManager {
    static let toolName = "BabelDOC"

    let fileStore: PaperFileStore
    let runner: ProcessRunner
    let logger = Logger(subsystem: "com.yiyan.ReadPaper", category: "BabelDocToolManager")

    init(fileStore: PaperFileStore = PaperFileStore(), runner: ProcessRunner = ProcessRunner()) {
        self.fileStore = fileStore
        self.runner = runner
    }

    var toolRoot: URL {
        get throws {
            try fileStore.toolDirectory.appendingPathComponent("BabelDOC", isDirectory: true)
        }
    }

    var toolBinDirectory: URL {
        get throws {
            try toolRoot.appendingPathComponent("bin", isDirectory: true)
        }
    }

    var uvExecutableURL: URL {
        get throws {
            try toolBinDirectory.appendingPathComponent("uv")
        }
    }

    var babelDocExecutableURL: URL {
        get throws {
            try toolBinDirectory.appendingPathComponent("babeldoc")
        }
    }

    func environment() throws -> [String: String] {
        let root = try toolRoot
        let bin = try toolBinDirectory
        return [
            "UV_TOOL_DIR": root.appendingPathComponent("tools", isDirectory: true).path,
            "UV_TOOL_BIN_DIR": bin.path,
            "UV_PYTHON_INSTALL_DIR": root.appendingPathComponent("python", isDirectory: true).path,
            "UV_CACHE_DIR": root.appendingPathComponent("cache", isDirectory: true).path,
            "PATH": "\(bin.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
    }

    func detect() throws -> ToolInstallStatus {
        if FileManager.default.isExecutableFile(atPath: try babelDocExecutableURL.path) {
            return .ready
        }
        return .missing
    }

    func installOrUpdateBabelDOC(version: String) async throws -> ProcessResult {
        try prepareDirectories()
        let uvURL = try await ensureUV()
        let result = try await runner.run(
            executableURL: uvURL,
            arguments: ["tool", "install", "--force", "BabelDOC==\(version)"],
            environment: try environment(),
            currentDirectoryURL: try toolRoot
        )
        guard result.exitCode == 0 else {
            logger.error("BabelDOC installation failed: \(result.combinedOutput, privacy: .public)")
            return result
        }
        return result
    }

    private func prepareDirectories() throws {
        let fm = FileManager.default
        for directory in [
            try toolRoot,
            try toolBinDirectory,
            try toolRoot.appendingPathComponent("tools", isDirectory: true),
            try toolRoot.appendingPathComponent("python", isDirectory: true),
            try toolRoot.appendingPathComponent("cache", isDirectory: true)
        ] {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    private func ensureUV() async throws -> URL {
        let managedUV = try uvExecutableURL
        if FileManager.default.isExecutableFile(atPath: managedUV.path) {
            return managedUV
        }

        if let existing = findSystemUV() {
            return existing
        }

        let installDirectory = try toolBinDirectory
        let script = "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR='\(installDirectory.path)' sh"
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: try environment(),
            currentDirectoryURL: try toolRoot
        )
        guard result.exitCode == 0, FileManager.default.isExecutableFile(atPath: managedUV.path) else {
            throw ToolInstallError.uvInstallFailed(result.combinedOutput)
        }
        return managedUV
    }

    private func findSystemUV() -> URL? {
        ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "/usr/bin/uv"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum ToolInstallError: Error, LocalizedError {
    case uvInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .uvInstallFailed(let output):
            "uv installation failed: \(output)"
        }
    }
}
