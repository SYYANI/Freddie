import AppKit
import SwiftUI

/// Gives a thin `NavigationSplitView` divider a stable cursor and drag target without
/// replacing the system split view or its delegate.
struct StableNavigationSplitDividerHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DividerHandleView {
        DividerHandleView()
    }

    func updateNSView(_ nsView: DividerHandleView, context: Context) {
        nsView.resolveSplitViewIfNeeded()
    }

    final class DividerHandleView: NSView {
        private weak var splitView: NSSplitView?
        private var dividerIndex: Int?
        private var dragOffset: CGFloat?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveSplitViewIfNeeded()
            window?.invalidateCursorRects(for: self)
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
            resolveSplitViewIfNeeded()
            if let splitView, let dividerIndex {
                let location = splitView.convert(event.locationInWindow, from: nil)
                let dividerPosition = splitView.arrangedSubviews[dividerIndex].frame.maxX
                dragOffset = dividerPosition - location.x
            }
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            resizeSplitView(for: event)
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            dragOffset = nil
            NSCursor.resizeLeftRight.set()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect],
                    owner: self
                )
            )
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        func resolveSplitViewIfNeeded() {
            guard splitView == nil || dividerIndex == nil else { return }

            var ancestor = superview
            while let current = ancestor, !(current is NSSplitView) {
                ancestor = current.superview
            }

            guard let splitView = ancestor as? NSSplitView, splitView.isVertical else { return }
            guard let paneIndex = splitView.arrangedSubviews.firstIndex(where: { pane in
                self === pane || isDescendant(of: pane)
            }) else { return }
            guard paneIndex < splitView.arrangedSubviews.count - 1 else { return }

            self.splitView = splitView
            dividerIndex = paneIndex
        }

        private func resizeSplitView(for event: NSEvent) {
            guard let splitView, let dividerIndex else { return }
            let location = splitView.convert(event.locationInWindow, from: nil)
            splitView.setPosition(location.x + (dragOffset ?? 0), ofDividerAt: dividerIndex)
        }
    }
}
