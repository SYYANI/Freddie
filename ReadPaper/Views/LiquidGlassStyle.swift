import SwiftUI

/// Hover for a tooltip, or activate to keep the explanation open, including on touch devices.
struct ReadPaperInfoButton: View {
    @Environment(\.localizationBundle) private var bundle
    @State private var isPresented = false

    let title: String
    let message: String

    init(_ title: String, message: String) {
        self.title = title
        self.message = message
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                #if os(macOS)
                .frame(width: 20, height: 20)
                #else
                .frame(width: 44, height: 44)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(message)
        .accessibilityLabel(AppLocalization.format("About %@", bundle: bundle, title))
        .popover(isPresented: $isPresented) {
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .padding(16)
                .frame(idealWidth: 300, maxWidth: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A row label with its info button, for `LabeledContent` and section headers. Keeping the
/// button out of the control's own label leaves it reachable by VoiceOver and next to the text.
struct ReadPaperInfoLabel: View {
    let title: String
    let message: String

    init(_ title: String, message: String) {
        self.title = title
        self.message = message
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            ReadPaperInfoButton(title, message: message)
        }
    }
}

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
