import SwiftData
import SwiftSoup
import WebKit
import XCTest
@testable import ReadPaper

final class HTMLTranslationPipelineTests: XCTestCase {
    @MainActor
    func testDarkSiteProseUsesReaderPaletteForNewAndSavedArticles() async throws {
        // Reduced sigh.dev structure: a dark body palette plus a retained .md-body
        // class overrides the extracted article's color on our light reading surface.
        let paragraph = String(repeating: "An article paragraph with enough content for extraction. ", count: 8)
        let html = """
        <html><head><title>Dark site article</title><meta name="author" content="Example author">
        <style>
        :root { --site-text: #bfd0d7; }
        body { background: #08151c; color: var(--site-text); }
        .md-body { color: var(--site-text); background-color: #08151c; }
        .md-body strong, .md-body h2 { color: #ddeeff; text-shadow: 1px 1px black; }
        .md-body a { color: #00ccff; }
        pre { background: #112233; color: #ddeeff; }
        code span { color: #ff9900; }
        math mi { color: #0000ff; }
        </style></head><body><article><div class="md-body">
        <p>\(paragraph) <strong>Emphasis</strong> <a href="/reference"><span>Reference</span></a></p>
        <h2>Article section</h2><p>\(paragraph)</p>
        <pre><code><span>example_code()</span></code></pre>
        <svg><text style="fill: #ff0000; color: #00ff00">Diagram</text></svg>
        <math><mi>x</mi></math>
        </div></article></body></html>
        """
        let localized = try HTMLLocalizer().makeDocumentForLocalization(
            html: html, sourceURL: URL(string: "https://example.com/article")!
        )
        XCTAssertTrue(localized.body()?.hasClass("rp-readability-body") == true)
        let prepared = try HTMLTranslationPipeline.prepareDocument(localized.outerHtml())
        let translated = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: Dictionary(uniqueKeysWithValues: prepared.candidates.map { ($0.segmentID, "用于验证阅读器配色的中文译文。") })
        )

        for repairSavedDocument in [false, true] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
            let loaded = expectation(description: "Dark site article loaded")
            let observer = HTMLLayoutNavigationObserver(loaded: loaded)
            webView.navigationDelegate = observer
            webView.loadHTMLString(repairSavedDocument
                ? translated.replacingOccurrences(of: HTMLLocalizer.readableProseColorCSS, with: "")
                : translated, baseURL: nil)
            await fulfillment(of: [loaded], timeout: 15)

            if repairSavedDocument {
                let oldColor = try await webView.evaluateJavaScript("getComputedStyle(document.querySelector('.md-body p')).color")
                XCTAssertEqual(oldColor as? String, "rgb(191, 208, 215)")
                _ = try await webView.evaluateJavaScript("window.savedBodyHTML = document.body.innerHTML;")
                _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.instrumentationScript)
                let unchanged = try await webView.evaluateJavaScript("window.savedBodyHTML === document.body.innerHTML")
                XCTAssertEqual(unchanged as? Bool, true, "Color repair must preserve note-anchor DOM paths")
            }

            let coordinator = HTMLReaderView.Coordinator(
                scrollRatio: .constant(0), onNoteSelectionChanged: nil, onSelectionAssistantDismissed: nil
            )
            // Exercise both palettes and switching back, so paper colors cannot leak.
            for appearance in [PDFDisplayAppearance.defaultMode, .paper, .defaultMode] {
                coordinator.displayAppearance = appearance
                coordinator.applyDisplayAppearance(to: webView)
                let result = try await webView.evaluateJavaScript("""
                (() => {
                    const color = selector => getComputedStyle(document.querySelector(selector)).color;
                    return {
                        title: color('.rp-readability-title'), prose: color('.md-body p'),
                        emphasis: color('.md-body strong'), link: color('.md-body a span'),
                        translation: color('.md-body .rp-translation-block'),
                        code: color('code span'), formula: color('math mi'), diagram: color('svg text'),
                        codeBackground: getComputedStyle(document.querySelector('pre')).backgroundColor,
                        background: getComputedStyle(document.querySelector('.md-body')).backgroundColor
                    };
                })();
                """)
                let colors = try XCTUnwrap(result as? [String: String])
                let paper = appearance == .paper
                XCTAssertEqual(colors["title"], paper ? "rgb(33, 27, 20)" : "rgb(31, 31, 31)")
                XCTAssertEqual(colors["prose"], paper ? "rgb(43, 38, 31)" : "rgb(31, 31, 31)")
                XCTAssertEqual(colors["emphasis"], colors["prose"])
                XCTAssertEqual(colors["link"], paper ? "rgb(40, 95, 134)" : "rgb(51, 92, 133)")
                XCTAssertEqual(colors["translation"], paper ? "rgb(36, 83, 61)" : "rgb(31, 77, 58)")
                XCTAssertEqual(colors["code"], "rgb(255, 153, 0)")
                XCTAssertEqual(colors["formula"], "rgb(0, 0, 255)")
                XCTAssertEqual(colors["diagram"], "rgb(0, 255, 0)")
                XCTAssertEqual(colors["background"], "rgba(0, 0, 0, 0)")
                if !paper { XCTAssertEqual(colors["codeBackground"], "rgb(17, 34, 51)") }
            }
        }
    }

    @MainActor
    func testReadableTranslationsShareColumnWithCenteredSourceProse() async throws {
        // Mirrors the source site's reading-column rule, without fetching the site.
        let paragraph = String(repeating: "A research paragraph long enough for readability extraction. ", count: 8)
        let html = """
        <html><head><title>Research article</title><style>
        .reading-column { max-width: 640px; width: 100%; margin-left: auto; margin-right: auto; }
        blockquote { margin-inline: 40px; }
        ul { padding-left: 40px; }
        </style></head><body><article>
        <h2 class="reading-column">Research findings</h2>
        <p class="reading-column">\(paragraph)</p>
        <p class="reading-column">\(paragraph)</p>
        <blockquote><p class="reading-column">\(paragraph)</p></blockquote>
        <ul><li><p class="reading-column">\(paragraph)</p></li></ul>
        </article></body></html>
        """
        let localized = try HTMLLocalizer().makeDocumentForLocalization(
            html: html, sourceURL: URL(string: "https://example.com/research")!
        )
        XCTAssertTrue(localized.body()?.hasClass("rp-readability-body") == true)
        let prepared = try HTMLTranslationPipeline.prepareDocument(localized.outerHtml())
        let translated = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: Dictionary(uniqueKeysWithValues: prepared.candidates.map { ($0.segmentID, "用于验证正文和译文对齐的中文段落。") })
        )

        for repairSavedDocument in [false, true] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
            let loaded = expectation(description: "Readability document loaded")
            let observer = HTMLLayoutNavigationObserver(loaded: loaded)
            webView.navigationDelegate = observer
            let documentHTML = repairSavedDocument
                ? translated.replacingOccurrences(of: HTMLLocalizer.readableProseLayoutCSS, with: "")
                : translated
            webView.loadHTMLString(documentHTML, baseURL: nil)
            await fulfillment(of: [loaded], timeout: 15)
            if repairSavedDocument {
                let oldWidthDifference = try await webView.evaluateJavaScript("""
                (() => {
                    const source = document.querySelector('.rp-readability-content p.reading-column');
                    return source.nextElementSibling.getBoundingClientRect().width - source.getBoundingClientRect().width;
                })();
                """)
                XCTAssertGreaterThan(try XCTUnwrap(oldWidthDifference as? Double), 100)
                _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.instrumentationScript)
            }

            for width in [1100.0, 600.0] {
                webView.setFrameSize(CGSize(width: width, height: 800))
                let aligned = try await webView.evaluateJavaScript("""
                (() => {
                    document.documentElement.dataset.rpDisplayMode = 'bilingual';
                    const sources = [...document.querySelectorAll('.rp-readability-content [data-rp-source="true"]')];
                    return sources.length >= 4 && sources.every(source => {
                        const translation = source.nextElementSibling;
                        const a = source.getBoundingClientRect();
                        const b = translation.getBoundingClientRect();
                        return translation.classList.contains('rp-translation-block') && a.width > 0 &&
                            Math.abs(a.left - b.left) < 1 && Math.abs(a.width - b.width) < 1 && b.top >= a.bottom;
                    }) && parseFloat(getComputedStyle(document.querySelector('blockquote')).marginLeft) === 40 &&
                        parseFloat(getComputedStyle(document.querySelector('ul')).paddingLeft) === 40;
                })();
                """)
                XCTAssertEqual(aligned as? Bool, true, "width=\(width), saved=\(repairSavedDocument)")
            }
        }
    }

    func testHTMLReaderTypographyClampsFontSize() {
        XCTAssertEqual(HTMLReaderTypography.clampFontSize(8), 13)
        XCTAssertEqual(HTMLReaderTypography.clampFontSize(17), 17)
        XCTAssertEqual(HTMLReaderTypography.clampFontSize(40), 28)
    }

    @MainActor
    func testHTMLSelectionInstrumentationKeepsJavaScriptNewlineEscapesIntact() throws {
        let script = HTMLReaderView.Coordinator.instrumentationScript

        XCTAssertTrue(script.contains(".join('\\n\\n')"))
        XCTAssertFalse(script.contains(".join('\n\n')"))
        XCTAssertTrue(script.contains("rpSelection.postMessage({ quote, selector, localContext })"))
        XCTAssertTrue(script.contains("CSS.highlights.set('rp-assistant-selection'"))
        XCTAssertTrue(script.contains("window.__rpClearSelectionAssistantHighlight"))
        XCTAssertTrue(script.contains("::highlight(rp-assistant-selection)"))
        XCTAssertTrue(script.contains("window.__rpSetSelectionAssistantHistory"))
        XCTAssertTrue(script.contains("::highlight(rp-assistant-history)"))
        XCTAssertTrue(script.contains("rp-assistant-history-fallback"))
        XCTAssertTrue(script.contains("assistantHistorySelectionGraceUntil"))
        XCTAssertTrue(script.contains("Date.now() < assistantHistorySelectionGraceUntil"))
        XCTAssertTrue(HTMLReaderView.Coordinator.nativeSelectionClearScript.contains("removeAllRanges"))
        XCTAssertTrue(script.contains("rpSelectionReset.postMessage(null)"))
        XCTAssertTrue(script.contains("document.addEventListener('pointerdown'"))
        XCTAssertTrue(script.contains("#readability-page-1 :not(svg, svg *, math, math *)"))
        XCTAssertTrue(script.contains("position: static !important"))
        XCTAssertTrue(script.contains("#readability-page-1 :is(ul, ol)"))
        XCTAssertTrue(script.contains("position: relative !important"))
        let translationStyleCall = try XCTUnwrap(script.range(of: "ensureTranslationDisplayStyle();"))
        let layoutRepairCall = try XCTUnwrap(
            script.range(
                of: "ensureReadabilityLayoutRepairStyle();",
                range: translationStyleCall.upperBound..<script.endIndex
            )
        )
        XCTAssertLessThan(script.distance(from: translationStyleCall.upperBound, to: layoutRepairCall.lowerBound), 80)
    }

    @MainActor
    func testExtractsSegmentsAndProtectsMathAndCitations() throws {
        let html = """
        <html><body>
        <p>We show that <math><mi>x</mi></math> improves the baseline <cite>[1]</cite> in a controlled setting.</p>
        <p class="rp-translation-block" data-rp-translation="true">Already translated.</p>
        </body></html>
        """
        let candidates = try HTMLTranslationPipeline.extractCandidates(from: html)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].sourceText.contains("[PROTECTED_0]"))
        XCTAssertTrue(candidates[0].sourceText.contains("[PROTECTED_1]"))
        XCTAssertEqual(candidates[0].protectedFragments.count, 2)
    }

    @MainActor
    func testFormulaOnlyBlocksAreNotTranslationCandidates() throws {
        let html = #"""
        <html><body>
        <p>\[a_{t+1} \sim \pi_{\theta}(\cdot \mid \mathcal{H}_{&lt;t}, o_t)\]</p>
        <p>$$x^2 + y^2 = z^2$$</p>
        <p>\begin{align*} f(x) &amp;= x^2 \\ g(x) &amp;= x^3 \end{align*}</p>
        <p><math><mi>x</mi><mo>=</mo><mn>1</mn></math> (1)</p>
        <p>The agent \(\pi_{\theta}\) produces an action \(a_t\) every turn.</p>
        </body></html>
        """#
        let candidates = try HTMLTranslationPipeline.extractCandidates(from: html)
        XCTAssertEqual(candidates.map(\.sourceText), [#"The agent \(\pi_{\theta}\) produces an action \(a_t\) every turn."#])
    }

    @MainActor
    func testCandidatesCarrySectionAndNeighborContext() throws {
        let html = """
        <html><body>
        <h2>Methods</h2>
        <p>The previous paragraph is long enough to be translated.</p>
        <p>The current paragraph is also long enough to be translated.</p>
        <p>The next paragraph is long enough to be translated.</p>
        </body></html>
        """

        let candidates = try HTMLTranslationPipeline.extractCandidates(from: html)

        XCTAssertEqual(candidates.count, 4)
        XCTAssertNil(candidates[0].sectionTitle)
        XCTAssertEqual(candidates[1].sectionTitle, "Methods")
        XCTAssertEqual(candidates[2].sectionTitle, "Methods")
        XCTAssertEqual(candidates[2].previousSourceText, candidates[1].sourceText)
        XCTAssertEqual(candidates[2].nextSourceText, candidates[3].sourceText)
    }

    func testAcademicPromptEnforcesFaithfulTranslationAndCarriesContext() {
        let systemPrompt = AcademicTranslationPrompt.systemPrompt(targetLanguage: "zh-CN")
        XCTAssertTrue(systemPrompt.contains("into zh-CN"))
        XCTAssertTrue(systemPrompt.contains("faithful"))
        XCTAssertTrue(systemPrompt.contains("Do not omit, summarize, simplify, expand"))
        XCTAssertTrue(systemPrompt.contains("keep terms, abbreviations, symbols, and named concepts consistent"))
        XCTAssertTrue(systemPrompt.contains("[BABELDOC_FORMULA_1]"))
        XCTAssertTrue(systemPrompt.contains("every placeholder token in the source appears exactly once"))
        XCTAssertTrue(systemPrompt.contains("Output only the translation"))

        let userPrompt = AcademicTranslationPrompt.userPrompt(
            sourceText: "Current source",
            context: AcademicTranslationContext(
                documentTitle: "Context Paper",
                sectionTitle: "Methods",
                previousSegment: "Previous source",
                nextSegment: "Next source",
                glossary: "attention = 注意力"
            )
        )
        XCTAssertTrue(userPrompt.contains("<<<DOCUMENT_TITLE>>>\nContext Paper"))
        XCTAssertTrue(userPrompt.contains("<<<SECTION_TITLE>>>\nMethods"))
        XCTAssertTrue(userPrompt.contains("<<<PREVIOUS_SEGMENT>>>\nPrevious source"))
        XCTAssertTrue(userPrompt.contains("<<<NEXT_SEGMENT>>>\nNext source"))
        XCTAssertTrue(userPrompt.contains("<<<OPTIONAL_GLOSSARY>>>\nattention = 注意力"))
        XCTAssertTrue(userPrompt.contains("<<<SOURCE_SEGMENT_TO_TRANSLATE>>>\nCurrent source"))
    }

    func testPromptVersionAndAPIStyleArePartOfRouteCacheIdentity() {
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "paper-model")
        XCTAssertTrue(route.translationCacheIdentity.contains("prompt=\(AcademicTranslationPrompt.version)"))
        XCTAssertTrue(route.translationCacheIdentity.contains("api=chat-completions"))
    }

    @MainActor
    func testAppliesTranslationBlocks() throws {
        let html = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)
        let output = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: [prepared.candidates[0].segmentID: "Translated paragraph."]
        )
        XCTAssertTrue(output.contains("rp-translation-block"))
        XCTAssertTrue(output.contains("Translated paragraph."))
    }

    @MainActor
    func testTitleTranslationBlocksResetCrampedHeadingLayout() throws {
        let html = """
        <html>
        <head>
        <style>h1 { line-height: 0.7; max-height: 1em; overflow: hidden; }</style>
        <style id="rp-translation-display-style">.rp-translation-block { color: red; }</style>
        </head>
        <body>
        <h1>A title that will wrap after translation</h1>
        </body>
        </html>
        """
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)
        let candidate = try XCTUnwrap(prepared.candidates.first)
        let output = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: [
                candidate.segmentID: "这是一个会在阅读器中换行的中文标题译文，用来验证标题译文不会上下重叠。"
            ]
        )

        XCTAssertTrue(output.contains("<h1 class=\"rp-translation-block\""))
        XCTAssertTrue(output.contains(".rp-translation-block:is(h1, h2, h3, h4, h5, h6)"))
        XCTAssertTrue(output.contains(".rp-readability-content [data-rp-source='true'] + .rp-translation-block"))
        XCTAssertTrue(output.contains("font-size: inherit !important"))
        XCTAssertTrue(output.contains("margin-left: 0 !important"))
        XCTAssertTrue(output.contains("line-height: 1.45 !important"))
        XCTAssertTrue(output.contains("max-height: none !important"))
        XCTAssertFalse(output.contains("color: red"))
    }

    @MainActor
    func testNestedListParagraphsDoNotCreateParentListCandidates() throws {
        let html = """
        <html><body>
        <ul>
        <li><p>Nested list paragraph that should be translated once only.</p></li>
        <li>Plain list item that still needs its own translation.</li>
        </ul>
        </body></html>
        """
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)

        XCTAssertEqual(prepared.candidates.count, 2)
        XCTAssertEqual(prepared.candidates.map(\.tagName), ["p", "li"])

        let preparedDocument = try SwiftSoup.parse(prepared.preparedHTML)
        let items = try preparedDocument.select("li").array()
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].hasAttr("data-rp-source"))
        XCTAssertNotNil(try items[0].select("p[data-rp-source=true]").first())
        XCTAssertTrue(items[1].hasAttr("data-rp-source"))

        let translations = Dictionary(uniqueKeysWithValues: prepared.candidates.enumerated().map { index, candidate in
            (candidate.segmentID, "Translated block \(index).")
        })
        let output = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: translations
        )
        let translatedBlocks = try SwiftSoup.parse(output).select("body .rp-translation-block").array()
        XCTAssertEqual(translatedBlocks.count, 2)
        XCTAssertEqual(translatedBlocks.map { $0.tagName() }, ["p", "li"])
    }

    @MainActor
    func testPrepareDocumentClearsStaleSourceMarkersFromSkippedContainers() throws {
        let html = """
        <html><body>
        <ul>
        <li data-rp-segment-id="old-li" data-rp-source="true">
            <p data-rp-segment-id="old-p" data-rp-source="true">Nested paragraph with stale markers should keep only paragraph source markers.</p>
            <p class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="old-p">Old nested translation.</p>
        </li>
        <li class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="old-li">Old parent translation.</li>
        </ul>
        </body></html>
        """
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)
        let preparedDocument = try SwiftSoup.parse(prepared.preparedHTML)

        XCTAssertNil(try preparedDocument.select(".rp-translation-block").first())
        XCTAssertNil(try preparedDocument.select("li[data-rp-source=true]").first())
        XCTAssertNotNil(try preparedDocument.select("li p[data-rp-source=true]").first())
        XCTAssertFalse(prepared.preparedHTML.contains("old-li"))
        XCTAssertFalse(prepared.preparedHTML.contains("old-p"))
    }

    @MainActor
    func testTranslateHTMLUsesCacheOnlyWhenRouteMatches() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }

        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)

        let prepared = try HTMLTranslationPipeline.prepareDocument(sourceHTML)
        let candidate = try XCTUnwrap(prepared.candidates.first)
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "cached-model")

        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Cached translation.",
            providerProfileID: route.providerProfileID,
            modelProfileID: route.modelProfileID,
            modelName: route.translationCacheIdentity
        ))
        try environment.modelContext.save()

        let client = MockTranslationLLMClient(translatedText: "Fresh translation.")
        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 2,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: route,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("Cached translation."))
        let cacheHitCallCount = await client.currentCallCount()
        XCTAssertEqual(cacheHitCallCount, 0)
    }

    @MainActor
    func testTranslateHTMLSkipsCacheWhenModelRouteChanges() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }

        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)

        let prepared = try HTMLTranslationPipeline.prepareDocument(sourceHTML)
        let candidate = try XCTUnwrap(prepared.candidates.first)
        let cachedRoute = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "cached-model")
        let activeRoute = makeRoute(modelID: UUID(), providerID: cachedRoute.providerProfileID, modelName: "fresh-model")

        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Old translation.",
            providerProfileID: cachedRoute.providerProfileID,
            modelProfileID: cachedRoute.modelProfileID,
            modelName: cachedRoute.translationCacheIdentity
        ))
        try environment.modelContext.save()

        let client = MockTranslationLLMClient(translatedText: "Fresh translation.")
        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 2,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: activeRoute,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("Fresh translation."))
        let cacheMissCallCount = await client.currentCallCount()
        XCTAssertEqual(cacheMissCallCount, 1)

        let storedSegments = try environment.modelContext.fetch(FetchDescriptor<TranslationSegment>())
        XCTAssertEqual(storedSegments.count, 2)
        XCTAssertTrue(storedSegments.contains(where: { $0.modelProfileID == activeRoute.modelProfileID }))
    }

    @MainActor
    func testTranslateHTMLSkipsCacheWhenReasoningConfigurationChanges() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }

        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)

        let candidate = try XCTUnwrap(HTMLTranslationPipeline.prepareDocument(sourceHTML).candidates.first)
        let modelID = UUID()
        let providerID = UUID()
        let cachedRoute = makeRoute(
            modelID: modelID,
            providerID: providerID,
            modelName: "deepseek-v4-pro"
        )
        var activeRoute = cachedRoute
        activeRoute.thinkingMode = .enabled
        activeRoute.reasoningEffort = .max

        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Old translation.",
            providerProfileID: cachedRoute.providerProfileID,
            modelProfileID: cachedRoute.modelProfileID,
            modelName: cachedRoute.translationCacheIdentity
        ))
        try environment.modelContext.save()

        let client = MockTranslationLLMClient(translatedText: "Reasoned translation.")
        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 2,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: activeRoute,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("Reasoned translation."))
        let callCount = await client.currentCallCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testTranslateHTMLPassesDocumentSectionNeighborsAndGlossary() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let sourceHTML = """
        <html><body>
        <h2>Methods</h2>
        <p>The previous paragraph is long enough to be translated.</p>
        <p>The current paragraph is long enough to be translated.</p>
        <p>The next paragraph is long enough to be translated.</p>
        </body></html>
        """
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let client = MockTranslationLLMClient(translatedText: "译文")

        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24",
                translationGlossary: "attention = 注意力"
            ),
            route: makeRoute(modelID: UUID(), providerID: UUID(), modelName: "paper-model"),
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let requests = await client.currentRequests()
        let current = try XCTUnwrap(requests.first(where: {
            $0.text.contains("current paragraph")
        }))
        XCTAssertEqual(current.context.documentTitle, "Pipeline Test")
        XCTAssertEqual(current.context.sectionTitle, "Methods")
        XCTAssertEqual(
            current.context.previousSegment,
            "The previous paragraph is long enough to be translated."
        )
        XCTAssertEqual(
            current.context.nextSegment,
            "The next paragraph is long enough to be translated."
        )
        XCTAssertEqual(current.context.glossary, "attention = 注意力")
    }

    @MainActor
    func testGlossaryChangeInvalidatesHTMLTranslationCache() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let candidate = try XCTUnwrap(HTMLTranslationPipeline.prepareDocument(sourceHTML).candidates.first)
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "paper-model")
        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Old glossary translation.",
            providerProfileID: route.providerProfileID,
            modelProfileID: route.modelProfileID,
            modelName: route.translationCacheIdentity
        ))
        try environment.modelContext.save()
        let client = MockTranslationLLMClient(translatedText: "New glossary translation.")

        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24",
                translationGlossary: "model = 模型"
            ),
            route: route,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let callCount = await client.currentCallCount()
        XCTAssertEqual(callCount, 1)
        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("New glossary translation."))
    }

    @MainActor
    func testPromptVersionChangeInvalidatesLegacyHTMLTranslationCache() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let candidate = try XCTUnwrap(HTMLTranslationPipeline.prepareDocument(sourceHTML).candidates.first)
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "paper-model")
        let legacyCacheIdentity = route.translationCacheIdentity.replacingOccurrences(
            of: "|prompt=\(AcademicTranslationPrompt.version)",
            with: ""
        )
        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Legacy prompt translation.",
            providerProfileID: route.providerProfileID,
            modelProfileID: route.modelProfileID,
            modelName: legacyCacheIdentity
        ))
        try environment.modelContext.save()
        let client = MockTranslationLLMClient(translatedText: "Versioned prompt translation.")

        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: route,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let callCount = await client.currentCallCount()
        XCTAssertEqual(callCount, 1)
        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("Versioned prompt translation."))
    }

    @MainActor
    func testTranslateHTMLRetriesEchoedPromptWithoutNeighborContext() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let sourceHTML = """
        <html><body>
        <p>The first paragraph describes the scribal school and its many surviving exercises.</p>
        <p>The second paragraph explains how the empire shaped the curriculum of future elites.</p>
        </body></html>
        """
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let candidates = try HTMLTranslationPipeline.prepareDocument(sourceHTML).candidates
        XCTAssertEqual(candidates.count, 2)
        let echoedPrompt = AcademicTranslationPrompt.userPrompt(
            sourceText: candidates[0].sourceText,
            context: candidates[0].translationContext(documentTitle: "Pipeline Test", glossary: nil)
        )
        let client = MockTranslationLLMClient(responses: [echoedPrompt, "可靠的译文。"])
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "unstable-model")

        let outcome = try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: route,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        XCTAssertEqual(outcome.failedSegments, 0)
        let requests = await client.currentRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotNil(requests[0].context.nextSegment)
        XCTAssertNil(requests[1].context.nextSegment)
        XCTAssertNil(requests[1].context.previousSegment)
        XCTAssertEqual(requests[1].context.documentTitle, "Pipeline Test")

        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertFalse(translatedHTML.contains("SOURCE_SEGMENT_TO_TRANSLATE"))
        let cachedTexts = try environment.modelContext.fetch(FetchDescriptor<TranslationSegment>()).map(\.translatedText)
        XCTAssertEqual(cachedTexts, ["可靠的译文。", "可靠的译文。"])
    }

    @MainActor
    func testTranslateHTMLSkipsAndDoesNotCacheSegmentsThatKeepEchoing() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let source = "This paragraph keeps coming back from the model without any translation at all."
        let sourceHTML = "<html><body><p>\(source)</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let client = MockTranslationLLMClient(translatedText: source)
        var progressUpdates: [Int] = []

        let outcome = try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: makeRoute(modelID: UUID(), providerID: UUID(), modelName: "unstable-model"),
            apiKey: "sk-test",
            modelContext: environment.modelContext,
            onProgressUpdated: { processed, _ in progressUpdates.append(processed) }
        )

        XCTAssertEqual(outcome.failedSegments, 1)
        let callCount = await client.currentCallCount()
        XCTAssertEqual(callCount, TranslationOutputValidator.maximumAttempts)
        XCTAssertEqual(progressUpdates.last, 1)
        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertFalse(translatedHTML.contains("data-rp-translation=\"true\""))
        XCTAssertTrue(try environment.modelContext.fetch(FetchDescriptor<TranslationSegment>()).isEmpty)
        let job = try XCTUnwrap(environment.modelContext.fetch(FetchDescriptor<TranslationJob>()).first)
        XCTAssertEqual(job.state, .completed)
        XCTAssertNotNil(job.lastError)
    }

    @MainActor
    func testTranslateHTMLPurgesCachedPromptEchoAndRetranslates() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let candidate = try XCTUnwrap(HTMLTranslationPipeline.prepareDocument(sourceHTML).candidates.first)
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "cached-model")
        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: AcademicTranslationPrompt.userPrompt(
                sourceText: candidate.sourceText,
                context: AcademicTranslationContext(documentTitle: "Pipeline Test")
            ),
            providerProfileID: route.providerProfileID,
            modelProfileID: route.modelProfileID,
            modelName: route.translationCacheIdentity
        ))
        try environment.modelContext.save()
        let client = MockTranslationLLMClient(translatedText: "新的译文。")

        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: route,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let callCount = await client.currentCallCount()
        XCTAssertEqual(callCount, 1)
        let cachedTexts = try environment.modelContext.fetch(FetchDescriptor<TranslationSegment>()).map(\.translatedText)
        XCTAssertEqual(cachedTexts, ["新的译文。"])
        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("新的译文。"))
        XCTAssertFalse(translatedHTML.contains("DOCUMENT_TITLE"))
    }

    @MainActor
    private func makeEnvironment() throws -> HTMLPipelineTestEnvironment {
        let schema = Schema([
            Paper.self,
            PaperAttachment.self,
            TranslationSegment.self,
            TranslationJob.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let paper = Paper(title: "Pipeline Test")
        let htmlURL = rootURL.appendingPathComponent("paper.html")
        let attachment = PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .generated,
            filename: "paper.html",
            filePath: htmlURL.path
        )

        modelContext.insert(paper)
        modelContext.insert(attachment)
        try modelContext.save()

        return HTMLPipelineTestEnvironment(
            rootURL: rootURL,
            modelContext: modelContext,
            paper: paper,
            attachment: attachment
        )
    }

    private func makeRoute(modelID: UUID, providerID: UUID, modelName: String) -> LLMModelRouteSnapshot {
        LLMModelRouteSnapshot(
            providerProfileID: providerID,
            providerName: "Provider",
            modelProfileID: modelID,
            modelProfileName: "Model",
            baseURL: "https://api.example.test/v1",
            apiKeyRef: "provider-ref",
            modelName: modelName,
            temperature: nil,
            topP: nil,
            maxTokens: nil
        )
    }
}

private struct HTMLPipelineTestEnvironment {
    let rootURL: URL
    let modelContext: ModelContext
    let paper: Paper
    let attachment: PaperAttachment
}

@MainActor
private final class HTMLLayoutNavigationObserver: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) {
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}

private actor MockTranslationLLMClient: TranslationLLMClientProtocol {
    struct Request: Sendable {
        let text: String
        let context: AcademicTranslationContext
    }

    /// Returned in order; the last response repeats once the list is exhausted.
    let responses: [String]
    private(set) var callCount = 0
    private(set) var requests: [Request] = []

    init(translatedText: String) {
        self.responses = [translatedText]
    }

    init(responses: [String]) {
        self.responses = responses
    }

    func translate(
        _ text: String,
        targetLanguage _: String,
        route _: LLMModelRouteSnapshot,
        apiKey _: String,
        context: AcademicTranslationContext
    ) async throws -> String {
        callCount += 1
        requests.append(.init(text: text, context: context))
        return responses[min(callCount, responses.count) - 1]
    }

    func currentCallCount() -> Int {
        callCount
    }

    func currentRequests() -> [Request] {
        requests
    }
}
