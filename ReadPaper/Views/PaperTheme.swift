import AppKit
import SwiftUI

enum ReadPaperSurfaceRole {
    case library
    case reader
    case inspector
}

/// Observes the system appearance independently from any light appearance
/// applied to an individual Freddie window.
@MainActor
final class SystemAppearanceMonitor: ObservableObject {
    @Published private(set) var readerAppearance: PDFDisplayAppearance

    private var appearanceObservation: NSKeyValueObservation?

    init(application: NSApplication = .shared) {
        readerAppearance = Self.readerAppearance(for: application.effectiveAppearance)
        appearanceObservation = application.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] application, _ in
            MainActor.assumeIsolated {
                let readerAppearance = Self.readerAppearance(for: application.effectiveAppearance)
                self?.readerAppearance = readerAppearance
            }
        }
    }

    static func readerAppearance(for appearance: NSAppearance) -> PDFDisplayAppearance {
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return .synchronized(isSystemDarkMode: isDarkMode)
    }
}

enum ReadPaperTheme {
    static func surfaceColor(_ role: ReadPaperSurfaceRole, scheme _: ColorScheme) -> Color {
        switch role {
        case .library:
            Color(red: 0.918, green: 0.910, blue: 0.884)
        case .reader:
            Color(red: 0.965, green: 0.949, blue: 0.906)
        case .inspector:
            Color(red: 0.944, green: 0.931, blue: 0.895)
        }
    }

    static var accentColor: Color {
        Color(nsColor: .controlAccentColor)
    }

    static func cardColor(scheme _: ColorScheme) -> Color {
        Color(red: 0.982, green: 0.971, blue: 0.941)
    }

    static func cardBorderColor(scheme _: ColorScheme) -> Color {
        Color(red: 0.333, green: 0.294, blue: 0.231).opacity(0.11)
    }

    static func grainColor(scheme _: ColorScheme) -> Color {
        .black.opacity(0.026)
    }

    static func fiberColor(scheme _: ColorScheme) -> Color {
        Color(red: 0.42, green: 0.36, blue: 0.26).opacity(0.035)
    }
}

enum PaperTextureMetrics {
    static func dotCount(for size: CGSize) -> Int {
        let area = max(1, size.width * size.height)
        return min(720, max(90, Int(area / 2_000)))
    }

    static func fiberCount(for height: CGFloat) -> Int {
        min(24, max(8, Int(height / 70)))
    }

    static func unit(_ value: Int, modulus: Int) -> CGFloat {
        CGFloat(abs(value % modulus)) / CGFloat(modulus)
    }
}

struct ReadPaperSurface: View {
    var role: ReadPaperSurfaceRole
    var textureOpacity = 1.0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ReadPaperTheme.surfaceColor(role, scheme: colorScheme)
            ReadPaperTextureOverlay(role: role, textureOpacity: textureOpacity)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ReadPaperAppearanceSurface: View {
    var role: ReadPaperSurfaceRole
    var textureOpacity = 1.0

    @Environment(\.pdfDisplayAppearance) private var displayAppearance

    @ViewBuilder
    var body: some View {
        if displayAppearance == .paper {
            ReadPaperSurface(role: role, textureOpacity: textureOpacity)
        } else {
            Color.clear
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

struct ReadPaperTextureOverlay: View {
    var role: ReadPaperSurfaceRole
    var textureOpacity = 1.0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .white.opacity(role == .reader ? 0.22 : 0.14),
                    .clear,
                    Color(red: 0.64, green: 0.34, blue: 0.24).opacity(0.018)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ReadPaperGrain(opacity: textureOpacity)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ReadPaperHeaderSurface: View {
    var role: ReadPaperSurfaceRole

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            ReadPaperTheme.surfaceColor(role, scheme: colorScheme)
                .opacity(0.86)
            ReadPaperGrain(opacity: 0.42)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ReadPaperAppearanceHeaderSurface: View {
    var role: ReadPaperSurfaceRole

    @Environment(\.pdfDisplayAppearance) private var displayAppearance

    @ViewBuilder
    var body: some View {
        if displayAppearance == .paper {
            ReadPaperHeaderSurface(role: role)
        } else {
            Color.clear
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

private struct ReadPaperGrain: View {
    var opacity: Double

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let grain = ReadPaperTheme.grainColor(scheme: colorScheme)
            let fiber = ReadPaperTheme.fiberColor(scheme: colorScheme)

            for index in 0..<PaperTextureMetrics.dotCount(for: size) {
                let x = PaperTextureMetrics.unit(index &* 83 &+ 17, modulus: 997) * size.width
                let y = PaperTextureMetrics.unit(index &* 191 &+ 43, modulus: 991) * size.height
                let diameter = 0.38 + PaperTextureMetrics.unit(index &* 47 &+ 11, modulus: 89) * 0.72
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                    with: .color(grain)
                )
            }

            for index in 0..<PaperTextureMetrics.fiberCount(for: size.height) {
                let y = PaperTextureMetrics.unit(index &* 127 &+ 31, modulus: 983) * size.height
                let length = 24 + PaperTextureMetrics.unit(index &* 53 &+ 7, modulus: 97) * 72
                let x = PaperTextureMetrics.unit(index &* 211 &+ 13, modulus: 977) * max(1, size.width - length)
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addCurve(
                    to: CGPoint(x: x + length, y: y + 0.5),
                    control1: CGPoint(x: x + length * 0.32, y: y - 0.7),
                    control2: CGPoint(x: x + length * 0.68, y: y + 0.9)
                )
                context.stroke(path, with: .color(fiber), lineWidth: 0.42)
            }
        }
        .opacity(opacity)
    }
}

/// Gives the reader column its own native panel material, parallel to the
/// system-owned sidebar and inspector materials on macOS 26.
struct ReadPaperReaderMaterialSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            configureGlass(view)
            return view
        }

        let view = NSVisualEffectView()
        configureLegacyMaterial(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let view = nsView as? NSGlassEffectView {
            configureGlass(view)
        } else if let view = nsView as? NSVisualEffectView {
            configureLegacyMaterial(view)
        }
    }

    @available(macOS 26.0, *)
    private func configureGlass(_ view: NSGlassEffectView) {
        view.style = .regular
        if #available(macOS 27.0, *) {
            // macOS 27 applies the user's system-wide Liquid Glass tint to
            // custom glass views. Adding our macOS 26 compensation tint here
            // makes the reader canvas look opaque, so let AppKit provide the
            // native material without an additional app-owned tint.
            view.tintColor = nil
        } else {
            // System-owned sidebars and inspectors receive extra container
            // tinting on macOS 26 that a standalone public glass view does not.
            // Add a restrained, appearance-adaptive tint so the reader keeps
            // its translucency while matching the surrounding panels.
            view.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78)
        }
    }

    private func configureLegacyMaterial(_ view: NSVisualEffectView) {
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
    }
}

struct ReadPaperWindowChrome: NSViewRepresentable {
    var colorScheme: ColorScheme
    var isPaperEnabled: Bool

    func makeNSView(context: Context) -> PaperWindowChromeView {
        PaperWindowChromeView(
            colorScheme: colorScheme,
            isPaperEnabled: isPaperEnabled
        )
    }

    func updateNSView(_ nsView: PaperWindowChromeView, context: Context) {
        nsView.apply(
            colorScheme: colorScheme,
            isPaperEnabled: isPaperEnabled
        )
    }

    static func dismantleNSView(_ nsView: PaperWindowChromeView, coordinator: Void) {
        nsView.restoreWindowChrome()
    }
}

final class PaperWindowChromeView: NSView {
    private struct OriginalWindowChrome {
        var styleMask: NSWindow.StyleMask
        var titlebarAppearsTransparent: Bool
        var titlebarSeparatorStyle: NSTitlebarSeparatorStyle
        var backgroundColor: NSColor
        var isOpaque: Bool
    }

    private var colorScheme: ColorScheme
    private var isPaperEnabled: Bool
    private weak var configuredWindow: NSWindow?
    private var originalWindowChrome: OriginalWindowChrome?

    init(colorScheme: ColorScheme, isPaperEnabled: Bool) {
        self.colorScheme = colorScheme
        self.isPaperEnabled = isPaperEnabled
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowChrome()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            restoreWindowChrome()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func apply(colorScheme: ColorScheme, isPaperEnabled: Bool) {
        self.colorScheme = colorScheme
        self.isPaperEnabled = isPaperEnabled
        updateWindowChrome()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func updateWindowChrome() {
        guard let window else { return }

        if configuredWindow !== window || originalWindowChrome == nil {
            restoreWindowChrome()
            configuredWindow = window
            originalWindowChrome = OriginalWindowChrome(
                styleMask: window.styleMask,
                titlebarAppearsTransparent: window.titlebarAppearsTransparent,
                titlebarSeparatorStyle: window.titlebarSeparatorStyle,
                backgroundColor: window.backgroundColor,
                isOpaque: window.isOpaque
            )
        }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        if isPaperEnabled {
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(
                ReadPaperTheme.surfaceColor(.reader, scheme: colorScheme)
            )
            window.isOpaque = true
        } else {
            // The full-size transparent titlebar does not reliably render the
            // AppKit separator. ReaderPaneView draws the boundary explicitly.
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = .clear
            window.isOpaque = false
        }
    }

    func restoreWindowChrome() {
        guard let window = configuredWindow,
              let originalWindowChrome
        else { return }

        window.styleMask = originalWindowChrome.styleMask
        window.titlebarAppearsTransparent = originalWindowChrome.titlebarAppearsTransparent
        window.titlebarSeparatorStyle = originalWindowChrome.titlebarSeparatorStyle
        window.backgroundColor = originalWindowChrome.backgroundColor
        window.isOpaque = originalWindowChrome.isOpaque
        configuredWindow = nil
        self.originalWindowChrome = nil
    }
}
