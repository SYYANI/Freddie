import AppKit
import XCTest
@testable import ReadPaper

@MainActor
final class PaperLinkRouterTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.close()
        }
        windows = []
        super.tearDown()
    }

    private func makeWindow(frame: NSRect = NSRect(x: 0, y: 0, width: 400, height: 300)) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    func testReadPaperURLsGoToTheFrontmostMainWindow() throws {
        let back = makeWindow()
        let front = makeWindow()
        var activations = 0
        let router = PaperLinkRouter(
            orderedWindows: { [front, back] },
            keyWindow: { nil },
            activateApplication: { activations += 1 }
        )
        let backID = UUID()
        let frontID = UUID()
        router.register(windowID: backID, window: back)
        router.register(windowID: frontID, window: front)
        let paperID = UUID()

        XCTAssertTrue(router.open(try XCTUnwrap(URL(string: "readpaper://paper/\(paperID.uuidString)?p=3&anchor=rp-anchor:0/2"))))

        let delivery = try XCTUnwrap(router.delivery)
        XCTAssertEqual(delivery.windowID, frontID)
        XCTAssertEqual(delivery.citation, PaperCitation(paperID: paperID, pageIndex: 2, htmlSelector: "rp-anchor:0/2"))
        XCTAssertNil(delivery.quote)
        XCTAssertEqual(activations, 1)

        router.finish(delivery)
        XCTAssertNil(router.delivery)
        XCTAssertFalse(router.open(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertFalse(router.open(try XCTUnwrap(URL(string: "readpaper://writing/\(UUID().uuidString)"))))
        XCTAssertNil(router.delivery)
    }

    func testCitationWaitsForAMainWindowToOpen() throws {
        var openRequests = 0
        let router = PaperLinkRouter(orderedWindows: { [] }, keyWindow: { nil }, activateApplication: {})
        router.openMainWindow = { openRequests += 1 }
        let citation = PaperCitation(paperID: UUID(), pageIndex: 0, quotePrefix: "Quoted")

        router.openCitation(citation, quote: "Quoted passage", origin: .writingWindow)
        XCTAssertEqual(openRequests, 1)
        XCTAssertNil(router.delivery)

        let windowID = UUID()
        router.register(windowID: windowID, window: makeWindow())
        let delivery = try XCTUnwrap(router.delivery)
        XCTAssertEqual(delivery.windowID, windowID)
        XCTAssertEqual(delivery.citation, citation)
        XCTAssertEqual(delivery.quote, "Quoted passage")
    }

    /// A link that launches the app opens no window by itself; when no main window shows
    /// up, the router reopens the app as a Dock click would.
    func testWithoutAMainWindowTheAppIsReopened() async throws {
        var reopenRequests = 0
        let paperID = UUID()
        let url = try XCTUnwrap(URL(string: "readpaper://paper/\(paperID.uuidString)"))
        func makeRouter() -> PaperLinkRouter {
            PaperLinkRouter(
                orderedWindows: { [] },
                keyWindow: { nil },
                activateApplication: {},
                reopenApplication: { reopenRequests += 1 },
                windowFallbackDelay: .milliseconds(100)
            )
        }

        // Windows restored at launch take the link.
        let restoring = makeRouter()
        XCTAssertTrue(restoring.open(url))
        restoring.register(windowID: UUID(), window: makeWindow())
        XCTAssertEqual(restoring.delivery?.citation.paperID, paperID)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(reopenRequests, 0)

        let empty = makeRouter()
        XCTAssertTrue(empty.open(url))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(reopenRequests, 1)
        let windowID = UUID()
        empty.register(windowID: windowID, window: makeWindow())
        XCTAssertEqual(empty.delivery?.windowID, windowID)
    }

    func testClosedWindowsAreNotChosen() throws {
        let router = PaperLinkRouter(orderedWindows: { [] }, keyWindow: { nil }, activateApplication: {})
        let closedID = UUID()
        let openID = UUID()
        router.register(windowID: closedID, window: makeWindow())
        router.register(windowID: openID, window: makeWindow())
        router.unregister(windowID: closedID)

        router.openCitation(PaperCitation(paperID: UUID()), quote: nil, origin: .external)

        XCTAssertEqual(router.delivery?.windowID, openID)
    }

    /// Beside the main window, the writing window keeps the keyboard; covering it, the main
    /// window comes forward.
    func testWritingWindowCitationsBringTheMainWindowForwardOnlyWhenCovered() throws {
        let main = makeWindow(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let besideWriting = makeWindow(frame: NSRect(x: 500, y: 0, width: 300, height: 300))
        main.orderFront(nil)
        besideWriting.orderFront(nil)
        var keyWindow: NSWindow? = besideWriting
        let router = PaperLinkRouter(
            orderedWindows: { [besideWriting, main] },
            keyWindow: { keyWindow },
            activateApplication: {}
        )
        router.register(windowID: UUID(), window: main)

        router.openCitation(PaperCitation(paperID: UUID()), quote: nil, origin: .writingWindow)
        XCTAssertEqual(NSApp.orderedWindows.firstIndex(of: besideWriting).map { $0 < (NSApp.orderedWindows.firstIndex(of: main) ?? .max) }, true)

        let coveringWriting = makeWindow(frame: NSRect(x: 100, y: 50, width: 300, height: 300))
        coveringWriting.orderFront(nil)
        keyWindow = coveringWriting
        router.openCitation(PaperCitation(paperID: UUID()), quote: nil, origin: .writingWindow)
        let order = NSApp.orderedWindows
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: main)), try XCTUnwrap(order.firstIndex(of: coveringWriting)))
    }
}
