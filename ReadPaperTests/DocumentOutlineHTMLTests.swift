import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

@MainActor
final class DocumentOutlineHTMLTests: XCTestCase {
    func testDOMOutlineSkipsHiddenAndSyntheticHeadingsAndTracksTranslationAndScroll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paper.html")
        try #"""
        <html><head><meta charset="UTF-8"></head><body>
        <h1>Document</h1>
        <h2 id="intro" data-rp-segment-id="s1">Introduction</h2>
        <h2 class="rp-translation-block" data-rp-source-segment-id="s1">引言</h2>
        <section data-rp-region-hidden="true" style="display:none"><h2>Hidden heading</h2></section>
        <span class="rp-tex-math"><h3>Math artifact</h3></span>
        <div style="height:1200px">Body</div><h2 id="methods">Methods</h2>
        <div style="height:1000px">Body</div>
        </body></html>
        """#.write(to: url, atomically: true, encoding: .utf8)
        var entries: [DocumentOutlineEntry] = []
        var current: String?
        let coordinator = HTMLReaderView.Coordinator(scrollRatio: .constant(0), onNoteSelectionChanged: nil, onSelectionAssistantDismissed: nil)
        coordinator.loadedURL = url
        coordinator.onOutlineChanged = { entries = $0; current = $1 }
        let configuration = HTMLReaderView.makeConfiguration(coordinator: coordinator)
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 500), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        webView.loadFileURL(url, allowingReadAccessTo: directory)
        try await waitUntil { entries.count == 3 }
        XCTAssertEqual(entries.map(\.title), ["Document", "Introduction", "Methods"])
        XCTAssertEqual(entries[1].translation, "引言")
        XCTAssertTrue(entries.allSatisfy { $0.anchor?.hasPrefix("rp-anchor:") == true })
        let methodsID = entries[2].id
        _ = try await webView.evaluateJavaScript("document.getElementById('methods').scrollIntoView(); true")
        try await waitUntil { current == methodsID }
        // An in-page link adds a fragment to location.href; the outline must keep updating.
        let introID = entries[1].id
        _ = try await webView.evaluateJavaScript("location.hash = 'intro'; true")
        try await waitUntil { current == introID }
        _ = try await webView.evaluateJavaScript("document.getElementById('methods').scrollIntoView(); true")
        try await waitUntil { current == methodsID }
        // Mutation-driven updates keep both heading translations and hidden-region edits current.
        _ = try await webView.evaluateJavaScript("document.querySelector('.rp-translation-block').textContent = '新的引言'; document.getElementById('methods').setAttribute('data-rp-region-hidden', 'true'); true")
        try await waitUntil { entries.count == 2 && entries[1].translation == "新的引言" }
        XCTAssertFalse(entries.contains { $0.id == methodsID })
    }

    func testPanelKeyboardNavigationFilteringPinAndEscape() async throws {
        let model = DocumentOutlineModel()
        let entries = ["Introduction", "Methods", "Experiments"].enumerated().map { index, title in
            DocumentOutlineEntry(id: String(index), title: title, level: 1, anchor: "rp-anchor:\(index)")
        }
        model.updateHTML(entries, currentID: "0")
        model.isPresented = true
        var navigations: [String] = []
        let panel = DocumentOutlinePanel(model: model, isHTML: true, onNavigate: { navigations.append($0.id) }, onOrganize: {})
        let hosting = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        sendKey("\u{F701}", code: 125, window: window)
        sendKey("\r", code: 36, window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(navigations, ["1"])
        XCTAssertFalse(model.isPresented, "Unpinned navigation closes the panel")
        model.isPresented = true
        model.isPinned = true
        // Direct typing filters the entries; Return opens the matching heading.
        for character in "Experiments" { sendKey(String(character), code: 0, window: window) }
        try await Task.sleep(for: .milliseconds(100))
        sendKey("\r", code: 36, window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(navigations.last, "2")
        XCTAssertTrue(model.isPresented, "Pinned navigation keeps the panel open")
        sendKey("\u{1B}", code: 53, window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isPresented)

    }

    private func sendKey(_ characters: String, code: UInt16, window: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
            window.sendEvent(event)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The HTML outline did not reach the expected state")
        throw CocoaError(.coderReadCorrupt)
    }
}
