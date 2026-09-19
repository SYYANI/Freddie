import AppKit
import SwiftUI
import XCTest
@testable import ReadPaper

final class SelectionAssistantOverlayTests: XCTestCase {
    func testResizableCardRemainsHorizontallyCenteredBottomAlignedAndClamped() {
        let availableSize = CGSize(width: 1_000, height: 700)
        let startingSize = CGSize(width: 600, height: 360)
        let expectedSize = CGSize(width: 680, height: 390)
        let translations: [(SelectionAssistantResizeCorner, CGSize)] = [
            (.topLeading, CGSize(width: -40, height: -30)),
            (.topTrailing, CGSize(width: 40, height: -30)),
            (.bottomLeading, CGSize(width: -40, height: 30)),
            (.bottomTrailing, CGSize(width: 40, height: 30))
        ]
        for (corner, translation) in translations {
            XCTAssertEqual(
                SelectionAssistantResizeGeometry.proposedCardSize(
                    startingSize: startingSize,
                    dragTranslation: translation,
                    corner: corner
                ),
                expectedSize
            )
        }

        let maximumSize = SelectionAssistantResizeGeometry.clampedCardSize(
            CGSize(width: 2_000, height: 2_000),
            availableSize: availableSize,
            minimumSize: CGSize(width: 340, height: 160)
        )
        XCTAssertEqual(maximumSize, CGSize(width: 964, height: 600))

        let minimumSize = SelectionAssistantResizeGeometry.clampedCardSize(
            CGSize(width: 20, height: 20),
            availableSize: availableSize,
            minimumSize: CGSize(width: 340, height: 160)
        )
        XCTAssertEqual(minimumSize, CGSize(width: 340, height: 160))
    }

    func testScrollTargetIncludesQuestionAnswerAndBottomInset() {
        typealias Target = SelectionAssistantConversationScrollTarget
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 200, viewportHeight: 480), .bottom)
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 470, viewportHeight: 480), .bottom)
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 475, viewportHeight: 480), .turn(3))
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 800, viewportHeight: 480), .turn(3))
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 400, viewportHeight: 300), .turn(3))
    }

    func testStreamingAlwaysTargetsBottomForAnAnswerTallerThanViewport() {
        typealias Target = SelectionAssistantConversationScrollTarget
        XCTAssertEqual(
            Target.resolve(
                turnIndex: 2,
                turnHeight: 800,
                viewportHeight: 480,
                followsStreamingBottom: true
            ),
            .bottom
        )
    }

    @MainActor
    func testShortFollowUpIsFullyVisibleAfterLongExplanation() async throws {
        let fixture = ConversationFixture()
        defer { fixture.window.close() }
        let initial = turn(answer: Self.longAnswer)
        fixture.show([initial])
        try await fixture.settle()
        fixture.show([initial], pending: "What is the main point?")
        try await fixture.settle()
        fixture.show([initial, turn(question: "What is the main point?", answer: "A short answer.")])
        try await fixture.settle()

        let scroll = try fixture.scrollView()
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.height, accuracy: 1)
    }

    @MainActor
    func testLongFollowUpStartsAtQuestionAndManualScrollIsPreserved() async throws {
        let fixture = ConversationFixture()
        let reference = ConversationFixture()
        defer {
            fixture.window.close()
            reference.window.close()
        }
        let initial = turn(answer: "Initial explanation.")
        let latest = turn(question: "Please explain in detail.", answer: Self.longAnswer)
        reference.show([latest], showsInitialQuestion: true)
        fixture.show([initial])
        try await fixture.settle()
        fixture.show([initial], pending: latest.question)
        try await fixture.settle()
        fixture.show([initial, latest])
        try await fixture.settle()

        try assertLatestTurnAtTop(fixture, reference: reference)
        let scroll = try fixture.scrollView()
        let manualOffset = scroll.contentView.bounds.minY + 100
        scroll.contentView.scroll(to: NSPoint(x: 0, y: manualOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await fixture.settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, manualOffset, accuracy: 1)
    }

    @MainActor
    func testLongPendingQuestionAndErrorStayAtQuestionTop() async throws {
        let fixture = ConversationFixture()
        let reference = ConversationFixture()
        defer {
            fixture.window.close()
            reference.window.close()
        }
        let initial = turn(answer: "Initial explanation.")
        let question = String(repeating: "A long question with context. ", count: 100)
        fixture.show([initial])
        try await fixture.settle()
        reference.show([], pending: question, showsInitialQuestion: true)
        fixture.show([initial], pending: question)
        try await fixture.settle()
        try assertLatestTurnAtTop(fixture, reference: reference)

        reference.show([], pending: question, error: "Request failed.", showsInitialQuestion: true)
        fixture.show([initial], pending: question, error: "Request failed.")
        try await fixture.settle()
        try assertLatestTurnAtTop(fixture, reference: reference)
    }

    @MainActor
    func testResizingUsesAvailableViewportInsteadOfMaximumHeight() async throws {
        let fixture = ConversationFixture(height: 700)
        let reference = ConversationFixture()
        defer {
            fixture.window.close()
            reference.window.close()
        }
        let latest = turn(answer: (1...14).map { "Answer line \($0)." }.joined(separator: "\n"))
        reference.show([latest], showsInitialQuestion: true)
        fixture.show([turn(answer: Self.longAnswer), latest])
        try await fixture.settle()
        let scroll = try fixture.scrollView()
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.height, accuracy: 1)

        fixture.window.setContentSize(NSSize(width: 370, height: 300))
        try await fixture.settle()
        XCTAssertLessThan(scroll.contentView.bounds.height, 300)
        try assertLatestTurnAtTop(fixture, reference: reference)
    }

    @MainActor
    func testStreamingAnswerStaysAtBottomWithStableViewportHeight() async throws {
        let fixture = ConversationFixture()
        defer { fixture.window.close() }
        let request = SelectionAssistantConversationScrollRequest(turnIndex: 0)

        fixture.show(
            [],
            pending: "Explain this.",
            partialAnswer: String(repeating: "Streaming answer text. ", count: 80),
            scrollRequest: request
        )
        try await fixture.settle()
        let scroll = try fixture.scrollView()
        let initialViewportHeight = scroll.contentView.bounds.height
        XCTAssertGreaterThan(initialViewportHeight, 0)
        XCTAssertLessThanOrEqual(initialViewportHeight, 480)
        XCTAssertEqual(
            scroll.contentView.bounds.maxY,
            try XCTUnwrap(scroll.documentView).bounds.height,
            accuracy: 1
        )

        fixture.show(
            [],
            pending: "Explain this.",
            partialAnswer: String(repeating: "Streaming answer text. ", count: 120),
            scrollRequest: request
        )
        try await fixture.settle()
        XCTAssertEqual(scroll.contentView.bounds.height, initialViewportHeight, accuracy: 1)
        XCTAssertEqual(
            scroll.contentView.bounds.maxY,
            try XCTUnwrap(scroll.documentView).bounds.height,
            accuracy: 1
        )
    }

    @MainActor
    func testShortInitialStreamingAnswerUsesItsContentHeight() async throws {
        let fixture = ConversationFixture()
        defer { fixture.window.close() }

        fixture.show(
            [],
            pending: "Explain this.",
            partialAnswer: "A short explanation.",
            scrollRequest: .init(turnIndex: 0)
        )
        try await fixture.settle()

        let scroll = try fixture.scrollView()
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 0)
        XCTAssertLessThan(scroll.contentView.bounds.height, 120)
        XCTAssertEqual(
            scroll.contentView.bounds.maxY,
            try XCTUnwrap(scroll.documentView).bounds.height,
            accuracy: 1
        )
    }

    @MainActor
    func testCompletingStreamDoesNotShrinkConversationViewport() async throws {
        let fixture = ConversationFixture()
        defer { fixture.window.close() }
        let request = SelectionAssistantConversationScrollRequest(turnIndex: 0)

        fixture.show(
            [],
            pending: "Explain this.",
            partialAnswer: String(repeating: "Streaming answer text. ", count: 100),
            scrollRequest: request
        )
        try await fixture.settle()

        let scroll = try fixture.scrollView()
        let streamingViewportHeight = scroll.contentView.bounds.height
        XCTAssertGreaterThan(streamingViewportHeight, 0)

        // Finalization replaces the streaming Markdown node. The finalized text
        // can be shorter after trimming or citation normalization, but the card
        // must retain the height the user was already reading at.
        fixture.show(
            [turn(answer: "A concise final answer.")],
            scrollRequest: .init(turnIndex: 0)
        )
        try await fixture.settle()

        let completedScroll = try fixture.scrollView()
        XCTAssertEqual(completedScroll.contentView.bounds.height, streamingViewportHeight, accuracy: 1)
    }

    private static let longAnswer = (1...45).map { "Explanation line \($0)." }.joined(separator: "\n")

    private func turn(question: String = "A question.", answer: String) -> SelectionAssistantConversationTurn {
        SelectionAssistantConversationTurn(question: question, answer: answer)
    }

    @MainActor
    private func assertLatestTurnAtTop(
        _ fixture: ConversationFixture,
        reference: ConversationFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scroll = try fixture.scrollView()
        let document = try XCTUnwrap(scroll.documentView)
        let latestDocument = try XCTUnwrap(reference.scrollView().documentView)
        // Render the same latest turn by itself to measure its actual Text layout.
        let latestTurnTop = document.bounds.height - latestDocument.bounds.height
        XCTAssertGreaterThan(latestTurnTop, 0, file: file, line: line)
        XCTAssertEqual(scroll.contentView.bounds.minY, latestTurnTop, accuracy: 1, file: file, line: line)
    }
}

@MainActor
private final class ConversationFixture {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window: NSWindow

    init(height: CGFloat = 500) {
        window = NSWindow(
            contentRect: NSRect(x: -10_000, y: 0, width: 370, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        host.sizingOptions = []
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
    }

    func show(
        _ turns: [SelectionAssistantConversationTurn],
        pending: String? = nil,
        error: String? = nil,
        partialAnswer: String = "",
        showsInitialQuestion: Bool = false,
        scrollRequest: SelectionAssistantConversationScrollRequest? = nil
    ) {
        let index = pending == nil ? turns.count - 1 : turns.count
        withAnimation(.smooth(duration: 0.34, extraBounce: 0)) {
            host.rootView = AnyView(
                VStack(spacing: 10) {
                    Text("AI Explanation").frame(height: 20)
                    SelectionAssistantConversationView(
                        conversation: turns,
                        pendingQuestion: pending,
                        isWorking: pending != nil && error == nil,
                        errorText: error,
                        loadingText: "Generating an answer...",
                        partialAnswer: partialAnswer,
                        showsInitialQuestion: showsInitialQuestion,
                        conversationMaximumHeight: 480,
                        conversationScrollRequest: scrollRequest ?? .init(turnIndex: index)
                    )
                    Text("Follow-up input").frame(height: 34)
                }
                .font(.system(size: 14))
                .lineSpacing(3)
                .padding(16)
                .environment(\.localizationBundle, AppLocalization.resolveBundle(for: "en"))
            )
        }
    }

    func scrollView() throws -> NSScrollView {
        try XCTUnwrap(descendants(of: host).first)
    }

    private func descendants(of view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(descendants)
    }

    func settle() async throws {
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
