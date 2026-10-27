import SwiftData
import SwiftUI

/// Touch text input used by the shared inspector's note rows.
struct InsetTextView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Binding var text: String
    var shouldFocus: Bool
    var onFocusApplied: () -> Void
    var onEditingBegan: () -> Void = {}
    var onEditingEnded: () -> Void = {}
    var usesPaperTypography = false
    @FocusState private var isFocused: Bool
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.system(.body, design: usesPaperTypography ? .serif : .default))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 120)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { applyFocus() }
        .onChange(of: shouldFocus) { _, _ in applyFocus() }
        .onChange(of: isFocused) { _, focused in
            if focused { onEditingBegan() } else {
                save()
                onEditingEnded()
            }
        }
        // Saved when editing ends, not while typing: each save refetches every
        // @Query and redraws the whole window.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
        .onDisappear { save() }
    }

    private func applyFocus() {
        guard shouldFocus else { return }
        isFocused = true
        onFocusApplied()
    }

    private func save() {
        do {
            if modelContext.hasChanges { try modelContext.save() }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
