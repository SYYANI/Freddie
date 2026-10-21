import SwiftUI

/// Keeps custom control chrome native on macOS 26 while preserving the app's
/// existing material treatment on older releases.
struct ReadPaperGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    /// Use for compact UI that floats over document content, such as PDF labels.
    @ViewBuilder
    func readPaperGlassEffect<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// Uses the native Liquid Glass button artwork when it is available.
    @ViewBuilder
    func readPaperGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    func readPaperInspectorBackground() -> some View {
        modifier(ReadPaperInspectorBackgroundModifier())
    }

    /// The well behind the app's own text fields (Settings, the find bar): a soft
    /// translucent fill with a hairline edge, instead of the system's opaque white
    /// field that stands out against translucent surfaces.
    func readPaperFieldWell(isFocused: Bool = false) -> some View {
        modifier(ReadPaperFieldWell(isFocused: isFocused))
    }
}

private struct ReadPaperFieldWell: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color(nsColor: .keyboardFocusIndicatorColor) : Color(nsColor: .separatorColor),
                        lineWidth: isFocused ? 2 : 0.5
                    )
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

private struct ReadPaperInspectorBackgroundModifier: ViewModifier {
    @Environment(\.pdfDisplayAppearance) private var displayAppearance

    private var isPaperAppearance: Bool {
        displayAppearance == .paper
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPaperAppearance {
            content.background {
                ReadPaperSurface(role: .inspector, textureOpacity: 0.62)
                    .ignoresSafeArea()
            }
        } else if #available(macOS 26.0, *) {
            content
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
