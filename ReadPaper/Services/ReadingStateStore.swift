import Foundation
import SwiftData

struct ReadingStateStore {
    @MainActor
    func state(for paperID: UUID, in modelContext: ModelContext) throws -> ReadingState? {
        let descriptor = FetchDescriptor<ReadingState>(
            predicate: #Predicate<ReadingState> { $0.paperID == paperID }
        )
        let states = try modelContext.fetch(descriptor).sorted { $0.modifiedAt > $1.modifiedAt }
        return states.first
    }

    @MainActor
    func upsertState(
        for paperID: UUID,
        attachmentID: UUID?,
        readerMode: ReaderMode,
        pageIndex: Int,
        scrollRatio: Double,
        zoomScale: Double = 1,
        htmlAnchor: String? = nil,
        in modelContext: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<ReadingState>(
            predicate: #Predicate<ReadingState> { $0.paperID == paperID }
        )
        let states = try modelContext.fetch(descriptor).sorted { $0.modifiedAt > $1.modifiedAt }
        let readingState = states.first ?? ReadingState(paperID: paperID)

        if states.isEmpty {
            modelContext.insert(readingState)
        } else {
            for duplicate in states.dropFirst() {
                modelContext.delete(duplicate)
            }
        }

        let normalizedPageIndex = max(0, pageIndex)
        let normalizedScrollRatio = Self.clampedScrollRatio(scrollRatio)

        guard readingState.attachmentID != attachmentID ||
                readingState.readerMode != readerMode ||
                readingState.pageIndex != normalizedPageIndex ||
                readingState.scrollRatio != normalizedScrollRatio ||
                readingState.zoomScale != zoomScale ||
                readingState.htmlAnchor != htmlAnchor ||
                states.count > 1 else {
            return
        }

        readingState.attachmentID = attachmentID
        readingState.readerMode = readerMode
        readingState.pageIndex = normalizedPageIndex
        readingState.scrollRatio = normalizedScrollRatio
        readingState.zoomScale = zoomScale
        readingState.htmlAnchor = htmlAnchor
        readingState.modifiedAt = Date()
        try modelContext.save()
    }

    static func resolvedReaderMode(
        preferredMode: ReaderMode?,
        hasHTML: Bool,
        hasPDF: Bool,
        hasTranslatedPDF: Bool
    ) -> ReaderMode {
        if let preferredMode,
           supports(
                preferredMode,
                hasHTML: hasHTML,
                hasPDF: hasPDF,
                hasTranslatedPDF: hasTranslatedPDF
           ) {
            return preferredMode
        }
        if hasPDF {
            return .pdf
        }
        if hasHTML {
            return .html
        }
        if hasTranslatedPDF {
            return .translatedPDF
        }
        return .pdf
    }

    static func clampedScrollRatio(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return (clamped * 1000).rounded() / 1000
    }

    private static func supports(
        _ mode: ReaderMode,
        hasHTML: Bool,
        hasPDF: Bool,
        hasTranslatedPDF: Bool
    ) -> Bool {
        switch mode {
        case .html:
            hasHTML
        case .pdf:
            hasPDF
        case .bilingualPDF:
            hasPDF && hasTranslatedPDF
        case .translatedPDF:
            hasTranslatedPDF
        }
    }
}
