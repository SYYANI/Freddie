import AppKit
import SwiftUI
import XCTest
@testable import ReadPaper

@MainActor
final class SelectionAssistantAutoRunTests: XCTestCase {
    func testAutoRunStartsQuickGlossForItsSelection() async throws {
        let selection = NoteSelectionContext(
            attachmentID: UUID(),
            quote: "stochastic gradient descent",
            pageIndex: 2,
            localContext: "We train with stochastic gradient descent."
        )
        let recorder = RequestRecorder()
        let window = makeWindow(
            selection: selection,
            autoRun: SelectionAssistantAutoRun(
                selectionIdentity: selection.selectionAssistantIdentity,
                token: 1
            ),
            recorder: recorder
        )
        defer { window.close() }

        try await waitUntil { recorder.requests.isEmpty == false }

        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.action, .explain)
        XCTAssertTrue(request.isQuickGloss)
        XCTAssertEqual(request.selection, "stochastic gradient descent")
        XCTAssertEqual(request.localContext, "We train with stochastic gradient descent.")
    }

    func testOverlayWaitsForAClickWithoutAutoRun() async throws {
        let selection = NoteSelectionContext(attachmentID: UUID(), quote: "a term", pageIndex: 0)
        let recorder = RequestRecorder()
        let other = makeWindow(
            selection: selection,
            autoRun: SelectionAssistantAutoRun(selectionIdentity: "another selection", token: 1),
            recorder: recorder
        )
        defer { other.close() }
        let none = makeWindow(selection: selection, autoRun: nil, recorder: recorder)
        defer { none.close() }

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    private func makeWindow(
        selection: NoteSelectionContext,
        autoRun: SelectionAssistantAutoRun?,
        recorder: RequestRecorder
    ) -> NSWindow {
        let overlay = SelectionAssistantOverlay(
            selection: selection,
            progress: nil,
            initialConversation: nil,
            perform: { request, _ in
                recorder.requests.append(request)
                return SelectionAssistantResult(answer: "**译文** 随机梯度下降")
            },
            saveAsNote: { _, _, _ in UUID() },
            onSourceActivated: { _ in },
            onConversationChanged: { _ in },
            onInteractionBegan: {},
            onDismiss: {},
            autoRun: autoRun
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: overlay)
        window.orderFront(nil)
        return window
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the overlay to send a request.")
    }
}

@MainActor
private final class RequestRecorder {
    var requests: [SelectionAssistantRequest] = []
}
