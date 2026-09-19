import AppKit
import CoreText
import PDFKit
import SwiftUI
import XCTest
@testable import ReadPaper

final class PDFAnnotationStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var paperID: UUID!
    private var attachmentID: UUID!
    private var fileStore: PaperFileStore!
    private var annotationStore: PDFAnnotationStore!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFAnnotationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        paperID = UUID()
        attachmentID = UUID()
        fileStore = PaperFileStore(applicationSupportDirectory: temporaryDirectory)
        annotationStore = PDFAnnotationStore(fileStore: fileStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        annotationStore = nil
        fileStore = nil
        attachmentID = nil
        paperID = nil
        temporaryDirectory = nil
        super.tearDown()
    }

    func testSidecarRoundTripAndAttachmentIsolation() throws {
        let record = makeHighlightRecord(pageIndex: 2)

        try annotationStore.save([record], paperID: paperID, attachmentID: attachmentID)

        XCTAssertEqual(
            try annotationStore.load(paperID: paperID, attachmentID: attachmentID),
            [record]
        )
        XCTAssertEqual(
            try annotationStore.load(paperID: paperID, attachmentID: UUID()),
            []
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try annotationStore.sidecarURL(
                paperID: paperID,
                attachmentID: attachmentID
            ).path)
        )
    }

    func testSidecarRejectsContentCopiedToAnotherAttachmentScope() throws {
        let otherAttachmentID = UUID()
        try annotationStore.save(
            [makeHighlightRecord(pageIndex: 0)],
            paperID: paperID,
            attachmentID: attachmentID
        )
        let sourceURL = try annotationStore.sidecarURL(
            paperID: paperID,
            attachmentID: attachmentID
        )
        let mismatchedURL = try annotationStore.sidecarURL(
            paperID: paperID,
            attachmentID: otherAttachmentID
        )
        try Data(contentsOf: sourceURL).write(to: mismatchedURL, options: .atomic)

        XCTAssertThrowsError(
            try annotationStore.load(paperID: paperID, attachmentID: otherAttachmentID)
        ) { error in
            XCTAssertEqual(error as? PDFAnnotationStoreError, .mismatchedScope)
        }
    }

    @MainActor
    func testRendererCreatesStandardPDFAnnotationAndCompensatesDarkAppearance() throws {
        let record = makeHighlightRecord(pageIndex: 0)
        let regular = PDFAnnotationRenderer.makeAnnotation(from: record, invertedColor: false)
        let darkCompensated = PDFAnnotationRenderer.makeAnnotation(from: record, invertedColor: true)

        XCTAssertEqual(regular.markupType, .highlight)
        XCTAssertEqual(PDFAnnotationRenderer.recordID(for: regular), record.id)
        XCTAssertEqual(regular.bounds, record.bounds.cgRect)

        let compensatedValue = record.color.displayAdjusted(inverted: true)
        XCTAssertEqual(compensatedValue.red, 1 - record.color.red, accuracy: 0.001)
        XCTAssertEqual(compensatedValue.green, 1 - record.color.green, accuracy: 0.001)
        XCTAssertEqual(compensatedValue.blue, 1 - record.color.blue, accuracy: 0.001)
        XCTAssertEqual(compensatedValue.alpha, record.color.alpha, accuracy: 0.001)
        XCTAssertNotEqual(darkCompensated.color, regular.color)
    }

    @MainActor
    func testExporterWritesStandardAnnotationsWithoutChangingSourcePDF() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("annotated.pdf")
        let sourceDocument = makePDFDocument(pageCount: 1)
        XCTAssertTrue(sourceDocument.write(to: sourceURL))

        let highlight = makeHighlightRecord(pageIndex: 0)
        let ink = PDFAnnotationRecord(
            pageIndex: 0,
            kind: .ink,
            bounds: CGRect(x: 20, y: 20, width: 80, height: 30),
            color: PDFAnnotationColorPreset.red.color(for: .ink),
            lineWidth: 3,
            inkPaths: [[
                CGPoint(x: 22, y: 22),
                CGPoint(x: 55, y: 40),
                CGPoint(x: 95, y: 24),
            ]]
        )
        try annotationStore.save(
            [highlight, ink],
            paperID: paperID,
            attachmentID: attachmentID
        )

        let exportedCount = try PDFAnnotationExporter(store: annotationStore).export(
            sourcePDFURL: sourceURL,
            paperID: paperID,
            attachmentID: attachmentID,
            destinationURL: destinationURL
        )

        XCTAssertEqual(exportedCount, 2)
        XCTAssertEqual(PDFDocument(url: sourceURL)?.page(at: 0)?.annotations.count, 0)
        let exportedAnnotations = try XCTUnwrap(PDFDocument(url: destinationURL)?.page(at: 0)?.annotations)
        XCTAssertEqual(exportedAnnotations.count, 2)
        XCTAssertEqual(Set(exportedAnnotations.compactMap(PDFAnnotationRenderer.recordID)), Set([highlight.id, ink.id]))
        let exportedInk = try XCTUnwrap(exportedAnnotations.first {
            PDFAnnotationRenderer.recordID(for: $0) == ink.id
        })
        XCTAssertFalse(exportedInk.paths?.isEmpty ?? true)
        XCTAssertEqual(exportedInk.border?.lineWidth, 3)
    }

    @MainActor
    func testCoordinatorPersistsTextNoteAndSupportsUndoRedo() throws {
        var pageIndex = 0
        let coordinator = PDFReaderView.Coordinator(
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: Binding(get: { pageIndex }, set: { pageIndex = $0 }),
            onNoteSelectionChanged: nil,
            annotationStore: annotationStore
        )
        let pdfView = PDFView()
        pdfView.document = makePDFDocument(pageCount: 1)
        coordinator.attach(to: pdfView)
        coordinator.configure(
            paperID: paperID,
            attachmentID: attachmentID,
            annotationSession: nil
        )
        coordinator.loadAnnotations(in: pdfView)
        let baselineAnnotationCount = pdfView.document?.page(at: 0)?.annotations.count ?? 0

        coordinator.addTextNote(
            pageIndex: 0,
            point: CGPoint(x: 40, y: 40),
            contents: "Review this result",
            preset: .purple
        )

        XCTAssertEqual(try annotationStore.load(paperID: paperID, attachmentID: attachmentID).count, 1)
        XCTAssertEqual(freddieAnnotationCount(on: pdfView.document?.page(at: 0)), 1)
        XCTAssertTrue(coordinator.canUndoPDFAnnotation)

        coordinator.undoPDFAnnotation()
        XCTAssertEqual(try annotationStore.load(paperID: paperID, attachmentID: attachmentID), [])
        XCTAssertEqual(freddieAnnotationCount(on: pdfView.document?.page(at: 0)), 0)
        XCTAssertEqual(pdfView.document?.page(at: 0)?.annotations.count, baselineAnnotationCount)
        XCTAssertTrue(coordinator.canRedoPDFAnnotation)

        coordinator.redoPDFAnnotation()
        XCTAssertEqual(try annotationStore.load(paperID: paperID, attachmentID: attachmentID).count, 1)
        XCTAssertEqual(freddieAnnotationCount(on: pdfView.document?.page(at: 0)), 1)
    }

    @MainActor
    func testCoordinatorInterceptsOnlyArxivLinksWhenImportHandlerIsAvailable() throws {
        var pageIndex = 0
        var activatedURL: URL?
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: Binding(get: { pageIndex }, set: { pageIndex = $0 }),
            onNoteSelectionChanged: nil,
            onArxivLinkActivated: { activatedURL = $0 }
        )
        let arxivURL = try XCTUnwrap(URL(string: "https://arxiv.org/abs/2303.08774"))
        let doiURL = try XCTUnwrap(URL(string: "https://doi.org/10.1145/3731715.3733394"))

        XCTAssertTrue(coordinator.handleLinkActivation(arxivURL))
        XCTAssertEqual(activatedURL, arxivURL)
        XCTAssertFalse(coordinator.handleLinkActivation(doiURL))
        XCTAssertEqual(activatedURL, arxivURL)

        coordinator.onArxivLinkActivated = nil
        XCTAssertFalse(coordinator.handleLinkActivation(arxivURL))
    }

    @MainActor
    func testTranslatedSidecarRecordAppearsWhenPartialDocumentGainsPage() throws {
        let futureRecord = makeHighlightRecord(pageIndex: 2)
        try annotationStore.save(
            [futureRecord],
            paperID: paperID,
            attachmentID: attachmentID
        )
        var pageIndex = 0
        let coordinator = PDFReaderView.Coordinator(
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: Binding(get: { pageIndex }, set: { pageIndex = $0 }),
            onNoteSelectionChanged: nil,
            annotationStore: annotationStore
        )
        let pdfView = PDFView()
        pdfView.document = makePDFDocument(pageCount: 2)
        coordinator.attach(to: pdfView)
        coordinator.loadAnnotations(in: pdfView)

        XCTAssertTrue(coordinator.hasPDFAnnotations)
        XCTAssertEqual(pdfView.document?.page(at: 0)?.annotations.count, 0)
        XCTAssertEqual(pdfView.document?.page(at: 1)?.annotations.count, 0)

        pdfView.document = makePDFDocument(pageCount: 3)
        coordinator.loadAnnotations(in: pdfView)

        let restored = try XCTUnwrap(pdfView.document?.page(at: 2)?.annotations.first)
        XCTAssertEqual(PDFAnnotationRenderer.recordID(for: restored), futureRecord.id)
    }

    @MainActor
    func testSelectionAssistantHistoryAnchorsRenderOnlyNearVisiblePage() async throws {
        let document = makePDFDocument(pageCount: 5)
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let lastPage = try XCTUnwrap(document.page(at: 4))
        let pdfView = PDFView()
        pdfView.document = document
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: attachmentID,
            pageIndex: .constant(0),
            onNoteSelectionChanged: nil
        )
        coordinator.attach(to: pdfView)
        coordinator.applySelectionAssistantHistoryAnchors(
            [
                SelectionAssistantHistoryAnchor(
                    selectionIdentity: "first-page-anchor",
                    attachmentID: attachmentID,
                    quote: "Page 1",
                    pageIndex: 0,
                    htmlSelector: nil
                ),
                SelectionAssistantHistoryAnchor(
                    selectionIdentity: "last-page-anchor",
                    attachmentID: attachmentID,
                    quote: "Page 5",
                    pageIndex: 4,
                    htmlSelector: nil
                ),
            ],
            in: pdfView
        )

        XCTAssertTrue(firstPage.string?.contains("Page 1") == true)
        XCTAssertEqual(document.index(for: try XCTUnwrap(pdfView.currentPage)), 0)
        try? await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(firstPage.annotations.count, 1)
        XCTAssertEqual(lastPage.annotations.count, 0)

        pdfView.go(to: lastPage)
        try? await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(firstPage.annotations.count, 1)
        XCTAssertEqual(lastPage.annotations.count, 1)
    }

    @MainActor
    func testDebugInteractionExclusivelyForcesBrowseMode() {
        let session = PDFAnnotationSession()
        session.selectInteractionMode(.ink)
        XCTAssertEqual(session.interactionMode, .ink)

        session.beginDebugInteraction()
        XCTAssertTrue(session.isDebugInteractionActive)
        XCTAssertEqual(session.interactionMode, .browse)

        session.selectInteractionMode(.erase)
        XCTAssertEqual(session.interactionMode, .browse)

        session.endDebugInteraction()
        session.selectInteractionMode(.erase)
        XCTAssertEqual(session.interactionMode, .erase)

        session.selectInteractionMode(.textNote)
        session.cancelPendingTextNote()
        XCTAssertEqual(session.interactionMode, .browse)
    }

    @MainActor
    func testRegisterMovesActiveAttachmentAwayFromReleasedHandler() {
        let session = PDFAnnotationSession()
        let firstAttachmentID = UUID()
        let secondAttachmentID = UUID()
        var firstHandler: PDFAnnotationSessionHandlerStub? = PDFAnnotationSessionHandlerStub(
            attachmentID: firstAttachmentID
        )
        session.register(firstHandler!, for: firstAttachmentID)
        XCTAssertEqual(session.activeAttachmentID, firstAttachmentID)

        firstHandler = nil
        let secondHandler = PDFAnnotationSessionHandlerStub(attachmentID: secondAttachmentID)
        session.register(secondHandler, for: secondAttachmentID)

        XCTAssertEqual(session.activeAttachmentID, secondAttachmentID)
    }

    private func makeHighlightRecord(pageIndex: Int) -> PDFAnnotationRecord {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return PDFAnnotationRecord(
            id: UUID(),
            pageIndex: pageIndex,
            kind: .highlight,
            bounds: CGRect(x: 12, y: 18, width: 90, height: 14),
            color: PDFAnnotationColorPreset.yellow.color(for: .highlight),
            quote: "Important result",
            createdAt: date,
            modifiedAt: date
        )
    }

    @MainActor
    private func makePDFDocument(pageCount: Int) -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 120)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("Unable to create in-memory PDF context")
            return PDFDocument()
        }

        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            let text = NSAttributedString(
                string: "Page \(index + 1)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.black,
                ]
            )
            let line = CTLineCreateWithAttributedString(text as CFAttributedString)
            context.textPosition = CGPoint(x: 20, y: 50)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            XCTFail("Unable to load in-memory PDF document")
            return PDFDocument()
        }
        return document
    }

    @MainActor
    private func freddieAnnotationCount(on page: PDFPage?) -> Int {
        page?.annotations.compactMap(PDFAnnotationRenderer.recordID).count ?? 0
    }
}

@MainActor
private final class PDFAnnotationSessionHandlerStub: PDFAnnotationSessionHandler {
    let annotationAttachmentID: UUID?
    var hasPDFTextSelection = false
    var canUndoPDFAnnotation = false
    var canRedoPDFAnnotation = false
    var hasPDFAnnotations = false

    init(attachmentID: UUID) {
        annotationAttachmentID = attachmentID
    }

    func applyTextMarkup(_ kind: PDFTextMarkupKind, preset: PDFAnnotationColorPreset) {}
    func addTextNote(pageIndex: Int, point: CGPoint, contents: String, preset: PDFAnnotationColorPreset) {}
    func undoPDFAnnotation() {}
    func redoPDFAnnotation() {}
}
