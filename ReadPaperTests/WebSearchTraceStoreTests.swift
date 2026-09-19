import XCTest
@testable import ReadPaper

final class WebSearchTraceStoreTests: XCTestCase {
    @MainActor
    func testAppendingBatchesKeepsEntryOrderAndFullText() {
        let store = WebSearchTraceStore()

        store.append(["[1] WEB SEARCH CAPABILITY TEST", "[2] REQUEST POST"])
        store.append([])
        store.append(["[3] SSE response.output_text.delta", "[4] RESULT"])

        XCTAssertFalse(store.isEmpty)
        XCTAssertEqual(store.entries.map(\.text), [
            "[1] WEB SEARCH CAPABILITY TEST",
            "[2] REQUEST POST",
            "[3] SSE response.output_text.delta",
            "[4] RESULT"
        ])
        XCTAssertEqual(
            store.fullText,
            "[1] WEB SEARCH CAPABILITY TEST\n\n[2] REQUEST POST\n\n[3] SSE response.output_text.delta\n\n[4] RESULT"
        )
        XCTAssertEqual(store.entries.map(\.id), Array(0..<4))
    }

    @MainActor
    func testEmptyStoreReportsNoTrace() {
        let store = WebSearchTraceStore()

        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.fullText, "")
    }

    @MainActor
    func testResetClearsAccumulatedEntries() {
        let store = WebSearchTraceStore()
        store.append(["[1] REQUEST POST", "[2] RESULT"])

        store.reset()

        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.entries, [])
        XCTAssertEqual(store.fullText, "")
    }

    /// Regression: trace rows are rendered by a lazy stack, so a row must never
    /// read the entry array by index. Entries keep stable identities even when
    /// the store is reset between two test runs.
    @MainActor
    func testEntryIdentitiesStayUniqueAcrossAReset() {
        let store = WebSearchTraceStore()
        store.append(["[1] REQUEST POST", "[2] RESULT"])
        let firstRunIDs = store.entries.map(\.id)

        store.reset()
        store.append(["[1] REQUEST POST"])

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(firstRunIDs.contains(store.entries[0].id))
        XCTAssertEqual(store.entries[0].text, "[1] REQUEST POST")
    }
}
