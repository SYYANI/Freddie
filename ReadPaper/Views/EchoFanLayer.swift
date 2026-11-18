import SwiftData
import SwiftUI

/// Shows the echoes of a marked paragraph next to its mark in the reader, as a popover:
/// the card being read on top, and when the paragraph has several, the others fanned out
/// below like a hand of cards. Only this layer observes `LearningEchoModel.fan`.
struct EchoFanLayer: View {
    var model: LearningEchoModel = .shared
    var currentPaperID: UUID?
    var onOpenCitation: (PaperCitation, String?) -> Void
    /// Reports a passage quoted in the open writing, with the writing's title.
    var onQuoted: (String) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            if let fan = model.fan, fan.paperID == currentPaperID {
                Color.clear
                    .frame(width: max(fan.rect.width, 1), height: max(fan.rect.height, 1))
                    .offset(x: fan.rect.minX, y: fan.rect.minY)
                    // Only an anchor: clicks reach the reader underneath.
                    .allowsHitTesting(false)
                    .popover(
                        isPresented: Binding(
                            get: { model.fan != nil },
                            set: { if $0 == false { model.closeFan() } }
                        ),
                        // Away from the edge the mark sits on.
                        arrowEdge: fan.rect.midX > geometry.size.width / 2 ? .leading : .trailing
                    ) {
                        EchoHandView(
                            fan: fan,
                            model: model,
                            currentPaperID: currentPaperID,
                            onOpenCitation: onOpenCitation,
                            onQuoted: onQuoted
                        )
                    }
            }
        }
    }
}

/// The popover's content. A card becomes the one on top when clicked in the hand; being
/// on top is what counts as seen.
struct EchoHandView: View {
    static let width: CGFloat = 340

    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var papers: [UUID: Paper] = [:]
    @State private var errorMessage: String?

    var fan: LearningEchoModel.Fan
    var model: LearningEchoModel
    var currentPaperID: UUID?
    var recorder: LearningRecorder = .shared
    var onOpenCitation: (PaperCitation, String?) -> Void
    var onQuoted: (String) -> Void

    private var selected: LearningEcho? {
        fan.echoes.first { $0.id == selectedID } ?? fan.echoes.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                LearningEchoCard(echo: selected, paperTitle: paperTitle(of: selected.event)) {
                    EmptyView()
                }
                .id(selected.id)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                actions(selected)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if fan.echoes.count > 1 {
                hand
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selected?.id)
        .task(id: fan.blockID) {
            loadPapers()
            if let selected {
                model.markOpened(selected)
            }
        }
        .onChange(of: selected?.id) { _, _ in
            if let selected {
                model.markOpened(selected)
            }
        }
    }

    private func actions(_ echo: LearningEcho) -> some View {
        HStack(spacing: 8) {
            Button(String(localized: "Open in Paper", bundle: bundle)) {
                model.closeFan()
                onOpenCitation(echo.event.citation, echo.event.quote)
            }
            .keyboardShortcut(.defaultAction)
            if echo.event.quote != nil {
                Button(String(localized: "Quote in Writing", bundle: bundle)) {
                    quote(echo)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button(String(localized: "Not Related", bundle: bundle)) {
                    Task { await model.dismiss(echo, context: LearningEchoModel.readingContext(fan.paperID)) }
                }
                Button(String(localized: "Delete Record", bundle: bundle), role: .destructive) {
                    Task {
                        await recorder.delete(echo.event)
                        model.forget(echo)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "More", bundle: bundle))
        }
        .controlSize(.small)
    }

    /// The paragraph's other echoes, fanned along an arc. Hovering lifts a card; clicking
    /// brings it to the top.
    private var hand: some View {
        let count = fan.echoes.count
        let middle = Double(count - 1) / 2
        return ZStack {
            ForEach(Array(fan.echoes.enumerated()), id: \.element.id) { index, echo in
                let position = Double(index) - middle
                let isSelected = echo.id == selected?.id
                let isHovered = echo.id == hoveredID
                // Overlapping like a held hand, later cards over earlier ones; the card on
                // top of the fan rises out of it.
                miniCard(echo, isSelected: isSelected)
                    .rotationEffect(.degrees(position * 5), anchor: .bottom)
                    .offset(
                        x: position * Self.handSpacing(count: count),
                        y: position * position * 3 - (isSelected ? 14 : isHovered ? 7 : 0)
                    )
                    .zIndex(isSelected ? 100 : isHovered ? 50 : Double(index))
                    .onHover { hoveredID = $0 ? echo.id : (hoveredID == echo.id ? nil : hoveredID) }
                    .onTapGesture { selectedID = echo.id }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(echo.event.kind.echoTitle(bundle: bundle) + ". " + (echo.event.text ?? echo.event.quote ?? ""))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { selectedID = echo.id }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 118)
        .padding(.top, 6)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hoveredID)
    }

    /// Wide enough that every card shows most of its text, narrow enough that five fit.
    static func handSpacing(count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return min(64, (width - 28 - 74) / CGFloat(count - 1))
    }

    private func miniCard(_ echo: LearningEcho, isSelected: Bool) -> some View {
        let isSeen = model.openedSubjects.contains(echo.id) && isSelected == false
        return VStack(alignment: .leading, spacing: 5) {
            Image(systemName: echo.event.kind.systemImage)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(echo.event.text ?? echo.event.quote ?? "")
                .font(.system(size: 10))
                .foregroundStyle(isSeen ? .tertiary : .secondary)
                .lineLimit(5)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(width: 74, height: 96, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(isSelected ? 0.16 : 0.08), radius: isSelected ? 6 : 3, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func quote(_ echo: LearningEcho) {
        guard let paper = papers[echo.event.paperID] else {
            errorMessage = String(localized: "The cited paper is no longer in your library.", bundle: bundle)
            return
        }
        let label = PaperCitation.label(
            authors: paper.authors,
            title: paper.title,
            year: paper.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
            pageIndex: echo.event.pageIndex
        )
        do {
            let title = try WritingDocumentCenter.shared.insertCitation(echo.event.citation, label: label, quote: echo.event.quote)
            model.closeFan()
            onQuoted(title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func paperTitle(of event: LearningEvent) -> String {
        if event.paperID == currentPaperID {
            return String(localized: "This Paper", bundle: bundle)
        }
        return papers[event.paperID]?.title ?? String(localized: "Deleted Paper", bundle: bundle)
    }

    private func loadPapers() {
        let ids = Set(fan.echoes.map(\.event.paperID)).subtracting(papers.keys)
        guard ids.isEmpty == false else { return }
        let fetched = (try? modelContext.fetch(FetchDescriptor<Paper>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for paper in fetched {
            papers[paper.id] = paper
        }
    }
}
