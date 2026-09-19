import AppKit
import SwiftUI

enum AppWindowBackdropRole {
    case about
    case settings
}

enum SettingsWindowMetrics {
    static let defaultWidth: CGFloat = 920
    static let defaultHeight: CGFloat = 720
    /// The Providers/Models tabs lay out a fixed 310pt list column plus a
    /// 420pt minimum detail column, so the window keeps room for that pair.
    static let minWidth: CGFloat = 840
    static let minHeight: CGFloat = 520

    static let defaultContentSize = NSSize(width: defaultWidth, height: defaultHeight)
    static let minContentSize = NSSize(width: minWidth, height: minHeight)

    /// Keeps the settings window a little away from the screen edges, so the
    /// traffic lights and the tab bar stay inside the menu bar / Dock area.
    static let screenMargin: CGFloat = 12

    /// Largest content size that still keeps the whole window inside
    /// `visibleFrame`, once the title bar chrome is accounted for.
    static func maximumContentSize(
        fitting visibleFrame: NSSize,
        chromeSize: NSSize,
        margin: CGFloat = screenMargin
    ) -> NSSize {
        NSSize(
            width: max(0, visibleFrame.width - chromeSize.width - margin * 2),
            height: max(0, visibleFrame.height - chromeSize.height - margin * 2)
        )
    }

    /// Shrinks `contentSize` only when it would not fit on the screen. This runs
    /// on small displays where the default 920x720 window is taller than the
    /// visible frame (menu bar + Dock), which used to push part of the settings
    /// content off screen.
    static func contentSizeFittedToScreen(
        _ contentSize: NSSize,
        visibleFrame: NSSize,
        chromeSize: NSSize,
        margin: CGFloat = screenMargin
    ) -> NSSize {
        let maximum = maximumContentSize(fitting: visibleFrame, chromeSize: chromeSize, margin: margin)

        return NSSize(
            width: min(contentSize.width, maximum.width),
            height: min(contentSize.height, maximum.height)
        )
    }
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
        window.styleMask.remove(.miniaturizable)
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false

        switch role {
        case .about:
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false

            let contentSize = AboutWindowMetrics.contentSize
            window.contentMinSize = contentSize
            window.contentMaxSize = contentSize

            if window.contentLayoutRect.size != contentSize {
                window.setContentSize(contentSize)
            }

        case .settings:
            // The settings tabs are scrollable, so the window can be resized down
            // to fit displays that are smaller than the default 920x720 window.
            window.styleMask.insert(.resizable)
            window.contentMinSize = SettingsWindowMetrics.minContentSize
            window.standardWindowButton(.zoomButton)?.isEnabled = true

            // Re-checked on every pass, because SwiftUI can resize the window
            // after its hosted view has already joined it. The fit is a no-op as
            // long as the window is not taller or wider than the screen.
            fitContentSizeToScreenIfNeeded(window)
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

    private func fitContentSizeToScreenIfNeeded(_ styledWindow: NSWindow) {
        let screen = styledWindow.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let contentRect = styledWindow.contentRect(forFrameRect: styledWindow.frame)
        let chromeSize = NSSize(
            width: styledWindow.frame.width - contentRect.width,
            height: styledWindow.frame.height - contentRect.height
        )
        let fittedSize = SettingsWindowMetrics.contentSizeFittedToScreen(
            contentRect.size,
            visibleFrame: visibleFrame.size,
            chromeSize: chromeSize
        )

        guard fittedSize != contentRect.size else { return }

        styledWindow.setContentSize(fittedSize)
    }
}
