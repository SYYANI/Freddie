import AppKit
import SwiftUI

struct DocumentFindBar: View {
    @Environment(\.localizationBundle) private var bundle

    @Binding var query: String
    @Binding var options: DocumentSearchOptions
    /// Present only in the side-by-side PDF reader.
    var bilingualTarget: Binding<DualPDFSelectionSource>?
    var status: DocumentFindStatus?
    var focusToken: Int
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    @FocusState private var isQueryFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let bilingualTarget {
                Picker(String(localized: "Search In", bundle: bundle), selection: bilingualTarget) {
                    Text("Original", bundle: bundle).tag(DualPDFSelectionSource.original)
                    Text("Translation", bundle: bundle).tag(DualPDFSelectionSource.translated)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            queryField
                .frame(maxWidth: 420)

            ControlGroup {
                Button(action: onPrevious) {
                    Label(String(localized: "Previous Match", bundle: bundle), systemImage: "chevron.up")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help(String(localized: "Previous Match", bundle: bundle))

                Button(action: onNext) {
                    Label(String(localized: "Next Match", bundle: bundle), systemImage: "chevron.down")
                }
                .keyboardShortcut("g", modifiers: .command)
                .help(String(localized: "Next Match", bundle: bundle))
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .fixedSize()
            .disabled(query.isEmpty)

            HStack(spacing: 4) {
                optionToggle(
                    String(localized: "Match Case", bundle: bundle),
                    isOn: $options.matchCase
                ) {
                    Text(verbatim: "Aa")
                }
                optionToggle(
                    String(localized: "Whole Words", bundle: bundle),
                    isOn: $options.wholeWords
                ) {
                    Text(verbatim: "ab").underline()
                }
            }
            .fixedSize()

            Spacer(minLength: 0)

            Button(String(localized: "Done", bundle: bundle), action: onClose)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ReadPaperAppearanceHeaderSurface(role: .reader))
        .onAppear {
            isQueryFocused = true
        }
        .onChange(of: focusToken) { _, _ in
            isQueryFocused = true
        }
    }

    private func optionToggle(
        _ title: String,
        isOn: Binding<Bool>,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Toggle(isOn: isOn) {
            label()
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 18)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }

    private var queryField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(String(localized: "Find in Document", bundle: bundle), text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($isQueryFocused)
                .onSubmit(onNext)
                .onExitCommand(perform: onClose)

            statusView

            if query.isEmpty == false {
                Button {
                    query = ""
                    isQueryFocused = true
                } label: {
                    Label(String(localized: "Clear Search", bundle: bundle), systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(String(localized: "Clear Search", bundle: bundle))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(isQueryFocused ? 0.22 : 0.1))
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let status {
            if status.isSearching {
                ProgressView()
                    .controlSize(.mini)
            } else if status.matchCount == 0 {
                Text("No Matches", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Text(verbatim: "\((status.currentIndex ?? -1) + 1)/\(status.matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}
