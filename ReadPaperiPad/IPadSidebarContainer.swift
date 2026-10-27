import SwiftUI
import UIKit

/// Geometry for the iPad's library sidebar and inspector. A panel's placement is a pure
/// function of its open progress (0 hidden, 1 shown), so a drag can move it linearly with
/// the finger and a release only has to animate the progress to 0 or 1.
enum IPadSidebarLayout {
    enum Edge: Equatable {
        case leading
        case trailing
    }

    struct DragTarget: Equatable {
        let edge: Edge
        /// The touch started on the panel itself, so the drag can only close it.
        let isOnPanel: Bool
    }

    static let sidebarWidth: CGFloat = 260
    static let inspectorWidth: CGFloat = 340
    /// A panel that would leave the reader narrower than this slides over it instead.
    static let minimumReaderWidth: CGFloat = 400
    /// Narrow windows keep this much of the reader visible beside an overlaid panel.
    static let overlayMargin: CGFloat = 56
    /// Width of the reader strip along each panel edge where a horizontal swipe grabs the panel.
    static let edgeGrabWidth: CGFloat = 28
    /// Releases faster than this settle in the fling's direction regardless of position.
    static let flingVelocity: CGFloat = 300

    struct Metrics: Equatable {
        var sidebarWidth: CGFloat
        var inspectorWidth: CGFloat
        var sidebarTiles: Bool
        var inspectorTiles: Bool

        func width(of edge: Edge) -> CGFloat {
            edge == .leading ? sidebarWidth : inspectorWidth
        }

        func tiles(_ edge: Edge) -> Bool {
            edge == .leading ? sidebarTiles : inspectorTiles
        }
    }

    static func metrics(containerWidth: CGFloat) -> Metrics {
        let sidebar = min(sidebarWidth, max(0, containerWidth - overlayMargin))
        let inspector = min(inspectorWidth, max(0, containerWidth - overlayMargin))
        let sidebarTiles = containerWidth >= sidebar + minimumReaderWidth
        let inspectorTiles = containerWidth >= (sidebarTiles ? sidebar : 0) + inspector + minimumReaderWidth
        return Metrics(
            sidebarWidth: sidebar,
            inspectorWidth: inspector,
            sidebarTiles: sidebarTiles,
            inspectorTiles: inspectorTiles
        )
    }

    /// Which panel a horizontal drag starting at `x` moves, if any. `velocityX` is positive
    /// for a rightward drag. Drags on a panel can only close it; `IPadSidebarPanDriver` also
    /// leaves drags on text and list rows to them.
    static func dragTarget(
        atX x: CGFloat,
        velocityX: CGFloat,
        containerWidth: CGFloat,
        metrics: Metrics,
        sidebarProgress: CGFloat,
        inspectorProgress: CGFloat
    ) -> DragTarget? {
        let rightward = velocityX > 0
        let sidebarEdge = metrics.sidebarWidth * sidebarProgress
        let inspectorEdge = containerWidth - metrics.inspectorWidth * inspectorProgress

        // An overlaid panel owns every touch until it closes; the reader beside it is dimmed.
        if !metrics.sidebarTiles, sidebarProgress > 0 {
            return rightward ? nil : DragTarget(edge: .leading, isOnPanel: x < sidebarEdge)
        }
        if !metrics.inspectorTiles, inspectorProgress > 0 {
            return rightward ? DragTarget(edge: .trailing, isOnPanel: x > inspectorEdge) : nil
        }

        if x < sidebarEdge {
            return rightward ? nil : DragTarget(edge: .leading, isOnPanel: true)
        }
        if x > inspectorEdge {
            return rightward ? DragTarget(edge: .trailing, isOnPanel: true) : nil
        }
        let canMoveSidebar = rightward ? sidebarProgress < 1 : sidebarProgress > 0
        if x <= sidebarEdge + edgeGrabWidth, canMoveSidebar {
            return DragTarget(edge: .leading, isOnPanel: false)
        }
        let canMoveInspector = rightward ? inspectorProgress > 0 : inspectorProgress < 1
        if x >= inspectorEdge - edgeGrabWidth, canMoveInspector {
            return DragTarget(edge: .trailing, isOnPanel: false)
        }
        return nil
    }

    /// Open progress after dragging a panel `translation` points (positive is rightward)
    /// from `start`: the panel edge stays under the finger.
    static func progress(from start: CGFloat, translation: CGFloat, panelWidth: CGFloat, edge: Edge) -> CGFloat {
        guard panelWidth > 0 else { return start }
        let opening = edge == .leading ? translation : -translation
        return min(1, max(0, start + opening / panelWidth))
    }

    static func settlesOpen(progress: CGFloat, velocityX: CGFloat, edge: Edge) -> Bool {
        let opening = edge == .leading ? velocityX : -velocityX
        if abs(opening) >= flingVelocity { return opening > 0 }
        return progress >= 0.5
    }

    /// Spring velocity, as a fraction of the remaining distance per second, that continues
    /// the finger's speed into the settle animation.
    static func settleVelocity(
        from progress: CGFloat, to target: CGFloat, velocityX: CGFloat, panelWidth: CGFloat, edge: Edge
    ) -> Double {
        let remaining = target - progress
        guard abs(remaining) > 0.001, panelWidth > 0 else { return 0 }
        let opening = edge == .leading ? velocityX : -velocityX
        return Double(min(30, max(0, opening / panelWidth / remaining)))
    }
}

/// Three-column iPad layout whose library sidebar and inspector follow the finger when
/// swiped open or closed. `NavigationSplitView` and `.inspector` only animate between
/// fixed states, so the columns are laid out here and driven by `IPadSidebarPanView`.
/// Panels push the reader aside when there is room and slide over it otherwise.
struct IPadSidebarContainer<Selection: Equatable, Sidebar: View, Detail: View, Inspector: View>: View {
    private typealias Edge = IPadSidebarLayout.Edge

    @Binding var isSidebarPresented: Bool
    @Binding var isInspectorPresented: Bool
    /// Changing this closes an overlaid sidebar, as picking a paper should reveal the reader.
    let selection: Selection
    let sidebar: Sidebar
    let detail: Detail
    let inspector: Inspector

    @Environment(\.displayScale) private var displayScale
    @State private var containerWidth: CGFloat = 0
    @State private var sidebarProgress: CGFloat
    @State private var inspectorProgress: CGFloat
    @State private var isInspectorMounted: Bool
    @State private var drag: Drag?

    private struct Drag {
        let edge: IPadSidebarLayout.Edge
        let startProgress: CGFloat
    }

    init(
        isSidebarPresented: Binding<Bool>,
        isInspectorPresented: Binding<Bool>,
        selection: Selection,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder inspector: () -> Inspector
    ) {
        _isSidebarPresented = isSidebarPresented
        _isInspectorPresented = isInspectorPresented
        self.selection = selection
        self.sidebar = sidebar()
        self.detail = detail()
        self.inspector = inspector()
        _sidebarProgress = State(initialValue: isSidebarPresented.wrappedValue ? 1 : 0)
        _inspectorProgress = State(initialValue: isInspectorPresented.wrappedValue ? 1 : 0)
        _isInspectorMounted = State(initialValue: isInspectorPresented.wrappedValue)
    }

    private var metrics: IPadSidebarLayout.Metrics {
        IPadSidebarLayout.metrics(containerWidth: containerWidth)
    }

    var body: some View {
        let metrics = metrics
        let overlayProgress = max(
            metrics.sidebarTiles ? 0 : sidebarProgress,
            metrics.inspectorTiles ? 0 : inspectorProgress
        )
        ZStack(alignment: .topLeading) {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, metrics.sidebarTiles ? metrics.sidebarWidth * sidebarProgress : 0)
                .padding(.trailing, metrics.inspectorTiles ? metrics.inspectorWidth * inspectorProgress : 0)

            if overlayProgress > 0 {
                Color.black.opacity(0.18 * overlayProgress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeOverlaidPanels)
                    .accessibilityHidden(true)
            }

            panel(sidebar, edge: .leading, metrics: metrics)

            if isInspectorMounted {
                panel(inspector, edge: .trailing, metrics: metrics)
            }
        }
        .background {
            IPadSidebarPanRecognizer(
                resolveTarget: { x, velocityX in
                    IPadSidebarLayout.dragTarget(
                        atX: x,
                        velocityX: velocityX,
                        containerWidth: containerWidth,
                        metrics: metrics,
                        sidebarProgress: sidebarProgress,
                        inspectorProgress: inspectorProgress
                    )
                },
                onBegan: beginDrag,
                onChanged: updateDrag,
                onEnded: endDrag
            )
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { containerWidth = $0 }
        // Each column handles the keyboard itself; the reader should not shrink while a
        // note is edited in the inspector.
        .ignoresSafeArea(.keyboard)
        .onChange(of: isSidebarPresented) { _, isPresented in
            settle(.leading, open: isPresented)
        }
        .onChange(of: isInspectorPresented) { _, isPresented in
            settle(.trailing, open: isPresented)
        }
        .onChange(of: metrics) { _, _ in closeSecondOverlayIfNeeded() }
        .onChange(of: selection) { _, _ in
            if !metrics.sidebarTiles, isSidebarPresented { isSidebarPresented = false }
        }
    }

    private func panel(_ content: some View, edge: Edge, metrics: IPadSidebarLayout.Metrics) -> some View {
        let width = metrics.width(of: edge)
        let progress = progress(of: edge)
        let overlays = !metrics.tiles(edge)
        return content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .overlay(alignment: edge == .leading ? .trailing : .leading) {
                if !overlays {
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 1 / displayScale)
                        .ignoresSafeArea()
                }
            }
            .shadow(color: .black.opacity(overlays ? 0.18 * progress : 0), radius: 16)
            .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
            .offset(x: (edge == .leading ? -width : width) * (1 - progress))
            .allowsHitTesting(progress > 0)
            .accessibilityHidden(progress == 0)
            .accessibilityAction(.escape) { setPresented(edge, false) }
    }

    private func progress(of edge: Edge) -> CGFloat {
        edge == .leading ? sidebarProgress : inspectorProgress
    }

    private func setProgress(_ value: CGFloat, of edge: Edge) {
        if edge == .leading { sidebarProgress = value } else { inspectorProgress = value }
    }

    private func isPresented(_ edge: Edge) -> Bool {
        edge == .leading ? isSidebarPresented : isInspectorPresented
    }

    private func setPresented(_ edge: Edge, _ value: Bool) {
        if edge == .leading { isSidebarPresented = value } else { isInspectorPresented = value }
    }

    private func beginDrag(_ edge: Edge) {
        drag = Drag(edge: edge, startProgress: progress(of: edge))
        if edge == .trailing { isInspectorMounted = true }
    }

    private func updateDrag(_ translation: CGFloat) {
        guard let drag else { return }
        let progress = IPadSidebarLayout.progress(
            from: drag.startProgress,
            translation: translation,
            panelWidth: metrics.width(of: drag.edge),
            edge: drag.edge
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { setProgress(progress, of: drag.edge) }
    }

    private func endDrag(_ translation: CGFloat, _ velocityX: CGFloat) {
        guard let drag else { return }
        updateDrag(translation)
        self.drag = nil
        let open = IPadSidebarLayout.settlesOpen(
            progress: progress(of: drag.edge), velocityX: velocityX, edge: drag.edge
        )
        settle(drag.edge, open: open, velocityX: velocityX)
        if isPresented(drag.edge) != open { setPresented(drag.edge, open) }
    }

    private func settle(_ edge: Edge, open: Bool, velocityX: CGFloat = 0) {
        guard drag?.edge != edge else { return }
        let target: CGFloat = open ? 1 : 0
        if open {
            if edge == .trailing { isInspectorMounted = true }
            closeOtherOverlay(opening: edge)
        }
        guard progress(of: edge) != target else {
            if edge == .trailing, !open { isInspectorMounted = false }
            return
        }
        let velocity = IPadSidebarLayout.settleVelocity(
            from: progress(of: edge), to: target, velocityX: velocityX,
            panelWidth: metrics.width(of: edge), edge: edge
        )
        withAnimation(
            .interpolatingSpring(duration: 0.34, bounce: 0, initialVelocity: velocity),
            completionCriteria: .removed
        ) {
            setProgress(target, of: edge)
        } completion: {
            // Unmount the inspector like `.inspector` does, once it has slid out.
            if edge == .trailing, !isInspectorPresented, drag?.edge != .trailing, inspectorProgress == 0 {
                isInspectorMounted = false
            }
        }
    }

    /// Two overlaid panels would cover each other and the reader, so opening one closes the other.
    private func closeOtherOverlay(opening edge: Edge) {
        let other: Edge = edge == .leading ? .trailing : .leading
        if !metrics.tiles(edge), !metrics.tiles(other), isPresented(other) {
            setPresented(other, false)
        }
    }

    private func closeSecondOverlayIfNeeded() {
        if !metrics.sidebarTiles, !metrics.inspectorTiles, isSidebarPresented, isInspectorPresented {
            isInspectorPresented = false
        }
    }

    private func closeOverlaidPanels() {
        if !metrics.sidebarTiles, isSidebarPresented { isSidebarPresented = false }
        if !metrics.inspectorTiles, isInspectorPresented { isInspectorPresented = false }
    }
}

private struct IPadSidebarPanRecognizer: UIViewRepresentable {
    var resolveTarget: (CGFloat, CGFloat) -> IPadSidebarLayout.DragTarget?
    var onBegan: (IPadSidebarLayout.Edge) -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> IPadSidebarPanView {
        let view = IPadSidebarPanView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: IPadSidebarPanView, context: Context) {
        let driver = view.driver
        driver.resolveTarget = resolveTarget
        driver.onBegan = onBegan
        driver.onChanged = onChanged
        driver.onEnded = onEnded
    }

    static func dismantleUIView(_ view: IPadSidebarPanView, coordinator: ()) {
        view.driver.uninstall()
    }
}

/// Sits behind the columns and installs the panel pan on the window, so the pan sees touches
/// that land in PDF, web and list views without an overlay that would swallow their taps.
final class IPadSidebarPanView: UIView {
    let driver = IPadSidebarPanDriver()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        driver.anchorView = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        driver.install(on: window)
    }
}

/// The panel pan runs alongside the columns' own gestures and only begins for a horizontal
/// swipe that `IPadSidebarLayout.dragTarget` assigns to a panel; scrolling under the finger
/// stops then. Locations are in the anchor view, which spans the whole layout.
final class IPadSidebarPanDriver: NSObject, UIGestureRecognizerDelegate {
    var resolveTarget: ((CGFloat, CGFloat) -> IPadSidebarLayout.DragTarget?)?
    var onBegan: ((IPadSidebarLayout.Edge) -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat, CGFloat) -> Void)?
    weak var anchorView: UIView?

    let recognizer = UIPanGestureRecognizer()
    private weak var installedWindow: UIWindow?
    private weak var touchedView: UIView?
    private var pendingEdge: IPadSidebarLayout.Edge?
    private var activeEdge: IPadSidebarLayout.Edge?

    override init() {
        super.init()
        recognizer.addTarget(self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        // Pencil strokes near a panel edge are annotations, not panel swipes.
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    }

    func install(on window: UIWindow?) {
        guard installedWindow !== window else { return }
        uninstall()
        window?.addGestureRecognizer(recognizer)
        installedWindow = window
    }

    func uninstall() {
        installedWindow?.removeGestureRecognizer(recognizer)
        installedWindow = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Sheets, alerts and the settings cover share the window but are not this layout.
        guard let anchorView, let window = anchorView.window,
              window.rootViewController?.presentedViewController == nil,
              anchorView.bounds.contains(touch.location(in: anchorView)) else { return false }
        touchedView = touch.view
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        pendingEdge = nil
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: anchorView?.window)
        guard abs(velocity.x) > abs(velocity.y) * 1.2,
              let target = resolveTarget?(pan.location(in: anchorView).x, velocity.x),
              // Dragging across text selects it.
              !isInTextInput(touchedView),
              // Library rows swipe left to delete.
              !(target.isOnPanel && isInListRow(touchedView)) else { return false }
        pendingEdge = target.edge
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc func handlePan(_ pan: UIPanGestureRecognizer) {
        let window = anchorView?.window
        let translation = pan.translation(in: window).x
        switch pan.state {
        case .began:
            guard let edge = pendingEdge else { return }
            activeEdge = edge
            stopScrolling(under: touchedView)
            onBegan?(edge)
            onChanged?(translation)
        case .changed:
            guard activeEdge != nil else { return }
            onChanged?(translation)
        case .ended:
            guard activeEdge != nil else { return }
            activeEdge = nil
            onEnded?(translation, pan.velocity(in: window).x)
        case .cancelled, .failed:
            guard activeEdge != nil else { return }
            activeEdge = nil
            onEnded?(translation, 0)
        default:
            break
        }
    }

    private func isInTextInput(_ view: UIView?) -> Bool {
        ancestors(of: view).contains { $0 is UITextView || $0 is UITextField }
    }

    private func isInListRow(_ view: UIView?) -> Bool {
        ancestors(of: view).contains { $0 is UICollectionViewCell || $0 is UITableViewCell }
    }

    /// The pan runs alongside scroll views so it can take over a swipe that starts in them;
    /// once it does, cancel their pans so the page or list does not drift with the panel.
    private func stopScrolling(under view: UIView?) {
        for case let scrollView as UIScrollView in ancestors(of: view) {
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
        }
    }

    private func ancestors(of view: UIView?) -> [UIView] {
        guard let view else { return [] }
        return Array(sequence(first: view, next: \.superview))
    }
}
