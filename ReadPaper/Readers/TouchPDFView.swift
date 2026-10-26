#if os(iOS)
import PDFKit
import UIKit

/// The touch counterpart of InteractivePDFView's live-magnify handling.
final class TouchPDFView: PDFView {
    var onInitialLayoutReady: (() -> Void)?
    private let observedPinches = NSHashTable<UIPinchGestureRecognizer>.weakObjects()

    override func layoutSubviews() {
        super.layoutSubviews()
        observePinches(in: self)
        if window != nil, !bounds.isEmpty, let action = onInitialLayoutReady {
            onInitialLayoutReady = nil
            // Let PDFKit's child scroll view finish its first layout as well.
            Task { @MainActor in action() }
        }
    }

    private func observePinches(in view: UIView) {
        for case let pinch as UIPinchGestureRecognizer in view.gestureRecognizers ?? [] {
            guard !observedPinches.contains(pinch) else { continue }
            observedPinches.add(pinch)
            // Keep PDFKit's recognizer and delegate so zooming and text selection still work.
            pinch.addTarget(self, action: #selector(pinchChanged(_:)))
        }
        // PDFKit zooms its scroll view; don't walk every rendered page on every layout.
        if view is UIScrollView { return }
        for child in view.subviews {
            observePinches(in: child)
        }
    }

    @objc func pinchChanged(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed {
            // PDFKit can leave autoScales enabled after replacing the document. A later
            // layout would then discard the user's zoom, just as on macOS.
            autoScales = false
        }
    }
}
#endif
