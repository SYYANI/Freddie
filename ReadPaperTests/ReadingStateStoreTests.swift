import SwiftData
import XCTest
@testable import ReadPaper

final class ReadingStateStoreTests: XCTestCase {
    @MainActor
    func testUpsertStateCreatesSingleNormalizedReadingStatePerPaper() throws {
        let container = try makeContainer()
        let modelContext = ModelContext(container)
        let paperID = UUID()

        let olderState = ReadingState(
            paperID: paperID,
            attachmentID: UUID(),
            readerMode: .html,
            pageIndex: 1,
            scrollRatio: 0.15,
            modifiedAt: Date.distantPast
        )
        let newerState = ReadingState(
            paperID: paperID,
            attachmentID: UUID(),
            readerMode: .pdf,
            pageIndex: 3,
            scrollRatio: 0.35,
            modifiedAt: Date()
        )

        modelContext.insert(olderState)
        modelContext.insert(newerState)
        try modelContext.save()

        let attachmentID = UUID()
        try ReadingStateStore().upsertState(
            for: paperID,
            attachmentID: attachmentID,
            readerMode: .bilingualPDF,
            pageIndex: -7,
            scrollRatio: 1.234,
            in: modelContext
        )

        let states = try modelContext.fetch(FetchDescriptor<ReadingState>())
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.paperID, paperID)
        XCTAssertEqual(states.first?.attachmentID, attachmentID)
        XCTAssertEqual(states.first?.readerMode, .bilingualPDF)
        XCTAssertEqual(states.first?.pageIndex, 0)
        XCTAssertEqual(states.first?.scrollRatio, 1)
    }

    func testResolvedReaderModeDefaultsToPDFWhenNoSavedStateExists() {
        let mode = ReadingStateStore.resolvedReaderMode(
            preferredMode: nil,
            hasHTML: true,
            hasPDF: true,
            hasTranslatedPDF: false
        )

        XCTAssertEqual(mode, .pdf)
    }

    func testResolvedReaderModeFallsBackWhenSavedModeIsUnavailable() {
        let missingTranslatedMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: .bilingualPDF,
            hasHTML: true,
            hasPDF: true,
            hasTranslatedPDF: false
        )
        let missingHTMLMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: .html,
            hasHTML: false,
            hasPDF: true,
            hasTranslatedPDF: false
        )

        XCTAssertEqual(missingTranslatedMode, .pdf)
        XCTAssertEqual(missingHTMLMode, .pdf)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            ReadingState.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }
}
