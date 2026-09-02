import AppKit
import SwiftUI

enum AppWindowBackdropRole {
    case about
    case settings
}

struct AppWindowBackdrop: NSViewRepresentable {
    let role: AppWindowBackdropRole

    func makeNSView(context: Context) -> AppWindowConfigurationProbe {
        AppWindowConfigurationProbe(role: role)
    }

    func updateNSView(_ nsView: AppWindowConfigurationProbe, context: Context) {
        nsView.role = role
        nsView.applyWindowAppearanceIfNeeded()
    }
}

final class AppWindowConfigurationProbe: NSView {
    private static let containerViewIdentifier = NSUserInterfaceItemIdentifier(
        "com.yiyan.ReadPaper.window-material-container"
    )

    var role: AppWindowBackdropRole

    private weak var configuredWindow: NSWindow?
    private var didConfigureWindow = false
    private var didCenterConfiguredWindow = false

    init(role: AppWindowBackdropRole) {
        self.role = role
        super.init(frame: .zero)
        if case .settings = role {
            installMaterialLayer()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        guard let newWindow else { return }
        if configuredWindow !== newWindow {
            configuredWindow = newWindow
            didConfigureWindow = false
            didCenterConfiguredWindow = false
        }

        applyWindowAppearance(to: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window, configuredWindow !== window {
            configuredWindow = window
            didConfigureWindow = false
            didCenterConfiguredWindow = false
        }

        applyWindowAppearanceIfNeeded()

        // SwiftUI can update a Window scene's style mask and sizing constraints
        // after its hosted view has joined the window, notably on macOS 15.
        // Reapply the AppKit constraints on the next run-loop turn so the About
        // window does not become freely resizable due to that ordering.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.applyWindowAppearance(to: window)
        }
    }

    func applyWindowAppearanceIfNeeded() {
        guard let window = window ?? configuredWindow else { return }
        applyWindowAppearance(to: window)
    }

    private func applyWindowAppearance(to window: NSWindow) {
        if didConfigureWindow == false {
            didConfigureWindow = true

            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert([.titled, .closable, .fullSizeContentView])
            window.isMovableByWindowBackground = false
            window.toolbar?.showsBaselineSeparator = false

            if case .about = role {
                installWindowMaterialIfNeeded(in: window)
            }
        }

        // Keep these constraints outside the one-time appearance setup. SwiftUI
        // may restore `.resizable` while reconciling a Window scene on macOS 15.
        window.styleMask.remove([.miniaturizable, .resizable])
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        if case .about = role {
            let contentSize = AboutWindowMetrics.contentSize
            window.contentMinSize = contentSize
            window.contentMaxSize = contentSize

            if window.contentLayoutRect.size != contentSize {
                window.setContentSize(contentSize)
            }
        }

        centerWindowIfNeeded(window)
    }

    private func installWindowMaterialIfNeeded(in window: NSWindow) {
        guard let originalContentView = window.contentView,
              originalContentView.identifier != Self.containerViewIdentifier else {
            return
        }

        if #available(macOS 26.0, *) {
            let glassEffectView = NSGlassEffectView(frame: originalContentView.frame)
            glassEffectView.style = .regular
            glassEffectView.tintColor = .clear
            glassEffectView.identifier = Self.containerViewIdentifier
            glassEffectView.autoresizingMask = [.width, .height]

            originalContentView.frame = glassEffectView.bounds
            originalContentView.autoresizingMask = [.width, .height]
            glassEffectView.contentView = originalContentView
            window.contentView = glassEffectView
            return
        }

        let containerView = NSView(frame: originalContentView.frame)
        containerView.identifier = Self.containerViewIdentifier
        containerView.autoresizingMask = [.width, .height]

        let visualEffectView = NSVisualEffectView(frame: containerView.bounds)
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .underWindowBackground
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]

        originalContentView.frame = containerView.bounds
        originalContentView.autoresizingMask = [.width, .height]
        containerView.addSubview(visualEffectView)
        containerView.addSubview(originalContentView)
        window.contentView = containerView
    }

    private func installMaterialLayer() {
        let materialView: NSView
        if #available(macOS 26.0, *) {
            let glassEffectView = NSGlassEffectView(frame: bounds)
            glassEffectView.style = .regular
            glassEffectView.tintColor = .clear
            materialView = glassEffectView
        } else {
            let visualEffectView = NSVisualEffectView(frame: bounds)
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.material = .underWindowBackground
            visualEffectView.state = .active
            materialView = visualEffectView
        }

        materialView.frame = bounds
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView)
    }

    private func centerWindowIfNeeded(_ styledWindow: NSWindow) {
        guard didCenterConfiguredWindow == false else { return }

        let anchorWindow = NSApp.windows.first { candidate in
            candidate !== styledWindow
                && candidate.isVisible
                && (candidate.isMainWindow || candidate.isKeyWindow)
        } ?? NSApp.orderedWindows.first { candidate in
            candidate !== styledWindow && candidate.isVisible
        }

        let targetScreen = anchorWindow?.screen ?? styledWindow.screen ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? styledWindow.frame
        var frame = styledWindow.frame

        if let anchorFrame = anchorWindow?.frame {
            frame.origin.x = anchorFrame.midX - (frame.width / 2)
            frame.origin.y = anchorFrame.midY - (frame.height / 2)
        } else {
            frame.origin.x = visibleFrame.midX - (frame.width / 2)
            frame.origin.y = visibleFrame.midY - (frame.height / 2)
        }

        let maxOriginX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        let maxOriginY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), maxOriginX)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), maxOriginY)

        styledWindow.setFrame(frame, display: false)
        didCenterConfiguredWindow = true
    }
}
