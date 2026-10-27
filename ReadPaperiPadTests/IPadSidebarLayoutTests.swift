import SwiftUI
import UIKit
import XCTest
@testable import ReadPaperiPad

final class IPadSidebarLayoutTests: XCTestCase {
    func testPanelsTileWhileTheReaderKeepsItsMinimumWidth() {
        let landscape = IPadSidebarLayout.metrics(containerWidth: 1376)
        XCTAssertTrue(landscape.sidebarTiles)
        XCTAssertTrue(landscape.inspectorTiles)
        XCTAssertEqual(landscape.sidebarWidth, IPadSidebarLayout.sidebarWidth)

        let portrait13 = IPadSidebarLayout.metrics(containerWidth: 1032)
        XCTAssertTrue(portrait13.sidebarTiles)
        XCTAssertTrue(portrait13.inspectorTiles)

        let portrait11 = IPadSidebarLayout.metrics(containerWidth: 834)
        XCTAssertTrue(portrait11.sidebarTiles)
        XCTAssertFalse(portrait11.inspectorTiles)

        let slideOver = IPadSidebarLayout.metrics(containerWidth: 300)
        XCTAssertFalse(slideOver.sidebarTiles)
        XCTAssertFalse(slideOver.inspectorTiles)
        XCTAssertEqual(slideOver.sidebarWidth, 300 - IPadSidebarLayout.overlayMargin)
        XCTAssertEqual(slideOver.inspectorWidth, 300 - IPadSidebarLayout.overlayMargin)
    }

    func testDragTargetsFollowEdgesAndOnlyCloseFromInsideAPanel() {
        let width: CGFloat = 1200
        let metrics = IPadSidebarLayout.metrics(containerWidth: width)
        func target(_ x: CGFloat, _ velocity: CGFloat, sidebar: CGFloat, inspector: CGFloat) -> IPadSidebarLayout.DragTarget? {
            IPadSidebarLayout.dragTarget(
                atX: x, velocityX: velocity, containerWidth: width, metrics: metrics,
                sidebarProgress: sidebar, inspectorProgress: inspector
            )
        }
        // Closed panels open from the reader's edges, not from its middle.
        XCTAssertEqual(target(10, 500, sidebar: 0, inspector: 0), .init(edge: .leading, isOnPanel: false))
        XCTAssertEqual(target(1190, -500, sidebar: 0, inspector: 0), .init(edge: .trailing, isOnPanel: false))
        XCTAssertNil(target(600, 500, sidebar: 0, inspector: 0))
        XCTAssertNil(target(10, -500, sidebar: 0, inspector: 0))

        // Open panels close from their body or the reader strip beside them.
        XCTAssertEqual(target(100, -500, sidebar: 1, inspector: 1), .init(edge: .leading, isOnPanel: true))
        XCTAssertNil(target(100, 500, sidebar: 1, inspector: 1))
        XCTAssertEqual(target(270, -500, sidebar: 1, inspector: 1), .init(edge: .leading, isOnPanel: false))
        XCTAssertNil(target(270, 500, sidebar: 1, inspector: 1))
        XCTAssertEqual(target(1000, 500, sidebar: 1, inspector: 1), .init(edge: .trailing, isOnPanel: true))
        XCTAssertNil(target(1000, -500, sidebar: 1, inspector: 1))
        XCTAssertEqual(target(850, 500, sidebar: 1, inspector: 1), .init(edge: .trailing, isOnPanel: false))

        // An overlaid panel takes every closing swipe, even over the dimmed reader.
        let narrow = IPadSidebarLayout.metrics(containerWidth: 500)
        XCTAssertEqual(
            IPadSidebarLayout.dragTarget(atX: 480, velocityX: -500, containerWidth: 500, metrics: narrow,
                                         sidebarProgress: 1, inspectorProgress: 0),
            .init(edge: .leading, isOnPanel: false)
        )
        XCTAssertNil(IPadSidebarLayout.dragTarget(atX: 480, velocityX: 500, containerWidth: 500, metrics: narrow,
                                                  sidebarProgress: 1, inspectorProgress: 0))
    }

    func testProgressFollowsTheFingerLinearlyAndReleaseUsesFlings() {
        let width = IPadSidebarLayout.sidebarWidth
        XCTAssertEqual(IPadSidebarLayout.progress(from: 0, translation: width / 4, panelWidth: width, edge: .leading), 0.25)
        XCTAssertEqual(IPadSidebarLayout.progress(from: 0, translation: width / 2, panelWidth: width, edge: .leading), 0.5)
        XCTAssertEqual(IPadSidebarLayout.progress(from: 1, translation: -width * 2, panelWidth: width, edge: .leading), 0)
        XCTAssertEqual(IPadSidebarLayout.progress(from: 0, translation: -85, panelWidth: 340, edge: .trailing), 0.25)

        XCTAssertTrue(IPadSidebarLayout.settlesOpen(progress: 0.6, velocityX: 0, edge: .leading))
        XCTAssertFalse(IPadSidebarLayout.settlesOpen(progress: 0.4, velocityX: 0, edge: .leading))
        XCTAssertTrue(IPadSidebarLayout.settlesOpen(progress: 0.1, velocityX: 800, edge: .leading))
        XCTAssertFalse(IPadSidebarLayout.settlesOpen(progress: 0.9, velocityX: 800, edge: .trailing))
        XCTAssertEqual(
            IPadSidebarLayout.settleVelocity(from: 0.5, to: 1, velocityX: 260, panelWidth: 260, edge: .leading), 2
        )
        XCTAssertEqual(
            IPadSidebarLayout.settleVelocity(from: 0.5, to: 1, velocityX: -260, panelWidth: 260, edge: .leading), 0
        )
    }

    @MainActor
    func testEdgeSwipeOpensSidebarUnderTheFingerAndPushesTheReader() async throws {
        let harness = try makeHarness(sidebar: false, inspector: false)
        defer { harness.close() }
        try await settle()
        XCTAssertEqual(harness.frame(of: "sidebar").maxX, 0, accuracy: 1)
        XCTAssertEqual(harness.frame(of: "reader").minX, 0, accuracy: 1)

        let pan = FakePan()
        XCTAssertFalse(harness.begin(pan, at: 600, velocityX: 600), "the middle of the reader scrolls")
        XCTAssertTrue(harness.begin(pan, at: 10, velocityX: 600))
        try await harness.move(pan, to: 65)
        XCTAssertEqual(harness.frame(of: "sidebar").maxX, 65, accuracy: 1)
        XCTAssertEqual(harness.frame(of: "reader").minX, 65, accuracy: 1)
        try await harness.move(pan, to: 195)
        XCTAssertEqual(harness.frame(of: "sidebar").maxX, 195, accuracy: 1)
        XCTAssertFalse(harness.model.isSidebarPresented, "nothing commits until release")

        try await harness.end(pan, at: 200, velocityX: 0)
        XCTAssertTrue(harness.model.isSidebarPresented)
        XCTAssertEqual(harness.frame(of: "sidebar").maxX, IPadSidebarLayout.sidebarWidth, accuracy: 1)
        XCTAssertEqual(harness.frame(of: "reader").minX, IPadSidebarLayout.sidebarWidth, accuracy: 1)
    }

    @MainActor
    func testSlowReleaseSnapsBackAndFlingClosesTheInspector() async throws {
        let harness = try makeHarness(sidebar: true, inspector: true)
        defer { harness.close() }
        try await settle()
        let inspectorWidth = IPadSidebarLayout.inspectorWidth
        XCTAssertEqual(harness.frame(of: "inspector").minX, 1200 - inspectorWidth, accuracy: 1)

        let pan = FakePan()
        XCTAssertFalse(harness.begin(pan, at: 1100, velocityX: -600), "a panel only closes from inside")
        XCTAssertTrue(harness.begin(pan, at: 1100, velocityX: 600))
        try await harness.move(pan, to: 100)
        XCTAssertEqual(harness.frame(of: "inspector").minX, 1200 - inspectorWidth + 100, accuracy: 1)
        try await harness.end(pan, at: 100, velocityX: 0)
        XCTAssertTrue(harness.model.isInspectorPresented)
        XCTAssertEqual(harness.frame(of: "inspector").minX, 1200 - inspectorWidth, accuracy: 1)

        XCTAssertTrue(harness.begin(pan, at: 1100, velocityX: 600))
        try await harness.move(pan, to: 40)
        try await harness.end(pan, at: 40, velocityX: 900)
        XCTAssertFalse(harness.model.isInspectorPresented)
        XCTAssertNil(harness.probe("inspector"), "the inspector unmounts once it has slid out")
        XCTAssertEqual(harness.frame(of: "reader").maxX, 1200, accuracy: 1)
    }

    @MainActor
    func testNarrowWindowsOverlayOnePanelAndSelectionRevealsTheReader() async throws {
        let harness = try makeHarness(sidebar: true, inspector: true, width: 500)
        defer { harness.close() }
        try await settle()
        XCTAssertTrue(harness.model.isSidebarPresented)
        XCTAssertFalse(harness.model.isInspectorPresented, "two overlaid panels would cover each other")
        XCTAssertEqual(harness.frame(of: "reader").minX, 0, accuracy: 1, "an overlaid panel does not push the reader")

        harness.model.selection += 1
        try await settle()
        XCTAssertFalse(harness.model.isSidebarPresented)

        harness.model.isInspectorPresented = true
        try await settle()
        harness.model.isSidebarPresented = true
        try await settle()
        XCTAssertFalse(harness.model.isInspectorPresented)
    }

    @MainActor
    private func makeHarness(sidebar: Bool, inspector: Bool, width: CGFloat = 1200) throws -> SidebarHarness {
        let model = SidebarHarnessModel(isSidebarPresented: sidebar, isInspectorPresented: inspector, width: width)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SidebarHarnessView(model: model))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return SidebarHarness(model: model, window: window)
    }
}

@MainActor
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(600))
}

@MainActor
private final class FakePan: UIPanGestureRecognizer {
    var simulatedState: UIGestureRecognizer.State = .possible
    var simulatedLocation = CGPoint.zero
    var translationX: CGFloat = 0
    var velocityX: CGFloat = 0
    override var state: UIGestureRecognizer.State {
        get { simulatedState }
        set { simulatedState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { simulatedLocation }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: translationX, y: 0) }
    override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: velocityX, y: 0) }
}

@MainActor
private final class SidebarHarnessModel: ObservableObject {
    @Published var isSidebarPresented: Bool
    @Published var isInspectorPresented: Bool
    @Published var selection = 0
    let width: CGFloat

    init(isSidebarPresented: Bool, isInspectorPresented: Bool, width: CGFloat) {
        self.isSidebarPresented = isSidebarPresented
        self.isInspectorPresented = isInspectorPresented
        self.width = width
    }
}

private struct SidebarHarnessView: View {
    @ObservedObject var model: SidebarHarnessModel
    var body: some View {
        IPadSidebarContainer(
            isSidebarPresented: $model.isSidebarPresented,
            isInspectorPresented: $model.isInspectorPresented,
            selection: model.selection
        ) {
            ProbeView(name: "sidebar")
        } detail: {
            ProbeView(name: "reader")
        } inspector: {
            ProbeView(name: "inspector")
        }
        .frame(width: model.width, height: 700)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

private struct ProbeView: UIViewRepresentable {
    let name: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = name
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

@MainActor
private struct SidebarHarness {
    let model: SidebarHarnessModel
    let window: UIWindow

    private var driver: IPadSidebarPanDriver {
        get throws { try XCTUnwrap(descendants(in: window).compactMap { $0 as? IPadSidebarPanView }.first).driver }
    }

    func probe(_ name: String) -> UIView? {
        descendants(in: window).first { $0.accessibilityIdentifier == name }
    }

    /// Frame on screen, including the offset that slides a panel out.
    func frame(of name: String) -> CGRect {
        guard let view = probe(name) else { return .null }
        let host = descendants(in: window).first { $0 is IPadSidebarPanView } ?? window
        let presentation = view.layer.presentation() ?? view.layer
        return presentation.convert(presentation.bounds, to: host.layer)
    }

    func begin(_ pan: FakePan, at x: CGFloat, velocityX: CGFloat) -> Bool {
        pan.simulatedLocation = CGPoint(x: x, y: 300)
        pan.velocityX = velocityX
        pan.translationX = 0
        guard let driver = try? driver, driver.gestureRecognizerShouldBegin(pan) else { return false }
        pan.simulatedState = .began
        driver.handlePan(pan)
        return true
    }

    func move(_ pan: FakePan, to translation: CGFloat) async throws {
        pan.simulatedState = .changed
        pan.translationX = translation
        try driver.handlePan(pan)
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
    }

    func end(_ pan: FakePan, at translation: CGFloat, velocityX: CGFloat) async throws {
        pan.simulatedState = .ended
        pan.translationX = translation
        pan.velocityX = velocityX
        try driver.handlePan(pan)
        try await settle()
        window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func descendants(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }
}
