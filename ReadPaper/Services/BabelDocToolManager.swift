import Foundation
import OSLog

enum BabelDocInstallSource: String, CaseIterable, Identifiable, Sendable {
    case official
    case tsinghua

    static let userDefaultsKey = "ReadPaper.Settings.BabelDocInstallSource"

    var id: String { rawValue }

    var defaultIndexURL: URL {
        switch self {
        case .official:
            URL(string: "https://pypi.org/simple")!
        case .tsinghua:
            URL(string: "https://pypi.tuna.tsinghua.edu.cn/simple")!
        }
    }

    var metadataURL: URL {
        switch self {
        case .official:
            URL(string: "https://pypi.org/pypi/BabelDOC/json")!
        case .tsinghua:
            URL(string: "https://pypi.tuna.tsinghua.edu.cn/pypi/BabelDOC/json")!
        }
    }

    var simplePackageIndexURL: URL {
        defaultIndexURL.appendingPathComponent("babeldoc", isDirectory: true)
    }

    static func stored(userDefaults: UserDefaults = .standard) -> Self {
        guard
            let rawValue = userDefaults.string(forKey: userDefaultsKey),
            let source = Self(rawValue: rawValue)
        else {
            return .official
        }
        return source
    }
}

struct BabelDocToolManager {
    static let toolName = "BabelDOC"
    static let latestVersionKeyword = "latest"

    let fileStore: PaperFileStore
    let runner: ProcessRunner
    let session: URLSession
    let installSource: BabelDocInstallSource
    let logger = Logger(subsystem: "com.yiyan.ReadPaper", category: "BabelDocToolManager")

    init(
        fileStore: PaperFileStore = PaperFileStore(),
        runner: ProcessRunner = ProcessRunner(),
        session: URLSession = .shared,
        installSource: BabelDocInstallSource = .stored()
    ) {
        self.fileStore = fileStore
        self.runner = runner
        self.session = session
        self.installSource = installSource
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

    var cacheDirectory: URL {
        get throws {
            try toolRoot.appendingPathComponent("cache", isDirectory: true)
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

    func hasManagedInstallation() throws -> Bool {
        fileStore.fileManager.fileExists(atPath: try toolRoot.path)
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

    func latestPublishedVersion() async throws -> String {
        do {
            return try await latestPublishedVersionFromSimpleIndex()
        } catch {
            logger.error("Falling back to BabelDOC metadata lookup after simple index lookup failed: \(error.localizedDescription, privacy: .public)")
            return try await latestPublishedVersionFromMetadata()
        }
    }

    func resolvedInstallVersion(_ requestedVersion: String) async throws -> String {
        let trimmed = requestedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(Self.latestVersionKeyword) == .orderedSame {
            return try await latestPublishedVersion()
        }
        return trimmed
    }

    func installOrUpdateBabelDOC(version: String) async throws -> ProcessResult {
        do {
            try prepareDirectories()
            let uvURL = try await ensureUV()
            let resolvedVersion = try await resolvedInstallVersion(version)
            let result = try await runner.run(
                executableURL: uvURL,
                arguments: Self.installArguments(version: resolvedVersion, source: installSource),
                environment: try environment(),
                currentDirectoryURL: try toolRoot
            )
            guard result.exitCode == 0 else {
                logger.error("BabelDOC installation failed: \(result.combinedOutput, privacy: .public)")
                return result
            }
            return result
        } catch {
            if Self.isCancellation(error) || Task.isCancelled {
                do {
                    try removeDownloadedCache()
                } catch {
                    logger.error("Failed to clear BabelDOC download cache after cancellation: \(error.localizedDescription, privacy: .public)")
                }
            }
            throw error
        }
    }

    func removeDownloadedCache() throws {
        try removeManagedItem(at: cacheDirectory)
    }

    func removeBabelDOC() throws {
        try removeManagedItem(at: toolRoot)
    }

    private func prepareDirectories() throws {
        let fm = FileManager.default
        for directory in [
            try toolRoot,
            try toolBinDirectory,
            try toolRoot.appendingPathComponent("tools", isDirectory: true),
            try toolRoot.appendingPathComponent("python", isDirectory: true),
            try cacheDirectory
        ] {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    private func latestPublishedVersionFromSimpleIndex() async throws -> String {
        var request = URLRequest(url: installSource.simplePackageIndexURL)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolInstallError.latestVersionLookupFailed("Missing HTTP response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ToolInstallError.latestVersionLookupFailed("HTTP \(httpResponse.statusCode)")
        }

        let versions = Self.extractVersionsFromSimpleIndex(data)
        guard let version = versions.max()?.rawValue else {
            throw ToolInstallError.latestVersionLookupFailed("No BabelDOC versions found in simple index.")
        }
        return version
    }

    private func latestPublishedVersionFromMetadata() async throws -> String {
        var request = URLRequest(url: installSource.metadataURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolInstallError.latestVersionLookupFailed("Missing HTTP response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ToolInstallError.latestVersionLookupFailed("HTTP \(httpResponse.statusCode)")
        }

        let payload = try JSONDecoder().decode(BabelDocReleaseMetadata.self, from: data)
        if let version = payload.releaseVersions.compactMap(PythonPackageVersion.init).max()?.rawValue {
            return version
        }
        guard let version = Self.normalizedExplicitVersion(payload.info.version) else {
            throw ToolInstallError.invalidLatestBabelDocVersion(payload.info.version)
        }
        return version
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

    private func removeManagedItem(at url: URL) throws {
        let fm = fileStore.fileManager
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    private static func normalizedExplicitVersion(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        guard trimmed.caseInsensitiveCompare(latestVersionKeyword) != .orderedSame else {
            return nil
        }
        return trimmed
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

    private static func extractVersionsFromSimpleIndex(_ data: Data) -> Set<PythonPackageVersion> {
        let page = String(decoding: data, as: UTF8.self)
        var matches = Set<PythonPackageVersion>()

        for pattern in [
            #"(?i)\bbabeldoc-([0-9][A-Za-z0-9.!+_]*)-[^"'<>/\s]+\.whl\b"#,
            #"(?i)\bbabeldoc-([0-9][A-Za-z0-9.!+_]*)\.(?:tar\.gz|zip)\b"#
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let nsRange = NSRange(page.startIndex..<page.endIndex, in: page)
            for match in regex.matches(in: page, range: nsRange) {
                guard
                    match.numberOfRanges >= 2,
                    let range = Range(match.range(at: 1), in: page),
                    let version = PythonPackageVersion(String(page[range]))
                else {
                    continue
                }
                matches.insert(version)
            }
        }

        return matches
    }

    static func installArguments(version: String, source: BabelDocInstallSource) -> [String] {
        [
            "tool", "install",
            "--force",
            "--default-index", source.defaultIndexURL.absoluteString,
            "BabelDOC==\(version)"
        ]
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
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

private struct BabelDocReleaseMetadata: Decodable {
    struct Info: Decodable {
        let version: String
    }

    let info: Info
    let releases: [String: [ReleaseFile]]?

    var releaseVersions: [String] {
        releases.map { Array($0.keys) } ?? []
    }
}

private struct ReleaseFile: Decodable {}

private struct PythonPackageVersion: Comparable, Hashable {
    struct PreRelease: Hashable {
        enum Label: Int {
            case alpha
            case beta
            case releaseCandidate
        }

        let label: Label
        let number: Int
    }

    private enum Stage: Int {
        case development
        case preRelease
        case final
        case postRelease
    }

    let rawValue: String

    private let release: [Int]
    private let preRelease: PreRelease?
    private let postRelease: Int?
    private let developmentRelease: Int?

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let canonical = trimmed.split(separator: "+", maxSplits: 1).first.map(String.init) ?? trimmed
        let pattern = #"(?i)^v?(\d+(?:\.\d+)*)(?:(a|b|rc)(\d*))?(?:\.post(\d+))?(?:\.dev(\d+))?$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: canonical,
                range: NSRange(canonical.startIndex..<canonical.endIndex, in: canonical)
            )
        else {
            return nil
        }

        func capture(_ index: Int) -> String? {
            guard
                match.numberOfRanges > index,
                let range = Range(match.range(at: index), in: canonical)
            else {
                return nil
            }
            return String(canonical[range])
        }

        guard let releaseString = capture(1) else {
            return nil
        }

        let release = releaseString
            .split(separator: ".")
            .compactMap { Int($0) }
        guard release.isEmpty == false else {
            return nil
        }

        let preRelease: PreRelease?
        if let labelString = capture(2)?.lowercased() {
            let label: PreRelease.Label?
            switch labelString {
            case "a":
                label = .alpha
            case "b":
                label = .beta
            case "rc":
                label = .releaseCandidate
            default:
                label = nil
            }

            guard let label else {
                return nil
            }

            preRelease = PreRelease(
                label: label,
                number: Int(capture(3) ?? "") ?? 0
            )
        } else {
            preRelease = nil
        }

        self.rawValue = trimmed
        self.release = release
        self.preRelease = preRelease
        self.postRelease = Int(capture(4) ?? "")
        self.developmentRelease = Int(capture(5) ?? "")
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let maxCount = max(lhs.release.count, rhs.release.count)
        for index in 0..<maxCount {
            let left = index < lhs.release.count ? lhs.release[index] : 0
            let right = index < rhs.release.count ? rhs.release[index] : 0
            if left != right {
                return left < right
            }
        }

        let lhsStage = lhs.stage
        let rhsStage = rhs.stage
        if lhsStage != rhsStage {
            return lhsStage.rawValue < rhsStage.rawValue
        }

        switch lhsStage {
        case .development:
            let preComparison = compareOptionalPreRelease(lhs.preRelease, rhs.preRelease, nilIsLower: true)
            if preComparison != 0 {
                return preComparison < 0
            }
            return (lhs.developmentRelease ?? 0) < (rhs.developmentRelease ?? 0)
        case .preRelease:
            return compareOptionalPreRelease(lhs.preRelease, rhs.preRelease, nilIsLower: false) < 0
        case .final:
            return false
        case .postRelease:
            return (lhs.postRelease ?? 0) < (rhs.postRelease ?? 0)
        }
    }

    private var stage: Stage {
        if developmentRelease != nil {
            return .development
        }
        if preRelease != nil {
            return .preRelease
        }
        if postRelease != nil {
            return .postRelease
        }
        return .final
    }

    private static func compareOptionalPreRelease(
        _ lhs: PreRelease?,
        _ rhs: PreRelease?,
        nilIsLower: Bool
    ) -> Int {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left.label != right.label {
                return left.label.rawValue < right.label.rawValue ? -1 : 1
            }
            if left.number != right.number {
                return left.number < right.number ? -1 : 1
            }
            return 0
        case (nil, nil):
            return 0
        case (nil, _):
            return nilIsLower ? -1 : 1
        case (_, nil):
            return nilIsLower ? 1 : -1
        }
    }
}

enum ToolInstallError: Error, LocalizedError {
    case uvInstallFailed(String)
    case invalidBabelDocLauncher(String)
    case latestVersionLookupFailed(String)
    case invalidLatestBabelDocVersion(String)

    var errorDescription: String? {
        switch self {
        case .uvInstallFailed(let output):
            AppLocalization.format("uv installation failed: %@", output)
        case .invalidBabelDocLauncher(let path):
            AppLocalization.format("BabelDOC launcher is invalid: %@", path)
        case .latestVersionLookupFailed(let details):
            AppLocalization.format("Failed to fetch the latest BabelDOC version: %@", details)
        case .invalidLatestBabelDocVersion(let version):
            AppLocalization.format("The latest BabelDOC version could not be parsed: %@", version)
        }
    }
}
