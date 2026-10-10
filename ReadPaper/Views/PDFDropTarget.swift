import AppKit
import SwiftUI

extension View {
    /// Accepts PDF files dragged onto any part of the window and shows the import overlay
    /// while a drag is over the window or a dropped import is running.
    func pdfFileDropTarget(
        isTargeted: Binding<Bool>,
        isImporting: Bool,
        perform: @escaping ([URL]) -> Bool
    ) -> some View {
        overlay {
            // Keep one always-present container that ignores the safe area: applied inside a
            // transitioning view, it only takes effect once the insertion finishes, so the card
            // would first appear centered below the toolbar and then jump up.
            ZStack {
                PDFFileDropCatcher(
                    isEnabled: !isImporting,
                    onTargetedChange: { targeted in
                        withAnimation(PDFDropOverlay.animation) {
                            isTargeted.wrappedValue = targeted
                        }
                    },
                    onDrop: perform
                )

                PDFDropOverlay(
                    isPresented: isTargeted.wrappedValue || isImporting,
                    isImporting: isImporting
                )
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .animation(PDFDropOverlay.animation, value: isImporting)
        }
    }
}

/// Window-wide drop target for PDF files.
///
/// AppKit hands a drag to the frontmost view registered for one of its pasteboard types and
/// never bubbles it to the views behind. A SwiftUI `dropDestination` on the window content
/// sits behind the readers, and `WKWebView` claims every drag over its frame regardless of
/// the types it registered, so an open HTML reader swallowed PDFs dragged from Finder. This
/// view is layered above the whole window instead. AppKit's drag lookup does not consult
/// `hitTest(_:)`, so the view can stay transparent to clicks, scrolling, and cursor updates.
struct PDFFileDropCatcher: NSViewRepresentable {
    var isEnabled: Bool
    var onTargetedChange: (Bool) -> Void
    var onDrop: ([URL]) -> Bool

    func makeNSView(context: Context) -> PDFFileDropCatcherView {
        let view = PDFFileDropCatcherView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: PDFFileDropCatcherView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: PDFFileDropCatcherView) {
        view.isEnabled = isEnabled
        view.onTargetedChange = onTargetedChange
        view.onDrop = onDrop
    }
}

final class PDFFileDropCatcherView: NSView {
    static let acceptedDraggedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    ]

    var isEnabled = true
    var onTargetedChange: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Bool)?

    private var isTargeted = false
    private var evaluatedDrag: (sequenceNumber: Int, containsPDFs: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedDraggedTypes)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTargeting(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTargeting(for: sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        evaluatedDrag = nil
        setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isEnabled && containsPDFs(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.pdfURLs(on: sender.draggingPasteboard)
        setTargeted(false)
        guard isEnabled, !urls.isEmpty else { return false }
        return onDrop?(urls) ?? false
    }

    /// Local PDF files on `pasteboard`, in drag order and without duplicates.
    static func pdfURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return PaperImporter.supportedLocalPDFs(from: urls)
    }

    private func updateTargeting(for sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = isEnabled && containsPDFs(sender)
        setTargeted(accepts)
        return accepts ? .copy : []
    }

    /// Reads the drag pasteboard once per drag session instead of on every mouse move.
    private func containsPDFs(_ sender: NSDraggingInfo) -> Bool {
        if let evaluatedDrag, evaluatedDrag.sequenceNumber == sender.draggingSequenceNumber {
            return evaluatedDrag.containsPDFs
        }
        let containsPDFs = !Self.pdfURLs(on: sender.draggingPasteboard).isEmpty
        evaluatedDrag = (sender.draggingSequenceNumber, containsPDFs)
        return containsPDFs
    }

    private func setTargeted(_ targeted: Bool) {
        guard isTargeted != targeted else { return }
        isTargeted = targeted
        onTargetedChange?(targeted)
    }
}

/// Full-window veil with a floating card, styled like the reader's other floating UI: native
/// glass with a hairline edge, and paper colors plus serif type in the paper appearance.
struct PDFDropOverlay: View {
    static let animation = Animation.easeOut(duration: 0.18)

    @Environment(\.localizationBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isPresented: Bool
    let isImporting: Bool

    private var isPaperAppearance: Bool {
        displayAppearance == .paper
    }

    var body: some View {
        ZStack {
            if isPresented {
                veil
                    .transition(.opacity)

                card
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.94).combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Washes the window toward its own surface color so the card reads as the focus without
    /// tinting the reader in a color the rest of the app does not use.
    private var veil: some View {
        Group {
            if isPaperAppearance {
                ReadPaperTheme.surfaceColor(.reader, scheme: colorScheme)
                    .opacity(0.42)
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.34)
            }
        }
        .accessibilityHidden(true)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return VStack(spacing: 14) {
            Image(systemName: isImporting ? "doc.badge.ellipsis" : "arrow.down.doc.fill")
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ReadPaperTheme.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .background(
                    ReadPaperTheme.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .accessibilityHidden(true)

            Group {
                if isImporting {
                    Text("Importing PDFs…", bundle: bundle)
                } else {
                    Text("Drop PDFs to Import", bundle: bundle)
                }
            }
            .font(.system(.title3, design: isPaperAppearance ? .serif : .rounded, weight: .semibold))
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(minWidth: 240)
        .readPaperGlassEffect(in: shape)
        .overlay {
            shape.strokeBorder(
                isPaperAppearance
                    ? ReadPaperTheme.cardBorderColor(scheme: colorScheme)
                    : Color.primary.opacity(0.12),
                lineWidth: 0.5
            )
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }
}
