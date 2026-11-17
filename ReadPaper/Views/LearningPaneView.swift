import SwiftData
import SwiftUI

/// The inspector's Learning tab: what the reader highlighted, noted, asked and quoted,
/// for the selected paper (grouped by kind) or across the library (grouped by day).
struct LearningPaneView: View {
    enum Scope: String {
        case paper
        case library
        case concepts
        case weekly

        static let userDefaultsKey = "ReadPaper.Learning.Scope"
    }

    /// The cross-paper list shows this many of the most recent records.
    static let libraryRecordLimit = 300

    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @AppStorage(Scope.userDefaultsKey) private var scopeRawValue = Scope.paper.rawValue
    @State private var events: [LearningEvent] = []
    @State private var paperTitles: [UUID: String] = [:]
    @State private var loadedRequest: LoadRequest?
    @State private var record: PaperLearningRecord?
    @State private var eventsByID: [String: LearningEvent] = [:]
    @State private var pendingCount = 0
    @State private var hasRoute = false
    @State private var concepts: [LearningConcept] = []
    @State private var weeks: [LearningWeek] = []
    /// When the reader last looked at the shown paper's record before this visit: what
    /// the organizer changed after it is marked as new.
    @State private var seenCutoff: SeenCutoff?
    @State private var itemEdit: ItemEdit?
    @State private var conceptRename: ConceptRename?
    @State private var lastRemoved: RemovedItem?
    @State private var showsActivity = false
    @FocusState private var focusedField: EditField?

    var paper: Paper?
    var notes: [Note]
    var recorder: LearningRecorder = .shared
    var log: LearningEventLog = .shared
    var organizer: LearningOrganizer = .shared
    var recordStore: LearningRecordStore = .shared
    var onOpenCitation: (PaperCitation, String?) -> Void
    /// Starts a paragraph about a concept (name, where it came from, the passage) in the
    /// open writing.
    var onWriteAboutConcept: ((String, PaperCitation, String?) -> Void)? = nil

    private struct SeenCutoff: Equatable {
        var paperID: UUID
        var date: Date
    }

    private struct ItemEdit: Equatable {
        var paperID: UUID
        var itemID: String
        var kind: LearningRecordItem.Kind
        var title: String
        var detail: String
    }

    private struct ConceptRename: Equatable {
        var conceptID: String
        var name: String
    }

    private struct RemovedItem: Equatable {
        var paperID: UUID
        var itemID: String
        var title: String
    }

    private enum EditField: Hashable {
        case title
        case detail
    }

    private struct LoadRequest: Equatable {
        var scope: Scope
        var paperID: UUID?
        var revision: Int
        var organizerRevision: Int
    }

    private var scope: Scope {
        Scope(rawValue: scopeRawValue) ?? .paper
    }

    var body: some View {
        let request = LoadRequest(
            scope: scope,
            paperID: paper?.id,
            revision: recorder.revision,
            organizerRevision: organizer.revision
        )
        VStack(spacing: 0) {
            header
            Divider()
            if loadedRequest?.scope != scope || loadedRequest?.paperID != paper?.id {
                Color.clear
            } else if scope == .paper, paper == nil {
                emptyState(String(localized: "No Paper Selected", bundle: bundle))
            } else if scope == .concepts, concepts.isEmpty {
                emptyState(
                    String(localized: "No concepts yet.", bundle: bundle),
                    detail: String(
                        localized: "Terms you look up or ask about appear here after a paper's learning record is organized.",
                        bundle: bundle
                    )
                )
            } else if scope != .concepts, events.isEmpty {
                emptyState(
                    String(localized: "No learning records yet.", bundle: bundle),
                    detail: String(
                        localized: "Highlights, notes, questions and citations you make while reading are collected here.",
                        bundle: bundle
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        switch scope {
                        case .paper: paperSections
                        case .library: librarySections
                        case .concepts: conceptRows
                        case .weekly: weekSections
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: request) {
            await load(request)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(
                scope == .concepts
                    ? String(format: String(localized: "%lld concepts", bundle: bundle), concepts.count)
                    : String(format: String(localized: "%lld records", bundle: bundle), events.count)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker(String(localized: "Scope", bundle: bundle), selection: $scopeRawValue) {
                Text("This Paper", bundle: bundle).tag(Scope.paper.rawValue)
                Text("Concepts", bundle: bundle).tag(Scope.concepts.rawValue)
                Text("Weekly", bundle: bundle).tag(Scope.weekly.rawValue)
                Divider()
                Text("All Activity", bundle: bundle).tag(Scope.library.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var paperSections: some View {
        let recordSections = Self.recordSections(of: record)
        if let paper {
            organizerStatus(paper)
            if let lastRemoved, lastRemoved.paperID == paper.id {
                removedRow(lastRemoved)
            }
            let unseen = unseenItemIDs(paperID: paper.id)
            ForEach(recordSections, id: \.group) { section in
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    InspectorSectionHeader(title: section.group.title(bundle: bundle)) {
                        Text(section.items.count, format: .number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(section.items) { item in
                        if let itemEdit, itemEdit.paperID == paper.id, itemEdit.itemID == item.id {
                            itemEditor(itemEdit)
                        } else {
                            recordRow(item, paperID: paper.id, isNew: unseen.contains(item.id))
                        }
                    }
                }
                .padding(16)
            }
        }
        // What the reader did is the evidence behind the record above. Once there is a
        // record, it stays folded away until asked for.
        let sections = Self.sections(of: events)
        let isExpanded = recordSections.isEmpty || showsActivity
        if recordSections.isEmpty == false, sections.isEmpty == false {
            Divider()
            Button {
                showsActivity.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsActivity ? 90 : 0))
                    Text("What You Did", bundle: bundle)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(events.count, format: .number)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                showsActivity
                    ? String(localized: "Expanded", bundle: bundle)
                    : String(localized: "Collapsed", bundle: bundle)
            )
        }
        if isExpanded {
            ForEach(Array(sections.enumerated()), id: \.element.group) { _, section in
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    InspectorSectionHeader(title: section.group.title(bundle: bundle)) {
                        Text(section.events.count, format: .number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(section.events) { event in
                        row(event, showsPaper: false)
                    }
                }
                .padding(16)
            }
        }
    }

    private func unseenItemIDs(paperID: UUID) -> Set<String> {
        guard let seenCutoff, seenCutoff.paperID == paperID else { return [] }
        return record?.unseenItemIDs(since: seenCutoff.date) ?? []
    }

    private func removedRow(_ removed: RemovedItem) -> some View {
        HStack(spacing: 8) {
            Text(String(format: String(localized: "Removed “%@”", bundle: bundle), removed.title))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(String(localized: "Undo", bundle: bundle)) {
                lastRemoved = nil
                Task { await organizer.restoreItem(removed.itemID, paperID: removed.paperID) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func itemEditor(_ edit: ItemEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                String(localized: "Title", bundle: bundle),
                text: Binding(get: { itemEdit?.title ?? "" }, set: { itemEdit?.title = $0 }),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .focused($focusedField, equals: .title)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .readPaperFieldWell(isFocused: focusedField == .title)
            TextField(
                String(localized: "Details", bundle: bundle),
                text: Binding(get: { itemEdit?.detail ?? "" }, set: { itemEdit?.detail = $0 }),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .lineLimit(2...10)
            .focused($focusedField, equals: .detail)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .readPaperFieldWell(isFocused: focusedField == .detail)
            if edit.kind == .concept {
                Text("Give it the name of another concept to merge the two.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(localized: "Cancel", bundle: bundle)) {
                    itemEdit = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", bundle: bundle)) {
                    itemEdit = nil
                    let detail = edit.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await organizer.editItem(
                            edit.itemID,
                            title: edit.title,
                            detail: detail.isEmpty ? nil : detail,
                            paperID: edit.paperID
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(edit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func itemActions(_ item: LearningRecordItem, paperID: UUID) -> some View {
        Button(String(localized: "Edit…", bundle: bundle)) {
            itemEdit = ItemEdit(
                paperID: paperID,
                itemID: item.id,
                kind: item.kind,
                title: item.title,
                detail: item.detail ?? ""
            )
            focusedField = .title
        }
        ForEach(LearningRecordItem.Kind.allCases.filter { $0 != item.kind }, id: \.self) { kind in
            Button(kind.moveTitle(bundle: bundle)) {
                Task { await organizer.setKind(kind, itemID: item.id, paperID: paperID) }
            }
        }
        Divider()
        Button(String(localized: "Remove", bundle: bundle), role: .destructive) {
            lastRemoved = RemovedItem(paperID: paperID, itemID: item.id, title: item.title)
            Task { await organizer.removeItem(item.id, paperID: paperID) }
        }
    }

    /// What an entry was built from, as counts of the reader's own actions.
    private func evidenceSummary(_ sources: [LearningEvent]) -> some View {
        let counts = LearningGroup.allCases.compactMap { group -> (group: LearningGroup, count: Int)? in
            let count = sources.filter { LearningGroup($0.kind) == group }.count
            return count > 0 ? (group, count) : nil
        }
        return HStack(spacing: 8) {
            Text("From your", bundle: bundle)
            ForEach(counts, id: \.group) { entry in
                HStack(spacing: 2) {
                    Image(systemName: entry.group.systemImage)
                    Text(entry.count, format: .number)
                }
                .help(entry.group.title(bundle: bundle))
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "%lld sources", bundle: bundle), sources.count))
    }

    @ViewBuilder
    private var librarySections: some View {
        let days = Self.days(of: events)
        ForEach(Array(days.enumerated()), id: \.element.day) { index, day in
            if index > 0 {
                Divider()
            }
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionHeader(title: day.day.formatted(date: .abbreviated, time: .omitted)) {
                    Text(day.events.count, format: .number)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(day.events) { event in
                    row(event, showsPaper: true)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var conceptRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(concepts) { concept in
                conceptRow(concept)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func conceptRow(_ concept: LearningConcept) -> some View {
        if let conceptRename, conceptRename.conceptID == concept.id {
            conceptRenamer(concept, name: conceptRename.name)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                conceptButton(concept)
                // Looked up again and again but never put into words: the next step is
                // offered where the reader sees it.
                if onWriteAboutConcept != nil, concept.stage == .recurring {
                    InspectorIconButton(
                        title: String(localized: "Write About It", bundle: bundle),
                        systemImage: "square.and.pencil"
                    ) {
                        writeAbout(concept)
                    }
                }
            }
            .contextMenu {
                if onWriteAboutConcept != nil {
                    Button(String(localized: "Write About It", bundle: bundle)) {
                        writeAbout(concept)
                    }
                }
                Button(String(localized: "Rename…", bundle: bundle)) {
                    conceptRename = ConceptRename(conceptID: concept.id, name: concept.name)
                    focusedField = .title
                }
            }
        }
    }

    private func writeAbout(_ concept: LearningConcept) {
        let source = Self.writingSource(for: concept, eventsByID: eventsByID)
        onWriteAboutConcept?(concept.name, source.citation, source.quote)
    }

    /// The passage to quote when writing about a concept: from its most recently updated
    /// entry that has one, preferring a passage the reader can be taken back to.
    static func writingSource(
        for concept: LearningConcept,
        eventsByID: [String: LearningEvent]
    ) -> (citation: PaperCitation, quote: String?) {
        let sources = concept.entries.flatMap { $0.item.evidence.compactMap { eventsByID[$0] } }
        let quoted = sources.filter { $0.quote?.isEmpty == false }
        if let event = quoted.first(where: \.hasAnchor) ?? quoted.first ?? sources.first {
            return (event.citation, event.quote)
        }
        return (PaperCitation(paperID: concept.entries.first?.paperID ?? UUID()), nil)
    }

    private func conceptRenamer(_ concept: LearningConcept, name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                String(localized: "Name", bundle: bundle),
                text: Binding(get: { conceptRename?.name ?? "" }, set: { conceptRename?.name = $0 })
            )
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .title)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .readPaperFieldWell(isFocused: focusedField == .title)
            .onSubmit { commitRename(of: concept, to: name) }
            Text("Renames it in every paper. Give it the name of another concept to merge the two.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(localized: "Cancel", bundle: bundle)) {
                    conceptRename = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Rename", bundle: bundle)) {
                    commitRename(of: concept, to: name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func commitRename(of concept: LearningConcept, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        conceptRename = nil
        guard name.isEmpty == false, name != concept.name else { return }
        Task { await organizer.renameConcept(concept, to: name) }
    }

    private func conceptButton(_ concept: LearningConcept) -> some View {
        Button {
            open(concept.entries.first)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(concept.name)
                    Text(concept.stage.title(bundle: bundle))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(concept.stage.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(concept.stage.tint)
                }
                if let detail = concept.entries.first?.item.detail {
                    Text(NoteMarkdownRenderer.preview(detail))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(conceptCaption(concept))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func conceptCaption(_ concept: LearningConcept) -> String {
        let counts = String(
            format: String(localized: "%1$lld papers · looked up %2$lld times", bundle: bundle),
            concept.paperIDs.count,
            concept.lookupCount
        )
        let titles = concept.paperIDs.prefix(2).map(title(of:))
        return ([counts] + titles).joined(separator: " · ")
    }

    @ViewBuilder
    private var weekSections: some View {
        ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
            if index > 0 {
                Divider()
            }
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionHeader(
                    title: (week.start..<week.end).formatted(.interval.month(.abbreviated).day())
                ) {
                    Text(String(format: String(localized: "%lld records", bundle: bundle), week.eventCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                weekGroup(String(localized: "Papers Read", bundle: bundle), systemImage: "doc.text", isEmpty: week.papers.isEmpty) {
                    ForEach(week.papers, id: \.paperID) { activity in
                        Button {
                            onOpenCitation(PaperCitation(paperID: activity.paperID), nil)
                        } label: {
                            HStack(spacing: 8) {
                                Text(title(of: activity.paperID))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(activity.eventCount, format: .number)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                weekGroup(String(localized: "New Concepts", bundle: bundle), systemImage: "character.book.closed", isEmpty: week.newConcepts.isEmpty) {
                    ForEach(week.newConcepts, id: \.id) { entry in
                        weekItemRow(entry)
                    }
                }
                weekGroup(String(localized: "Open Questions", bundle: bundle), systemImage: "questionmark.bubble", isEmpty: week.openQuestions.isEmpty) {
                    ForEach(week.openQuestions, id: \.id) { entry in
                        weekItemRow(entry)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func weekGroup<Rows: View>(
        _ title: String,
        systemImage: String,
        isEmpty: Bool,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        if isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                rows()
            }
        }
    }

    private func weekItemRow(_ entry: LearningConcept.Entry) -> some View {
        Button {
            open(entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.title)
                    .lineLimit(2)
                Text(title(of: entry.paperID))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(of paperID: UUID) -> String {
        paperTitles[paperID] ?? String(localized: "Deleted Paper", bundle: bundle)
    }

    /// Jumps to the passage behind a record entry, or just to its paper when none of its
    /// events has a position.
    private func open(_ entry: LearningConcept.Entry?) {
        guard let entry else { return }
        let sources = entry.item.evidence.compactMap { eventsByID[$0] }
        if let target = sources.first(where: \.hasAnchor) ?? sources.first {
            onOpenCitation(target.citation, target.quote)
        } else {
            onOpenCitation(PaperCitation(paperID: entry.paperID), nil)
        }
    }

    private func organizerStatus(_ paper: Paper) -> some View {
        let isRunning = organizer.isRunning(paper.id)
        let failure = organizer.failures[paper.id]
        return HStack(spacing: 8) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("Organizing…", bundle: bundle)
            } else if let failure {
                Text(failure)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            } else if hasRoute == false {
                Text("Choose a model in Settings to organize learning records.", bundle: bundle)
            } else if pendingCount > 0 {
                Text(String(format: String(localized: "%lld new records to organize", bundle: bundle), pendingCount))
            } else if let organizedAt = record?.organizedAt {
                let newCount = unseenItemIDs(paperID: paper.id).count
                Text(
                    [
                        String(
                            format: String(localized: "Organized %@", bundle: bundle),
                            organizedAt.formatted(date: .abbreviated, time: .shortened)
                        ),
                        newCount > 0
                            ? String(format: String(localized: "%lld new or updated", bundle: bundle), newCount)
                            : nil,
                    ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                )
            } else {
                Text("Nothing to organize yet.", bundle: bundle)
            }
            Spacer(minLength: 8)
            InspectorIconButton(
                title: String(localized: "Organize Now", bundle: bundle),
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                let context = LearningOrganizer.PaperContext(id: paper.id, title: paper.title, abstract: paper.abstractText)
                Task { await organizer.organize(context, trigger: .manual, modelContext: modelContext) }
            }
            .disabled(isRunning || hasRoute == false || pendingCount == 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func recordRow(_ item: LearningRecordItem, paperID: UUID, isNew: Bool) -> some View {
        let sources = item.evidence.compactMap { eventsByID[$0] }
        let target = sources.first(where: \.hasAnchor) ?? sources.first
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if item.kind == .question {
                Button {
                    Task { await organizer.setResolved(!item.isResolved, itemID: item.id, paperID: paperID) }
                } label: {
                    Image(systemName: item.isResolved ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isResolved ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16)
                .help(
                    item.isResolved
                        ? String(localized: "Mark as Open", bundle: bundle)
                        : String(localized: "Mark as Resolved", bundle: bundle)
                )
                .accessibilityLabel(
                    item.isResolved
                        ? String(localized: "Mark as Open", bundle: bundle)
                        : String(localized: "Mark as Resolved", bundle: bundle)
                )
            } else {
                Image(systemName: item.kind == .concept ? "character.book.closed" : "star")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            Button {
                if let target {
                    onOpenCitation(target.citation, target.quote)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title)
                            .foregroundStyle(item.kind == .question && item.isResolved ? .secondary : .primary)
                        if isNew {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                                .accessibilityLabel(String(localized: "New since your last visit", bundle: bundle))
                        }
                    }
                    if let detail = item.detail {
                        Text(NoteMarkdownRenderer.preview(detail))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if sources.isEmpty {
                        Text(String(format: String(localized: "%lld sources", bundle: bundle), item.evidence.count))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        evidenceSummary(sources)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(target == nil)
            Menu {
                itemActions(item, paperID: paperID)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "More", bundle: bundle))
        }
        .contextMenu {
            itemActions(item, paperID: paperID)
        }
    }

    private func row(_ event: LearningEvent, showsPaper: Bool) -> some View {
        Button {
            onOpenCitation(event.citation, event.quote)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: event.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityLabel(LearningGroup(event.kind).title(bundle: bundle))
                VStack(alignment: .leading, spacing: 4) {
                    // A note's body and the assistant's answer are Markdown; the quote is
                    // the paper's own text.
                    if let text = event.text {
                        Text(NoteMarkdownRenderer.preview(text))
                            .lineLimit(4)
                    }
                    if let quote = event.quote {
                        Text(quote)
                            .font(event.text == nil ? .body : .callout)
                            .foregroundStyle(event.text == nil ? .primary : .secondary)
                            .lineLimit(3)
                    }
                    if let response = event.response {
                        Text(NoteMarkdownRenderer.preview(response))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text(caption(for: event, showsPaper: showsPaper))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Only in the context menu: deleting a record is rare, and the row stays one tap
        // target for opening the passage.
        .contextMenu {
            Button(String(localized: "Delete Record", bundle: bundle), role: .destructive) {
                Task { await recorder.delete(event) }
            }
        }
    }

    private func caption(for event: LearningEvent, showsPaper: Bool) -> String {
        var parts: [String] = []
        if showsPaper {
            parts.append(paperTitles[event.paperID] ?? String(localized: "Deleted Paper", bundle: bundle))
        }
        if let pageIndex = event.pageIndex {
            parts.append(String(format: String(localized: "p. %lld", bundle: bundle), pageIndex + 1))
        }
        parts.append(
            showsPaper
                ? event.occurredAt.formatted(date: .omitted, time: .shortened)
                : event.occurredAt.formatted(date: .abbreviated, time: .omitted)
        )
        return parts.joined(separator: " · ")
    }

    private func emptyState(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func load(_ request: LoadRequest) async {
        // Collect first so the tab shows what was done since the paper was opened. A
        // collection that appends bumps `recorder.revision` and restarts this task.
        if let paper {
            let values = notes.filter { $0.paperID == paper.id }.map(LearningEventSources.NoteValue.init)
            await recorder.collect(paperID: paper.id, notes: values)
        }
        let loaded: [LearningEvent]
        switch request.scope {
        case .paper:
            loaded = if let paperID = request.paperID { await log.events(paperID: paperID) } else { [] }
        case .library, .concepts, .weekly:
            loaded = await log.allEvents()
        }
        var allRecords: [PaperLearningRecord] = []
        if request.scope == .concepts || request.scope == .weekly {
            allRecords = await recordStore.allRecords()
        }
        var loadedRecord: PaperLearningRecord?
        if request.scope == .paper, let paperID = request.paperID {
            loadedRecord = try? await recordStore.record(paperID: paperID)
        }
        var cutoff = seenCutoff
        if request.scope == .paper, let paperID = request.paperID {
            // Each load tells the organizer the record is being looked at; the cutoff
            // stays the one from the start of this visit.
            let now = Date()
            let previous = await organizer.markSeen(paperID: paperID, now: now)
            if cutoff?.paperID != paperID {
                cutoff = SeenCutoff(paperID: paperID, date: previous ?? now)
            }
        }
        guard Task.isCancelled == false else { return }
        seenCutoff = cutoff
        if lastRemoved?.paperID != request.paperID {
            lastRemoved = nil
        }
        record = loadedRecord
        pendingCount = loadedRecord?.pendingEvents(in: loaded).count ?? 0
        eventsByID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hasRoute = organizer.hasRoute(modelContext: modelContext)
        if let paper, paper.id == request.paperID {
            let context = LearningOrganizer.PaperContext(id: paper.id, title: paper.title, abstract: paper.abstractText)
            Task { await organizer.organize(context, trigger: .automatic, modelContext: modelContext) }
        }
        concepts = request.scope == .concepts
            ? LearningLibrary.concepts(records: allRecords, eventsByID: eventsByID)
            : []
        weeks = request.scope == .weekly ? LearningLibrary.weeks(events: loaded, records: allRecords) : []
        var revisions = LearningEvent.latestRevisions(of: loaded)
        if request.scope != .paper {
            if request.scope == .library {
                revisions = Array(revisions.suffix(Self.libraryRecordLimit))
            }
            let papers = (try? modelContext.fetch(FetchDescriptor<Paper>())) ?? []
            paperTitles = Dictionary(papers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
        events = revisions
        loadedRequest = request
    }

    struct Section: Equatable {
        var group: LearningGroup
        var events: [LearningEvent]
    }

    struct RecordSection: Equatable {
        var group: LearningRecordGroup
        var items: [LearningRecordItem]
    }

    /// Open questions first, settled ones last; most recently updated first within each.
    static func recordSections(of record: PaperLearningRecord?) -> [RecordSection] {
        guard let record else { return [] }
        return LearningRecordGroup.allCases.compactMap { group in
            let items = record.items
                .filter { LearningRecordGroup($0) == group }
                .sorted { $0.updatedAt > $1.updatedAt }
            return items.isEmpty ? nil : RecordSection(group: group, items: items)
        }
    }

    struct Day: Equatable {
        var day: Date
        var events: [LearningEvent]
    }

    /// Non-empty groups in display order, newest record first within each.
    static func sections(of events: [LearningEvent]) -> [Section] {
        LearningGroup.allCases.compactMap { group in
            let matching = events
                .filter { LearningGroup($0.kind) == group }
                .sorted { $0.occurredAt > $1.occurredAt }
            return matching.isEmpty ? nil : Section(group: group, events: matching)
        }
    }

    /// Newest day first, newest record first within each.
    static func days(of events: [LearningEvent], calendar: Calendar = .current) -> [Day] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.occurredAt) }
            .map { Day(day: $0.key, events: $0.value.sorted { $0.occurredAt > $1.occurredAt }) }
            .sorted { $0.day > $1.day }
    }
}

extension LearningConcept.Entry: Identifiable {
    var id: String { "\(paperID.uuidString)/\(item.id)" }
}

extension LearningConcept.Stage {
    func title(bundle: Bundle) -> String {
        switch self {
        case .new: String(localized: "First Seen", bundle: bundle)
        case .recurring: String(localized: "Looked Up Often", bundle: bundle)
        case .writtenAbout: String(localized: "Written About", bundle: bundle)
        }
    }

    var tint: Color {
        switch self {
        case .new: .secondary
        case .recurring: .blue
        case .writtenAbout: .green
        }
    }
}

/// How the Learning tab groups a paper's organized record.
enum LearningRecordGroup: CaseIterable {
    case openQuestions
    case concepts
    case takeaways
    case resolvedQuestions

    init(_ item: LearningRecordItem) {
        switch item.kind {
        case .question: self = item.isResolved ? .resolvedQuestions : .openQuestions
        case .concept: self = .concepts
        case .takeaway: self = .takeaways
        }
    }

    func title(bundle: Bundle) -> String {
        switch self {
        case .openQuestions: String(localized: "Open Questions", bundle: bundle)
        case .concepts: String(localized: "Concepts", bundle: bundle)
        case .takeaways: String(localized: "Takeaways", bundle: bundle)
        case .resolvedQuestions: String(localized: "Resolved Questions", bundle: bundle)
        }
    }
}

/// How the Learning tab groups a paper's records.
enum LearningGroup: CaseIterable {
    case questions
    case lookups
    case marks
    case citations

    init(_ kind: LearningEvent.Kind) {
        switch kind {
        case .question: self = .questions
        case .explanation, .translation: self = .lookups
        case .highlight, .note: self = .marks
        case .citation: self = .citations
        }
    }

    func title(bundle: Bundle) -> String {
        switch self {
        case .questions: String(localized: "Questions", bundle: bundle)
        case .lookups: String(localized: "Explanations and Translations", bundle: bundle)
        case .marks: String(localized: "Highlights and Notes", bundle: bundle)
        case .citations: String(localized: "Quoted in Writings", bundle: bundle)
        }
    }
}

extension LearningGroup {
    var systemImage: String {
        switch self {
        case .questions: "questionmark.bubble"
        case .lookups: "lightbulb"
        case .marks: "highlighter"
        case .citations: "quote.opening"
        }
    }
}

extension LearningRecordItem.Kind {
    func moveTitle(bundle: Bundle) -> String {
        switch self {
        case .question: String(localized: "Move to Questions", bundle: bundle)
        case .concept: String(localized: "Move to Concepts", bundle: bundle)
        case .takeaway: String(localized: "Move to Takeaways", bundle: bundle)
        }
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
