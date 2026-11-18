import SwiftUI

/// The inspector's Learning tab: echoes, the reader's past highlights, notes and questions
/// that relate to what is on screen. The organized records and the event log behind them
/// are not shown as lists; they surface only as echoes, the concept chips over a selection
/// and the open-question notice.
struct LearningPaneView: View {
    @Environment(\.modelContext) private var modelContext

    var paper: Paper?
    var notes: [Note]
    var recorder: LearningRecorder = .shared
    var organizer: LearningOrganizer = .shared
    var onOpenCitation: (PaperCitation, String?) -> Void
    /// Starts a paragraph about a concept (name, where it came from, the passage) in the
    /// open writing.
    var onWriteAboutConcept: ((String, PaperCitation, String?) -> Void)? = nil
    /// Quotes an echoed passage in the open writing.
    var onQuoteEchoInWriting: ((LearningEvent) -> Void)? = nil

    private struct LoadRequest: Equatable {
        var paperID: UUID?
        var revision: Int
    }

    var body: some View {
        LearningEchoesView(
            paper: paper,
            recorder: recorder,
            organizer: organizer,
            onOpenCitation: onOpenCitation,
            onQuoteInWriting: onQuoteEchoInWriting,
            onWriteAboutConcept: onWriteAboutConcept
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: LoadRequest(paperID: paper?.id, revision: recorder.revision)) {
            await collect()
        }
    }

    /// Collects what was done since the paper was opened, so echoes are current, then lets
    /// the organizer catch up. A collection that appends bumps `recorder.revision` and
    /// restarts this task.
    private func collect() async {
        guard let paper else { return }
        let values = notes.filter { $0.paperID == paper.id }.map(LearningEventSources.NoteValue.init)
        await recorder.collect(paperID: paper.id, notes: values)
        guard Task.isCancelled == false else { return }
        let context = LearningOrganizer.PaperContext(id: paper.id, title: paper.title, abstract: paper.abstractText)
        Task { await organizer.organize(context, trigger: .automatic, modelContext: modelContext) }
    }
}

extension LearningEvent.Kind {
    var systemImage: String {
        switch self {
        case .highlight: "highlighter"
        case .note: "note.text"
        case .translation: "translate"
        case .explanation: "lightbulb"
        case .question: "questionmark.bubble"
        case .citation: "quote.opening"
        }
    }
}
