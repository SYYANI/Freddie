import SwiftUI

/// Shown above the HTML reader while regions of an imported page are being edited.
struct HTMLRegionEditBar: View {
    @Environment(\.localizationBundle) private var bundle

    var hiddenRegionCount: Int
    var hiddenRegions: [HTMLHiddenRegion]
    var canUndo: Bool
    var canRedo: Bool
    var onReveal: (_ path: String) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onRestoreAll: () -> Void
    var onDone: () -> Void

    private struct KeyHint: Identifiable {
        var key: String
        var label: String

        var id: String { key }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            // As many key hints as fit; the tooltip always has the full instructions.
            ViewThatFits(in: .horizontal) {
                keyHintRow(allKeyHints)
                keyHintRow(allKeyHints.filter { $0.key != "⌘Z" })
                keyHintRow(Array(allKeyHints.prefix(2)))
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            .help(instructions)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(instructions)

            Spacer(minLength: 8)

            hiddenRegionsMenu

            ControlGroup {
                Button(action: onUndo) {
                    Label(String(localized: "Undo Region Change", bundle: bundle), systemImage: "arrow.uturn.backward")
                }
                .disabled(canUndo == false)
                .help(String(localized: "Undo Region Change", bundle: bundle))

                Button(action: onRedo) {
                    Label(String(localized: "Redo Region Change", bundle: bundle), systemImage: "arrow.uturn.forward")
                }
                .disabled(canRedo == false)
                .help(String(localized: "Redo Region Change", bundle: bundle))
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .fixedSize()

            // Fixed, so the key hints give way before the buttons truncate.
            Button(String(localized: "Restore All", bundle: bundle), action: onRestoreAll)
                .controlSize(.small)
                .disabled(hiddenRegionCount == 0)
                .fixedSize()

            Button(String(localized: "Done", bundle: bundle), action: onDone)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ReadPaperAppearanceHeaderSurface(role: .reader))
    }

    private var allKeyHints: [KeyHint] {
        [
            KeyHint(key: String(localized: "Click", bundle: bundle), label: String(localized: "Hide/Restore", bundle: bundle)),
            KeyHint(key: String(localized: "⇧ Click", bundle: bundle), label: String(localized: "Range", bundle: bundle)),
            KeyHint(key: "↑ ↓", label: String(localized: "Resize", bundle: bundle)),
            KeyHint(key: "⌘Z", label: String(localized: "Undo", bundle: bundle)),
            KeyHint(key: "Esc", label: String(localized: "Done", bundle: bundle)),
        ]
    }

    private func keyHintRow(_ hints: [KeyHint]) -> some View {
        HStack(spacing: 10) {
            ForEach(hints) { hint in
                HStack(spacing: 4) {
                    Text(verbatim: hint.key)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(verbatim: hint.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize()
    }

    /// Lists hidden regions; choosing one scrolls to it and outlines it for restoring.
    private var hiddenRegionsMenu: some View {
        Menu {
            ForEach(hiddenRegions) { region in
                Button(region.text.isEmpty ? region.kind : "\(region.kind): \(region.text)") {
                    onReveal(region.path)
                }
            }
        } label: {
            Text(AppLocalization.format("Hidden: %lld", bundle: bundle, hiddenRegionCount))
                .font(.caption.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(hiddenRegions.isEmpty)
        .help(String(localized: "Show a hidden region on the page", bundle: bundle))
    }

    private var instructions: String {
        String(
            localized: "Click a region to hide it, or a faded region to restore it. Shift-click another region to make the same change to everything in between. Press ↑ or ↓ to resize the outline and Esc to finish.",
            bundle: bundle
        )
    }
}
