import PDFKit
import WebKit
import XCTest
@testable import ReadPaper

final class NoteAnchorTests: XCTestCase {
    func testSelectionContextNormalizesQuoteAndAnchor() {
        let attachmentID = UUID()
        let selection = NoteSelectionContext(
            attachmentID: attachmentID,
            quote: "  A  highlighted\n passage  ",
            pageIndex: -4,
            htmlSelector: "  rp-anchor:1/2/3  ",
            localContext: "  Nearby paragraph.  "
        )

        XCTAssertEqual(selection.attachmentID, attachmentID)
        XCTAssertEqual(selection.trimmedQuote, "A highlighted passage")
        XCTAssertEqual(selection.pageIndex, 0)
        XCTAssertEqual(selection.htmlSelector, "rp-anchor:1/2/3")
        XCTAssertEqual(selection.localContext, "Nearby paragraph.")
        XCTAssertTrue(selection.hasAnchor)
    }

    func testNoteNavigationRequestUsesAvailableAnchor() throws {
        let note = Note(
            paperID: UUID(),
            attachmentID: UUID(),
            quote: "Selected quote",
            body: "Body",
            pageIndex: 5,
            htmlSelector: "rp-anchor:4/2"
        )

        let request = try XCTUnwrap(note.navigationRequest)
        XCTAssertEqual(request.attachmentID, note.attachmentID)
        XCTAssertEqual(request.pageIndex, 5)
        XCTAssertEqual(request.htmlSelector, "rp-anchor:4/2")
        XCTAssertEqual(request.quote, "Selected quote")
    }

    func testPDFNavigationTextMatcherMapsNormalizedWhitespaceToSourceRange() throws {
        let pageText = "Before  Selected\nquote\tcontinues. After"
        let range = try XCTUnwrap(
            PDFNoteNavigationTextMatcher.range(
                of: " Selected   quote continues. ",
                in: pageText
            )
        )

        XCTAssertEqual((pageText as NSString).substring(with: range), "Selected\nquote\tcontinues.")
    }

    func testPDFNavigationTextMatcherReturnsNilForMissingQuote() {
        XCTAssertNil(PDFNoteNavigationTextMatcher.range(of: "Missing", in: "Page text"))
    }

    func testAssistantSourceUsesDedicatedNavigationQuoteInsteadOfContextExcerpt() throws {
        let source = AssistantSource(
            id: "paper-page-2",
            kind: .paperPDF,
            title: "Page 2",
            excerpt: "Previous page context\n\nExact target passage\n\nNext page context",
            attachmentID: UUID(),
            pageIndex: 1,
            navigationQuote: "Exact target passage"
        )

        let request = try XCTUnwrap(source.navigationRequest)
        XCTAssertEqual(request.quote, "Exact target passage")
        XCTAssertNotNil(PDFNoteNavigationTextMatcher.range(
            of: try XCTUnwrap(request.quote),
            in: "Heading\nExact target passage\nFooter"
        ))
    }

    func testAssistantSourceDecodesLegacyPayloadWithoutNavigationQuote() throws {
        let data = Data(#"""
        {
          "id": "legacy-source",
          "kind": "paperPDF",
          "title": "Page 1",
          "excerpt": "Legacy page excerpt",
          "sectionPath": [],
          "pageIndex": 0,
          "isLowConfidence": true
        }
        """#.utf8)

        let source = try JSONDecoder().decode(AssistantSource.self, from: data)
        XCTAssertNil(source.navigationQuote)
        XCTAssertEqual(source.navigationRequest?.quote, "Legacy page excerpt")
    }

    func testNoteWithoutAnchorDoesNotProduceNavigationRequest() {
        let note = Note(
            paperID: UUID(),
            quote: "Selected quote",
            body: "Body"
        )

        XCTAssertFalse(note.hasAnchor)
        XCTAssertNil(note.navigationRequest)
    }

    func testSelectionAssistantNotePreservesQuoteResultAndAnchor() {
        let paperID = UUID()
        let attachmentID = UUID()
        let selection = NoteSelectionContext(
            attachmentID: attachmentID,
            quote: " Selected source text ",
            pageIndex: 7,
            htmlSelector: "rp-anchor:2/4",
            localContext: "Nearby text"
        )

        let note = Note.selectionAssistantNote(
            paperID: paperID,
            selection: selection,
            result: "AI explanation"
        )

        XCTAssertEqual(note.paperID, paperID)
        XCTAssertEqual(note.attachmentID, attachmentID)
        XCTAssertEqual(note.quote, "Selected source text")
        XCTAssertEqual(note.body, "AI explanation")
        XCTAssertEqual(note.pageIndex, 7)
        XCTAssertEqual(note.htmlSelector, "rp-anchor:2/4")
    }

    func testHTMLSidenotesKeepOnlyNotesAnchoredInTheHTMLAttachment() {
        let paperID = UUID()
        let htmlAttachmentID = UUID()
        let htmlNote = Note(
            paperID: paperID,
            attachmentID: htmlAttachmentID,
            quote: "  quoted\n text ",
            body: "**Body**",
            htmlSelector: " rp-anchor:1/2 "
        )
        let legacyHTMLNote = Note(paperID: paperID, quote: "Legacy", htmlSelector: "[data-rp-segment-id=\"s1\"]")
        let pdfNote = Note(paperID: paperID, attachmentID: UUID(), quote: "PDF", pageIndex: 3)
        let otherAttachmentNote = Note(paperID: paperID, attachmentID: UUID(), quote: "Other", htmlSelector: "rp-anchor:3")
        let unanchoredNote = Note(paperID: paperID, body: "Loose thought")

        let sidenotes = HTMLSidenote.sidenotes(
            from: [htmlNote, legacyHTMLNote, pdfNote, otherAttachmentNote, unanchoredNote],
            attachmentID: htmlAttachmentID
        )

        XCTAssertEqual(sidenotes.map(\.id), [htmlNote.id, legacyHTMLNote.id])
        XCTAssertEqual(sidenotes.first?.quote, "quoted text")
        XCTAssertEqual(sidenotes.first?.htmlSelector, "rp-anchor:1/2")
        XCTAssertEqual(sidenotes.first?.markdown, "**Body**")
    }

    func testSidenotePlainTextFallbackEscapesHTML() {
        XCTAssertEqual(
            HTMLSidenote.plainTextHTML("<b>x</b> & \"y\"\nnext"),
            "&lt;b&gt;x&lt;/b&gt; &amp; &quot;y&quot;<br>next"
        )
    }

    @MainActor
    func testHTMLSidenotesAlignInMarginEditInPlaceAndCollapseToPopoverWhenNarrow() async throws {
        let paragraph = String(repeating: "Reading column filler text for the margin layout test. ", count: 6)
        let html = """
        <html><head><meta charset="UTF-8"><style>
        body.rp-readability-body { margin: 0; padding: 32px 24px 56px; }
        .rp-readability-shell { max-width: 980px; margin: 0 auto; }
        </style></head><body class="rp-readability-body"><main class="rp-readability-shell">
        <div class="rp-readability-content">
        <p data-rp-segment-id="s1" data-rp-source="true">Opening sentence with the alpha phrase. \(paragraph)</p>
        <p class="rp-translation-block" data-rp-source-segment-id="s1">译文里的重点句子。</p>
        <p data-rp-segment-id="s2" data-rp-source="true">Beta phrase starts here. Gamma phrase follows.</p>
        <p data-rp-segment-id="s3" data-rp-source="true">\(paragraph)</p>
        </div></main></body></html>
        """
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0), onNoteSelectionChanged: nil, onSelectionAssistantDismissed: nil
        )
        configuration.userContentController.add(coordinator, name: HTMLReaderView.Coordinator.sidenoteMessageHandlerName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1400, height: 900), configuration: configuration)
        let loaded = expectation(description: "Sidenote document loaded")
        let observer = SidenoteNavigationObserver(loaded: loaded)
        webView.navigationDelegate = observer
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.instrumentationScript)
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.sidenoteScript)
        let originalBodyHTML = try await webView.evaluateJavaScript("document.body.innerHTML") as? String

        let alpha = HTMLSidenote(id: UUID(), quote: "alpha phrase", htmlSelector: "[data-rp-segment-id=\"s1\"]", markdown: "First **note**")
        let translated = HTMLSidenote(id: UUID(), quote: "译文里的重点句子", htmlSelector: "[data-rp-segment-id=\"s1\"]", markdown: "")
        let beta = HTMLSidenote(id: UUID(), quote: "Beta phrase", htmlSelector: "[data-rp-segment-id=\"s2\"]", markdown: "Beta note")
        let gamma = HTMLSidenote(id: UUID(), quote: "Gamma phrase", htmlSelector: "[data-rp-segment-id=\"s2\"]", markdown: "Gamma note")
        coordinator.sidenotes = [gamma, beta, translated, alpha]
        coordinator.sidenoteLabels = HTMLSidenoteLabels(placeholder: "Click to edit", editorPlaceholder: "Write", delete: "Delete")
        coordinator.renderSidenoteMarkdown = NoteMarkdownRenderer.html
        var events: [HTMLSidenoteEvent] = []
        let committed = expectation(description: "Sidenote edit committed")
        coordinator.onSidenoteEvent = { event in
            events.append(event)
            if case .bodyChanged(_, _, true) = event { committed.fulfill() }
        }
        coordinator.webView(webView, didFinish: nil)

        let wide = try await sidenoteState(in: webView)
        XCTAssertEqual(wide.mode, "margin")
        let shellRightValue = try await webView.evaluateJavaScript(
            "document.querySelector('.rp-readability-shell').getBoundingClientRect().right"
        )
        let shellRight = try XCTUnwrap(shellRightValue as? Double)
        let ordered = wide.cards.sorted { $0.top < $1.top }
        XCTAssertEqual(ordered.map(\.id), [alpha, translated, beta, gamma].map(\.id.uuidString))
        XCTAssertEqual(ordered.map(\.number), ["1", "2", "3", "4"])
        for card in ordered {
            XCTAssertTrue(card.visible)
            XCTAssertTrue(card.hasRange, "Quote should resolve to a text range: \(card.id)")
            XCTAssertGreaterThanOrEqual(card.left, shellRight + 30)
        }
        for (upper, lower) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(upper.bottom, lower.top, "Margin notes must not overlap")
        }
        let alphaCard = try XCTUnwrap(ordered.first)
        XCTAssertEqual(alphaCard.top, try XCTUnwrap(alphaCard.anchorTop) - 6, accuracy: 1)
        XCTAssertEqual(alphaCard.html.contains("<strong>note</strong>"), true)
        XCTAssertEqual(ordered[1].text, "Click to edit")
        let bodyHTML = try await webView.evaluateJavaScript("document.body.innerHTML") as? String
        XCTAssertEqual(bodyHTML, originalBodyHTML, "Margin notes must not change note-anchor DOM paths")

        coordinator.sidenoteFocusRequest = SidenoteFocusRequest(noteID: beta.id)
        coordinator.applySidenoteFocusIfNeeded(to: webView)
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const editor = document.querySelector('[data-note-id="\(beta.id.uuidString)"] textarea');
            editor.value = 'Edited *in* margin';
            editor.dispatchEvent(new Event('input'));
            editor.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
        })();
        """)
        await fulfillment(of: [committed], timeout: 5)
        XCTAssertEqual(events.last, .bodyChanged(noteID: beta.id, body: "Edited *in* margin", isFinal: true))

        var editedBeta = beta
        editedBeta.markdown = "Edited *in* margin"
        coordinator.sidenotes = [gamma, editedBeta, translated, alpha]
        coordinator.applySidenotes(to: webView)
        let edited = try await sidenoteState(in: webView)
        XCTAssertNil(edited.editingID)
        XCTAssertEqual(edited.cards.first { $0.id == beta.id.uuidString }?.html.contains("<em>in</em>"), true)

        webView.setFrameSize(CGSize(width: 700, height: 900))
        let narrow = try await sidenoteState(in: webView)
        XCTAssertEqual(narrow.mode, "compact")
        XCTAssertTrue(narrow.cards.allSatisfy { !$0.visible })
        _ = try await webView.evaluateJavaScript("window.__rpFocusSidenote('\(alpha.id.uuidString)')")
        let popover = try await sidenoteState(in: webView)
        XCTAssertEqual(popover.openID, alpha.id.uuidString)
        XCTAssertEqual(popover.cards.filter(\.visible).map(\.id), [alpha.id.uuidString])

        coordinator.sidenotes = [alpha]
        coordinator.applySidenotes(to: webView)
        let pruned = try await sidenoteState(in: webView)
        XCTAssertEqual(pruned.cards.map(\.id), [alpha.id.uuidString])
    }

    @MainActor
    func testHTMLSidenotesOnlyReserveMissingWidthWhenSiteCapsBodyWidth() async throws {
        // Reduced sigh.dev layout: the site caps <body> at 768px and keeps it left
        // aligned. Cover both box models, which react differently to padding.
        for boxSizing in ["border-box", "content-box"] {
            try await assertCappedBodyKeepsReadableColumn(boxSizing: boxSizing)
        }
    }

    @MainActor
    private func assertCappedBodyKeepsReadableColumn(boxSizing: String) async throws {
        let paragraph = String(repeating: "I haven't found much use for the personal assistant part of Muse. ", count: 5)
        let html = """
        <html><head><meta charset="UTF-8"><style>
        *, ::before, ::after { box-sizing: \(boxSizing); }
        body.rp-readability-body { margin: 0; padding: 32px 24px 56px; }
        .rp-readability-shell { max-width: 980px; margin: 0 auto; }
        body { max-width: 768px; }
        </style></head><body class="rp-readability-body"><main class="rp-readability-shell">
        <div class="rp-readability-content"><div class="md-body"><p>\(paragraph)</p><p>\(paragraph)</p></div></div>
        </main></body></html>
        """
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1400, height: 800), configuration: configuration)
        let loaded = expectation(description: "Capped body document loaded")
        let observer = SidenoteNavigationObserver(loaded: loaded)
        webView.navigationDelegate = observer
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.instrumentationScript)
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.sidenoteScript)
        let naturalWidthValue = try await webView.evaluateJavaScript(
            "document.querySelector('.md-body p').getBoundingClientRect().width"
        )
        let naturalWidth = try XCTUnwrap(naturalWidthValue as? Double)
        let notesJSON = String(data: try JSONSerialization.data(withJSONObject: [[
            "id": UUID().uuidString, "quote": "personal assistant", "htmlSelector": "rp-anchor:0/0/0/0",
            "markdown": "Note", "html": "Note",
        ]]), encoding: .utf8)!
        _ = try await webView.evaluateJavaScript("window.__rpSetSidenotes(\(notesJSON), {}); true")

        let metricsScript = """
        (() => {
            const state = window.__rpSidenoteState();
            const card = state.cards[0];
            const text = document.querySelector('.md-body p').getBoundingClientRect();
            return JSON.stringify({
                mode: state.mode, visible: card.visible, cardLeft: card.left,
                cardRight: document.querySelector('.rp-sidenote').getBoundingClientRect().right,
                textRight: text.right, textWidth: text.width,
                reserved: document.documentElement.hasAttribute('data-rp-sidenote-reserved')
            });
        })()
        """
        struct Metrics: Decodable {
            var mode: String
            var visible: Bool
            var cardLeft: Double
            var cardRight: Double
            var textRight: Double
            var textWidth: Double
            var reserved: Bool
        }
        func metrics() async throws -> Metrics {
            let json = try await webView.evaluateJavaScript(metricsScript) as? String
            return try JSONDecoder().decode(Metrics.self, from: Data(try XCTUnwrap(json).utf8))
        }

        let roomy = try await metrics()
        XCTAssertEqual(roomy.mode, "margin", boxSizing)
        XCTAssertFalse(roomy.reserved, "Pages with room beside the text keep their layout (\(boxSizing))")
        XCTAssertEqual(roomy.textWidth, naturalWidth, accuracy: 0.5, boxSizing)
        XCTAssertGreaterThanOrEqual(roomy.cardLeft, roomy.textRight + 30, boxSizing)

        webView.setFrameSize(CGSize(width: 970, height: 800))
        let tight = try await metrics()
        XCTAssertEqual(tight.mode, "margin", boxSizing)
        XCTAssertTrue(tight.visible, boxSizing)
        XCTAssertTrue(tight.reserved, boxSizing)
        XCTAssertGreaterThan(tight.textWidth, 600, "Only the missing width is taken from the text (\(boxSizing))")
        XCTAssertGreaterThanOrEqual(tight.cardLeft, tight.textRight + 30, boxSizing)
        XCTAssertLessThanOrEqual(tight.cardRight, 970, boxSizing)
    }

    func testSidenoteStackingKeepsDesiredTopsAndPushesOverlapsDown() {
        XCTAssertEqual(
            SidenoteStacking.tops(desired: [10, 20, 200, 205], heights: [30, 40, 10, 10], spacing: 8),
            [10, 48, 200, 218]
        )
        XCTAssertEqual(SidenoteStacking.tops(desired: [-50, -40], heights: [20, 20], spacing: 10), [-50, -20])
        XCTAssertEqual(SidenoteStacking.tops(desired: [], heights: [], spacing: 10), [])
    }

    func testPDFSidenoteAnchorsKeepNotesOfTheDisplayedPDF() {
        let paperID = UUID()
        let originalID = UUID()
        let translatedID = UUID()
        let original = Note(paperID: paperID, attachmentID: originalID, quote: " Original\n quote ", pageIndex: 2)
        let translated = Note(paperID: paperID, attachmentID: translatedID, quote: "译文", pageIndex: 0)
        let legacy = Note(paperID: paperID, quote: "Legacy", pageIndex: 1)
        let html = Note(paperID: paperID, attachmentID: UUID(), quote: "HTML", htmlSelector: "rp-anchor:1")
        let notes = [original, translated, legacy, html]

        let originalAnchors = PDFSidenoteAnchor.anchors(
            from: notes, attachmentID: originalID, includesUnattributedNotes: true
        )
        XCTAssertEqual(originalAnchors, [
            PDFSidenoteAnchor(id: legacy.id, pageIndex: 1, quote: "Legacy"),
            PDFSidenoteAnchor(id: original.id, pageIndex: 2, quote: "Original quote"),
        ])
        XCTAssertEqual(
            PDFSidenoteAnchor.anchors(from: notes.reversed(), attachmentID: originalID, includesUnattributedNotes: true),
            originalAnchors,
            "Reordering notes, e.g. by editing one, must not change the anchors"
        )
        XCTAssertEqual(
            PDFSidenoteAnchor.anchors(from: notes, attachmentID: translatedID, includesUnattributedNotes: false).map(\.id),
            [translated.id]
        )
    }

    @MainActor
    func testPDFSidenoteAnchorsResolveQuoteBoundsAndFollowPDFViewScrolling() async throws {
        let document = try XCTUnwrap(PDFDocument(data: try makeSidenoteTestPDF()))
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let alpha = PDFSidenoteAnchor(id: UUID(), pageIndex: 0, quote: "Alpha target")
        let beta = PDFSidenoteAnchor(id: UUID(), pageIndex: 0, quote: "beta phrase")
        let missing = PDFSidenoteAnchor(id: UUID(), pageIndex: 1, quote: "Not on this page")
        let outOfRange = PDFSidenoteAnchor(id: UUID(), pageIndex: 5, quote: "Alpha target")
        let pageText: (Int) -> String? = { document.page(at: $0)?.string }

        let alphaRect = try XCTUnwrap(PDFSidenoteAnchorResolver.pageRect(for: alpha, in: document, pageText: pageText))
        XCTAssertTrue(firstPage.selection(for: alphaRect)?.string?.contains("Alpha target") == true)
        XCTAssertEqual(alphaRect.minY, 500, accuracy: 8)
        let missingRect = try XCTUnwrap(PDFSidenoteAnchorResolver.pageRect(for: missing, in: document, pageText: pageText))
        let secondPageBounds = try XCTUnwrap(document.page(at: 1)).bounds(for: .cropBox)
        XCTAssertEqual(missingRect.maxY, secondPageBounds.maxY)
        XCTAssertEqual(missingRect.height, PDFSidenoteAnchorResolver.fallbackBandHeight)
        XCTAssertNil(PDFSidenoteAnchorResolver.pageRect(for: outOfRange, in: document, pageText: pageText))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        let coordinator = PDFReaderView.Coordinator(attachmentID: nil, pageIndex: .constant(0), onNoteSelectionChanged: nil)
        coordinator.attach(to: pdfView)
        pdfView.document = document
        let layout = PDFSidenoteLayoutModel()
        coordinator.applySidenoteAnchors(
            [alpha, beta, missing, outOfRange], layout: layout, documentReloaded: true, in: pdfView
        )
        try await waitUntil { layout.anchorTops.count == 3 }

        let before = layout.anchorTops
        let alphaTop = try XCTUnwrap(before[alpha.id])
        let betaTop = try XCTUnwrap(before[beta.id])
        let missingTop = try XCTUnwrap(before[missing.id])
        XCTAssertNil(before[outOfRange.id])
        XCTAssertEqual(betaTop - alphaTop, 300, accuracy: 2, "Tops follow page coordinates at 100% scale")
        XCTAssertGreaterThan(missingTop, betaTop)

        let highlights = firstPage.annotations.filter { "/" + ($0.type ?? "") == PDFAnnotationSubtype.highlight.rawValue }
        XCTAssertEqual(highlights.count, 2, "One highlight per found quote line; none for missing quotes")
        XCTAssertTrue(try XCTUnwrap(document.page(at: 1)).annotations.isEmpty)
        let alphaHighlight = try XCTUnwrap(highlights.first { $0.bounds.intersects(alphaRect) })
        let restingAlpha = alphaHighlight.color.alphaComponent
        layout.setActiveNote(alpha.id)
        XCTAssertGreaterThan(alphaHighlight.color.alphaComponent, restingAlpha, "The hovered note's highlight is emphasized")
        layout.setActiveNote(nil)
        XCTAssertEqual(alphaHighlight.color.alphaComponent, restingAlpha, accuracy: 0.01)

        pdfView.go(to: try XCTUnwrap(document.page(at: 1)))
        try await waitUntil { layout.anchorTops[alpha.id] != alphaTop }
        let after = layout.anchorTops
        let alphaShift = alphaTop - (try XCTUnwrap(after[alpha.id]))
        let missingShift = missingTop - (try XCTUnwrap(after[missing.id]))
        XCTAssertGreaterThan(alphaShift, 100, "Scrolling down moves anchors up")
        XCTAssertEqual(alphaShift, missingShift, accuracy: 1)

        coordinator.applySidenoteAnchors([], layout: layout, documentReloaded: false, in: pdfView)
        try await waitUntil { layout.anchorTops.isEmpty }
        XCTAssertTrue(firstPage.annotations.isEmpty, "Removing notes removes their highlights")
        coordinator.detach()
    }

    private func makeSidenoteTestPDF() throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let pages: [[(String, CGFloat)]] = [
            [("Alpha target sentence", 500), ("Lower beta phrase", 200)],
            [("Second page text", 500)],
        ]
        for lines in pages {
            context.beginPDFPage(nil)
            for (line, y) in lines {
                let text = NSAttributedString(
                    string: line,
                    attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
                )
                context.textPosition = CGPoint(x: 40, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func sidenoteState(in webView: WKWebView) async throws -> SidenoteState {
        let json = try await webView.evaluateJavaScript("JSON.stringify(window.__rpSidenoteState())") as? String
        return try JSONDecoder().decode(SidenoteState.self, from: Data(try XCTUnwrap(json).utf8))
    }
}

private struct SidenoteState: Decodable {
    struct Card: Decodable {
        var id: String
        var number: String
        var visible: Bool
        var hasRange: Bool
        var left: Double
        var top: Double
        var bottom: Double
        var anchorTop: Double?
        var text: String
        var html: String
    }

    var mode: String
    var editingID: String?
    var openID: String?
    var cards: [Card]
}

@MainActor
private final class SidenoteNavigationObserver: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) {
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
