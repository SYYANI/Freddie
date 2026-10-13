import AppKit
import Observation
import SwiftUI

/// Sends citations to a main window: those clicked in the separate writing window and
/// `readpaper://` links opened from other apps, such as a writing exported to Obsidian.
/// The frontmost main window goes to the passage. With no main window open, one is opened
/// and takes the citation once it registers. A link that launches the app opens no window
/// by itself (macOS sends it instead of the "open application" event), so the router
/// reopens the app like a click on its Dock icon when no main window has shown up.
@MainActor
@Observable
final class PaperLinkRouter {
    static let shared = PaperLinkRouter()

    enum Origin: Equatable {
        /// A link opened in another app: Freddie comes forward.
        case external
        /// A citation clicked in the writing window. Beside the main window, the writing
        /// window keeps the focus; when it covers the main window, the main window comes forward.
        case writingWindow
    }

    /// A citation for the main window registered as `windowID`.
    struct Delivery: Equatable, Identifiable {
        let id: UUID
        var windowID: UUID
        var citation: PaperCitation
        var quote: String?
    }

    private struct PendingCitation {
        var citation: PaperCitation
        var quote: String?
        var origin: Origin
    }

    private final class WindowReference {
        weak var window: NSWindow?

        init(_ window: NSWindow) {
            self.window = window
        }
    }

    private(set) var delivery: Delivery?
    /// Opens a main window; set by the views that can.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var windows: [UUID: WindowReference] = [:]
    @ObservationIgnored private var pending: PendingCitation?
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    @ObservationIgnored private let orderedWindows: () -> [NSWindow]
    @ObservationIgnored private let keyWindow: () -> NSWindow?
    @ObservationIgnored private let activateApplication: () -> Void
    /// Opens a main window without a SwiftUI view to do it.
    @ObservationIgnored private let reopenApplication: () -> Void
    /// How long a citation waits for a main window before the app is reopened; windows
    /// restored at launch register well within it.
    @ObservationIgnored private let windowFallbackDelay: Duration

    init(
        orderedWindows: @escaping () -> [NSWindow] = { NSApp.orderedWindows },
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
        activateApplication: @escaping () -> Void = { NSApp.activate() },
        reopenApplication: @escaping () -> Void = PaperLinkRouter.sendReopenEvent,
        windowFallbackDelay: Duration = .seconds(1)
    ) {
        self.orderedWindows = orderedWindows
        self.keyWindow = keyWindow
        self.activateApplication = activateApplication
        self.reopenApplication = reopenApplication
        self.windowFallbackDelay = windowFallbackDelay
    }

    /// A main window shows up, moves to another window or goes away (nil).
    func register(windowID: UUID, window: NSWindow?) {
        guard let window else {
            windows[windowID] = nil
            return
        }
        windows[windowID] = WindowReference(window)
        if let pending {
            self.pending = nil
            fallbackTask?.cancel()
            fallbackTask = nil
            openCitation(pending.citation, quote: pending.quote, origin: pending.origin)
        }
    }

    func unregister(windowID: UUID) {
        windows[windowID] = nil
    }

    /// Opens a `readpaper://paper/…` link; false for any other URL.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let citation = PaperCitation(linkDestination: url.absoluteString) else { return false }
        openCitation(citation, quote: nil, origin: .external)
        return true
    }

    func openCitation(_ citation: PaperCitation, quote: String?, origin: Origin) {
        guard let (windowID, window) = targetWindow() else {
            pending = PendingCitation(citation: citation, quote: quote, origin: origin)
            // Before any view has appeared the app is launching, and restored windows may
            // still come; the fallback reopens the app if none does.
            openMainWindow?()
            scheduleWindowFallback()
            return
        }
        bringForward(window, origin: origin)
        delivery = Delivery(id: UUID(), windowID: windowID, citation: citation, quote: quote)
    }

    private func scheduleWindowFallback() {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self, windowFallbackDelay] in
            try? await Task.sleep(for: windowFallbackDelay)
            guard Task.isCancelled == false, let self, self.pending != nil, self.targetWindow() == nil else { return }
            self.fallbackTask = nil
            self.activateApplication()
            self.reopenApplication()
        }
    }

    /// The event a click on the Dock icon sends, which SwiftUI answers by opening a window.
    nonisolated private static func sendReopenEvent() {
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try? event.sendEvent(options: [.noReply], timeout: 5)
    }

    /// Called by the window that handled `delivery`.
    func finish(_ delivery: Delivery) {
        if self.delivery?.id == delivery.id {
            self.delivery = nil
        }
    }

    /// The frontmost registered window, or any registered one when all are minimized.
    private func targetWindow() -> (UUID, NSWindow)? {
        let registered = windows.compactMap { id, reference in
            reference.window.map { (id, $0) }
        }
        windows = windows.filter { $0.value.window != nil }
        guard registered.isEmpty == false else { return nil }
        for window in orderedWindows() {
            if let match = registered.first(where: { $0.1 === window }) {
                return match
            }
        }
        return registered.min { $0.0.uuidString < $1.0.uuidString }
    }

    private func bringForward(_ window: NSWindow, origin: Origin) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        switch origin {
        case .external:
            activateApplication()
            window.makeKeyAndOrderFront(nil)
        case .writingWindow:
            let covered = keyWindow().map { $0 !== window && $0.frame.intersects(window.frame) } ?? false
            if covered || window.isVisible == false {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// Reports the window a SwiftUI view is in.
struct HostingWindowReader: NSViewRepresentable {
    var onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindowChange = onWindowChange
    }

    final class ReaderView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
