import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import ReadPaper

@MainActor
final class PDFDropTargetTests: XCTestCase {
    func testPDFURLsKeepsLocalPDFsInDragOrderWithoutDuplicates() throws {
        let fixture = try DropFixture()
        defer { fixture.tearDown() }
        let first = try fixture.makeFile("first.pdf")
        let notes = try fixture.makeFile("notes.txt")
        let second = try fixture.makeFile("second.PDF")
        let pasteboard = fixture.makePasteboard(urls: [
            first,
            notes,
            second,
            first,
            try XCTUnwrap(URL(string: "https://arxiv.org/pdf/1706.03762")),
        ])

        XCTAssertEqual(
            PDFFileDropCatcherView.pdfURLs(on: pasteboard).map { $0.resolvingSymlinksInPath() },
            [first, second].map { $0.resolvingSymlinksInPath() }
        )
    }

    func testDragOfPDFsTargetsTheWindowAndDropsOnlyThePDFs() throws {
        let fixture = try DropFixture()
        defer { fixture.tearDown() }
        let pdf = try fixture.makeFile("paper.pdf")
        let notes = try fixture.makeFile("notes.txt")
        let catcher = PDFFileDropCatcherView(frame: .zero)
        var targetedChanges: [Bool] = []
        var droppedURLs: [[URL]] = []
        catcher.onTargetedChange = { targetedChanges.append($0) }
        catcher.onDrop = { urls in
            droppedURLs.append(urls)
            return true
        }
        let drag = FakeDraggingInfo(pasteboard: fixture.makePasteboard(urls: [notes, pdf]), sequenceNumber: 1)

        XCTAssertEqual(catcher.draggingEntered(drag), .copy)
        XCTAssertEqual(catcher.draggingUpdated(drag), .copy)
        XCTAssertTrue(catcher.prepareForDragOperation(drag))
        XCTAssertTrue(catcher.performDragOperation(drag))
        catcher.draggingEnded(drag)

        XCTAssertEqual(targetedChanges, [true, false])
        XCTAssertEqual(droppedURLs.map { $0.map { $0.resolvingSymlinksInPath() } }, [[pdf.resolvingSymlinksInPath()]])
    }

    func testDragWithoutPDFsIsRejectedAndShowsNoOverlay() throws {
        let fixture = try DropFixture()
        defer { fixture.tearDown() }
        let catcher = PDFFileDropCatcherView(frame: .zero)
        var targetedChanges: [Bool] = []
        catcher.onTargetedChange = { targetedChanges.append($0) }
        catcher.onDrop = { _ in
            XCTFail("A drag without PDFs must not be dropped")
            return true
        }
        let drag = FakeDraggingInfo(
            pasteboard: fixture.makePasteboard(urls: [try fixture.makeFile("notes.txt")]),
            sequenceNumber: 2
        )

        XCTAssertEqual(catcher.draggingEntered(drag), [])
        XCTAssertFalse(catcher.prepareForDragOperation(drag))
        XCTAssertFalse(catcher.performDragOperation(drag))
        XCTAssertEqual(targetedChanges, [])
    }

    func testDisabledCatcherRejectsPDFDragsWhileAnImportRuns() throws {
        let fixture = try DropFixture()
        defer { fixture.tearDown() }
        let catcher = PDFFileDropCatcherView(frame: .zero)
        var targetedChanges: [Bool] = []
        catcher.isEnabled = false
        catcher.onTargetedChange = { targetedChanges.append($0) }
        catcher.onDrop = { _ in
            XCTFail("A disabled drop target must not import")
            return true
        }
        let drag = FakeDraggingInfo(
            pasteboard: fixture.makePasteboard(urls: [try fixture.makeFile("paper.pdf")]),
            sequenceNumber: 3
        )

        XCTAssertEqual(catcher.draggingEntered(drag), [])
        XCTAssertFalse(catcher.performDragOperation(drag))
        XCTAssertEqual(targetedChanges, [])
    }

    func testLeavingTheWindowClearsTheOverlay() throws {
        let fixture = try DropFixture()
        defer { fixture.tearDown() }
        let catcher = PDFFileDropCatcherView(frame: .zero)
        var targetedChanges: [Bool] = []
        catcher.onTargetedChange = { targetedChanges.append($0) }
        let drag = FakeDraggingInfo(
            pasteboard: fixture.makePasteboard(urls: [try fixture.makeFile("paper.pdf")]),
            sequenceNumber: 4
        )

        XCTAssertEqual(catcher.draggingEntered(drag), .copy)
        catcher.draggingExited(drag)

        XCTAssertEqual(targetedChanges, [true, false])
    }

    /// Regression: `WKWebView` claims every drag over its frame, so a drop target behind the
    /// reader never saw PDFs dragged onto an open HTML paper. The catcher must win AppKit's
    /// drag lookup over the web view while ordinary clicks still reach the web view.
    func testDropTargetWinsDragsOverWebViewWithoutBlockingClicks() async throws {
        let size = NSSize(width: 480, height: 320)
        let host = NSHostingView(rootView:
            WebViewStub()
                .frame(width: size.width, height: size.height)
                .pdfFileDropTarget(isTargeted: .constant(false), isImporting: false) { _ in false }
        )
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: 0), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.orderBack(nil)
        defer { window.close() }

        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }

        let catcher = try XCTUnwrap(descendants(of: host).compactMap { $0 as? PDFFileDropCatcherView }.first)
        let webView = try XCTUnwrap(descendants(of: host).compactMap { $0 as? WKWebView }.first)
        let frameView = try XCTUnwrap(container.superview)
        XCTAssertEqual(catcher.convert(catcher.bounds, to: nil), host.convert(host.bounds, to: nil))

        let webViewFrame = webView.convert(webView.bounds, to: nil)
        let point = NSPoint(x: webViewFrame.midX, y: webViewFrame.midY)

        let clicked = try XCTUnwrap(frameView.hitTest(point))
        XCTAssertTrue(clicked === webView || clicked.isDescendant(of: webView), "Clicks must reach the reader")

        let destination = try dragDestination(in: frameView, at: point, types: Self.finderPDFDragTypes)
        XCTAssertTrue(destination === catcher, "Drag went to \(destination.map { String(describing: type(of: $0)) } ?? "nothing")")
    }

    // MARK: - Helpers

    /// Pasteboard types of a PDF dragged from Finder, widened by type conformance as AppKit
    /// does when it matches them against registered drag types.
    private static let finderPDFDragTypes: Set<String> = {
        var types: Set<String> = [
            NSPasteboard.PasteboardType.fileURL.rawValue,
            "NSFilenamesPboardType",
            "Apple URL pasteboard type",
            "com.apple.finder.node",
        ]
        types.formUnion(UTType.fileURL.supertypes.map(\.identifier))
        return types
    }()

    /// AppKit's own drag-destination lookup. It walks the view tree front to back and does not
    /// consult `hitTest(_:)`; `WKWebView` overrides it to claim drags over its frame.
    private func dragDestination(in frameView: NSView, at point: NSPoint, types: Set<String>) throws -> NSView? {
        typealias Lookup = @convention(c) (NSView, Selector, UnsafePointer<CGPoint>, NSSet) -> NSView?
        let selector = NSSelectorFromString("_hitTest:dragTypes:")
        guard let implementation = class_getMethodImplementation(object_getClass(frameView), selector),
              NSView.instancesRespond(to: selector)
        else {
            throw XCTSkip("AppKit no longer exposes its drag-destination lookup")
        }
        let lookup = unsafeBitCast(implementation, to: Lookup.self)
        var location = point
        return lookup(frameView, selector, &location, NSSet(set: types))
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

/// Temporary files and private pasteboards for one test.
@MainActor
private final class DropFixture {
    private let directory: URL
    private var pasteboards: [NSPasteboard] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFDropTargetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("%PDF-1.4\n".utf8).write(to: url)
        return url
    }

    func makePasteboard(urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ReadPaperTests.drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboards.append(pasteboard)
        return pasteboard
    }

    func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct WebViewStub: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    init(pasteboard: NSPasteboard, sequenceNumber: Int) {
        draggingPasteboard = pasteboard
        draggingSequenceNumber = sequenceNumber
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
