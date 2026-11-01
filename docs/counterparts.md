# 原生与跨平台版的对应关系

原生 Freddie（本仓库）与跨平台版 `../FreddieGeneral`（Electron）实现同一套功能，很多改动要在两边一起做。本表列出两边对应的文件，用于改完一边后对照检查另一边是否要跟着改；功能层面“移植了什么”见 `../FreddieGeneral/docs/SWIFT_PARITY.md`。

原生路径相对本仓库根，Electron 路径相对 `../FreddieGeneral` 仓库根。

用法：按改动的文件找到所在行，打开对应文件，按“一致性”判断是否要改。确定不改时，把原因写进提交说明或下面的“已知差异”。

一致性分四级：

- **逐字节**：两端写出的文件或字符串必须完全相同，否则同步互相重传、缓存不命中或锚点失效。
- **同一格式**：对方能读懂并原样保留的数据或协议，字段和规则一致即可。
- **同一行为**：用户可见的规则、判断和结果一致，实现方式可以不同。
- **界面对应**：同一入口、同样的状态和文案，布局按平台习惯。

## 数据与存储

| 模块 | 原生 | Electron | 一致性 |
|---|---|---|---|
| 论文库同步 | `ReadPaper/Services/LibrarySync/`，`docs/sync.md` | `electron/main/sync/`，`tests/fixtures/sync/swift-documents.json` | 逐字节（键排序、UUID 大写、毫秒日期、Swift `Double` 格式）；另见 `../freddie-sync-server` |
| 翻译缓存 | `ReadPaper/Models/TranslationSegment.swift`，`LLMModelRouteSnapshot.translationCacheIdentity` | `electron/main/translationSegments.ts` | 逐字节（缓存身份字符串，同一模型两端互相命中） |
| PDF 批注 | `ReadPaper/Services/PDFAnnotationStore.swift` | `electron/main/annotations.ts`，`shared/pdfAnnotationGeometry.ts` | 同一格式（`notes/pdf-annotations-{附件UUID}.json`，PDF 页面坐标，ISO8601 到秒） |
| 写作稿与引用 | `ReadPaper/Services/WritingStore.swift`，`ReadPaper/Services/WritingLibrary.swift`，`ReadPaper/Services/WritingMarkdown.swift`，`ReadPaper/Services/PaperCitation.swift` | `electron/main/writings.ts`，`shared/writing.ts` | 同一格式（`Writings/{UUID}/writing.md`、`meta.json`、`assets/`，`readpaper://` 引用链接） |
| 论文目录布局 | `ReadPaper/Services/PaperFileStore.swift` | `electron/main/store.ts`，`electron/main/files.ts` | 同一格式（`Library/{UUID}`、`Resources/`、`translations/`、`notes/`） |
| 数据模型 / schema | `ReadPaper/Models/*.swift`（SwiftData） | `electron/main/nativeLibrary.ts`（直接读 `ReadPaper.store` 导入原生库），`electron/main/store.ts`（`library.json` 迁移） | 同一格式：原生改字段要确认 `nativeLibrary.ts` 仍能读，Electron 加字段走单调迁移 |
| 文献类型、筛选 | `ReadPaper/Models/PaperItemType.swift`，`ReadPaper/Services/PaperItemTypeService.swift`，`ReadPaper/Services/PaperLibraryFilter.swift` | `shared/library.ts` | 同一行为（Zotero 标识符、按来源推断类型） |
| 阅读器目录缓存 | `ReadPaper/Services/DocumentOutlineService.swift`，`ReadPaper/Models/DocumentOutline.swift` | `electron/main/documentOutline.ts`，`electron/main/outlineExtraction.ts`，`shared/outline.ts` | 同一行为；改提取规则时两边都递增 `algorithmVersion` |
| HTML 笔记锚点 | `ReadPaper/Readers/HTMLReaderView.swift`（instrumentation），`ReadPaper/Services/HTMLRegionVisibility.swift`（`HTMLAnchorPath`） | `src/readers/htmlAnchors.ts` | 逐字节（`rp-anchor:` 路径，跳过 `.rp-translation-block`、`.rp-tex-math`） |
| 隐藏区域 | `ReadPaper/Services/HTMLRegionVisibility.swift`，`ReadPaper/Readers/HTMLRegionEditing.swift` | `electron/main/localizer.ts`（`applyHiddenRegions`），`src/readers/HtmlView.tsx` | 同一格式（`data-rp-region-hidden` 留在 `paper.html`） |

## LLM 与翻译

| 模块 | 原生 | Electron | 一致性 |
|---|---|---|---|
| 三种 API 协议的请求与解析 | `ReadPaper/Services/OpenAICompatibleLLMProvider.swift` | `electron/main/llm.ts`（`body`、`parseResponse`、`completeStreaming`） | 同一行为（请求字段、截断与错误判断、联网搜索来源） |
| 路由解析、缺配置错误 | `ReadPaper/Services/LLMRouteResolver.swift`，`ReadPaper/Services/LLMModelRouteSnapshot.swift` | `electron/main/llm.ts`（`resolveRoute`、`routeFor`） | 同一行为 |
| 内置 provider / model、快速配置 | `ReadPaper/Services/LLMConfigurationBootstrapper.swift`（`LLMDefaultProfiles`、`LLMQuickSetup`） | `electron/main/store.ts` | 同一格式（相同 ID） |
| HTML 段落翻译、提示词、输出校验 | `ReadPaper/Services/HTMLTranslationPipeline.swift`，`ReadPaper/Services/AcademicTranslationPrompt.swift`，`ReadPaper/Services/TranslationOutputValidator.swift`，`ReadPaper/Services/TranslationLLMClient.swift` | `electron/main/translation.ts`（`prepareHTML`、`userPrompt`、`outputIssue`、`translateSegment`） | 提示词与占位符逐字节一致（影响缓存）；校验与重试规则同一行为 |
| 摘要翻译 | `ReadPaper/Services/AbstractTranslationService.swift` | `electron/main/translation.ts`（`translateAbstract`） | 同一行为 |
| 摘要（Inspector 短摘要） | `ReadPaper/Services/PaperSummaryService.swift` | `electron/main/paperSummary.ts` | 同一行为 |
| BabelDOC PDF 翻译 | `ReadPaper/Services/BabelDocRunner.swift`，`ReadPaper/Services/BabelDocSemanticHintService.swift`，`../reWriteBabelDoc` | `BabelDocKit/`（逐文件对照见其 README），`electron/main/babeldocWorker*.ts`，`electron/main/babeldocSemanticHints.ts` | 同一行为；Swift 实现是准则 |
| arXiv LaTeX 翻译 | `ReadPaper/Services/LaTeXTranslationService.swift`，`../arxivLatex` | `LaTeXTransKit/`（逐文件对照见其 README），`electron/main/latexToolchain.ts` | 同一行为；提示词、模板、checkpoint key 一致 |
| 扫描版 PDF 翻译 | `ReadPaper/Services/ScannedPDFTranslationService.swift`，`../rebuild-pdf` | `RebuildPDFKit/`（逐文件对照见其 README） | 同一行为；Python 版是规则准则，parity fixture 要重新导出 |
| 阅读助手 | `ReadPaper/Services/SelectionAssistantService.swift`，`ReadPaper/Services/SelectionAssistantOrchestrator.swift`，`ReadPaper/Views/SelectionAssistantOverlay.swift` | `electron/main/assistant.ts`，`src/overlays/SelectionAssistant.tsx` | 提示词同一；界面对应 |

## 导入

| 模块 | 原生 | Electron | 一致性 |
|---|---|---|---|
| arXiv / PDF / 网页导入 | `ReadPaper/Services/PaperImporter.swift`，`ReadPaper/Services/ArxivClient.swift`，`ReadPaper/Services/ArxivImportProgress.swift` | `electron/main/importer.ts` | 同一行为（含进度阶段、去重规则、微信文章修复） |
| arXiv ID / DOI 识别 | `ReadPaper/Services/PaperImporter.swift`、`ReadPaper/Services/ArxivClient.swift` 中的规则 | `shared/identifiers.ts` | 同一行为（只认明确的 arXiv 上下文） |
| HTML 正文抽取与本地化 | `ReadPaper/Services/HTMLLocalizer.swift` | `electron/main/localizer.ts` | 同一格式（`rp-readability-*` 外壳、清除页面代码、UTF-8 charset） |
| 作者识别 | `ReadPaper/Services/AuthorExtractionService.swift` | `electron/main/authorExtraction.ts` | 同一行为 |
| 浏览器剪藏 | `ReadPaper/Services/BrowserClipperServer.swift`，`ReadPaper/Services/BrowserClipImporter.swift` | `electron/main/clipperServer.ts`，`electron/main/browserClip.ts`，`electron/main/importer.ts`（`importClip`） | 同一格式（端口、路由、请求检查、去重与补附件规则）；请求或响应字段变化时连同 `../freddie-clipper` |
| 文献摘录导出 | `ReadPaper/Services/PaperDigestExportPolicy.swift` | `shared/digest.ts` | 同一行为（模板与占位符） |

## 界面

| 模块 | 原生 | Electron | 一致性 |
|---|---|---|---|
| 文案 | `ReadPaper/Localizable.xcstrings` | `shared/locales/zh-Hans.json` | 新增或修改文案两边都加，英文 key 相同 |
| 阅读器工具栏、状态行、翻译菜单 | `ReadPaper/Views/ReaderPaneView.swift` | `src/main-window/ReaderPane.tsx`，`src/main-window/translationMenu.ts` | 界面对应 |
| 翻译进度胶囊 | `ReadPaper/Views/TranslationActivityCapsule.swift` | `src/overlays/TranslationCapsule.tsx` | 界面对应 |
| 双栏 PDF、滚动同步 | `ReadPaper/Readers/DualPDFReaderView.swift`，`ReadPaper/Services/DualPDFPageIndexSync.swift` | `src/readers/DualPdfView.tsx` | 同一行为（partial 译文不限制原文翻页） |
| 文内查找 | `ReadPaper/Services/DocumentTextSearch.swift` | `src/readers/find.ts` | 同一行为（空白、连字符容错） |
| HTML 目录 | `ReadPaper/Readers/HTMLDocumentOutline.swift` | `src/readers/htmlOutline.ts` | 同一行为 |
| 设置页 | `ReadPaper/Views/SettingsView.swift`，`ReadPaper/Views/LibrarySyncSettingsView.swift` | `src/settings/SettingsWindow.tsx` | 界面对应（同样的页签和表单） |
| 侧边栏、文件夹 | `ReadPaper/Views/LibrarySidebarView.swift`，`ReadPaper/Services/PaperFolderService.swift` | `src/main-window/LibrarySidebar.tsx` | 界面对应 |
| Inspector | `ReadPaper/Views/InspectorPaneView.swift` | `src/main-window/Inspector.tsx` | 界面对应 |
| 写作编辑器 | `ReadPaper/Services/MarkdownLiveSyntax.swift`，`ReadPaper/Views/WritingEditorView.swift`，`ReadPaper/Views/WritingPaneView.swift` | `src/writing/liveMarkdown.ts`，`src/writing/WritingEditor.tsx`，`src/writing/WritingPane.tsx` | 语法规则同一行为；界面对应 |
| 引用链接打开 | `ReadPaper/Views/PaperLinkRouter.swift` | `electron/main/index.ts` | 同一格式（`readpaper://` / `freddie-general://`，见 AGENTS.md） |

## 其他仓库

| 仓库 | 牵涉 |
|---|---|
| `../freddie-clipper` | 剪藏请求格式、响应字段（`openURL` 等） |
| `../freddie-sync-server` | 同步协议、凭证格式、payload（协议说明在其 README） |
| `../arxivLatex` | Swift `LaTeXTransKit`，对应 `FreddieGeneral/LaTeXTransKit/` |
| `../rebuild-pdf` | Python 参照实现 → Swift `RebuildPDFKit` → `FreddieGeneral/RebuildPDFKit/` |
| `../reWriteBabelDoc` | 原生 BabelDOC，对应 `FreddieGeneral/BabelDocKit/` |

## Electron 暂无对应

- `PDFTextLayerInspector`：Electron 不检查文字层，“翻译扫描版 PDF”在有 PDF 时总是可用，“翻译 PDF”也不会因扫描件禁用。
- `HTMLTeXRendering`（Temml）、阅读器里的划词助手历史标记、设置页的联网搜索 trace 面板（见 `SWIFT_PARITY.md`）。

## 已知差异

- 输出 token 截断（2026-11-01）：两端的 HTML 段落和摘要翻译遇到截断都直接报错、不重试、不写缓存，并在状态行提供“模型设置…”。原生的 Responses / Anthropic 协议在所有调用方（阅读助手、LaTeX 等）都把截断当错误；Electron 只在 `translateSegment` 里处理，LaTeX、BabelDOC、阅读助手仍接受截断的文本。两端的 LaTeX 路径对 Chat Completions 截断都不报错，由 LaTeXTransKit 按单元重试，最后报“未完成单元”。
