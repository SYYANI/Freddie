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
        if hasGenericSearchIntent(in: question) {
            if containsAny(question, terms: currentPaperSearchTerms) {
                return .fullPaper
            }
            return .external
        }
        if containsAny(question, terms: fullPaperIntentTerms) {
            return .fullPaper
        }
        return .nearby
    }

    /// Detects a "look this up" intent. Explicit command phrasings count on
    /// their own. Ambiguous search words only count when they are not part of
    /// a domain noun phrase such as "搜索空间" or "数据库查询".
    private static func hasGenericSearchIntent(in question: String) -> Bool {
        if containsAny(question, terms: genericSearchIntentTerms) {
            return true
        }
        guard containsAny(question, terms: ambiguousSearchVerbTerms) else { return false }
        return containsAny(question, terms: searchNounPhraseTerms) == false
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

    private static let genericSearchIntentTerms = [
        "搜索一下", "搜一下", "搜下", "搜搜", "查询一下", "查一下", "查查",
        "查找一下", "查阅一下", "检索一下", "请搜索", "请查询", "请检索",
        "帮我搜索", "帮我查询", "帮我检索", "帮我搜", "帮我查", "帮我找",
        "再了解", "进一步了解", "了解更多",
        "search for", "search this", "look up", "look it up", "find out more", "learn more",
        "research this", "web search"
    ]

    private static let ambiguousSearchVerbTerms = [
        "搜索", "查询", "检索"
    ]

    /// Noun usages that merely name something inside the paper, so an
    /// ambiguous search word should not turn them into a web-search request.
    private static let searchNounPhraseTerms = [
        "搜索空间", "搜索算法", "搜索策略", "搜索树", "搜索过程", "搜索效率", "搜索范围",
        "搜索路径", "搜索方法", "搜索宽度", "搜索深度",
        "数据库查询", "查询语句", "查询计划", "查询优化", "查询语言", "查询下推", "这个查询", "该查询",
        "信息检索", "文献检索", "全文检索", "向量检索", "检索算法", "检索模型", "检索系统", "检索任务",
        "检索增强",
        "search space", "search algorithm", "search strategy", "search tree",
        "search process", "beam search", "greedy search"
    ]

    private static let currentPaperSearchTerms = [
        "全文", "本文", "本论文", "这篇论文", "论文中", "文中", "原文中",
        "full text", "this paper", "in the paper", "within the paper", "in this article"
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
    private let userDefaults: UserDefaults

    init(
        assistantService: SelectionAssistantService = SelectionAssistantService(),
        fullTextSearchService: PaperFullTextSearchService = PaperFullTextSearchService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.assistantService = assistantService
        self.fullTextSearchService = fullTextSearchService
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
        var webSearchEnabled = false
        let query = resolvedRequest.question ?? resolvedRequest.selection

        if resolvedRequest.scope == .fullPaper || resolvedRequest.scope == .external {
            try Task.checkCancellation()
            onProgress?(.searchingFullText)
            let retrievedPaperSources = try retrievePaperSources(
                query: query,
                paper: paper,
                attachments: attachments,
                notes: notes
            )
            let paperSources = retrievedPaperSources.sources
            sources.append(contentsOf: paperSources)
            onProgress?(.foundPaperSources(paperSources.filter {
                $0.kind == .paperHTML || $0.kind == .paperPDF
            }.count))
            await Task.yield()

            if resolvedRequest.scope == .fullPaper,
               retrievedPaperSources.didAttemptFullTextSearch,
               paperSources.contains(where: { $0.kind == .paperHTML || $0.kind == .paperPDF }) == false {
                warnings.append(AppLocalization.localized("No supporting passage was found in this paper."))
            }
        }

        if resolvedRequest.scope == .external {
            try Task.checkCancellation()
            if userDefaults.bool(forKey: SelectionAssistantPreferences.externalSearchEnabledKey) == false {
                warnings.append(AppLocalization.localized("External search is disabled in Settings."))
            } else {
                onProgress?(.searchingExternalSources)
                await Task.yield()
                if route.snapshot.apiStyle == .responses {
                    webSearchEnabled = true
                } else {
                    warnings.append(AppLocalization.localized(
                        "Live web search requires the selected assistant model to use the Responses API."
                    ))
                }
            }
        }

        try Task.checkCancellation()
        // With server-side web search the progress stage above stays active
        // until output text starts; marking this request as "generating" would
        // hide the search stage behind the final answer spinner.
        if webSearchEnabled == false {
            onProgress?(.generatingAnswer)
        }
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
            webSearchEnabled: webSearchEnabled,
            onPartialAnswer: onPartialAnswer
        )
    }

    private func retrievePaperSources(
        query: String,
        paper: Paper,
        attachments: [PaperAttachment],
        notes: [Note]
    ) throws -> RetrievedPaperSources {
        var sources: [AssistantSource] = []
        var didAttemptFullTextSearch = false
        if let index = try fullTextSearchService.loadOrRebuild(paper: paper, attachments: attachments) {
            didAttemptFullTextSearch = PaperFullTextSearchService.canKeywordMatch(
                query: query,
                in: index
            )
            if didAttemptFullTextSearch {
                let hits = fullTextSearchService.search(query: query, in: index, topK: 4, adjacentBlockCount: 1)
                sources.append(contentsOf: hits.map(Self.source(from:)))
            }
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
                htmlSelector: note.normalizedHTMLSelector,
                navigationQuote: note.trimmedQuote
            )
        })
        return RetrievedPaperSources(
            sources: sources,
            didAttemptFullTextSearch: didAttemptFullTextSearch
        )
    }

    private struct RetrievedPaperSources {
        var sources: [AssistantSource]
        var didAttemptFullTextSearch: Bool
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
            htmlSelector: selection.htmlSelector,
            navigationQuote: selection.trimmedQuote
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
            navigationQuote: hit.block.text,
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
