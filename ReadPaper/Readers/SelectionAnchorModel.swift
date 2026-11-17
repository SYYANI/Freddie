#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// Where the reader's current text selection sits on screen, so a small view can be shown
/// next to it. The readers write it on every selection change and scroll; only the view
/// that reads `rect` is re-rendered, not the whole reader pane.
@MainActor
@Observable
final class SelectionAnchorModel {
    /// The visible part of the selection, in the coordinates of `referenceView` (origin at
    /// the top left). `nil` when nothing is selected or the selection is scrolled away.
    private(set) var rect: CGRect?

    /// The view the bubble is laid out in. Rects are converted into its coordinates.
    @ObservationIgnored weak var referenceView: NSView?
    /// The reader holding the selection. In the two-column reader both sides report here,
    /// and the side without a selection must not clear the other side's rect.
    @ObservationIgnored private weak var owner: AnyObject?

    /// `rect` is in `view`'s own coordinates.
    func update(_ rect: CGRect?, in view: NSView, owner: AnyObject) {
        guard let rect, rect.isNull == false, rect.isEmpty == false else {
            clear(owner: owner)
            return
        }
        guard let referenceView, referenceView.window != nil, view.window === referenceView.window else {
            self.owner = owner
            setRect(nil)
            return
        }
        self.owner = owner
        let converted = view.convert(rect, to: referenceView)
        setRect(referenceView.isFlipped ? converted : CGRect(
            x: converted.minX,
            y: referenceView.bounds.height - converted.maxY,
            width: converted.width,
            height: converted.height
        ))
    }

    func clear(owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        setRect(nil)
    }

    private func setRect(_ newValue: CGRect?) {
        let rounded = newValue.map { rect in
            CGRect(
                x: (rect.minX * 2).rounded() / 2,
                y: (rect.minY * 2).rounded() / 2,
                width: (rect.width * 2).rounded() / 2,
                height: (rect.height * 2).rounded() / 2
            )
        }
        guard rounded != rect else { return }
        rect = rounded
    }
}

private struct SelectionAnchorModelKey: EnvironmentKey {
    static let defaultValue: SelectionAnchorModel? = nil
}

extension EnvironmentValues {
    /// Set by the reader pane; the PDF and HTML readers report their selection's position to it.
    var selectionAnchorModel: SelectionAnchorModel? {
        get { self[SelectionAnchorModelKey.self] }
        set { self[SelectionAnchorModelKey.self] = newValue }
    }
}

/// Marks the area that `SelectionAnchorModel.rect` is expressed in. It never takes part in
/// hit testing, so clicks and scrolling reach the reader underneath.
struct SelectionAnchorReferenceView: NSViewRepresentable {
    let model: SelectionAnchorModel

    func makeNSView(context: Context) -> NSView {
        let view = ReferenceView()
        model.referenceView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if model.referenceView !== view {
            model.referenceView = view
        }
    }

    private final class ReferenceView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
