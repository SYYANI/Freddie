import PDFKit

/// BabelDOC renders translated content in crop-local coordinates. PDFs whose
/// CropBox starts away from the origin therefore need matching zero-origin
/// page boxes; otherwise PDF viewers apply the original crop offset a second
/// time and clip content along the page edges.
struct TranslatedPDFPageBoundsNormalizer {
    private static let originTolerance: CGFloat = 0.001

    @discardableResult
    static func normalize(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let document = PDFDocument(url: url) else {
            throw TranslatedPDFPageBoundsError.failedToOpenFile(url.path)
        }
        guard normalizeBounds(in: document) else { return false }

        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).normalized.pdf"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard document.write(to: temporaryURL) else {
            throw TranslatedPDFPageBoundsError.failedToWriteOutput(url.path)
        }
        _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        return true
    }

    @discardableResult
    static func normalizeBounds(in document: PDFDocument) -> Bool {
        var changed = false
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let cropBounds = page.bounds(for: .cropBox).standardized
            guard cropBounds.width > 0,
                  cropBounds.height > 0,
                  abs(cropBounds.origin.x) > originTolerance
                    || abs(cropBounds.origin.y) > originTolerance else {
                continue
            }

            let normalizedBounds = CGRect(origin: .zero, size: cropBounds.size)
            for displayBox in [
                PDFDisplayBox.mediaBox,
                .cropBox,
                .bleedBox,
                .trimBox,
                .artBox,
            ] {
                page.setBounds(normalizedBounds, for: displayBox)
            }
            changed = true
        }
        return changed
    }
}

struct PDFMerger {
    static func merge(existing: PDFDocument, increment: URL, output: URL) throws -> URL {
        guard let incrementDoc = PDFDocument(url: increment) else {
            throw PDFMergerError.failedToOpenFile(increment.path)
        }

        let merged = PDFDocument()
        var index = 0
        for i in 0..<existing.pageCount {
            guard let page = existing.page(at: i) else { continue }
            merged.insert(page, at: index)
            index += 1
        }
        for i in 0..<incrementDoc.pageCount {
            guard let page = incrementDoc.page(at: i) else { continue }
            merged.insert(page, at: index)
            index += 1
        }

        guard merged.write(to: output) else {
            throw PDFMergerError.failedToWriteOutput(output.path)
        }
        return output
    }

    static func merge(existing: URL, increment: URL, output: URL) throws -> URL {
        guard let existingDoc = PDFDocument(url: existing) else {
            throw PDFMergerError.failedToOpenFile(existing.path)
        }
        return try merge(existing: existingDoc, increment: increment, output: output)
    }

    static func mergeInBackground(existing: URL, increment: URL, output: URL) async throws -> URL {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try merge(existing: existing, increment: increment, output: output)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

enum TranslatedPDFPageBoundsError: Error, LocalizedError {
    case failedToOpenFile(String)
    case failedToWriteOutput(String)

    var errorDescription: String? {
        switch self {
        case .failedToOpenFile(let path):
            AppLocalization.format("Failed to open PDF file: %@", path)
        case .failedToWriteOutput(let path):
            AppLocalization.format("Failed to write translated PDF: %@", path)
        }
    }
}

enum PDFMergerError: Error, LocalizedError {
    case failedToOpenFile(String)
    case failedToWriteOutput(String)

    var errorDescription: String? {
        switch self {
        case .failedToOpenFile(let path):
            AppLocalization.format("Failed to open PDF file: %@", path)
        case .failedToWriteOutput(let path):
            AppLocalization.format("Failed to write merged PDF: %@", path)
        }
    }
}
