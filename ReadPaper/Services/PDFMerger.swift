import PDFKit

struct PDFMerger {
    static func merge(existing: URL, increment: URL, output: URL) throws -> URL {
        guard let existingDoc = PDFDocument(url: existing) else {
            throw PDFMergerError.failedToOpenFile(existing.path)
        }
        guard let incrementDoc = PDFDocument(url: increment) else {
            throw PDFMergerError.failedToOpenFile(increment.path)
        }

        let merged = PDFDocument()
        var index = 0
        for i in 0..<existingDoc.pageCount {
            guard let page = existingDoc.page(at: i) else { continue }
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
