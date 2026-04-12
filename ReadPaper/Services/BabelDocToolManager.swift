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

    var progressBridgeScriptURL: URL {
        get throws {
            try toolRoot.appendingPathComponent("babeldoc_progress_bridge.py")
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

    func babelDocPythonExecutableURL() throws -> URL {
        let launcherURL = try babelDocExecutableURL.resolvingSymlinksInPath()
        let fm = FileManager.default

        for candidateName in ["python3", "python"] {
            let sibling = launcherURL.deletingLastPathComponent().appendingPathComponent(candidateName)
            if fm.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }

        let launcher = try String(contentsOf: launcherURL, encoding: .utf8)
        if let execPath = Self.extractExecPath(from: launcher) {
            let direct = URL(fileURLWithPath: execPath)
            if fm.isExecutableFile(atPath: direct.path) {
                return direct
            }
        }

        if let shebangPath = try Self.extractShebangExecutable(from: launcher, resolveExecutable: resolveExecutable(named:)) {
            return shebangPath
        }

        throw ToolInstallError.invalidBabelDocLauncher(launcherURL.path)
    }

    func ensureProgressBridgeScript() throws -> URL {
        try prepareDirectories()
        let scriptURL = try progressBridgeScriptURL
        let contents = Self.progressBridgeScript

        if
            FileManager.default.fileExists(atPath: scriptURL.path),
            let existing = try? String(contentsOf: scriptURL, encoding: .utf8),
            existing == contents
        {
            return scriptURL
        }

        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        return scriptURL
    }

    func detect() throws -> ToolInstallStatus {
        if FileManager.default.isExecutableFile(atPath: try babelDocExecutableURL.path) {
            return .ready
        }
        return .missing
    }

    func installedVersion() async throws -> String? {
        let executableURL = try babelDocExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        let result = try await runner.run(
            executableURL: executableURL,
            arguments: ["--version"],
            environment: try environment(),
            currentDirectoryURL: try toolRoot
        )

        guard result.exitCode == 0 else {
            return nil
        }

        return Self.parseInstalledVersion(from: result.combinedOutput)
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

    private func resolveExecutable(named executableName: String) throws -> URL? {
        let path = try environment()["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fm = FileManager.default
        for directory in path.split(separator: ":").map(String.init) where directory.isEmpty == false {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executableName)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func extractExecPath(from launcher: String) -> String? {
        for line in launcher.split(whereSeparator: \.isNewline) {
            let rawLine = String(line)
            guard rawLine.contains("exec") else { continue }
            if let match = rawLine.range(of: #"'([^']+/python[^']*)'"#, options: .regularExpression) {
                let captured = String(rawLine[match]).dropFirst().dropLast()
                return String(captured)
            }
            if let match = rawLine.range(of: #"\"([^\"]+/python[^\"]*)\""#, options: .regularExpression) {
                let captured = String(rawLine[match]).dropFirst().dropLast()
                return String(captured)
            }
        }
        return nil
    }

    private static func extractShebangExecutable(
        from launcher: String,
        resolveExecutable: (String) throws -> URL?
    ) throws -> URL? {
        guard
            let firstLine = launcher
                .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            firstLine.hasPrefix("#!")
        else {
            return nil
        }

        let interpreterSpec = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        let components = interpreterSpec.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = components.first, command.isEmpty == false else {
            return nil
        }

        if command == "/usr/bin/env" {
            guard let executableName = components.dropFirst().first(where: { $0.hasPrefix("-") == false }) else {
                return nil
            }
            return try resolveExecutable(executableName)
        }

        return URL(fileURLWithPath: command)
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

    private static func parseInstalledVersion(from output: String) -> String? {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOutput.isEmpty == false else {
            return nil
        }

        let lines = trimmedOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        for line in lines {
            if let range = line.range(of: #"(?i)\b\d+\.\d+\.\d+(?:[-+._A-Za-z0-9]*)?\b"#, options: .regularExpression) {
                return String(line[range])
            }
        }

        return lines.first
    }

    private static let progressBridgeScript = #"""
import asyncio
import contextlib
import json
import logging
import multiprocessing as mp
import sys

import babeldoc.format.pdf.high_level
import babeldoc.main as babeldoc_main

READPAPER_PREFIX = "__READPAPER_BABELDOC_EVENT__"
STATE = {"error": None}


def sanitize_event(event):
    event_type = event.get("type")
    if not event_type:
        return None

    sanitized = {"type": event_type}
    for key in (
        "stage",
        "stage_current",
        "stage_total",
        "part_index",
        "total_parts",
        "stage_progress",
        "overall_progress",
    ):
        value = event.get(key)
        if value is None:
            continue
        if key in ("stage_progress", "overall_progress"):
            try:
                sanitized[key] = float(value)
            except (TypeError, ValueError):
                continue
        else:
            sanitized[key] = value

    if event_type == "error":
        sanitized["error"] = str(event.get("error", "Unknown BabelDOC error"))
        STATE["error"] = sanitized["error"]

    return sanitized


def emit_event(event):
    sanitized = sanitize_event(event)
    if sanitized is None:
        return
    payload = json.dumps(sanitized, ensure_ascii=True, separators=(",", ":"))
    print(READPAPER_PREFIX + payload, flush=True)


def create_progress_handler(_translation_config, show_log=False):
    def progress_handler(event):
        emit_event(event)

    return contextlib.nullcontext(), progress_handler


async def run():
    babeldoc_main.create_progress_handler = create_progress_handler
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, force=True)
    await babeldoc_main.main()
    return 1 if STATE["error"] else 0


if __name__ == "__main__":
    if sys.platform in ("darwin", "win32"):
        try:
            mp.set_start_method("spawn")
        except RuntimeError:
            pass
    else:
        try:
            mp.set_start_method("fork")
        except RuntimeError:
            pass

    babeldoc.format.pdf.high_level.init()

    try:
        sys.exit(asyncio.run(run()))
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        print(f"BabelDOC bridge failed: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
"""#
}

enum ToolInstallError: Error, LocalizedError {
    case uvInstallFailed(String)
    case invalidBabelDocLauncher(String)

    var errorDescription: String? {
        switch self {
        case .uvInstallFailed(let output):
            AppLocalization.format("uv installation failed: %@", output)
        case .invalidBabelDocLauncher(let path):
            AppLocalization.format("BabelDOC launcher is invalid: %@", path)
        }
    }
}
