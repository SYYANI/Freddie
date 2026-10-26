import PDFKit
import SwiftUI
import UIKit
import XCTest
@testable import ReadPaperiPad

final class IPadPDFLayoutTests: XCTestCase {
    func testSplitKeepsMinimumWidthsAndBalancesNarrowWindows() {
        for delta: CGFloat in [-2000, 2000] {
            let fraction = DualPDFSplitLayout.fraction(
                afterDraggingBy: delta, totalWidth: 1000, currentFraction: 0.5
            )
            let leading = DualPDFSplitLayout.leadingWidth(totalWidth: 1000, fraction: fraction)
            let trailing = 1000 - DualPDFSplitLayout.dividerWidth - leading
            XCTAssertGreaterThanOrEqual(leading, 180 - 0.001)
            XCTAssertGreaterThanOrEqual(trailing, 180 - 0.001)
        }
        XCTAssertEqual(
            DualPDFSplitLayout.leadingWidth(totalWidth: 320, fraction: 0.9),
            (320 - DualPDFSplitLayout.dividerWidth) / 2
        )
    }

    @MainActor
    func testTouchDividerFlushesFinalMovement() {
        let divider = TouchPDFSplitDivider()
        var starts = 0
        var distance: CGFloat = 0
        divider.onDragBegan = { starts += 1 }
        divider.onDrag = { distance += $0 }
        let gesture = TestPanGesture()
        for (state, delta): (UIGestureRecognizer.State, CGFloat) in [
            (.began, 5), (.changed, 40), (.changed, 20), (.ended, 7)
        ] {
            gesture.simulatedState = state
            gesture.delta = delta
            divider.drag(gesture)
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(distance, 72)
    }

    @MainActor
    func testDualPDFInitiallyFitsAndRefitsBothPanesWhenDividerMoves() async throws {
        let harness = try makeHarness()
        defer { harness.close() }
        try await settle()
        let panes = descendants(PDFView.self, in: harness.window)
        XCTAssertEqual(panes.count, 2)
        for pane in panes {
            XCTAssertTrue(pane.autoScales)
            XCTAssertEqual(pane.scaleFactor, pane.scaleFactorForSizeToFit, accuracy: 0.01)
        }
        let originalWidth = try XCTUnwrap(panes.first).bounds.width
        try await dragDivider(in: harness.window, by: 140)
        XCTAssertGreaterThan(panes[0].bounds.width, originalWidth + 100)
        XCTAssertLessThan(panes[1].bounds.width, originalWidth - 100)
        for pane in panes {
            XCTAssertTrue(pane.autoScales)
            XCTAssertEqual(pane.scaleFactor, pane.scaleFactorForSizeToFit, accuracy: 0.01)
        }
        let fraction = panes[0].bounds.width / (1000 - DualPDFSplitLayout.dividerWidth)
        harness.model.width = 700
        try await settle()
        XCTAssertEqual(panes[0].bounds.width / (700 - DualPDFSplitLayout.dividerWidth), fraction, accuracy: 0.01)
        for pane in panes {
            XCTAssertEqual(pane.scaleFactor, pane.scaleFactorForSizeToFit, accuracy: 0.01)
        }
    }

    @MainActor
    func testPinchAfterReloadKeepsManualScaleAndNearFitRestoresOnDividerDrag() async throws {
        let harness = try makeHarness()
        defer { harness.close() }
        try await settle()
        harness.model.reloadToken += 1
        try await settle()
        let panes = descendants(TouchPDFView.self, in: harness.window)
        XCTAssertEqual(panes.count, 2)
        let gesture = TestPinchGesture()
        gesture.simulatedState = .began
        for (index, pane) in panes.enumerated() {
            XCTAssertFalse(descendants(UIScrollView.self, in: pane).isEmpty)
            pane.pinchChanged(gesture)
            pane.scaleFactor = pane.scaleFactorForSizeToFit * (index == 0 ? 1.5 : 1.05)
        }
        let manualScale = panes[0].scaleFactor
        harness.window.setNeedsLayout()
        harness.window.layoutIfNeeded()
        try await settle()
        XCTAssertFalse(panes[0].autoScales)
        XCTAssertEqual(panes[0].scaleFactor, manualScale, accuracy: 0.01)

        try await dragDivider(in: harness.window, by: 100)
        XCTAssertFalse(panes[0].autoScales)
        XCTAssertEqual(panes[0].scaleFactor, manualScale, accuracy: 0.01)
        XCTAssertTrue(panes[1].autoScales)
        XCTAssertEqual(panes[1].scaleFactor, panes[1].scaleFactorForSizeToFit, accuracy: 0.01)
        harness.model.width = 850
        try await settle()
        XCTAssertEqual(panes[0].scaleFactor, manualScale, accuracy: 0.01)
        XCTAssertEqual(panes[1].scaleFactor, panes[1].scaleFactorForSizeToFit, accuracy: 0.01)
    }

    @MainActor
    func testPartialTranslationReopensAtAvailablePageWithoutClampingOriginal() async throws {
        let harness = try makeHarness(pageIndex: 4, translatedPageCount: 2)
        defer { harness.close() }
        try await settle()
        let panes = descendants(PDFView.self, in: harness.window)
        XCTAssertEqual(panes.count, 2)
        let original = panes[0]
        let translated = panes[1]
        XCTAssertEqual(original.document?.index(for: try XCTUnwrap(original.currentPage)), 4)
        XCTAssertEqual(translated.document?.index(for: try XCTUnwrap(translated.currentPage)), 1)
        XCTAssertEqual(harness.model.pageIndex, 4)
        try await dragDivider(in: harness.window, by: 80)
        XCTAssertEqual(harness.model.pageIndex, 4)
    }

    @MainActor
    private func makeHarness(pageIndex: Int = 0, translatedPageCount: Int = 6) throws -> PDFHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = [directory.appendingPathComponent("original.pdf"), directory.appendingPathComponent("translated.pdf")]
        for (index, url) in urls.enumerated() {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
            try renderer.writePDF(to: url) { context in
                for page in 0..<(index == 0 ? 6 : translatedPageCount) {
                    context.beginPage()
                    ("Page \(page + 1)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: nil)
                }
            }
        }
        let model = PDFHarnessModel(originalURL: urls[0], translatedURL: urls[1],
                                    translatedPageCount: translatedPageCount, pageIndex: pageIndex)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: PDFHarnessView(model: model))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return PDFHarness(model: model, window: window, directory: directory)
    }

    @MainActor
    private func dragDivider(in view: UIView, by delta: CGFloat) async throws {
        let divider = try XCTUnwrap(descendants(TouchPDFSplitDivider.self, in: view).first)
        let gesture = TestPanGesture()
        gesture.simulatedState = .began
        divider.drag(gesture)
        try await settle()
        gesture.simulatedState = .changed
        gesture.delta = delta
        divider.drag(gesture)
        gesture.simulatedState = .ended
        divider.drag(gesture)
        try await settle()
    }

    @MainActor
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    @MainActor
    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        if let match = view as? T { return [match] }
        return view.subviews.flatMap { descendants(type, in: $0) }
    }
}

@MainActor
private final class TestPanGesture: UIPanGestureRecognizer {
    var simulatedState: UIGestureRecognizer.State = .possible
    var delta: CGFloat = 0
    override var state: UIGestureRecognizer.State {
        get { simulatedState }
        set { simulatedState = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: delta, y: 0) }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { delta = translation.x }
}

@MainActor
private final class TestPinchGesture: UIPinchGestureRecognizer {
    var simulatedState: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { simulatedState }
        set { simulatedState = newValue }
    }
}

@MainActor
private final class PDFHarnessModel: ObservableObject {
    let originalURL: URL
    let translatedURL: URL
    let translatedPageCount: Int
    @Published var pageIndex: Int
    @Published var reloadToken = 0
    @Published var restoreToken = 0
    @Published var width: CGFloat = 1000

    init(originalURL: URL, translatedURL: URL, translatedPageCount: Int, pageIndex: Int) {
        self.originalURL = originalURL
        self.translatedURL = translatedURL
        self.translatedPageCount = translatedPageCount
        self.pageIndex = pageIndex
    }
}

private struct PDFHarnessView: View {
    @ObservedObject var model: PDFHarnessModel
    var body: some View {
        StableHorizontalPDFSplitView(onDividerDragBegan: { model.restoreToken += 1 }) {
            PDFReaderView(fileURL: model.originalURL, usesAutomaticScaling: true,
                          automaticScalingRestoreToken: model.restoreToken,
                          pageIndex: $model.pageIndex, reloadToken: model.reloadToken)
        } trailing: {
            PDFReaderView(fileURL: model.translatedURL, usesAutomaticScaling: true,
                          automaticScalingRestoreToken: model.restoreToken,
                          pageIndex: Binding(get: {
                              DualPDFPageIndexSync.translatedPageIndex(
                                  forOriginalPageIndex: model.pageIndex,
                                  translatedPageCount: model.translatedPageCount)
                          }, set: { _ in }), reloadToken: model.reloadToken)
        }
        .frame(width: model.width, height: 700)
    }
}

@MainActor
private struct PDFHarness {
    let model: PDFHarnessModel
    let window: UIWindow
    let directory: URL
    func close() {
        window.isHidden = true
        window.rootViewController = nil
        try? FileManager.default.removeItem(at: directory)
    }
}
