import SwiftUI

/// Shown above the HTML reader while regions of an imported page are being edited.
struct HTMLRegionEditBar: View {
    @Environment(\.localizationBundle) private var bundle

    var hiddenRegionCount: Int
    var canUndo: Bool
    var canRedo: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onRestoreAll: () -> Void
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(instructions)

            Spacer(minLength: 8)

            Text(AppLocalization.format("Hidden: %lld", bundle: bundle, hiddenRegionCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

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

            Button(String(localized: "Restore All", bundle: bundle), action: onRestoreAll)
                .controlSize(.small)
                .disabled(hiddenRegionCount == 0)

            Button(String(localized: "Done", bundle: bundle), action: onDone)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ReadPaperAppearanceHeaderSurface(role: .reader))
    }

    private var instructions: String {
        String(
            localized: "Click a region to hide it, or a faded region to restore it. Press ↑ or ↓ to resize the outline and Esc to finish.",
            bundle: bundle
        )
    }
}
