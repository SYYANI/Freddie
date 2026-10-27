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

    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    var body: some View {
        segments
            .padding(placement == .toolbar ? 3.5 : 3)
            .readPaperGlassEffect(in: Capsule())
    }

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
            Text(option.title)
                .font(.system(size: 13))
                .foregroundStyle(foregroundStyle(isAccented: isAccented))
                .padding(.horizontal, 14)
                .padding(.vertical, placement == .toolbar ? 6 : 5)
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
        ToolbarItem(placement: .primaryAction, content: content)
            .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: .primaryAction, content: content)
    }
}
