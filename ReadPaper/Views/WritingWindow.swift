import AppKit
import Observation
import SwiftUI

/// The separate writing window for large screens. It shows the same writing as the
/// inspector's Writing tab, which shows a placeholder while the window is open, so a
/// writing never has two editors at once.
enum WritingWindowScene {
    static let id = "writing"
    static let defaultWidth: CGFloat = 820
    static let defaultHeight: CGFloat = 860
    static let minWidth: CGFloat = 420
    static let minHeight: CGFloat = 360
    /// The longest lines a wide window shows; wider windows center a column.
    static let maximumTextWidth: CGFloat = 700
}

@MainActor
@Observable
final class WritingWindowState {
    static let shared = WritingWindowState()

    private(set) var isOpen = false
    /// Changing it moves keyboard focus into the window's editor.
    private(set) var focusRequest = 0

    @ObservationIgnored private var focusesEditorOnAppear = false
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    func windowDidAppear() {
        isOpen = true
        if focusesEditorOnAppear {
            focusesEditorOnAppear = false
            requestFocus()
        }
    }

    /// Only a hidden window counts as closed; closing is reported by the window itself.
    func windowDidDisappear() {
        if window?.isVisible != true {
            isOpen = false
        }
    }

    func track(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isOpen = false
            }
        }
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    /// Moves keyboard focus into the window's editor now, or once a window being opened appears.
    func focusEditorWhenShown() {
        if isOpen {
            requestFocus()
        } else {
            focusesEditorOnAppear = true
        }
    }
}

struct WritingWindowView: View {
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Environment(\.openWindow) private var openWindow
    var center: WritingDocumentCenter = .shared
    var state: WritingWindowState = .shared

    @State private var errorMessage: String?

    private var title: String {
        guard let writing = center.library.currentWriting else {
            return String(localized: "Writing", bundle: bundle)
        }
        return writing.title.isEmpty ? String(localized: "Untitled Writing", bundle: bundle) : writing.title
    }

    var body: some View {
        WritingPaneView(
            center: center,
            presentation: .window,
            focusRequest: state.focusRequest,
            onOpenCitation: { citation, quote in
                PaperLinkRouter.shared.openCitation(citation, quote: quote, origin: .writingWindow)
            }
        )
        .frame(minWidth: WritingWindowScene.minWidth, minHeight: WritingWindowScene.minHeight)
        .background {
            Group {
                if displayAppearance == .paper {
                    ReadPaperSurface(role: .reader)
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
            }
            .ignoresSafeArea()
        }
        .background {
            HostingWindowReader { window in
                state.track(window)
            }
            .frame(width: 0, height: 0)
        }
        .fontDesign(displayAppearance == .paper ? .serif : .default)
        .navigationTitle(title)
        .focusedSceneValue(\.newWritingAction, NewWritingAction { createWriting() })
        .onAppear {
            state.windowDidAppear()
            PaperLinkRouter.shared.openMainWindow = { [openWindow] in
                openWindow(id: MainWindowScene.id)
            }
        }
        .onDisappear {
            state.windowDidDisappear()
        }
        .alert(
            String(localized: "Unable to Update Writing", bundle: bundle),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func createWriting() {
        do {
            center.saveAll()
            try center.library.createWriting()
            state.requestFocus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
