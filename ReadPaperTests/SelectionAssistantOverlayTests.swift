import AppKit
import SwiftUI
import XCTest
@testable import ReadPaper

final class SelectionAssistantOverlayTests: XCTestCase {
    func testScrollTargetIncludesQuestionAnswerAndBottomInset() {
        typealias Target = SelectionAssistantConversationScrollTarget
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 200, viewportHeight: 480), .bottom)
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 470, viewportHeight: 480), .bottom)
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 475, viewportHeight: 480), .turn(3))
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 800, viewportHeight: 480), .turn(3))
        XCTAssertEqual(Target.resolve(turnIndex: 3, turnHeight: 400, viewportHeight: 300), .turn(3))
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
        showsInitialQuestion: Bool = false
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
                        showsInitialQuestion: showsInitialQuestion,
                        conversationMaximumHeight: 480,
                        conversationScrollRequest: .init(turnIndex: index)
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
