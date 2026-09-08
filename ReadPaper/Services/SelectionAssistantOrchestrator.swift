import Foundation

struct SelectionAssistantScopeResolver {
    static func resolve(_ request: SelectionAssistantRequest) -> AssistantScope {
        guard request.scope == .automatic else { return request.scope }
        if request.action == .translate { return .nearby }

        let question = request.question?
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased() ?? ""
        if containsAny(question, terms: externalIntentTerms) {
            return .external
        }
        if request.action == .ask || containsAny(question, terms: fullPaperIntentTerms) {
            return .fullPaper
        }
        return .nearby
    }

    private static func containsAny(_ text: String, terms: [String]) -> Bool {
        text.isEmpty == false && terms.contains { text.contains($0) }
    }

    private static let externalIntentTerms = [
        "联网", "外部资料", "论文之外", "其他论文", "相关论文", "最新研究", "最新进展",
        "项目主页", "代码仓库", "引用网络", "被引用", "出版信息", "github", "crossref",
        "openalex", "semantic scholar", "search the web", "search online", "external source",
        "outside the paper", "other papers", "related papers", "latest research", "latest work",
        "project page", "code repository", "citation network", "publication information"
    ]

    private static let fullPaperIntentTerms = [
        "全文", "论文中", "在文中", "作者", "后面", "哪一节", "哪里", "定义", "实验",
        "证据", "验证", "摘要", "贡献", "方法", "结论", "full paper", "full text", "paper",
        "author", "later", "section", "where", "define", "experiment", "evidence", "validate",
        "abstract", "contribution", "method", "conclusion"
    ]
}

@MainActor
struct SelectionAssistantOrchestrator {
    private let assistantService: SelectionAssistantService
    private let fullTextSearchService: PaperFullTextSearchService
    private let externalSearchService: any SelectionAssistantExternalSearching
    private let userDefaults: UserDefaults

    init(
        assistantService: SelectionAssistantService = SelectionAssistantService(),
        fullTextSearchService: PaperFullTextSearchService = PaperFullTextSearchService(),
        externalSearchService: any SelectionAssistantExternalSearching = SelectionAssistantExternalSearchService.shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.assistantService = assistantService
        self.fullTextSearchService = fullTextSearchService
        self.externalSearchService = externalSearchService
        self.userDefaults = userDefaults
    }

    func perform(
        _ request: SelectionAssistantRequest,
        selection: NoteSelectionContext,
        paper: Paper,
        attachments: [PaperAttachment],
        notes: [Note],
        targetLanguage: String,
        route: ResolvedLLMModelRoute,
        onProgress: ((SelectionAssistantProgress) -> Void)? = nil,
        onPartialAnswer: (@Sendable (String) async -> Void)? = nil
    ) async throws -> SelectionAssistantResult {
        try Task.checkCancellation()
        onProgress?(.collectingPaperContext)

        var resolvedRequest = request
        resolvedRequest.scope = SelectionAssistantScopeResolver.resolve(request)
        let paperMetadata = Self.paperMetadata(paper)
        let userNotes = Self.userNotes(notes)
        var sources = [Self.selectionSource(selection)]
        var warnings: [String] = []
        let query = resolvedRequest.question ?? resolvedRequest.selection

        if resolvedRequest.scope == .fullPaper || resolvedRequest.scope == .external {
            try Task.checkCancellation()
            onProgress?(.searchingFullText)
            let paperSources = try retrievePaperSources(
                query: query,
                paper: paper,
                attachments: attachments,
                notes: notes
            )
            sources.append(contentsOf: paperSources)
            onProgress?(.foundPaperSources(paperSources.filter {
                $0.kind == .paperHTML || $0.kind == .paperPDF
            }.count))
            await Task.yield()

            if paperSources.contains(where: { $0.kind == .paperHTML || $0.kind == .paperPDF }) == false {
                warnings.append(AppLocalization.localized("No supporting passage was found in this paper."))
            }
        }

        if resolvedRequest.scope == .external {
            try Task.checkCancellation()
            guard userDefaults.bool(forKey: SelectionAssistantPreferences.externalSearchEnabledKey) else {
                warnings.append(AppLocalization.localized("External search is disabled in Settings."))
                onProgress?(.generatingAnswer)
                await Task.yield()
                return try await assistantService.perform(
                    resolvedRequest,
                    paperTitle: paper.title,
                    targetLanguage: targetLanguage,
                    route: route,
                    paperMetadata: paperMetadata,
                    userNotes: userNotes,
                    sources: sources,
                    warnings: warnings,
                    onPartialAnswer: onPartialAnswer
                )
            }

            onProgress?(.searchingExternalSources)
            await Task.yield()
            let externalResult = await externalSearchService.search(
                query: query,
                paper: SelectionAssistantPaperContext(
                    id: paper.id,
                    title: paper.title,
                    abstractText: paper.abstractText,
                    authors: paper.authors,
                    arxivID: paper.arxivID,
                    arxivVersion: paper.arxivVersion,
                    doi: paper.doi
                ),
                limit: 6
            )
            try Task.checkCancellation()
            sources.append(contentsOf: externalResult.sources)
            warnings.append(contentsOf: externalResult.warnings)
            if externalResult.sources.isEmpty {
                warnings.append(AppLocalization.localized("No external source was found for this question."))
            }
        }

        try Task.checkCancellation()
        onProgress?(.generatingAnswer)
        await Task.yield()
        return try await assistantService.perform(
            resolvedRequest,
            paperTitle: paper.title,
            targetLanguage: targetLanguage,
            route: route,
            paperMetadata: paperMetadata,
            userNotes: userNotes,
            sources: Self.uniqueSources(sources),
            warnings: Self.uniqueWarnings(warnings),
            onPartialAnswer: onPartialAnswer
        )
    }

    private func retrievePaperSources(
        query: String,
        paper: Paper,
        attachments: [PaperAttachment],
        notes: [Note]
    ) throws -> [AssistantSource] {
        var sources: [AssistantSource] = []
        if let index = try fullTextSearchService.loadOrRebuild(paper: paper, attachments: attachments) {
            let hits = fullTextSearchService.search(query: query, in: index, topK: 4, adjacentBlockCount: 1)
            sources.append(contentsOf: hits.map(Self.source(from:)))
        }

        let rankedNotes = notes.compactMap { note -> (Note, Double)? in
            let score = PaperFullTextSearchService.relevanceScore(
                query: query,
                text: [note.quote, note.body].joined(separator: "\n"),
                title: "User note"
            )
            return score > 0 ? (note, score) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(2)

        sources.append(contentsOf: rankedNotes.map { note, _ in
            let excerpt = [note.quote, note.body]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .joined(separator: "\n\n")
            return AssistantSource(
                id: "note-\(note.id.uuidString)",
                kind: .userNote,
                title: AppLocalization.localized("User note"),
                excerpt: excerpt,
                attachmentID: note.attachmentID,
                pageIndex: note.pageIndex,
                htmlSelector: note.normalizedHTMLSelector
            )
        })
        return sources
    }

    private static func selectionSource(_ selection: NoteSelectionContext) -> AssistantSource {
        AssistantSource(
            id: "selection-\(Hashing.sha256Hex(selection.selectionAssistantIdentity).prefix(20))",
            kind: .currentSelection,
            title: AppLocalization.localized("Current passage"),
            excerpt: [selection.localContext, selection.quote]
                .compactMap { $0 }
                .joined(separator: "\n\n"),
            attachmentID: selection.attachmentID,
            pageIndex: selection.pageIndex,
            htmlSelector: selection.htmlSelector
        )
    }

    private static func source(from hit: PaperSearchHit) -> AssistantSource {
        let title: String
        if let pageIndex = hit.block.pageIndex {
            title = AppLocalization.format("Page %d", pageIndex + 1)
        } else if let section = hit.block.sectionPath.last, section.isEmpty == false {
            title = section
        } else {
            title = AppLocalization.localized("Paper passage")
        }
        return AssistantSource(
            id: "paper-\(hit.block.id)",
            kind: hit.block.kind == .pdfPage ? .paperPDF : .paperHTML,
            title: title,
            excerpt: String(hit.contextualText.prefix(8_000)),
            sectionPath: hit.block.sectionPath,
            attachmentID: hit.block.attachmentID,
            pageIndex: hit.block.pageIndex,
            htmlSelector: hit.block.htmlSelector,
            isLowConfidence: hit.block.kind == .pdfPage
        )
    }

    private static func paperMetadata(_ paper: Paper) -> String {
        var fields = ["Title: \(paper.title)"]
        if paper.authors.isEmpty == false {
            fields.append("Authors: \(paper.authors.joined(separator: ", "))")
        }
        if let arxivID = paper.arxivID {
            fields.append("arXiv: \(arxivID)\(paper.arxivVersion ?? "")")
        }
        if let doi = paper.doi {
            fields.append("DOI: \(doi)")
        }
        let abstract = paper.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        if abstract.isEmpty == false {
            fields.append("Abstract: \(abstract)")
        }
        return fields.joined(separator: "\n")
    }

    private static func userNotes(_ notes: [Note]) -> String {
        notes.prefix(40).enumerated().map { index, note in
            var fields = ["[N\(index + 1)]"]
            if note.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                fields.append("Quote: \(note.quote)")
            }
            if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                fields.append("Note: \(note.body)")
            }
            return fields.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func uniqueSources(_ sources: [AssistantSource]) -> [AssistantSource] {
        var seen: Set<String> = []
        return sources.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen: Set<String> = []
        return warnings.filter { seen.insert($0).inserted }
    }
}
