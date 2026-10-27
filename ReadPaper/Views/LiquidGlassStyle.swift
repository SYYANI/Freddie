import SwiftUI

extension View {
    /// Uses the native Liquid Glass button artwork when it is available.
    @ViewBuilder
    func readPaperGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
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

    private var fieldBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private var borderColor: Color {
        #if os(macOS)
        isFocused ? Color(nsColor: .keyboardFocusIndicatorColor) : Color(nsColor: .separatorColor)
        #else
        isFocused ? Color.accentColor : Color(uiColor: .separator)
        #endif
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fieldBackground.opacity(0.55))
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        borderColor,
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
        } else if #available(macOS 26.0, iOS 26.0, *) {
            content
        } else {
            #if os(macOS)
            content.background(Color(nsColor: .windowBackgroundColor))
            #else
            content.background(.regularMaterial)
            #endif
        }
    }
}
