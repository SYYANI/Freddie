import SwiftSoup
import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

final class HTMLRegionVisibilityTests: XCTestCase {
    func testAnchorPathsSkipReaderOnlyElementsAndRoundTrip() throws {
        let document = try SwiftSoup.parse("""
        <html><body><main>
        <p id="first" data-rp-segment-id="s1">First <span class="rp-tex-math">x</span><em>emphasis</em></p>
        <p class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="s1">第一段</p>
        <div><span>Share</span><a href="https://example.com">X</a></div>
        </main></body></html>
        """)
        let body = try XCTUnwrap(document.body())
        let share = try XCTUnwrap(document.select("div").first())
        let emphasis = try XCTUnwrap(document.select("em").first())
        let translation = try XCTUnwrap(document.select(".rp-translation-block").first())

        XCTAssertEqual(HTMLAnchorPath.path(of: share), "rp-anchor:0/1")
        XCTAssertEqual(HTMLAnchorPath.path(of: emphasis), "rp-anchor:0/0/0", "Typeset TeX must not shift indices")
        XCTAssertNil(HTMLAnchorPath.path(of: translation), "Translation blocks only exist next to their source")
        XCTAssertTrue(HTMLAnchorPath.element(at: "rp-anchor:", in: document) === body)
        XCTAssertNil(HTMLAnchorPath.element(at: "rp-anchor:0/5", in: document))
        XCTAssertNil(HTMLAnchorPath.element(at: "[data-rp-segment-id=\"s1\"]", in: document))
        XCTAssertEqual(HTMLAnchorPath.signature(of: share), "div||2|span,a")
        XCTAssertEqual(HTMLAnchorPath.signature(of: try XCTUnwrap(document.getElementById("first"))), "p|first|1|em")

        for element in try body.select("*").array() {
            guard let path = HTMLAnchorPath.path(of: element) else { continue }
            XCTAssertTrue(HTMLAnchorPath.element(at: path, in: document) === element, path)
        }
    }

    func testApplyingHidesAndRestoresRegionsAndPersistsTheHidingStyle() throws {
        let html = """
        <!doctype html><html><head><meta charset="UTF-8"><title>Page</title></head><body>
        <main><p>Keep this paragraph.</p><div class="share"><span>Share</span><a href="https://example.com">X</a></div></main>
        </body></html>
        """
        let hide = HTMLRegionChange(path: "rp-anchor:0/1", signature: "div||2|span,a", isHidden: true)

        let hidden = try HTMLRegionVisibility.applying([hide], toHTML: html)
        XCTAssertTrue(hidden.didChange)
        XCTAssertEqual(hidden.hiddenRegionCount, 1)
        XCTAssertEqual(hidden.unmatchedChanges, [])
        let hiddenDocument = try SwiftSoup.parse(hidden.html)
        XCTAssertEqual(try hiddenDocument.select("div.share").first()?.attr("data-rp-region-hidden"), "true")
        XCTAssertEqual(
            try hiddenDocument.getElementById(HTMLRegionVisibility.styleElementID)?.data(),
            HTMLRegionVisibility.hiddenRegionCSS
        )
        XCTAssertEqual(try hiddenDocument.select("meta[charset]").first()?.attr("charset"), "UTF-8")
        XCTAssertEqual(try hiddenDocument.select("main > p").text(), "Keep this paragraph.")

        let repeated = try HTMLRegionVisibility.applying([hide], toHTML: hidden.html)
        XCTAssertFalse(repeated.didChange)
        XCTAssertEqual(repeated.html, hidden.html)

        var restore = hide
        restore.isHidden = false
        let restored = try HTMLRegionVisibility.applying([restore], toHTML: hidden.html)
        XCTAssertTrue(restored.didChange)
        XCTAssertEqual(restored.hiddenRegionCount, 0)
        let restoredDocument = try SwiftSoup.parse(restored.html)
        XCTAssertFalse(try XCTUnwrap(restoredDocument.select("div.share").first()).hasAttr("data-rp-region-hidden"))
        XCTAssertNil(try restoredDocument.getElementById(HTMLRegionVisibility.styleElementID))
    }

    func testApplyingRejectsChangesThatNoLongerMatchTheSavedElement() throws {
        let html = #"<html><head><meta charset="UTF-8"></head><body><p>One</p><p>Two <em>three</em></p></body></html>"#
        let stale = HTMLRegionChange(path: "rp-anchor:1", signature: "p||0|", isHidden: true)
        let missing = HTMLRegionChange(path: "rp-anchor:7", signature: "p||0|", isHidden: true)

        let update = try HTMLRegionVisibility.applying([stale, missing], toHTML: html)

        XCTAssertFalse(update.didChange)
        XCTAssertEqual(update.html, html)
        XCTAssertEqual(update.unmatchedChanges, [stale, missing])
    }

    func testApplyingDeclaresUTF8WhenTheSavedPageDoesNot() throws {
        let html = #"<html><head><meta http-equiv="Content-Type" content="text/html; charset=ISO-8859-1"></head><body><p>Café</p></body></html>"#

        let update = try HTMLRegionVisibility.applying(
            [HTMLRegionChange(path: "rp-anchor:0", signature: "p||0|", isHidden: true)],
            toHTML: html
        )

        let document = try SwiftSoup.parse(update.html)
        XCTAssertEqual(try document.head()?.child(0).attr("charset"), "UTF-8")
        XCTAssertEqual(try document.select("meta[http-equiv]").count, 0)
    }

    @MainActor
    func testApplyToFileOnlyRewritesThePageWhenRegionsChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("paper.html")
        let html = #"<html><head><meta charset="UTF-8"></head><body><nav>Menu</nav><p>Article</p></body></html>"#
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        let hideNavigation = HTMLRegionChange(path: "rp-anchor:0", signature: "nav||0|", isHidden: true)

        try HTMLRegionVisibility.apply([hideNavigation], toFileAt: fileURL)
        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains(#"<nav data-rp-region-hidden="true">Menu</nav>"#))

        let unchanged = try HTMLRegionVisibility.apply([hideNavigation], toFileAt: fileURL)
        XCTAssertFalse(unchanged.didChange)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), saved)
    }

    @MainActor
    func testWriterSavesEditsInTheOrderTheyWereMade() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("paper.html")
        try #"<html><head><meta charset="UTF-8"></head><body><nav>Menu</nav><p>Article</p></body></html>"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let navigation = HTMLRegionChange(path: "rp-anchor:0", signature: "nav||0|", isHidden: true)
        let article = HTMLRegionChange(path: "rp-anchor:1", signature: "p||0|", isHidden: true)
        var restoredNavigation = navigation
        restoredNavigation.isHidden = false

        let writer = HTMLRegionWriter()
        var hiddenCounts: [Int] = []
        for changes in [[navigation], [article], [restoredNavigation]] {
            writer.write(changes, toFileAt: fileURL) { result in
                hiddenCounts.append((try? result.get().hiddenRegionCount) ?? -1)
            }
        }
        await writer.waitForQueuedWrites()

        XCTAssertEqual(hiddenCounts, [1, 2, 1])
        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("<nav>Menu</nav>"))
        XCTAssertTrue(saved.contains(#"<p data-rp-region-hidden="true">Article</p>"#))
    }

    @MainActor
    func testWriterFinishesQueuedEditsBeforeTermination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("paper.html")
        try #"<html><head><meta charset="UTF-8"></head><body><nav>Menu</nav><p>Article</p></body></html>"#
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let writer = HTMLRegionWriter()
        writer.write([HTMLRegionChange(path: "rp-anchor:0", signature: "nav||0|", isHidden: true)], toFileAt: fileURL) { _ in }
        writer.write([HTMLRegionChange(path: "rp-anchor:1", signature: "p||0|", isHidden: true)], toFileAt: fileURL) { _ in }
        // Termination cannot wait for tasks, so the edits must be on disk when this returns.
        writer.finishBeforeTermination()

        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains(#"<nav data-rp-region-hidden="true">Menu</nav>"#))
        XCTAssertTrue(saved.contains(#"<p data-rp-region-hidden="true">Article</p>"#))
    }

    @MainActor
    func testReaderEditsResolveToTheSameElementsInTheSavedPage() async throws {
        let html = Self.readerHTML
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0), onNoteSelectionChanged: nil, onSelectionAssistantDismissed: nil
        )
        configuration.userContentController.add(coordinator, name: HTMLRegionEditing.messageHandlerName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 1000), configuration: configuration)
        let loaded = expectation(description: "Region document loaded")
        let observer = RegionNavigationObserver(loaded: loaded)
        webView.navigationDelegate = observer
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        if !HTMLTeXRendering.userScript.isEmpty {
            _ = try await webView.evaluateJavaScript(HTMLTeXRendering.userScript)
        }
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.instrumentationScript)
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.findScript)
        _ = try await webView.evaluateJavaScript(HTMLRegionEditing.script)
        let bodyHTMLBeforeEditing = try await webView.evaluateJavaScript("document.body.innerHTML") as? String

        let recorder = RegionEditRecorder()
        coordinator.onRegionEditEvent = { event in recorder.record(event) }
        coordinator.isRegionEditing = true
        coordinator.regionEditLabels = HTMLRegionEditLabels(hide: "Hide", restore: "Restore")
        coordinator.webView(webView, didFinish: nil)
        try await recorder.waitForUpdates(1)
        XCTAssertEqual(recorder.updates.last?.changes, [])
        XCTAssertEqual(recorder.updates.last?.hiddenRegionCount, 0)

        // Inline content picks the enclosing block, and the click must not follow the link.
        let shareLinkDefaultPrevented = try await click(".share a", in: webView)
        XCTAssertTrue(shareLinkDefaultPrevented)
        try await recorder.waitForUpdates(2)
        // Clicking a translation edits its source; clicking the faded source again restores it.
        _ = try await click("#intro em", in: webView)
        _ = try await click(".rp-translation-block", in: webView)
        _ = try await click(".rp-translation-block", in: webView)
        try await recorder.waitForUpdates(5)
        XCTAssertEqual(recorder.updates[3].changes.map(\.isHidden), [false])

        // ↑ grows the outline to the parent block but never to the wrapper spanning the article.
        try await hover("#methods-one", in: webView)
        try await press(["key": "ArrowUp"], in: webView)
        try await press(["key": "ArrowUp"], in: webView)
        var state = try await editState(in: webView)
        XCTAssertEqual(state["selectedTag"] as? String, "section")
        XCTAssertEqual(state["action"] as? String, "Hide")
        _ = try await click("#methods-one", in: webView)
        try await recorder.waitForUpdates(6)
        state = try await editState(in: webView)
        XCTAssertEqual(state["action"] as? String, "Restore")

        // Table parts are skipped so a hover outlines the whole table.
        try await hover("td", in: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["selectedTag"] as? String, "table")

        try await press(["key": "z", "metaKey": true], in: webView)
        try await recorder.waitForUpdates(7)
        XCTAssertEqual(recorder.updates[6].changes.map(\.isHidden), [false])
        XCTAssertEqual(recorder.updates[6].canRedo, true)
        try await press(["key": "Z", "metaKey": true, "shiftKey": true], in: webView)
        try await recorder.waitForUpdates(8)
        XCTAssertEqual(recorder.updates[7].hiddenRegionCount, 3)
        try await press(["key": "Escape"], in: webView)
        try await waitUntil { recorder.exitRequests == 1 }

        // Every reported path names the same element in the saved file.
        let savedDocument = try SwiftSoup.parse(html)
        let expectedPaths = try [".share", "#intro", "section"].map { selector in
            try XCTUnwrap(HTMLAnchorPath.path(of: try XCTUnwrap(savedDocument.select(selector).first())))
        }
        let latestChanges = Dictionary(
            recorder.updates.flatMap(\.changes).map { ($0.path, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        XCTAssertEqual(Set(latestChanges.keys), Set(expectedPaths))
        let saved = try HTMLRegionVisibility.applying(Array(latestChanges.values), toHTML: html)
        XCTAssertEqual(saved.unmatchedChanges, [])
        XCTAssertEqual(saved.hiddenRegionCount, 3)
        let hiddenTexts = try SwiftSoup.parse(saved.html).select("[data-rp-region-hidden=true]").array().map { try $0.text() }
        XCTAssertEqual(hiddenTexts.count, 3)
        XCTAssertTrue(hiddenTexts[0].hasPrefix("Intro text"))
        XCTAssertEqual(hiddenTexts[1], "Share on X")
        XCTAssertTrue(hiddenTexts[2].hasPrefix("Methods"))

        coordinator.isRegionEditing = false
        coordinator.applyRegionEditing(to: webView)
        let finalState = try await jsonObject("""
        JSON.stringify({
            share: getComputedStyle(document.querySelector('.share')).display,
            intro: getComputedStyle(document.getElementById('intro')).display,
            translation: getComputedStyle(document.querySelector('.rp-translation-block')).display,
            section: getComputedStyle(document.querySelector('section')).display,
            table: getComputedStyle(document.querySelector('table')).display,
            editing: document.documentElement.hasAttribute('\(HTMLRegionVisibility.editingAttribute)'),
            outlineVisible: document.querySelector('.rp-region-edit-box').classList.contains('is-visible'),
            sectionAnchorStable: window.__rpResolveNoteAnchor('\(expectedPaths[2])') === document.querySelector('section'),
            findText: JSON.parse(window.__rpFindCollect()).segments.join(' '),
            bodyHTML: document.body.innerHTML.replaceAll(' \(HTMLRegionVisibility.hiddenAttribute)="true"', '')
        })
        """, in: webView)
        XCTAssertEqual(finalState["share"] as? String, "none")
        XCTAssertEqual(finalState["intro"] as? String, "none")
        XCTAssertEqual(finalState["translation"] as? String, "none", "A hidden source also hides its translation")
        XCTAssertEqual(finalState["section"] as? String, "none")
        XCTAssertNotEqual(finalState["table"] as? String, "none")
        XCTAssertEqual(finalState["editing"] as? Bool, false)
        XCTAssertEqual(finalState["outlineVisible"] as? Bool, false)
        XCTAssertEqual(finalState["sectionAnchorStable"] as? Bool, true)
        let findText = try XCTUnwrap(finalState["findText"] as? String)
        XCTAssertTrue(findText.contains("Cell A"))
        XCTAssertFalse(findText.contains("Share on"))
        XCTAssertFalse(findText.contains("Methods paragraph"))
        XCTAssertEqual(finalState["bodyHTML"] as? String, bodyHTMLBeforeEditing, "Editing must only toggle the hidden attribute")
    }

    @MainActor
    func testOutlinesNameWhatTheyHoldAndSkipWrappersOfTheSameSize() async throws {
        let page = try await loadEditingPage(Self.outlineHTML)
        let (webView, coordinator, recorder) = (page.webView, page.coordinator, page.recorder)
        let savedDocument = try SwiftSoup.parse(Self.outlineHTML)
        func path(_ selector: String) throws -> String {
            try XCTUnwrap(HTMLAnchorPath.path(of: try XCTUnwrap(savedDocument.select(selector).first())))
        }
        // The reader learns about regions hidden earlier before editing starts.
        try await waitUntil { recorder.loadedHiddenRegionCounts == [1] }

        coordinator.isRegionEditing = true
        coordinator.regionEditLabels = Self.labels
        coordinator.webView(webView, didFinish: nil)
        try await recorder.waitForUpdates(1)
        XCTAssertEqual(recorder.updates[0].hiddenRegions, [
            HTMLHiddenRegion(path: try path("#hidden-note"), kind: "Paragraph", text: "Hidden before editing.")
        ])

        try await hover("#short", in: webView)
        var state = try await editState(in: webView)
        XCTAssertEqual(state["kind"] as? String, "Paragraph")
        XCTAssertEqual(state["hint"] as? String, "p#short")
        XCTAssertTrue((state["share"] as? String)?.hasSuffix("% of the text") == true)
        XCTAssertEqual(state["largeShare"] as? Bool, false)
        XCTAssertEqual(state["parentOutlineVisible"] as? Bool, false)

        // A wrapper exactly as large as its paragraph adds no step; hiding it leaves no empty margins.
        try await hover("#framed", in: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["selectedTag"] as? String, "div")
        XCTAssertEqual(state["kind"] as? String, "Paragraph")
        XCTAssertEqual(state["hint"] as? String, "div.frame")

        // The dashed outline shows what ↑ selects next.
        try await hover("#bio-title", in: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["kind"] as? String, "Heading")
        XCTAssertEqual(state["parentOutlineVisible"] as? Bool, true)
        try await press(["key": "ArrowUp"], in: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["kind"] as? String, "Block")
        XCTAssertEqual(state["hint"] as? String, "section.author-box")
        XCTAssertEqual(state["parentOutlineVisible"] as? Bool, false)

        try await hover("#long", in: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["largeShare"] as? Bool, true, "Hiding most of the page's text is flagged")

        // The translated display mode hides sources; a translation still outlines its own source.
        _ = try await webView.evaluateJavaScript("document.documentElement.setAttribute('data-rp-display-mode', 'translated'); true")
        try await hover(".rp-translation-block", in: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["selectedPath"] as? String, try path("#source"))
        XCTAssertEqual(state["kind"] as? String, "Paragraph")
        _ = try await webView.evaluateJavaScript("document.documentElement.removeAttribute('data-rp-display-mode'); true")

        // The second click of a double-click must not restore what the first one hid.
        _ = try await click("#short", in: webView)
        try await recorder.waitForUpdates(2)
        _ = try await click("#short", detail: 2, in: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["restoring"] as? Bool, true)
        try await press(["key": "z", "metaKey": true], in: webView)
        try await recorder.waitForUpdates(3)
        XCTAssertEqual(recorder.updates[2].canRedo, true, "The update after the double-click is the undo")
        XCTAssertEqual(recorder.updates[2].changes.map(\.path), [try path("#short")])

        // Choosing a hidden region in the bar's list outlines it, ready to restore with Enter.
        coordinator.regionEditCommand = HTMLRegionEditCommand(action: .reveal(path: try path("#hidden-note")))
        coordinator.applyRegionEditCommandIfNeeded(to: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["selectedPath"] as? String, try path("#hidden-note"))
        XCTAssertEqual(state["restoring"] as? Bool, true)
        XCTAssertEqual(state["outlineVisible"] as? Bool, true)
        try await press(["key": "Enter"], in: webView)
        try await recorder.waitForUpdates(4)
        XCTAssertEqual(recorder.updates[3].changes.map(\.path), [try path("#hidden-note")])
        XCTAssertEqual(recorder.updates[3].changes.map(\.isHidden), [false])
        XCTAssertEqual(recorder.updates[3].hiddenRegions, [])
    }

    @MainActor
    func testShiftClickMakesTheLastChangeToEverythingInBetween() async throws {
        let page = try await loadEditingPage(Self.rangeHTML)
        let (webView, coordinator, recorder) = (page.webView, page.coordinator, page.recorder)
        let savedDocument = try SwiftSoup.parse(Self.rangeHTML)
        func path(_ selector: String) throws -> String {
            try XCTUnwrap(HTMLAnchorPath.path(of: try XCTUnwrap(savedDocument.select(selector).first())))
        }
        coordinator.isRegionEditing = true
        coordinator.regionEditLabels = Self.labels
        coordinator.webView(webView, didFinish: nil)
        try await recorder.waitForUpdates(1)

        _ = try await click(".rp-readability-byline", in: webView)
        try await recorder.waitForUpdates(2)

        // Holding Shift previews the run from the last edit to the region under the pointer.
        try await press(["key": "Shift", "shiftKey": true], in: webView)
        try await hover("#second", shiftKey: true, in: webView)
        var state = try await editState(in: webView)
        XCTAssertEqual(state["rangeCount"] as? Int, 4)
        XCTAssertEqual(state["action"] as? String, "Hide")
        XCTAssertEqual(state["kind"] as? String, "4 regions")

        // The run reaches from the header into the article without taking the title or a wrapper.
        _ = try await click("#second", shiftKey: true, in: webView)
        try await recorder.waitForUpdates(3)
        XCTAssertEqual(
            Set(recorder.updates[2].changes.map(\.path)),
            Set(try [".rp-readability-excerpt", "#first", "#second"].map(path))
        )
        XCTAssertEqual(recorder.updates[2].hiddenRegionCount, 4)
        try await release(["key": "Shift"], in: webView)

        // A container whose content lies in the run is taken whole, though the run ends at its last child.
        _ = try await click("#third", in: webView)
        try await recorder.waitForUpdates(4)
        _ = try await click("#bio", shiftKey: true, in: webView)
        try await recorder.waitForUpdates(5)
        XCTAssertEqual(recorder.updates[4].changes.map(\.path), [try path("#end")])

        // One undo step covers the whole run.
        try await press(["key": "z", "metaKey": true], in: webView)
        try await recorder.waitForUpdates(6)
        XCTAssertEqual(recorder.updates[5].changes.map(\.path), [try path("#end")])
        XCTAssertEqual(recorder.updates[5].changes.map(\.isHidden), [false])

        // After restoring a region, a Shift-click restores the hidden regions in between instead.
        _ = try await click("#first", in: webView)
        try await recorder.waitForUpdates(7)
        XCTAssertEqual(recorder.updates[6].changes.map(\.isHidden), [false])
        _ = try await click(".rp-readability-byline", shiftKey: true, in: webView)
        try await recorder.waitForUpdates(8)
        XCTAssertEqual(
            Set(recorder.updates[7].changes.map(\.path)),
            Set(try [".rp-readability-byline", ".rp-readability-excerpt"].map(path))
        )
        XCTAssertEqual(Set(recorder.updates[7].changes.map(\.isHidden)), [false])

        // Every change names the element it was made on in the saved file.
        let latestChanges = Dictionary(
            recorder.updates.flatMap(\.changes).map { ($0.path, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        XCTAssertTrue(Set(latestChanges.keys).isSubset(of: Set(try [
            ".rp-readability-byline", ".rp-readability-excerpt", "#first", "#second", "#third", "#end",
        ].map(path))))
        let saved = try HTMLRegionVisibility.applying(Array(latestChanges.values), toHTML: Self.rangeHTML)
        XCTAssertEqual(saved.unmatchedChanges, [])
        XCTAssertEqual(try SwiftSoup.parse(saved.html).select("[data-rp-region-hidden=true]").array().map { $0.id() }, ["second", "third"])
    }

    private static let labels = HTMLRegionEditLabels(
        hide: "Hide",
        restore: "Restore",
        kinds: ["paragraph": "Paragraph", "heading": "Heading", "block": "Block"],
        regions: "{count} regions",
        share: "{share} of the text"
    )

    private static let outlineHTML = #"""
    <!doctype html>
    <html><head><meta charset="UTF-8"><style>
    body { margin: 0; padding: 20px; font: 16px -apple-system; }
    p { margin: 12px 0; }
    .frame { margin: 0; padding: 0; }
    </style></head>
    <body class="rp-readability-body"><main class="rp-readability-shell">
    <div class="rp-readability-header"><h1 class="rp-readability-title">Outlines</h1><p class="rp-readability-byline">By Someone</p></div>
    <article class="rp-readability-content"><div id="readability-page-1" class="page"><div class="wrapper">
    <p id="short">A short paragraph.</p>
    <div class="frame"><p id="framed">A paragraph in a wrapper of the same size.</p></div>
    <section class="author-box"><h2 id="bio-title">About the author</h2><p>Bio.</p></section>
    <p id="long">Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page. Long body text that holds most of the page.</p>
    <p id="hidden-note" data-rp-region-hidden="true">Hidden before editing.</p>
    <section id="translated"><p id="source" data-rp-segment-id="s1" data-rp-source="true">Source paragraph.</p><p class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="s1">译文段落。</p><p>Other paragraph.</p></section>
    </div></div></article>
    </main></body></html>
    """#

    private static let rangeHTML = #"""
    <!doctype html>
    <html><head><meta charset="UTF-8"><style>body { margin: 0; padding: 20px; font: 16px -apple-system; }</style></head>
    <body class="rp-readability-body"><main class="rp-readability-shell">
    <div class="rp-readability-header"><h1 class="rp-readability-title">Range Editing</h1><p class="rp-readability-byline">By Someone</p><p class="rp-readability-excerpt">An excerpt of the article.</p></div>
    <article class="rp-readability-content"><div id="readability-page-1" class="page"><div class="wrapper">
    <p id="first">First paragraph of the preamble.</p>
    <p id="second">Second paragraph of the preamble.</p>
    <p id="third">The document starts here.</p>
    <section id="end">
      <h2>About the author</h2>
      <p id="bio">Bio.</p>
    </section>
    </div></div></article>
    </main></body></html>
    """#

    private struct EditingPage {
        var webView: WKWebView
        var coordinator: HTMLReaderView.Coordinator
        var recorder: RegionEditRecorder
        /// Navigation delegates are weak; this keeps the observer alive.
        var observer: RegionNavigationObserver
    }

    /// Loads a page with the reader scripts the region editor relies on, recording its events from the start.
    @MainActor
    private func loadEditingPage(_ html: String) async throws -> EditingPage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0), onNoteSelectionChanged: nil, onSelectionAssistantDismissed: nil
        )
        configuration.userContentController.add(coordinator, name: HTMLRegionEditing.messageHandlerName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 1000), configuration: configuration)
        let loaded = expectation(description: "Region document loaded")
        let observer = RegionNavigationObserver(loaded: loaded)
        webView.navigationDelegate = observer
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        let recorder = RegionEditRecorder()
        coordinator.onRegionEditEvent = { event in recorder.record(event) }
        if !HTMLTeXRendering.userScript.isEmpty {
            _ = try await webView.evaluateJavaScript(HTMLTeXRendering.userScript)
        }
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.instrumentationScript)
        _ = try await webView.evaluateJavaScript(HTMLRegionEditing.script)
        return EditingPage(webView: webView, coordinator: coordinator, recorder: recorder, observer: observer)
    }

    private static let readerHTML = #"""
    <!doctype html>
    <html><head><meta charset="UTF-8"><style>body { margin: 0; padding: 20px; font: 16px -apple-system; }</style></head>
    <body class="rp-readability-body"><main class="rp-readability-shell">
    <div class="rp-readability-header"><h1 class="rp-readability-title">Region Editing</h1></div>
    <article class="rp-readability-content"><div id="readability-page-1" class="page"><div class="wrapper">
    <p id="intro" data-rp-segment-id="s1" data-rp-source="true"><em>Intro text</em> with math \(x^2\) and <a href="https://example.com/intro">a link</a>.</p>
    <p class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="s1">介绍文字，包含公式。</p>
    <div class="share"><span>Share on</span> <a href="https://example.com/share">X</a></div>
    <section><h2>Methods</h2><p id="methods-one">Methods paragraph one.</p><p>Methods paragraph two.</p></section>
    <table><tbody><tr><td>Cell A</td><td>Cell B</td></tr></tbody></table>
    </div></div></article>
    </main></body></html>
    """#

    @MainActor
    private func click(
        _ selector: String,
        shiftKey: Bool = false,
        detail: Int = 1,
        in webView: WKWebView
    ) async throws -> Bool {
        let result = try await webView.evaluateJavaScript("""
        (() => {
            const target = document.querySelector(\(Self.literal(selector)));
            const rect = target.getClientRects()[0];
            const x = rect.left + Math.min(6, rect.width / 2);
            const y = rect.top + rect.height / 2;
            const event = new MouseEvent('click', {
                clientX: x, clientY: y, bubbles: true, cancelable: true, button: 0,
                shiftKey: \(shiftKey), detail: \(detail)
            });
            (document.elementFromPoint(x, y) || target).dispatchEvent(event);
            return event.defaultPrevented;
        })()
        """)
        return try XCTUnwrap(result as? Bool)
    }

    @MainActor
    private func hover(_ selector: String, shiftKey: Bool = false, in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const target = document.querySelector(\(Self.literal(selector)));
            const rect = target.getClientRects()[0];
            const x = rect.left + Math.min(6, rect.width / 2);
            const y = rect.top + rect.height / 2;
            (document.elementFromPoint(x, y) || target).dispatchEvent(
                new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true, shiftKey: \(shiftKey) })
            );
            return true;
        })()
        """)
    }

    @MainActor
    private func press(_ key: [String: Any], in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: key)
        let options = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("""
        (() => {
            window.dispatchEvent(new KeyboardEvent('keydown', Object.assign({ bubbles: true, cancelable: true }, \(options))));
            return true;
        })()
        """)
    }

    @MainActor
    private func release(_ key: [String: Any], in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: key)
        let options = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("""
        (() => {
            window.dispatchEvent(new KeyboardEvent('keyup', Object.assign({ bubbles: true, cancelable: true }, \(options))));
            return true;
        })()
        """)
    }

    @MainActor
    private func editState(in webView: WKWebView) async throws -> [String: Any] {
        try await jsonObject("window.__rpRegionEditState()", in: webView)
    }

    @MainActor
    private func jsonObject(_ script: String, in webView: WKWebView) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript(script)
        let json = try XCTUnwrap(result as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while condition() == false {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the page")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func literal(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }
}

@MainActor
private final class RegionEditRecorder {
    var updates: [HTMLRegionEditUpdate] = []
    var loadedHiddenRegionCounts: [Int] = []
    var exitRequests = 0

    func record(_ event: HTMLRegionEditEvent) {
        switch event {
        case let .loaded(_, hiddenRegionCount):
            loadedHiddenRegionCounts.append(hiddenRegionCount)
        case let .updated(update):
            updates.append(update)
        case .exitRequested:
            exitRequests += 1
        }
    }

    func waitForUpdates(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while updates.count < count {
            guard Date() < deadline else {
                XCTFail("Expected \(count) region updates, got \(updates.count)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class RegionNavigationObserver: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) {
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
