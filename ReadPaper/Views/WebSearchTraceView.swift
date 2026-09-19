import AppKit
import Observation
import SwiftUI

/// One redacted entry of a server-side web search trace.
///
/// The entry carries its own identity so a lazily realized row never has to
/// index back into the mutable entry array.
struct WebSearchTraceEntry: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Accumulates the redacted trace of a server-side web search test.
///
/// A complete trace grows to thousands of streamed SSE entries. Keeping the
/// entries in an observable reference type means appending a batch only
/// invalidates the trace panel instead of the whole settings form, and the
/// panel renders entries lazily so a growing trace never has to be laid out as
/// one large text block.
@MainActor
@Observable
final class WebSearchTraceStore {
    private(set) var entries: [WebSearchTraceEntry] = []
    private var nextEntryID = 0

    var isEmpty: Bool {
        entries.isEmpty
    }

    var fullText: String {
        entries.map(\.text).joined(separator: "\n\n")
    }

    func reset() {
        guard entries.isEmpty == false else { return }
        entries.removeAll()
    }

    func append(_ appendedEntries: [String]) {
        guard appendedEntries.isEmpty == false else { return }
        for appendedEntry in appendedEntries {
            entries.append(WebSearchTraceEntry(id: nextEntryID, text: appendedEntry))
            nextEntryID += 1
        }
    }
}

/// Shows the complete web search trace inside the provider settings panel.
struct WebSearchTracePanel: View {
    @Environment(\.localizationBundle) private var bundle

    let store: WebSearchTraceStore
    @Binding var isExpanded: Bool

    var body: some View {
        if store.isEmpty == false {
            DisclosureGroup(
                String(localized: "Complete Web Search Trace", bundle: bundle),
                isExpanded: $isExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(store.entries) { entry in
                                Text(entry.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 280)

                    Button(String(localized: "Copy Trace", bundle: bundle)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.fullText, forType: .string)
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}
