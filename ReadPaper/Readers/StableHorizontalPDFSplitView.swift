import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct DualPDFSplitLayout {
    #if os(macOS)
    static let dividerWidth: CGFloat = 8
    #else
    // A finger-sized target; the visible separator stays one point wide.
    static let dividerWidth: CGFloat = 28
    #endif
    static let minimumPaneWidth: CGFloat = 180
    static let minimumDragUpdateInterval: TimeInterval = 1.0 / 60.0

    static func shouldEmitDragUpdate(
        lastTimestamp: TimeInterval?,
        currentTimestamp: TimeInterval
    ) -> Bool {
        guard let lastTimestamp else { return true }
        let timestampTolerance: TimeInterval = 0.000_001
        return currentTimestamp - lastTimestamp + timestampTolerance >= minimumDragUpdateInterval
    }

    static func leadingWidth(totalWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        let availableWidth = max(0, totalWidth - dividerWidth)
        guard availableWidth > 0 else { return 0 }
        return availableWidth * clampedFraction(fraction, availableWidth: availableWidth)
    }

    static func fraction(
        afterDraggingBy delta: CGFloat,
        totalWidth: CGFloat,
        currentFraction: CGFloat
    ) -> CGFloat {
        let availableWidth = max(0, totalWidth - dividerWidth)
        guard availableWidth > 0 else { return 0.5 }
        let currentWidth = leadingWidth(totalWidth: totalWidth, fraction: currentFraction)
        return clampedFraction(
            (currentWidth + delta) / availableWidth,
            availableWidth: availableWidth
        )
    }

    private static func clampedFraction(_ fraction: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let minimumWidth = min(minimumPaneWidth, availableWidth / 2)
        let minimumFraction = minimumWidth / availableWidth
        return min(max(fraction, minimumFraction), 1 - minimumFraction)
    }
}

struct StableHorizontalPDFSplitView<Leading: View, Trailing: View>: View {
    @State private var leadingFraction: CGFloat = 0.5
    private let onDividerDragBegan: () -> Void
    private let leading: Leading
    private let trailing: Trailing

    init(
        onDividerDragBegan: @escaping () -> Void = {},
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.onDividerDragBegan = onDividerDragBegan
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let leadingWidth = DualPDFSplitLayout.leadingWidth(
                totalWidth: totalWidth,
                fraction: leadingFraction
            )

            HStack(spacing: 0) {
                leading
                    .frame(width: leadingWidth)

                StablePDFSplitDivider(
                    onDragBegan: onDividerDragBegan,
                    onDrag: { delta in
                        leadingFraction = DualPDFSplitLayout.fraction(
                            afterDraggingBy: delta,
                            totalWidth: totalWidth,
                            currentFraction: leadingFraction
                        )
                    }
                )
                .frame(width: DualPDFSplitLayout.dividerWidth)

                trailing
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

#if os(macOS)
private struct StablePDFSplitDivider: NSViewRepresentable {
    var onDragBegan: () -> Void
    var onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        view.onDragBegan = onDragBegan
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: DividerView, context: Context) {
        nsView.onDragBegan = onDragBegan
        nsView.onDrag = onDrag
    }

    final class DividerView: NSView {
        var onDragBegan: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        private var lastDragLocationX: CGFloat?
        private var pendingDragDelta: CGFloat = 0
        private var lastDragUpdateTimestamp: TimeInterval?

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDown(with event: NSEvent) {
            lastDragLocationX = event.locationInWindow.x
            pendingDragDelta = 0
            lastDragUpdateTimestamp = nil
            onDragBegan?()
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            let locationX = event.locationInWindow.x
            if let lastDragLocationX {
                pendingDragDelta += locationX - lastDragLocationX
            }
            self.lastDragLocationX = locationX
            if DualPDFSplitLayout.shouldEmitDragUpdate(
                lastTimestamp: lastDragUpdateTimestamp,
                currentTimestamp: event.timestamp
            ) {
                flushPendingDrag(at: event.timestamp)
            }
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            flushPendingDrag(at: event.timestamp)
            lastDragLocationX = nil
            lastDragUpdateTimestamp = nil
            NSCursor.resizeLeftRight.set()
        }

        private func flushPendingDrag(at timestamp: TimeInterval) {
            guard pendingDragDelta != 0 else { return }
            let delta = pendingDragDelta
            pendingDragDelta = 0
            lastDragUpdateTimestamp = timestamp
            onDrag?(delta)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect],
                    owner: self
                )
            )
        }
    }
}

#else
private struct StablePDFSplitDivider: UIViewRepresentable {
    @Environment(\.localizationBundle) private var bundle
    var onDragBegan: () -> Void
    var onDrag: (CGFloat) -> Void

    func makeUIView(context: Context) -> TouchPDFSplitDivider {
        let view = TouchPDFSplitDivider()
        view.onDragBegan = onDragBegan
        view.onDrag = onDrag
        view.accessibilityLabel = String(localized: "Resize", bundle: bundle)
        return view
    }

    func updateUIView(_ view: TouchPDFSplitDivider, context: Context) {
        view.onDragBegan = onDragBegan
        view.onDrag = onDrag
        view.accessibilityLabel = String(localized: "Resize", bundle: bundle)
    }
}

final class TouchPDFSplitDivider: UIView {
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    private var pendingDragDelta: CGFloat = 0
    private var lastDragUpdateTimestamp: TimeInterval?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityIncrement() {
        onDragBegan?()
        onDrag?(44)
    }

    override func accessibilityDecrement() {
        onDragBegan?()
        onDrag?(-44)
    }

    override func draw(_ rect: CGRect) {
        UIColor.separator.setFill()
        UIRectFill(CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height))
        UIColor.tertiaryLabel.setFill()
        UIBezierPath(roundedRect: CGRect(x: bounds.midX - 2, y: bounds.midY - 18,
                                         width: 4, height: 36), cornerRadius: 2).fill()
    }

    @objc func drag(_ gesture: UIPanGestureRecognizer) {
        // Use window coordinates: the divider itself moves as the panes resize.
        let delta = gesture.translation(in: window).x
        gesture.setTranslation(.zero, in: window)
        let timestamp = CACurrentMediaTime()
        switch gesture.state {
        case .began:
            pendingDragDelta = delta
            lastDragUpdateTimestamp = nil
            onDragBegan?()
        case .changed:
            pendingDragDelta += delta
            if DualPDFSplitLayout.shouldEmitDragUpdate(
                lastTimestamp: lastDragUpdateTimestamp, currentTimestamp: timestamp
            ) {
                flushPendingDrag(at: timestamp)
            }
        case .ended, .cancelled:
            pendingDragDelta += delta
            flushPendingDrag(at: timestamp)
            lastDragUpdateTimestamp = nil
        default:
            break
        }
    }

    private func flushPendingDrag(at timestamp: TimeInterval) {
        guard pendingDragDelta != 0 else { return }
        let delta = pendingDragDelta
        pendingDragDelta = 0
        lastDragUpdateTimestamp = timestamp
        onDrag?(delta)
    }
}
#endif
