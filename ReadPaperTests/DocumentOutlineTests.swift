import AppKit
import PDFKit
import XCTest
@testable import ReadPaper

final class DocumentOutlineTests: XCTestCase {
    func testNativeQualityRepairsSharedOffsetAndDiscardsJunk() {
        let entries = [
            entry("Introduction", 0), entry("Methods", 1), entry("Experiments", 2), entry("Conclusion", 3),
            entry("Cover", 0), entry("\\376\\377123", 0),
            DocumentOutlineEntry(id: "broken", title: "Broken destination", level: 1)
        ]
        let texts = ["Title", "Introduction", "Methods", "Experiments", "Conclusion"].map(DocumentSearchText.init)
        let result = DocumentOutlineService.assess(entries, pages: texts)
        XCTAssertTrue(result.isGood)
        XCTAssertEqual(result.repaired.map(\.title), ["Introduction", "Methods", "Experiments", "Conclusion"])
        XCTAssertEqual(result.repaired.compactMap(\.pageIndex), [1, 2, 3, 4])
        XCTAssertEqual(entries.first?.pageIndex, 0, "The original embedded outline remains selectable unchanged")
    }

    func testNativeQualityRejectsSingleEntryBrokenTargetsGibberishAndNarrowCoverage() {
        let pages = (0..<30).map { DocumentSearchText("Page \($0): Introduction Methods Experiments Conclusion") }
        XCTAssertFalse(DocumentOutlineService.assess([entry("Introduction", 0)], pages: pages).isGood)
        XCTAssertFalse(DocumentOutlineService.assess([entry("Introduction", 0), entry("Methods", 0), entry("Experiments", 0)], pages: pages).isGood)
        XCTAssertFalse(DocumentOutlineService.assess([entry("Introduction", 1), entry("Methods", 2), entry("Experiments", 3)], pages: pages).isGood)
        XCTAssertFalse(DocumentOutlineService.assess([entry("12345", 0), entry("�", 2)], pages: pages).isGood)
        XCTAssertFalse(DocumentOutlineService.assess([entry("Absent heading", 4), entry("Also absent", 8)], pages: pages).isGood)
    }

    func testQualityRejectsMostlyReversedPageOrder() {
        let pages = ["Conclusion", "Experiments", "Methods", "Introduction"].map(DocumentSearchText.init)
        let items = [entry("Introduction", 3), entry("Methods", 2), entry("Experiments", 1), entry("Conclusion", 0)]
        XCTAssertFalse(DocumentOutlineService.assess(items, pages: pages).isGood)
    }

    func testPartialTranslatedOutlineKeepsOriginalCoordinates() {
        let item = entry("Appendix", 17)
        let bilingual = DocumentOutlineNavigation.pdfDestination(entry: item, translatedOnly: false, translatedLastPage: 3)
        XCTAssertEqual(bilingual.pageIndex, 17, "A partial translation cannot clamp original navigation")
        XCTAssertFalse(bilingual.opensOriginal)
        let translated = DocumentOutlineNavigation.pdfDestination(entry: item, translatedOnly: true, translatedLastPage: 3)
        XCTAssertEqual(translated.pageIndex, 17)
        XCTAssertTrue(translated.opensOriginal)
        XCTAssertFalse(entry("Methods", 2).isUntranslated(lastPage: 3))
        XCTAssertTrue(entry("Results", 3).isUntranslated(lastPage: 3))
    }

    func testCurrentSectionTracksMultipleHeadingsOnOnePage() {
        var first = entry("Methods", 1); first.fraction = 0.1
        var second = entry("Experiments", 1); second.fraction = 0.7
        XCTAssertEqual(DocumentOutlineEntry.current(in: [first, second], page: 1, fraction: 0.4), first.id)
        XCTAssertEqual(DocumentOutlineEntry.current(in: [first, second], page: 1, fraction: 0.8), second.id)
        XCTAssertEqual(DocumentOutlineEntry.current(in: [first, second], page: 2), second.id)
    }

    func testScanSectionsPreserveOriginalPageAndHierarchy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("ScanRebuild/typeset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"\section{Introduction} text \subsection{A \textbf{nested} heading}"#.write(to: directory.appendingPathComponent("page-0004.page.tex"), atomically: true, encoding: .utf8)
        let entries = try DocumentOutlineService.scanEntries(root: root, pageCount: 8)
        XCTAssertEqual(entries.map(\.title), ["Introduction", "A nested heading"])
        XCTAssertEqual(entries.map(\.level), [1, 2])
        XCTAssertEqual(entries.compactMap(\.pageIndex), [3, 3])
    }

    func testCacheVersionAndSourceSelectionDoNotRewritePDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperFileStore(applicationSupportDirectory: root)
        let paperID = UUID()
        let pdfURL = try store.directory(for: paperID).appendingPathComponent("paper.pdf")
        try makePDF().write(to: pdfURL)
        let original = try Data(contentsOf: pdfURL)
        let request = DocumentOutlineRequest(paperID: paperID, pdfURL: pdfURL)
        let service = DocumentOutlineService(fileStore: store)
        let cache = try await service.load(request)
        XCTAssertEqual(cache.selectedSource, .automatic)
        XCTAssertGreaterThanOrEqual(cache.candidates.count, 3)
        let selected = try await service.select(.automatic, request: request)
        XCTAssertEqual(selected.userSelectedSource, .automatic)
        let url = pdfURL.deletingLastPathComponent().appendingPathComponent("Resources/Outline/outline.json")
        var obsolete = selected
        obsolete.algorithmVersion = 0
        obsolete.variants = []
        try JSONEncoder().encode(obsolete).write(to: url)
        let rebuilt = try await service.load(request)
        XCTAssertEqual(rebuilt.algorithmVersion, DocumentOutlineCache.algorithmVersion)
        XCTAssertGreaterThanOrEqual(rebuilt.variants.first?.entries.count ?? 0, 3)
        XCTAssertEqual(try Data(contentsOf: pdfURL), original)
    }

    func testHeuristicRejectsRepeatedHeadersAndUsesNumberDepth() throws {
        let document = try XCTUnwrap(PDFDocument(data: makePDF()))
        let entries = try DocumentOutlineService.heuristicEntries(document)
        XCTAssertFalse(entries.contains { $0.title == "Repeated running header" })
        XCTAssertTrue(entries.contains { $0.title == "2.1 Experiments" && $0.level == 2 })
    }

    func testAIOrganizerOnlyKeepsExistingHeadingsAndPersistsManualSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperFileStore(applicationSupportDirectory: root)
        let id = UUID()
        let url = try store.directory(for: id).appendingPathComponent("paper.pdf")
        try makePDF().write(to: url)
        let request = DocumentOutlineRequest(paperID: id, pdfURL: url)
        let service = DocumentOutlineService(fileStore: store)
        let before = try await service.load(request)
        let route = ResolvedLLMModelRoute(snapshot: .init(providerProfileID: UUID(), providerName: "Test", modelProfileID: UUID(), modelProfileName: "Test", baseURL: "https://invalid.example", apiKeyRef: "test-only", modelName: "test"), apiKey: "test-only")
        let result = try await service.organize(request, route: route, provider: OutlineMockProvider())
        let ai = try XCTUnwrap(result.variants.first { $0.source == .ai })
        XCTAssertEqual(ai.entries.map(\.id), before.candidates.map(\.id))
        XCTAssertEqual(ai.entries.compactMap(\.pageIndex), before.candidates.compactMap(\.pageIndex))
        XCTAssertFalse(ai.entries.contains { $0.id == "invented" })
        let reloaded = try await service.load(request)
        XCTAssertEqual(reloaded.userSelectedSource, .ai)
        XCTAssertEqual(reloaded.selectedSource, .ai)
    }

    @MainActor
    func testPDFOutlineReportsWithinPageScrollAndFollowingTranslatedPane() async throws {
        let document = try XCTUnwrap(PDFDocument(data: makePDF()))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        view.displayMode = .singlePageContinuous
        view.autoScales = false
        view.scaleFactor = 1
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = document
        view.layoutDocumentView()
        let coordinator = PDFReaderView.Coordinator(attachmentID: nil, pageIndex: .constant(0), onNoteSelectionChanged: nil)
        var reports: [(Int, Double)] = []
        coordinator.onOutlineLocationChanged = { reports.append(($0, $1)) }
        coordinator.attach(to: view)
        coordinator.observeOutlineGeometry(in: view)
        defer { coordinator.detach(); window.close() }
        view.go(to: try XCTUnwrap(document.page(at: 0)))
        try await Task.sleep(for: .milliseconds(100))
        let before = try XCTUnwrap(reports.last)
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 80))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let after = try XCTUnwrap(reports.last)
        XCTAssertEqual(before.0, after.0)
        XCTAssertGreaterThan(abs(after.1 - before.1), 0.05, "Outline location must change even when PDFView's current page stays the same")
        let translated = PDFView(frame: view.frame)
        translated.displayMode = .singlePageContinuous
        translated.document = try XCTUnwrap(PDFDocument(data: makePDF()))
        translated.layoutDocumentView()
        let sync = DualPDFScrollSync()
        sync.isUserScroll = { _, _, _ in false }
        coordinator.attachScrollSync(sync, side: .original, to: view)
        sync.register(translated, side: .translated) {}
        let target = try XCTUnwrap(translated.document?.page(at: 2))
        translated.go(to: PDFDestination(page: target, at: CGPoint(x: 0, y: 500)))
        sync.lead(.translated)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sync.isFollowing(.original))
        XCTAssertEqual(reports.last?.0, 2, "The original's outline also follows a scroll made on the translation")
    }

    func testNativeOutlineUsesMatchedHeadingGeometryWithoutChangingDestinations() throws {
        let document = try XCTUnwrap(PDFDocument(data: makePDF()))
        // Fit-page destinations carry no vertical coordinate.
        let unspecified = CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)
        let root = PDFOutline()
        for (index, title) in ["1 Introduction", "2 Methods", "2.1 Experiments", "3 Conclusion"].enumerated() {
            let item = PDFOutline()
            item.label = title
            item.destination = PDFDestination(page: try XCTUnwrap(document.page(at: index)), at: unspecified)
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
        let raw = DocumentOutlineService.nativeEntries(document)
        XCTAssertTrue(raw.allSatisfy { $0.fraction == nil })
        let texts = (0..<document.pageCount).map { DocumentSearchText(document.page(at: $0)?.string ?? "") }
        let located = DocumentOutlineService.withTextLocations(raw, document: document, texts: texts)
        XCTAssertEqual(located.compactMap(\.pageIndex), [0, 1, 2, 3])
        XCTAssertTrue(located.allSatisfy { ($0.fraction ?? 1) < 0.3 })
        XCTAssertTrue(DocumentOutlineService.assess(located, pages: texts).isGood)
        XCTAssertEqual(root.child(at: 0)?.destination?.point, unspecified, "The embedded outline is never mutated")
    }

    func testDestinationCoordinateWinsOverEarlierMentionOfTheTitle() throws {
        // "Methods" appears in body text above the real heading on the same page.
        let document = try XCTUnwrap(PDFDocument(data: makePDF(pages: [
            [("Ordinary body paragraph about methods", 11, false, 640), ("Methods", 16, true, 300)]
        ])))
        let page = try XCTUnwrap(document.page(at: 0))
        let root = PDFOutline()
        let item = PDFOutline()
        item.label = "Methods"
        item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 318))
        root.insertChild(item, at: 0)
        document.outlineRoot = root
        let texts = [DocumentSearchText(page.string ?? "")]
        let raw = DocumentOutlineService.nativeEntries(document)
        let located = DocumentOutlineService.withTextLocations(raw, document: document, texts: texts)
        XCTAssertEqual(try XCTUnwrap(located.first?.fraction), 382.0 / 700.0, accuracy: 0.001)
        var fitPage = raw[0]; fitPage.fraction = nil
        let fromText = try XCTUnwrap(DocumentOutlineService.withTextLocations([fitPage], document: document, texts: texts).first?.fraction)
        XCTAssertGreaterThan(fromText, 0.5, "Without a coordinate the heading line is used, not the body mention")
    }

    func testHeadingLinesIgnoreBodyMentions() {
        let text = DocumentSearchText("We describe our method in detail.\n3. Method\nBody text continues here.\nSection 4 Experiments:")
        let ranges = DocumentOutlineService.headingRanges(of: "Method", in: text)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(DocumentOutlineService.headingRanges(of: "4 Experiments", in: text).count, 1)
        XCTAssertTrue(DocumentOutlineService.headingRanges(of: "detail", in: text).isEmpty)
        // A neighbouring page's heading beats a mention on the bookmark's own page.
        let pages = ["Abstract mentions our method.", "Method\nBody"].map(DocumentSearchText.init)
        XCTAssertEqual(DocumentOutlineService.matchedPage("Method", target: 0, pages: pages), 1)
        XCTAssertEqual(DocumentOutlineService.matchedPage("Abstract", target: 0, pages: ["Abstract mentions it", "Body"].map(DocumentSearchText.init)), 0,
                       "A mention on the expected page still validates when no heading line exists nearby")
    }

    func testLaTeXHeadingsAreLocatedOnHeadingLinesInReadingOrder() throws {
        let document = try XCTUnwrap(PDFDocument(data: makePDF(pages: [
            [("Abstract: our method beats prior experiments", 11, false, 600)],
            [("Introduction", 16, true, 600), ("Method", 16, true, 300)],
            [("Experiments", 16, true, 600)]
        ])))
        let texts = (0..<document.pageCount).map { DocumentSearchText(document.page(at: $0)?.string ?? "") }
        var start = DocumentOutlineService.HeadingLocation(page: 0, fraction: 0, offset: -1)
        var pages: [Int] = []
        for title in ["Introduction", "Method", "Experiments"] {
            let location = try XCTUnwrap(DocumentOutlineService.locate(title, in: document, texts: texts, after: start))
            pages.append(location.page); start = location
        }
        XCTAssertEqual(pages, [1, 1, 2], "Body mentions on the abstract page must not pull headings forward")
        XCTAssertNil(DocumentOutlineService.locate("Absent", in: document, texts: texts, after: .init(page: 0, fraction: 0, offset: -1)))
    }

    func testGroupingBookmarksStayAsParents() {
        let group = DocumentOutlineEntry(id: "part", title: "Part I", level: 1)
        var children = [entry("Introduction", 1), entry("Methods", 2), entry("Results", 3)]
        for index in children.indices { children[index].level = 2 }
        let lonely = DocumentOutlineEntry(id: "lonely", title: "Lonely group", level: 1)
        let texts = ["Title", "Introduction", "Methods", "Results"].map(DocumentSearchText.init)
        let result = DocumentOutlineService.assess([group] + children + [lonely], pages: texts)
        XCTAssertTrue(result.isGood)
        XCTAssertEqual(result.repaired.map(\.id), ["part", "Introduction", "Methods", "Results"])
    }

    func testHeuristicLevelsCountFromTopLevelSectionsNotTheTitle() throws {
        let document = try XCTUnwrap(PDFDocument(data: makePDF(pages: [
            [("A Large Paper Title", 24, true, 640), ("1 Introduction", 16, true, 560)],
            [("2 Methods", 16, true, 640), ("2.1 Setup", 13, true, 500)],
            [("References", 16, true, 640)]
        ])))
        let levels = Dictionary(try DocumentOutlineService.heuristicEntries(document).map { ($0.title, $0.level) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(levels["1 Introduction"], 1)
        XCTAssertEqual(levels["2.1 Setup"], 2)
        XCTAssertEqual(levels["References"], 1, "Unnumbered sections share the numbered top level")
        XCTAssertEqual(levels["A Large Paper Title"], 1, "A larger title is not a parent of every section")
    }

    func testGoodNativeOutlineDefersHeuristicsUntilRequested() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperFileStore(applicationSupportDirectory: root)
        let paperID = UUID()
        let pdfURL = try store.directory(for: paperID).appendingPathComponent("paper.pdf")
        let document = try XCTUnwrap(PDFDocument(data: makePDF()))
        let outline = PDFOutline()
        for (index, title) in ["1 Introduction", "2 Methods", "2.1 Experiments", "3 Conclusion"].enumerated() {
            let item = PDFOutline()
            item.label = title
            item.destination = PDFDestination(page: try XCTUnwrap(document.page(at: index)), at: CGPoint(x: 0, y: 600))
            outline.insertChild(item, at: index)
        }
        document.outlineRoot = outline
        XCTAssertTrue(document.write(to: pdfURL))
        let request = DocumentOutlineRequest(paperID: paperID, pdfURL: pdfURL)
        let service = DocumentOutlineService(fileStore: store)
        let cache = try await service.load(request)
        XCTAssertEqual(cache.selectedSource, .pdf)
        XCTAssertTrue(cache.canGenerateAutomatic)
        XCTAssertTrue(cache.candidates.isEmpty)
        XCTAssertFalse(cache.variants.contains { $0.source == .automatic })
        let generated = try await service.select(.automatic, request: request)
        XCTAssertEqual(generated.selectedSource, .automatic)
        XCTAssertFalse(generated.canGenerateAutomatic)
        XCTAssertGreaterThanOrEqual(generated.candidates.count, 3)
        let reloaded = try await service.load(request)
        XCTAssertEqual(reloaded.selectedSource, .automatic)
    }

    func testOrganizeNeedsEnoughCandidates() {
        var cache = DocumentOutlineCache(fingerprint: "", variants: [], candidates: [entry("A", 0), entry("B", 1)])
        XCTAssertFalse(cache.canOrganize, "The model can only drop candidates, so two can never make an outline")
        cache.candidates.append(entry("C", 2))
        XCTAssertTrue(cache.canOrganize)
        XCTAssertTrue(DocumentOutlineCache(fingerprint: "", variants: [], deferredCandidates: true).canOrganize)
    }

    @MainActor
    func testModelExtractsOnlyWhenShownAndKeepsHTMLEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The shared service reads the real Application Support location, so this checks
        // only the no-fetch path, which never touches it.
        let model = DocumentOutlineModel()
        let html = [DocumentOutlineEntry(id: "h", title: "Heading", level: 1, anchor: "rp-anchor:0")]
        model.updateHTML(html, currentID: "h")
        let request = DocumentOutlineRequest(paperID: UUID(), pdfURL: root.appendingPathComponent("missing.pdf"))
        await model.load(request, paperID: request.paperID, fetch: false)
        XCTAssertNil(model.cache)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage, "Nothing is read while the panel is closed")
        XCTAssertEqual(model.entries(isHTML: true), html, "A page that reported first keeps its outline")
        XCTAssertEqual(model.currentID(isHTML: true), "h")
    }

    private func entry(_ title: String, _ page: Int) -> DocumentOutlineEntry {
        .init(id: title, title: title, level: 1, pageIndex: page)
    }
    /// Pages of (text, size, bold, baseline y) lines on a 500×700 page.
    private func makePDF(pages: [[(String, CGFloat, Bool, CGFloat)]]) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 500, height: 700)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            for (text, size, bold, y) in lines {
                let font = NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)!
                (text as NSString).draw(at: NSPoint(x: 30, y: y), withAttributes: [.font: font])
            }
            // Body text sets the document's body size.
            for line in 0..<12 {
                ("Ordinary body paragraph with several words and a period." as NSString).draw(at: NSPoint(x: 30, y: 260 - CGFloat(line) * 18), withAttributes: [.font: NSFont(name: "Helvetica", size: 11)!])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func makePDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 500, height: 700)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for title in ["1 Introduction", "2 Methods", "2.1 Experiments", "3 Conclusion"] {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            ("Repeated running header" as NSString).draw(at: NSPoint(x: 30, y: 665), withAttributes: [.font: NSFont(name: "Helvetica-Bold", size: 15)!])
            (title as NSString).draw(at: NSPoint(x: 30, y: 580), withAttributes: [.font: NSFont(name: "Helvetica-Bold", size: 16)!])
            for line in 0..<18 {
                ("Ordinary body paragraph with several words and a period." as NSString).draw(at: NSPoint(x: 30, y: 530 - line * 20), withAttributes: [.font: NSFont(name: "Helvetica", size: 11)!])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

private struct OutlineMockProvider: ReadPaperLLMCompleting {
    func complete(request: LLMCompletionRequest) async throws -> LLMCompletionResponse {
        let candidates = try JSONDecoder().decode([DocumentOutlineEntry].self, from: Data((request.messages.last?.content ?? "").utf8))
        let choices: [[String: Any]] = candidates.map { ["id": $0.id, "level": 1] } + [["id": "invented", "level": 1]]
        let data = try JSONSerialization.data(withJSONObject: choices)
        return .init(text: String(decoding: data, as: UTF8.self), resolvedEndpoint: nil)
    }
}
