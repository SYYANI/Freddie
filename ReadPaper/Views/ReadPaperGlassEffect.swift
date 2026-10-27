import SwiftUI

/// Keeps custom control chrome native on macOS and iPadOS 26 while preserving the app's
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
        if #available(macOS 26.0, iOS 26.0, *) {
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
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
