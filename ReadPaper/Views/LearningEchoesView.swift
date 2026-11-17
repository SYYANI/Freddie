import SwiftData
import SwiftUI

/// The Learning tab's first view: the reader's own past highlights, notes and questions
/// that relate to what is on screen. It follows the reader as they scroll and stays quiet,
/// a faint mark with a tooltip, when nothing relates.
struct LearningEchoesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @State private var paperTitles: [UUID: String] = [:]
    @State private var showsSeen = false

    var paper: Paper?
    var model: LearningEchoModel = .shared
    var recorder: LearningRecorder = .shared
    var organizer: LearningOrganizer = .shared
    var onOpenCitation: (PaperCitation, String?) -> Void
    /// Quotes the echoed passage in the open writing. Nil where writings cannot take
    /// insertions from here.
    var onQuoteInWriting: ((LearningEvent) -> Void)? = nil

    /// The current paper's screen; echoes found for another paper are not shown.
    private var reading: LearningEchoModel.ReadingEchoes? {
        guard let paper, let reading = model.reading, reading.focus.paperID == paper.id else { return nil }
        return reading
    }

    var body: some View {
        let reading = reading
        Group {
            if paper == nil {
                Text("No Paper Selected", bundle: bundle)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let reading, reading.echoes.isEmpty == false {
                content(reading)
            } else {
                quietMark
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.25), value: reading?.echoes.map(\.id))
        .task(id: Set(reading?.echoes.map(\.event.paperID) ?? [])) {
            loadTitles(for: reading?.echoes ?? [])
        }
        .task(id: recorder.revision &* 31 &+ organizer.revision) {
            await model.refreshReading()
        }
        .onAppear {
            model.acknowledgeReadingEchoes()
        }
        .onChange(of: reading?.echoes.map(\.id)) { _, _ in
            model.acknowledgeReadingEchoes()
        }
    }

    /// Nothing relates to the screen: no heading, no paragraph, only a mark that explains
    /// itself on hover and to VoiceOver.
    private var quietMark: some View {
        let explanation = String(
            localized: "As you read, passages you highlighted, noted or asked about before appear here when they relate to what is on screen.",
            bundle: bundle
        )
        return Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(.quaternary)
            .padding(12)
            .contentShape(Rectangle())
            .help(explanation)
            .accessibilityLabel(String(localized: "Echoes", bundle: bundle))
            .accessibilityValue(explanation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ reading: LearningEchoModel.ReadingEchoes) -> some View {
        let fresh = reading.echoes.filter { model.openedSubjects.contains($0.id) == false }
        let seen = reading.echoes.filter { model.openedSubjects.contains($0.id) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fresh) { echo in
                    card(echo, paperID: reading.focus.paperID)
                        .transition(.opacity)
                }
                if seen.isEmpty == false {
                    seenPile(count: seen.count)
                    if showsSeen {
                        ForEach(seen) { echo in
                            card(echo, paperID: reading.focus.paperID)
                                .opacity(0.6)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card(_ echo: LearningEcho, paperID: UUID) -> some View {
        LearningEchoCard(echo: echo, paperTitle: paperTitle(of: echo.event, currentPaperID: paperID)) {
            Menu {
                actions(echo, paperID: paperID)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "More", bundle: bundle))
        }
        .onTapGesture {
            open(echo)
        }
        .contextMenu {
            actions(echo, paperID: paperID)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            open(echo)
        }
        .accessibilityAction(named: Text("Quote in Writing", bundle: bundle)) {
            guard let onQuoteInWriting, echo.event.quote != nil else { return }
            model.markOpened(echo)
            onQuoteInWriting(echo.event)
        }
        .accessibilityAction(named: Text("Not Related", bundle: bundle)) {
            dismiss(echo, paperID: paperID)
        }
    }

    @ViewBuilder
    private func actions(_ echo: LearningEcho, paperID: UUID) -> some View {
        Button(String(localized: "Open in Paper", bundle: bundle)) {
            open(echo)
        }
        if let onQuoteInWriting, echo.event.quote != nil {
            Button(String(localized: "Quote in Writing", bundle: bundle)) {
                model.markOpened(echo)
                onQuoteInWriting(echo.event)
            }
        }
        Divider()
        Button(String(localized: "Not Related", bundle: bundle)) {
            dismiss(echo, paperID: paperID)
        }
    }

    /// Cards already opened, stacked out of the way.
    private func seenPile(count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                showsSeen.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    ForEach(0..<min(3, count), id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75)
                            .frame(width: 16, height: 11)
                            .offset(x: CGFloat(index) * 2.5, y: CGFloat(-index) * 2.5)
                    }
                }
                .frame(width: 16 + CGFloat(min(3, count) - 1) * 2.5, height: 16, alignment: .bottomLeading)
                Text("Seen", bundle: bundle)
                Text(count, format: .number)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(showsSeen ? 90 : 0))
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(
            showsSeen
                ? String(localized: "Expanded", bundle: bundle)
                : String(localized: "Collapsed", bundle: bundle)
        )
    }

    private func open(_ echo: LearningEcho) {
        model.markOpened(echo)
        onOpenCitation(echo.event.citation, echo.event.quote)
    }

    private func dismiss(_ echo: LearningEcho, paperID: UUID) {
        Task { await model.dismiss(echo, context: LearningEchoModel.readingContext(paperID)) }
    }

    private func paperTitle(of event: LearningEvent, currentPaperID: UUID) -> String {
        if event.paperID == currentPaperID {
            return String(localized: "This Paper", bundle: bundle)
        }
        return paperTitles[event.paperID] ?? String(localized: "Deleted Paper", bundle: bundle)
    }

    private func loadTitles(for echoes: [LearningEcho]) {
        let ids = Set(echoes.map(\.event.paperID)).subtracting(paperTitles.keys)
        guard ids.isEmpty == false else { return }
        let papers = (try? modelContext.fetch(FetchDescriptor<Paper>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for paper in papers {
            paperTitles[paper.id] = paper.title
        }
    }
}

/// One past action offered as an echo: the reader's own words first, the passage under a
/// thin rule, and one quiet line saying what they did, where and when. Why it was offered
/// is in the tooltip; the accessory (actions) shows on hover.
struct LearningEchoCard<Accessory: View>: View {
    @Environment(\.localizationBundle) private var bundle
    @State private var isHovered = false

    var echo: LearningEcho
    var paperTitle: String
    var isCompact = false
    /// Extra lines of help after the reason, e.g. how to use the card.
    var help: String? = nil
    @ViewBuilder var accessory: Accessory

    private var event: LearningEvent { echo.event }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let words = event.text {
                Text(NoteMarkdownRenderer.preview(words))
                    .font(isCompact ? .callout : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(isCompact ? 2 : 4)
            }
            if let quote = event.quote {
                Text(quote)
                    .font(.callout)
                    .foregroundStyle(event.text == nil ? .primary : .secondary)
                    .lineLimit(isCompact ? (event.text == nil ? 3 : 2) : 3)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 2)
                    }
            }
            if isCompact == false, event.text == nil, let response = event.response {
                Text(NoteMarkdownRenderer.preview(response))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: event.kind.systemImage)
                    .help(event.kind.echoTitle(bundle: bundle))
                // The title gives way; where and when stay whole.
                Text(paperTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(location)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            // Over the footer rather than beside it, so hidden actions take no room from
            // the title.
            .overlay(alignment: .trailing) {
                accessory
                    .font(.caption)
                    .padding(.leading, 6)
                    .background(
                        Color.primary.opacity(isHovered ? 0.06 : 0.035)
                            .background(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    )
                    .opacity(showsAccessory ? 1 : 0)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0.035))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(reason ?? "")
    }

    private var location: String {
        var parts: [String] = []
        if let pageIndex = event.pageIndex {
            parts.append(String(format: String(localized: "p. %lld", bundle: bundle), pageIndex + 1))
        }
        parts.append(event.occurredAt.formatted(.relative(presentation: .named)))
        return "· " + parts.joined(separator: " · ")
    }

    /// Touch screens have no hover, so the actions stay visible there.
    private var showsAccessory: Bool {
        #if os(macOS)
        isHovered
        #else
        true
        #endif
    }

    private var reason: String? {
        if let concept = echo.conceptName {
            return AppLocalization.format("Concept: %@", bundle: bundle, concept)
        }
        guard echo.sharedTerms.isEmpty == false else { return nil }
        return AppLocalization.format(
            "Both mention %@",
            bundle: bundle,
            echo.sharedTerms.joined(separator: ", ")
        )
    }

    private var tooltip: String {
        [event.kind.echoTitle(bundle: bundle), reason, help].compactMap { $0 }.joined(separator: "\n")
    }

    private var accessibilityText: String {
        [event.kind.echoTitle(bundle: bundle), event.text, event.quote, paperTitle, location]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

extension LearningEvent.Kind {
    /// What the reader did, for a card's tooltip and VoiceOver.
    func echoTitle(bundle: Bundle) -> String {
        switch self {
        case .highlight: String(localized: "You highlighted", bundle: bundle)
        case .note: String(localized: "You noted", bundle: bundle)
        case .translation: String(localized: "You translated", bundle: bundle)
        case .explanation: String(localized: "You asked for an explanation", bundle: bundle)
        case .question: String(localized: "You asked", bundle: bundle)
        case .citation: String(localized: "You quoted", bundle: bundle)
        }
    }
}
