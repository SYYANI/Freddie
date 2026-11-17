import SwiftData
import SwiftUI

/// Below the writing editor: passages the reader marked or asked about before that relate
/// to the paragraph being written. Nothing is shown when nothing relates. A card can be
/// dragged into the writing or inserted after the caret's paragraph, quoted with its
/// citation.
struct WritingEchoStrip: View {
    static let collapsedKey = "ReadPaper.Writing.EchoesCollapsed"
    static let cardWidth: CGFloat = 232
    static let cardHeight: CGFloat = 136

    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @AppStorage(Self.collapsedKey) private var isCollapsed = false
    @State private var papers: [UUID: Paper] = [:]
    @State private var errorMessage: String?

    var writingID: UUID
    var center: WritingDocumentCenter
    var model: LearningEchoModel = .shared
    var onOpenCitation: (PaperCitation, String?) -> Void

    private var echoes: [LearningEcho] {
        guard let writing = model.writing, writing.writingID == writingID else { return [] }
        return writing.echoes
    }

    var body: some View {
        let echoes = echoes
        VStack(spacing: 0) {
            if echoes.isEmpty == false {
                Divider()
                header(count: echoes.count)
                if isCollapsed == false {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(echoes) { echo in
                                card(echo)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: echoes.map(\.id))
        .animation(.easeOut(duration: 0.2), value: isCollapsed)
        .task(id: Set(echoes.map(\.event.paperID))) {
            loadPapers(for: echoes)
        }
        .alert(
            String(localized: "Unable to Update Writing", bundle: bundle),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if $0 == false { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func header(count: Int) -> some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("Echoes", bundle: bundle)
                // Collapsed, the count says there is something to open again.
                if isCollapsed {
                    Text(count, format: .number)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(
            isCollapsed
                ? String(localized: "Collapsed", bundle: bundle)
                : String(localized: "Expanded", bundle: bundle)
        )
    }

    private func card(_ echo: LearningEcho) -> some View {
        LearningEchoCard(
            echo: echo,
            paperTitle: papers[echo.event.paperID]?.title ?? String(localized: "Deleted Paper", bundle: bundle),
            isCompact: true,
            help: String(localized: "Drag a card into the writing to quote it", bundle: bundle)
        ) {
            HStack(spacing: 0) {
                if echo.event.quote != nil {
                    cardButton(String(localized: "Insert in Writing", bundle: bundle), systemImage: "text.insert") {
                        insert(echo)
                    }
                }
                cardButton(String(localized: "Open in Paper", bundle: bundle), systemImage: "arrow.up.forward.square") {
                    open(echo)
                }
            }
        }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .draggable(markdown(for: echo.event))
            .accessibilityAction(named: Text("Insert in Writing", bundle: bundle)) { insert(echo) }
            .accessibilityAction(named: Text("Open in Paper", bundle: bundle)) { open(echo) }
            .contextMenu {
                if echo.event.quote != nil {
                    Button(String(localized: "Insert in Writing", bundle: bundle)) { insert(echo) }
                }
                Button(String(localized: "Open in Paper", bundle: bundle)) { open(echo) }
                Divider()
                Button(String(localized: "Not Related", bundle: bundle)) {
                    Task { await model.dismiss(echo, context: LearningEchoModel.writingContext(writingID)) }
                }
            }
    }

    private func cardButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }

    private func label(for event: LearningEvent) -> String? {
        guard let paper = papers[event.paperID] else { return nil }
        return PaperCitation.label(
            authors: paper.authors,
            title: paper.title,
            year: paper.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
            pageIndex: event.pageIndex
        )
    }

    /// What a dropped card becomes: the quote with its citation, as "Quote in Writing"
    /// inserts it, or just the quote when the paper is gone.
    private func markdown(for event: LearningEvent) -> String {
        let quote = event.quote ?? event.text ?? ""
        guard let label = label(for: event) else {
            return quote.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        }
        return PaperCitation.quoteMarkdown(quote: quote, label: label, citation: event.citation)
    }

    private func insert(_ echo: LearningEcho) {
        guard let label = label(for: echo.event) else {
            errorMessage = String(localized: "The cited paper is no longer in your library.", bundle: bundle)
            return
        }
        do {
            _ = try center.insertCitation(echo.event.citation, label: label, quote: echo.event.quote)
            model.markOpened(echo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ echo: LearningEcho) {
        model.markOpened(echo)
        onOpenCitation(echo.event.citation, echo.event.quote)
    }

    private func loadPapers(for echoes: [LearningEcho]) {
        let ids = Set(echoes.map(\.event.paperID)).subtracting(papers.keys)
        guard ids.isEmpty == false else { return }
        let fetched = (try? modelContext.fetch(FetchDescriptor<Paper>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for paper in fetched {
            papers[paper.id] = paper
        }
    }
}
