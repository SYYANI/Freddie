import SwiftUI

/// Glass capsule segmented control whose selected segment is filled with the accent color.
///
/// On macOS 26 a segmented `Picker` in the toolbar always draws its selected segment gray
/// (`.tint` sets `selectedSegmentBezelColor`, but the toolbar ignores it), so the reader and
/// Inspector pickers draw their segments themselves. Like a native control, the selection
/// turns gray while the window is inactive.
///
/// In the toolbar, put it in `segmentedPickerToolbarItem`: the system's shared glass merges
/// adjacent custom items into one capsule, so the item hides it and the picker draws its own.
struct ReadPaperSegmentedPicker<Value: Hashable>: View {
    enum Placement {
        /// As tall as the other toolbar items' glass.
        case toolbar
        case content
    }

    struct Option {
        let value: Value
        let title: String
    }

    let label: String
    @Binding var selection: Value
    let options: [Option]
    var placement: Placement = .content
    /// False when the picker sits inside a capsule drawn by its container.
    var drawsCapsule = true

    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    @ViewBuilder
    var body: some View {
        if drawsCapsule {
            segments
                .padding(placement == .toolbar ? Self.toolbarInset : 3)
                .readPaperGlassEffect(in: Capsule())
        } else {
            segments
        }
    }

    #if os(iOS)
    /// iPadOS 26 toolbar glass is 44 pt tall: the inset plus `toolbarSegmentHeight`.
    static var toolbarInset: CGFloat { 4 }
    static var toolbarSegmentHeight: CGFloat { 36 }
    #else
    static var toolbarInset: CGFloat { 3.5 }
    #endif

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var isWindowActive: Bool {
        #if os(macOS)
        controlActiveState != .inactive
        #else
        true
        #endif
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = selection == option.value
        let isAccented = isSelected && isWindowActive
        return Button {
            selection = option.value
        } label: {
            segmentTitle(option.title)
                .foregroundStyle(foregroundStyle(isAccented: isAccented))
                .background {
                    if isSelected {
                        Capsule().fill(isAccented ? Color.accentColor : Color.primary.opacity(0.1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func segmentTitle(_ title: String) -> some View {
        #if os(iOS)
        if placement == .toolbar {
            Text(title)
                .font(.system(size: 15))
                .padding(.horizontal, 16)
                .frame(height: Self.toolbarSegmentHeight)
        } else {
            standardTitle(title)
        }
        #else
        standardTitle(title)
        #endif
    }

    private func standardTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, placement == .toolbar ? 6 : 5)
    }

    private func foregroundStyle(isAccented: Bool) -> AnyShapeStyle {
        if isAccented {
            return AnyShapeStyle(Color.white)
        }
        return isWindowActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

/// A primary-action toolbar item for `ReadPaperSegmentedPicker` that keeps its own capsule.
@ToolbarContentBuilder
func segmentedPickerToolbarItem<Content: View>(@ViewBuilder content: () -> Content) -> some ToolbarContent {
    if #available(macOS 26.0, iOS 26.0, *) {
        let content = content()
        ToolbarItem(placement: .primaryAction) {
            content.modifier(SegmentedPickerToolbarItemSpacing())
        }
        .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: .primaryAction, content: content)
    }
}

/// macOS 27 no longer leaves a gap around toolbar items whose shared glass is hidden, so
/// adjacent pickers' capsules touch. Pad them back to the spacing macOS 26 gives.
private struct SegmentedPickerToolbarItemSpacing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 27.0, *) {
            content.padding(.horizontal, 4)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
