import Foundation
import PDFKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PDFAnnotationKind: String, Codable, Equatable, Sendable {
    case highlight
    case underline
    case strikeOut
    case ink
    case text
}

struct PDFAnnotationPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct PDFAnnotationRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        let standardized = rect.standardized
        x = standardized.origin.x
        y = standardized.origin.y
        width = standardized.width
        height = standardized.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct PDFAnnotationColorValue: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    func displayAdjusted(inverted: Bool) -> Self {
        guard inverted else { return self }
        return Self(
            red: 1 - red,
            green: 1 - green,
            blue: 1 - blue,
            alpha: alpha
        )
    }

    #if os(macOS)
    func platformColor(inverted: Bool) -> NSColor {
        let value = displayAdjusted(inverted: inverted)
        return NSColor(
            calibratedRed: value.red,
            green: value.green,
            blue: value.blue,
            alpha: value.alpha
        )
    }
    #else
    func platformColor(inverted: Bool) -> UIColor {
        let value = displayAdjusted(inverted: inverted)
        return UIColor(
            red: value.red,
            green: value.green,
            blue: value.blue,
            alpha: value.alpha
        )
    }
    #endif
}

enum PDFAnnotationColorPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case green
    case blue
    case red
    case purple

    var id: String { rawValue }

    func color(for kind: PDFAnnotationKind) -> PDFAnnotationColorValue {
        let alpha = kind == .highlight ? 0.36 : 0.92
        switch self {
        case .yellow:
            return PDFAnnotationColorValue(red: 1.0, green: 0.78, blue: 0.08, alpha: alpha)
        case .green:
            return PDFAnnotationColorValue(red: 0.22, green: 0.72, blue: 0.32, alpha: alpha)
        case .blue:
            return PDFAnnotationColorValue(red: 0.12, green: 0.48, blue: 0.96, alpha: alpha)
        case .red:
            return PDFAnnotationColorValue(red: 0.92, green: 0.20, blue: 0.20, alpha: alpha)
        case .purple:
            return PDFAnnotationColorValue(red: 0.58, green: 0.30, blue: 0.90, alpha: alpha)
        }
    }
}

struct PDFAnnotationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var pageIndex: Int
    var kind: PDFAnnotationKind
    var bounds: PDFAnnotationRect
    var color: PDFAnnotationColorValue
    var lineWidth: Double
    var contents: String?
    var quote: String?
    var quadrilateralPoints: [PDFAnnotationPoint]
    var inkPaths: [[PDFAnnotationPoint]]
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        kind: PDFAnnotationKind,
        bounds: CGRect,
        color: PDFAnnotationColorValue,
        lineWidth: Double = 1,
        contents: String? = nil,
        quote: String? = nil,
        quadrilateralPoints: [CGPoint] = [],
        inkPaths: [[CGPoint]] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.pageIndex = max(0, pageIndex)
        self.kind = kind
        self.bounds = PDFAnnotationRect(bounds)
        self.color = color
        self.lineWidth = max(0.5, lineWidth)
        self.contents = contents
        self.quote = quote
        self.quadrilateralPoints = quadrilateralPoints.map(PDFAnnotationPoint.init)
        self.inkPaths = inkPaths.map { $0.map(PDFAnnotationPoint.init) }
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

struct PDFAnnotationSidecar: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var paperID: UUID
    var attachmentID: UUID
    var annotations: [PDFAnnotationRecord]
    var modifiedAt: Date

    init(
        paperID: UUID,
        attachmentID: UUID,
        annotations: [PDFAnnotationRecord],
        modifiedAt: Date = Date()
    ) {
        version = Self.currentVersion
        self.paperID = paperID
        self.attachmentID = attachmentID
        self.annotations = annotations
        self.modifiedAt = modifiedAt
    }
}

enum PDFAnnotationStoreError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case mismatchedScope
    case unableToOpenPDF
    case unableToWritePDF
    case sourceAndDestinationMatch

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return AppLocalization.localized("This PDF annotation file was created by a newer version of Freddie.")
        case .mismatchedScope:
            return AppLocalization.localized("The PDF annotation file does not match this attachment.")
        case .unableToOpenPDF:
            return AppLocalization.localized("The PDF could not be opened for annotation export.")
        case .unableToWritePDF:
            return AppLocalization.localized("The annotated PDF could not be written.")
        case .sourceAndDestinationMatch:
            return AppLocalization.localized("Choose a different location to preserve the original PDF.")
        }
    }
}

struct PDFAnnotationStore {
    var fileStore: PaperFileStore = PaperFileStore()

    func sidecarURL(paperID: UUID, attachmentID: UUID) throws -> URL {
        try fileStore.notesDirectory(for: paperID)
            .appendingPathComponent("pdf-annotations-\(attachmentID.uuidString).json")
    }

    func load(paperID: UUID, attachmentID: UUID) throws -> [PDFAnnotationRecord] {
        let url = try sidecarURL(paperID: paperID, attachmentID: attachmentID)
        guard fileStore.fileManager.fileExists(atPath: url.path) else { return [] }

        let sidecar = try JSONDecoder.pdfAnnotationDecoder.decode(
            PDFAnnotationSidecar.self,
            from: Data(contentsOf: url)
        )
        guard sidecar.version <= PDFAnnotationSidecar.currentVersion else {
            throw PDFAnnotationStoreError.unsupportedVersion(sidecar.version)
        }
        guard sidecar.paperID == paperID, sidecar.attachmentID == attachmentID else {
            throw PDFAnnotationStoreError.mismatchedScope
        }
        return sidecar.annotations.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func save(_ annotations: [PDFAnnotationRecord], paperID: UUID, attachmentID: UUID) throws {
        let sidecar = PDFAnnotationSidecar(
            paperID: paperID,
            attachmentID: attachmentID,
            annotations: annotations
        )
        let data = try JSONEncoder.pdfAnnotationEncoder.encode(sidecar)
        try data.write(
            to: sidecarURL(paperID: paperID, attachmentID: attachmentID),
            options: .atomic
        )
    }
}

@MainActor
enum PDFAnnotationRenderer {
    static let authorPrefix = "Freddie:"

    static func makeAnnotation(
        from record: PDFAnnotationRecord,
        invertedColor: Bool
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: record.bounds.cgRect,
            forType: subtype(for: record.kind),
            withProperties: nil
        )
        annotation.color = record.color.platformColor(inverted: invertedColor)
        annotation.userName = authorPrefix + record.id.uuidString
        annotation.modificationDate = record.modifiedAt
        annotation.contents = record.contents
        annotation.shouldDisplay = true
        annotation.shouldPrint = true

        if record.quadrilateralPoints.isEmpty == false {
            annotation.quadrilateralPoints = record.quadrilateralPoints.map {
                platformPointValue($0.cgPoint)
            }
        }

        if record.kind == .ink {
            let border = PDFBorder()
            border.lineWidth = record.lineWidth
            annotation.border = border
            addInkPaths(record.inkPaths, bounds: record.bounds.cgRect, to: annotation)
        }
        return annotation
    }

    static func recordID(for annotation: PDFAnnotation) -> UUID? {
        guard let userName = annotation.userName,
              userName.hasPrefix(authorPrefix)
        else {
            return nil
        }
        return UUID(uuidString: String(userName.dropFirst(authorPrefix.count)))
    }

    private static func subtype(for kind: PDFAnnotationKind) -> PDFAnnotationSubtype {
        switch kind {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        case .ink: return .ink
        case .text: return .text
        }
    }

    private static func platformPointValue(_ point: CGPoint) -> NSValue {
        #if os(macOS)
        return NSValue(point: point)
        #else
        return NSValue(cgPoint: point)
        #endif
    }

    private static func addInkPaths(
        _ paths: [[PDFAnnotationPoint]],
        bounds: CGRect,
        to annotation: PDFAnnotation
    ) {
        for points in paths where points.isEmpty == false {
            #if os(macOS)
            let path = NSBezierPath()
            #else
            let path = UIBezierPath()
            #endif
            let localizedPoints = points.map {
                CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)
            }
            guard let first = localizedPoints.first else { continue }
            path.move(to: first)
            for point in localizedPoints.dropFirst() {
                #if os(macOS)
                path.line(to: point)
                #else
                path.addLine(to: point)
                #endif
            }
            annotation.add(path)
        }
    }
}

@MainActor
struct PDFAnnotationExporter {
    var store: PDFAnnotationStore = PDFAnnotationStore()
    var fileManager: FileManager = .default

    @discardableResult
    func export(
        sourcePDFURL: URL,
        paperID: UUID,
        attachmentID: UUID,
        destinationURL: URL
    ) throws -> Int {
        guard sourcePDFURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw PDFAnnotationStoreError.sourceAndDestinationMatch
        }
        guard let document = PDFDocument(url: sourcePDFURL) else {
            throw PDFAnnotationStoreError.unableToOpenPDF
        }

        let records = try store.load(paperID: paperID, attachmentID: attachmentID)
        var exportedRecordCount = 0
        for record in records {
            guard let page = document.page(at: record.pageIndex) else { continue }
            page.addAnnotation(PDFAnnotationRenderer.makeAnnotation(from: record, invertedColor: false))
            exportedRecordCount += 1
        }

        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("Freddie-Annotated-\(UUID().uuidString).pdf")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard document.write(to: temporaryURL) else {
            throw PDFAnnotationStoreError.unableToWritePDF
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        return exportedRecordCount
    }
}

private extension JSONEncoder {
    static var pdfAnnotationEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var pdfAnnotationDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
