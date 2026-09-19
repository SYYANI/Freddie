#if DEBUG && os(macOS)
import AppKit
import Foundation
import PDFKit

struct PDFTranslationDebugExportRequest {
    var paperID: UUID
    var paperTitle: String
    var arxivID: String?
    var doi: String?
    var originalAttachmentID: UUID?
    var translatedAttachmentID: UUID
    var originalPDFURL: URL?
    var translatedPDFURL: URL
    var diagnosticsURL: URL?
    var translatedLastPage: Int?
    var selection: PDFDebugRegionSelection
}

struct PDFTranslationDebugRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct PDFTranslationDebugManifest: Codable, Equatable {
    struct AppInfo: Codable, Equatable {
        var version: String
        var build: String
        var configuration: String
    }

    struct PaperInfo: Codable, Equatable {
        var id: UUID
        var title: String
        var arxivID: String?
        var doi: String?
    }

    struct TranslationInfo: Codable, Equatable {
        var originalAttachmentID: UUID?
        var translatedAttachmentID: UUID
        var originalFilename: String?
        var translatedFilename: String
        var translatedLastPage: Int?
    }

    struct SelectionInfo: Codable, Equatable {
        var pageIndex: Int
        var pageNumber: Int
        var translatedPageBounds: PDFTranslationDebugRect
        var translatedBounds: PDFTranslationDebugRect
        var normalizedBounds: PDFTranslationDebugRect
        var originalPageBounds: PDFTranslationDebugRect?
        var originalBounds: PDFTranslationDebugRect?
    }

    var schemaVersion: Int
    var exportedAt: Date
    var app: AppInfo
    var paper: PaperInfo
    var translation: TranslationInfo
    var selection: SelectionInfo
    var translatedText: String
    var originalText: String?
    var files: [String: String]
}

enum PDFTranslationDebugExportError: Error, LocalizedError {
    case exportDirectoryUnavailable
    case translatedPDFUnavailable
    case selectedPageUnavailable(Int)
    case invalidSelection
    case imageRenderingFailed

    var errorDescription: String? {
        switch self {
        case .exportDirectoryUnavailable:
            AppLocalization.localized("The selected PDF debug export folder is unavailable.")
        case .translatedPDFUnavailable:
            AppLocalization.localized("The translated PDF could not be opened for debug export.")
        case .selectedPageUnavailable(let pageNumber):
            AppLocalization.format("PDF page %d is unavailable for debug export.", pageNumber)
        case .invalidSelection:
            AppLocalization.localized("The selected PDF region is empty.")
        case .imageRenderingFailed:
            AppLocalization.localized("The selected PDF region could not be rendered.")
        }
    }
}

@MainActor
struct PDFTranslationDebugExporter {
    private let fileManager: FileManager
    private let bundle: Bundle

    init(fileManager: FileManager = .default, bundle: Bundle = .main) {
        self.fileManager = fileManager
        self.bundle = bundle
    }

    func export(
        _ request: PDFTranslationDebugExportRequest,
        to directoryURL: URL,
        exportedAt: Date = Date()
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PDFTranslationDebugExportError.exportDirectoryUnavailable
        }

        guard let translatedDocument = PDFDocument(url: request.translatedPDFURL) else {
            throw PDFTranslationDebugExportError.translatedPDFUnavailable
        }
        guard let translatedPage = translatedDocument.page(at: request.selection.pageIndex) else {
            throw PDFTranslationDebugExportError.selectedPageUnavailable(request.selection.pageIndex + 1)
        }

        let translatedPageBounds = translatedPage.bounds(for: .cropBox).standardized
        let translatedBounds = request.selection.selectedBounds
            .standardized
            .intersection(translatedPageBounds)
        guard translatedBounds.width > 0, translatedBounds.height > 0 else {
            throw PDFTranslationDebugExportError.invalidSelection
        }

        let normalizedBounds = Self.normalizedBounds(
            translatedBounds,
            within: translatedPageBounds
        )
        let originalDocument = request.originalPDFURL.flatMap(PDFDocument.init(url:))
        let originalPage = originalDocument?.page(at: request.selection.pageIndex)
        let originalPageBounds = originalPage?.bounds(for: .cropBox).standardized
        let originalBounds = originalPageBounds.map {
            Self.bounds(fromNormalized: normalizedBounds, within: $0)
        }

        let directoryName = exportDirectoryName(
            paperTitle: request.paperTitle,
            pageNumber: request.selection.pageIndex + 1,
            date: exportedAt
        )
        let destinationURL = directoryURL.appendingPathComponent(directoryName, isDirectory: true)
        let stagingURL = directoryURL.appendingPathComponent(
            ".\(directoryName).\(UUID().uuidString).tmp",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)

        var completed = false
        defer {
            if completed == false {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        var files: [String: String] = [:]
        try writePage(
            translatedPage,
            selectedBounds: translatedBounds,
            role: "translated",
            to: stagingURL,
            files: &files
        )

        let translatedText = extractedText(from: translatedPage, in: translatedBounds)
        try writeText(translatedText, filename: "translated-text.txt", to: stagingURL)
        files["translatedText"] = "translated-text.txt"

        var originalText: String?
        if let originalPage, let originalBounds {
            try writePage(
                originalPage,
                selectedBounds: originalBounds,
                role: "original",
                to: stagingURL,
                files: &files
            )
            let text = extractedText(from: originalPage, in: originalBounds)
            try writeText(text, filename: "original-text.txt", to: stagingURL)
            files["originalText"] = "original-text.txt"
            originalText = text
        }

        if let diagnosticsURL = request.diagnosticsURL,
           fileManager.fileExists(atPath: diagnosticsURL.path) {
            let filename = "babeldoc-diagnostics.json"
            try fileManager.copyItem(
                at: diagnosticsURL,
                to: stagingURL.appendingPathComponent(filename)
            )
            files["babelDocDiagnostics"] = filename
        }

        let manifest = PDFTranslationDebugManifest(
            schemaVersion: 1,
            exportedAt: exportedAt,
            app: .init(
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                configuration: "DEBUG"
            ),
            paper: .init(
                id: request.paperID,
                title: request.paperTitle,
                arxivID: request.arxivID,
                doi: request.doi
            ),
            translation: .init(
                originalAttachmentID: request.originalAttachmentID,
                translatedAttachmentID: request.translatedAttachmentID,
                originalFilename: request.originalPDFURL?.lastPathComponent,
                translatedFilename: request.translatedPDFURL.lastPathComponent,
                translatedLastPage: request.translatedLastPage
            ),
            selection: .init(
                pageIndex: request.selection.pageIndex,
                pageNumber: request.selection.pageIndex + 1,
                translatedPageBounds: PDFTranslationDebugRect(translatedPageBounds),
                translatedBounds: PDFTranslationDebugRect(translatedBounds),
                normalizedBounds: PDFTranslationDebugRect(normalizedBounds),
                originalPageBounds: originalPageBounds.map(PDFTranslationDebugRect.init),
                originalBounds: originalBounds.map(PDFTranslationDebugRect.init)
            ),
            translatedText: translatedText,
            originalText: originalText,
            files: files.merging(["manifest": "manifest.json"]) { current, _ in current }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: stagingURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        try fileManager.moveItem(at: stagingURL, to: destinationURL)
        completed = true
        return destinationURL
    }

    static func normalizedBounds(_ bounds: CGRect, within pageBounds: CGRect) -> CGRect {
        guard pageBounds.width > 0, pageBounds.height > 0 else { return .zero }
        let clipped = bounds.standardized.intersection(pageBounds.standardized)
        return CGRect(
            x: (clipped.minX - pageBounds.minX) / pageBounds.width,
            y: (clipped.minY - pageBounds.minY) / pageBounds.height,
            width: clipped.width / pageBounds.width,
            height: clipped.height / pageBounds.height
        )
    }

    static func bounds(fromNormalized normalizedBounds: CGRect, within pageBounds: CGRect) -> CGRect {
        CGRect(
            x: pageBounds.minX + normalizedBounds.minX * pageBounds.width,
            y: pageBounds.minY + normalizedBounds.minY * pageBounds.height,
            width: normalizedBounds.width * pageBounds.width,
            height: normalizedBounds.height * pageBounds.height
        )
        .intersection(pageBounds)
        .standardized
    }

    private func writePage(
        _ page: PDFPage,
        selectedBounds: CGRect,
        role: String,
        to directoryURL: URL,
        files: inout [String: String]
    ) throws {
        let regionFilename = "\(role)-region.png"
        try renderedRegionPNG(page: page, selectedBounds: selectedBounds).write(
            to: directoryURL.appendingPathComponent(regionFilename),
            options: .atomic
        )
        files["\(role)RegionImage"] = regionFilename

        if let pageData = page.dataRepresentation {
            let pageFilename = "\(role)-page.pdf"
            try pageData.write(
                to: directoryURL.appendingPathComponent(pageFilename),
                options: .atomic
            )
            files["\(role)PagePDF"] = pageFilename
        }
    }

    private func renderedRegionPNG(page: PDFPage, selectedBounds: CGRect) throws -> Data {
        let pageBounds = page.bounds(for: .cropBox).standardized
        let transform = page.transform(for: .cropBox)
        let transformedPageBounds = pageBounds.applying(transform).standardized
        let transformedSelection = selectedBounds
            .applying(transform)
            .standardized
            .offsetBy(dx: -transformedPageBounds.minX, dy: -transformedPageBounds.minY)
        let canvasBounds = CGRect(origin: .zero, size: transformedPageBounds.size)
        let cropBounds = transformedSelection
            .insetBy(dx: -24, dy: -24)
            .intersection(canvasBounds)
            .standardized
        guard cropBounds.width > 0, cropBounds.height > 0 else {
            throw PDFTranslationDebugExportError.imageRenderingFailed
        }

        let scale: CGFloat = 2
        let pixelWidth = max(1, Int(ceil(cropBounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(cropBounds.height * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PDFTranslationDebugExportError.imageRenderingFailed
        }

        let requestedSize = CGSize(
            width: transformedPageBounds.width * scale,
            height: transformedPageBounds.height * scale
        )
        let pageImage = page.thumbnail(of: requestedSize, for: .cropBox)
        let outputBounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        NSColor.white.setFill()
        outputBounds.fill()
        pageImage.draw(
            in: CGRect(
                x: -cropBounds.minX * scale,
                y: -cropBounds.minY * scale,
                width: transformedPageBounds.width * scale,
                height: transformedPageBounds.height * scale
            ),
            from: CGRect(origin: .zero, size: pageImage.size),
            operation: .copy,
            fraction: 1
        )

        let highlightedBounds = CGRect(
            x: (transformedSelection.minX - cropBounds.minX) * scale,
            y: (transformedSelection.minY - cropBounds.minY) * scale,
            width: transformedSelection.width * scale,
            height: transformedSelection.height * scale
        )
        NSColor.systemRed.withAlphaComponent(0.14).setFill()
        highlightedBounds.fill()
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: highlightedBounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PDFTranslationDebugExportError.imageRenderingFailed
        }
        return data
    }

    private func extractedText(from page: PDFPage, in bounds: CGRect) -> String {
        page.selection(for: bounds)?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func writeText(_ text: String, filename: String, to directoryURL: URL) throws {
        try Data(text.utf8).write(
            to: directoryURL.appendingPathComponent(filename),
            options: .atomic
        )
    }

    private func exportDirectoryName(paperTitle: String, pageNumber: Int, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let slug = filenameSlug(paperTitle)
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "Freddie-PDF-Debug-\(slug)-p\(pageNumber)-\(formatter.string(from: date))-\(suffix)"
    }

    private func filenameSlug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var lastWasSeparator = false

        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if lastWasSeparator == false, result.isEmpty == false {
                result.append("-")
                lastWasSeparator = true
            }
            if result.count >= 48 { break }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "paper" : trimmed
    }
}
#endif
