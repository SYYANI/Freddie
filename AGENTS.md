# AGENTS.md

本文件适用于整个仓库。后续 agent 在本项目中工作时，优先遵守这里的项目约定，再结合具体任务做最小必要改动。

## 项目概览

ReadPaper 是一个 macOS SwiftUI 论文阅读应用，使用 SwiftData 做本地数据模型，PDFKit 处理本地 PDF 轻量文本抽取，`swift-readability` 处理 arXiv/ar5iv HTML 正文抽取，SwiftSoup 处理 HTML 本地化和 HTML 段落翻译。项目最低 macOS 版本为 14.0，Swift 版本为 6.0，Xcode 项目由 `project.yml` 描述，依赖 SwiftSoup、`swift-readability`、`SwiftOpenAI`，以及写作编辑器排版公式用的 `iosMath`（与 `SwiftStreamingMarkdown` 固定同一 revision）；扫描版 PDF 翻译用本地路径包 `../rebuild-pdf` 的 `RebuildPDFKit`（只链接 macOS target）。

核心能力分成五条路径：

- 本地 PDF：导入 PDF，抽取 Info dictionary 和前几页文本，只用于标题、作者和 arXiv ID 等轻量识别；不要把 PDF 纯文本当成稳定全文结构。本地 PDF 里的 `arxivID` 只应在出现明确 arXiv 上下文时写入，例如 `arXiv:2303.08774` 或 `arxiv.org` / `ar5iv.labs.arxiv.org` 链接；不要把 DOI、Crossref 链接或其他编号片段误识别成 arXiv ID。若能从 PDF 正文或元信息中可靠提取 DOI，可把 DOI 作为无 arXiv 时的降级展示标识。
- arXiv 论文：通过 arXiv API 获取元数据和 PDF，优先保存 `https://arxiv.org/html/{id}`，失败后回退到 `https://ar5iv.labs.arxiv.org/html/{id}`；获取 HTML 后优先用 `swift-readability` 提炼正文，再把 HTML、CSS、图片等资源本地化，若正文抽取失败再回退到原始 HTML。通过 arXiv ID/URL 导入时，不要只给一个不透明的 loading spinner；应尽量向用户暴露当前所处阶段，例如 ID 规范化、元数据获取、PDF 下载、HTML 获取/回退、最终入库保存。
- 网页导入：输入任意 HTTP/HTTPS 网页 URL，通过 `normalizeWebPageURL` 规范化 URL（自动补齐 https、去除 fragment）。下载响应后先检查 HTTP `Content-Type`；若为 `application/pdf`，则自动路由到 PDF 导入路径：写入 `paper.pdf`、从 PDF 元数据和前几页文本提取标题/作者/arXiv ID/DOI 等轻量信息，并以 PDF 附件形式入库。其余 HTML 网页走原有流程：用 `HTMLLocalizer` 的 `swift-readability` 路径下载并提炼正文，同时本地化页面中的 CSS、图片等链接资源；若 title 元素可解析则使用提取的标题，否则依次回退到 URL path 组件和 host，最终回退到"Untitled Web Page"。通过 `WebPageImportProgress` 反馈分步骤进度（URL 校验 → 网页抓取 → 创建库条目 → 最终保存），与 arXiv 导入一样使用确定型进度条。HTML 网页内容以本地化 HTML 形式保存为 `paper.html`，与 arXiv HTML 共用同一套展示和翻译管线。导入时以 URL 去重（`htmlURLString`），不依赖 arXiv ID。
- 翻译阅读：HTML 走 SwiftSoup DOM 分段翻译并插入 `.rp-translation-block`；完整 PDF 翻译交给 App 内嵌并签名的原生 BabelDOC helper，helper 直接使用 App Resources 中按 manifest 校验的 MuPDF、zstd、原生 Core ML layout model 与字体，输出翻译 PDF 后用双栏 PDF 阅读器展示。PDF 翻译支持按页增量生成与续翻，过程中译文 PDF 可能只是覆盖前 N 页的 partial 文档；进度与阅读器状态都要显式体现这一点。
- 扫描版 PDF 翻译：没有文字层（或文字层不可靠）的 PDF 走 `RebuildPDFKit`：视觉模型把每页转写成受限 LaTeX、对照原稿校对，文本模型翻译，XeLaTeX 按原页面尺寸、版心和分栏排版，输出与原稿逐页对应的 `translatedPDF`，同样用双栏阅读器展示。它是第三条 PDF 翻译路线，与 BabelDOC、arXiv LaTeX 翻译并列，不经过 BabelDOC。

原生 BabelDOC runtime 随 App 构建，不依赖 `tools/install_readpaper_native_runtime.sh` 或 Application Support 预安装目录。修改 Xcode 构建、资源路径或发布流程时，必须保留 `Contents/Resources/BabelDOCNative`、受信 manifest 与 helper 启动前双重验证契约。

`refer.md` 是当前项目 PDF/HTML/翻译架构的设计参考，涉及结构化处理、翻译流程或展示策略时先读它。

## 常用命令

项目使用 XcodeGen 配置：

```sh
xcodegen generate
```

打开项目：

```sh
open ReadPaper.xcodeproj
```

命令行构建：

```sh
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath /tmp/read-paper-derived-data build
```

命令行测试：

```sh
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath /tmp/read-paper-derived-data test
```

窄改动只跑相关测试时，可直接指定 `-only-testing`，例如验证 BabelDOC 安装/版本解析相关改动：

```sh
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath /tmp/read-paper-derived-data -only-testing:ReadPaperTests/BabelDocToolManagerTests test
```

GitHub Actions 构建 DMG：

- 仓库已包含 [`.github/workflows/release.yml`](/Users/yiyan/Desktop/read-paper/.github/workflows/release.yml)，支持在 GitHub Actions 上构建 DMG；触发方式为手动 `workflow_dispatch` 或推送 `v*` tag。
- 当前 workflow 运行在 `macos-26`，会恢复固定 commit 的本地 `swift-readability`，并从手动输入 `babeldoc_ref` 或仓库变量 `BABELDOC_REF` 恢复完整 40 位 commit 的 `../reWriteBabelDoc`。随后下载并验证模型/字体/许可证、从固定源码构建 zstd、校验 MuPDF 与 trusted runtime manifest，再安装 `xcodegen` 和 `create-dmg` 执行无签名 Release 构建。
- CI 产物当前是 unsigned 的 `Freddie.app` 和 `Freddie-<version>-unsigned.dmg`；helper 在关闭 Xcode signing 时仍做 ad-hoc 签名以满足 App 内信任契约。artifact 同时包含记录三份源码 commit、runtime manifest hash 和版本号的 `build-provenance.txt`。tag 与手动触发都只上传 Actions artifact；在 Developer ID 签名、notarization、Corresponding Source 和完整第三方 notices 闭环前，不自动创建公开 GitHub Release。
- 后续若调整 app 名称、scheme、产物路径、签名或打包方式，要同步更新 workflow 中的 `APP_NAME`、`APP_PATH`、`DMG_PATH` 和 release 上传逻辑，避免本地可构建但 CI 打包失效。
- `project.yml` 依赖本地路径包 `../rebuild-pdf`（`RebuildPDFKit`），但该仓库还没有远端，workflow 也还没有像 `../reWriteBabelDoc` 那样检出它；在 CI 上构建前要先推送仓库，并在 workflow 里按固定 commit 检出、写入 `build-provenance.txt`。

如果沙箱或受限终端里 `xcodebuild` 因 Xcode/SwiftPM/clang 缓存目录权限失败，不要先判断为代码失败；换到可写 Xcode 缓存的环境或使用 Xcode 运行后再确认。

## 目录职责

- `ReadPaper/ReadPaperApp.swift`：应用入口和 SwiftData `modelContainer` 注册。
- `ReadPaper/Models/`：SwiftData 模型和枚举。新增模型时同步检查 `ReadPaperApp` 中的 model container。
- `ReadPaper/Localization/`：运行时本地化基础设施，如 `LanguageManager`、bundle 解析和 SwiftUI environment 注入。
- `ReadPaper/Views/`：SwiftUI 界面，包含主布局、导入面板、阅读工具栏、设置页和检查器。
- `ReadPaper/Readers/`：PDF、HTML、双语 PDF 阅读器。
- `ReadPaper/Services/`：导入、arXiv API、HTML 本地化、翻译、BabelDOC、Keychain、文件存储、子进程运行等业务服务。
- `ReadPaperTests/`：XCTest 单元测试，重点覆盖 arXiv ID/Atom 解析、文件存储、HTML 翻译管线、BabelDOC 参数、进程运行和网页导入。
- `ReadPaper/Localizable.xcstrings`：应用自有 UI、状态文案和错误文案的字符串目录，当前以英文 source string 为 key，并提供 `en` / `zh-Hans`。
- `ReadPaper/InfoPlist.xcstrings`：Info.plist 对用户可见文案的字符串目录，例如 `NSDocumentsFolderUsageDescription`。
- `project.yml`：XcodeGen 的项目源配置。调整 target、依赖、构建设置时改这里并重新生成项目。
- `.github/workflows/release.yml`：GitHub Actions 的 unsigned DMG 验证构建流程；负责恢复固定 commit 的 `swift-readability` 与 `reWriteBabelDoc`、准备并验证原生 runtime、安装 `xcodegen` 与 `create-dmg`、构建 unsigned `Freddie.app` 并上传 Actions artifact。公开 Release 仍保持关闭。
- `ReadPaper.xcodeproj/project.xcworkspace/xcuserdata/`：Xcode 用户状态。除非任务明确要求，不要编辑或整理这类文件。
- `ReadPaper.xcodeproj/project.xcworkspace/xcuserdata/yiyan.xcuserdatad/UserInterfaceState.xcuserstate`：本地 Xcode 窗口/界面状态文件，默认视为无需处理的噪音文件；不要因为它是 dirty 而额外清理、提交或回退。

## 数据与文件约定

`PaperFileStore` 把应用数据放在 Application Support 下的 `ReadPaper` 目录，库文件位于 `Library/{paper UUID}`，每篇论文目录中会创建：

- `paper.pdf`
- `paper.html`
- `Resources/`
- `translations/`
- `notes/`

SwiftData 元数据 store 也应视为该目录的一部分：当前显式落在 `~/Library/Application Support/ReadPaper/ReadPaper.store`，承载 `Paper`、`PaperAttachment`、`TranslationSegment`、`LLMProviderProfile`、`LLMModelProfile`、`AppSettings` 等模型；不要再依赖系统默认 `~/Library/Application Support/default.store`。

上次打开的论文（启动时恢复的选中项）存在独立的 UserDefaults suite `<bundle id>.window-state`（`PaperSelectionStore.lastOpenedPaperIDKey`），每次切换立即写入；`AppSettings.lastOpenedPaperID` 只在该 suite 还没有值时作为回退读取，并在退出时同步一次。不要改回每次切换都 `modelContext.save()`：每次保存都会让所有 `@Query` 重新取数，约 150 ms 后把已加载模型的属性重新发布一遍，侧边栏、阅读器和工具栏跟着重绘，Release 下约 70 ms 主线程时间。也不要写进 `UserDefaults.standard`：对标准 defaults 的任何写入都会让所有 `@AppStorage` 失效，同样重绘整个窗口。切换论文这类高频路径里避免这两类写入。

SwiftData schema 变更要特别谨慎：历史上已经出现过“新版本删改 `AppSettings` 字段并写回 `ReadPaper.store`，随后旧版 `Freddie 0.1.8 (9)` 再打开同一份 store 时，在 `ReadPaperApp.init()` 创建 `ModelContainer` 阶段直接 `fatalError` 崩溃”的问题。对于会落盘的模型字段，尤其是 `AppSettings`、`LLMProviderProfile`、`LLMModelProfile` 这类启动早期就会参与建库/开库的类型，不要只改当前代码里的 `@Model` 定义；必须同时考虑旧 store 兼容、`SchemaMigrationPlan` / `VersionedSchema`、或至少临时保留兼容字段，避免发布后出现“新库打不开旧版 / 旧版打不开新库”的双向不兼容。

`paper.html` 当前默认保存的是适合阅读和翻译的本地化 HTML；对于 arXiv/ar5iv 导入，它通常是 `swift-readability` 提炼后的正文包装页，而不是原站完整页面快照。对于网页导入，同样走 `swift-readability` 提炼正文后以本地化 HTML 保存，与 arXiv HTML 共用同一套展示和翻译管线。若网页 URL 响应的 `Content-Type` 为 `application/pdf`，则不生成 `paper.html`，而是将 PDF 数据写入 `paper.pdf` 并以 PDF 附件形式入库。改导入链路时要注意这一展示语义。

用户在阅读器里“调整区域”隐藏的内容，以 `data-rp-region-hidden="true"` 属性留在 `paper.html` 原元素上，并配一份 `#rp-region-visibility-style` 隐藏样式；元素从不删除，所以随时可恢复。

`paper.html` 必须带有正确的 `<meta charset="UTF-8">` 声明。`HTMLLocalizer.makeDocumentForLocalization` 在解析 HTML 后会通过 `reconcileCharsetDeclaration` 移除旧的 `http-equiv="content-type"` meta 标签并插入 `<meta charset="UTF-8">`，因为源 HTML 的 charset 声明（如 `ISO-8859-1`）在翻译管道注入 UTF-8 多字节文本后会导致乱码。如果在 `HTMLLocalizer` 之外重建或覆写 `paper.html`，也要确保写入 UTF-8 charset 声明。

附件通过 `PaperAttachment` 记录，类型包括 `pdf`、`html`、`translatedPDF` 和 `resource`，来源包括 `arxivPDF`、`arxivHTML`、`localImport`、`webPage`、`babeldoc`、`latexTrans`、`scanRebuild` 和 `generated`（来源以字符串落盘，旧版 App 读到不认识的来源回退为 `generated`）。`translatedPDF` 在增量翻译路径下还会用 `translatedLastPage` 表示当前已覆盖到原文的最后一页；改文件写入、合并续翻或替换译文文件时，要同时维护附件记录、`translatedLastPage` 语义和 SwiftData 保存时机。

论文库文件夹：`PaperFolder`（名称，预留 `parentID`，当前只显示一层）与 `PaperFolderMembership`（`paperID` 唯一，即一篇论文最多属于一个文件夹）。归属关系刻意不放进 `Paper`：移动论文不改 `Paper` schema，也不改按 `modifiedAt` 排序的列表顺序。删除文件夹只删归属记录，论文回到“未归档”；`PaperDeletionService` 删除论文时一并删除其归属记录；指向已不存在文件夹的归属按未归档处理。侧边栏分组统一走 `PaperLibraryGrouping`（文件夹按名称排序，组内沿用库顺序），删除论文后的下一个选中项也按它的显示顺序计算。文件夹折叠状态是视图状态，存 UserDefaults（`LibraryFolderExpansion`），不进 SwiftData。旧版 App 打开含文件夹的 store 能正常打开，但会丢弃两张文件夹表。论文拖到文件夹使用自定义 UTType `com.yiyan.ReadPaper.paper-reference`（已在 `Info.plist` 声明），不要改成文件 URL，否则会被整窗 PDF 拖入遮罩截走。侧边栏工具栏在最小宽度下只放得下“添加论文”和“删除论文”两个按钮，“新建文件夹”放在 File 菜单（⇧⌘N）和列表右键菜单里，不要再往侧边栏工具栏加按钮。

侧边栏筛选：列表底部的筛选条（漏斗菜单 + `可见数 / 总数` + 清除按钮）是论文库新增操作的位置，不受顶部工具栏宽度限制。条件由 `PaperLibraryFilter` 定义（已收藏 / 有译文 / 有笔记，多选取交集），只是 `ContentView` 的 `@State`，不持久化，重启后总是显示完整论文库。筛选走 `PaperLibraryGrouping.filtered`：保留全部文件夹（“移到文件夹”菜单照常列出），筛选时隐藏没有可见论文的文件夹和空的“未归档”；当前打开的论文即使不再匹配也留在列表里；删除后的下一个选中项按筛选后的显示顺序计算。“有译文”= 有 `translatedPDF` 附件或有 `sourceType == "html"` 的 `TranslationSegment`，后者按需 fetch（只取 `paperID`），不要改成 `@Query`，否则 HTML 翻译每写一段缓存都会重绘整个窗口。收藏通过论文右键菜单切换，不更新 `modifiedAt`，避免打乱列表顺序。侧边栏每一行的 `.contextMenu` 内容不是右键时才构建，而是每次行刷新都会对所有已实现的行求值。`LibrarySidebarView` 和每一行（`LibraryPaperRow`）都是 `Equatable` 并通过 `.equatable()` 使用：侧边栏按对象身份比较论文、分组、文献类型、选中项和筛选条件，行比较论文、所在文件夹和“移到文件夹”的文件夹列表，所以 `ContentView` 为别的原因刷新时（例如打开 Inspector、SwiftData 保存后重新发布模型）整个侧边栏跳过，选中项变化时只更新列表、各行不重建菜单。闭包不参与比较，只能触达比视图值活得更久的状态（`@State`、binding、model context、`ContentView` 的方法）；给侧边栏或行新增影响显示的输入时，要同步更新 `==`。曾经在行菜单里放 37 项的文献类型子菜单，导致每次刷新从约 7 ms 涨到约 37 ms（Debug，106 篇），打开 Inspector 明显卡顿。行菜单只放轻量操作，不要再加入大型或随数据增长的子菜单；单篇论文的元数据编辑放到 Inspector。底部筛选菜单的内容同样每次刷新都会求值，里面的计算要保持轻量。筛选菜单另有“文献类型”一节（`PaperLibraryFilter.itemTypes`，类型之间取并集，再与上面的条件取交集），只列出库里实际出现的类型并带数量。

文献类型：`PaperItemType` 的 raw value 直接用 Zotero item type 标识符（`journalArticle`、`conferencePaper`、`preprint` 等共 37 种），中文名沿用 Zotero 简体中文译名，以后做引用导出或 Zotero 互通时直接映射，不要改成自定义值。类型默认由 `PaperItemTypeResolution` 按导入来源推断（有 `arxivID` → 预印本；有 `webPage` 来源的 HTML 附件 → 网页；其余包括带 DOI 的 PDF → 文档，DOI 本身分不出期刊还是会议，不要据此猜测），不落盘；只有用户在 Inspector 标题上方的类型菜单（`PaperItemTypePicker`）里手动选的类型才写入 `PaperItemTypeAssignment`（按 `paperID` 唯一，和文件夹归属一样不放进 `Paper`、不改 `modifiedAt`）。选回推断类型或“使用自动识别的类型”会删除记录，所以以后改进推断（例如查 Crossref）会自动作用到没有手动指定的论文。无法识别的 raw value（更新版本写入的类型）回退到推断类型。`PaperDeletionService` 删除论文时一并删除该记录；旧版 App 打开新 store 会丢弃这张表。

写作稿（Inspector 的“写作”页，或大屏用的独立写作窗口）：跨论文的长篇 Markdown 笔记，与锚定在原文上的 `Note` 旁注并存。正文存为 `Application Support/ReadPaper/Writings/{writing UUID}/writing.md`，图片复制进同目录的 `assets/` 并以相对路径引用（文件名只留字母数字、其余改成连字符，Markdown 里不用转义），整个文件夹在 Typora/Obsidian 里能直接带图打开。`meta.json` 只缓存标题（第一行可见文字；“更多”菜单的“重命名…”由 `WritingTitle.renaming` 改写这一行：是标题行就保留级别换掉文字，否则在最前面插入 `# 新标题`，原来的第一行留作正文）、时间、字数、引用到的 paperID，以及每条引用和它所引的原文段落（`citations`，供阅读器标记被引段落），缺失或比 `writing.md` 旧时从正文重建；旧版写回的 `meta.json` 没有 `citations` 键，此时也从正文重建；`version` 更高的元数据只读不覆盖。刻意不进 SwiftData：旧版 App 打开新 store 会丢弃不认识的表，写作稿不能跟着丢；也不放进 `Library/{paper UUID}/`，删论文不删写作稿，正文里的引用只是失效（删除确认里会提示）。列表由 `WritingLibrary` 提供（`@Observable`，不要改成 `@Query`，否则每次保存都会重绘整个窗口）；`WritingDocument` 在停止输入约 0.8 秒后写盘，关闭/切换编辑器、App 失去焦点和退出前立即落盘；删除写作稿移到废纸篓。当前打开的写作稿 ID 与 Inspector 页签存 UserDefaults。Inspector 最大宽度为 640，给写作留出空间。独立写作窗口是 `Window` scene（`WritingWindowScene.id`，出现在“窗口”菜单，也可从写作页标题栏的窗口按钮打开），显示的就是当前写作稿，正文列宽上限 700 居中；窗口背景与主窗口阅读区一致（默认外观用 `ReadPaperReaderMaterialSurface` 玻璃加 `ReadPaperWindowChrome`，纸张外观用纸面），写作稿切换菜单和新建/更多按钮放在标题栏的 SwiftUI toolbar 里、隐藏窗口标题，所以 Inspector 版的标题行只在 Inspector 显示。不要去掉这个 toolbar：没有 toolbar 的 `Window` scene 会被 SwiftUI 把 `titlebarAppearsTransparent` 重置回 false，标题栏又变成盖在玻璃上的白条；窗口打开期间 Inspector 的写作页只显示占位（“显示窗口 / 移回这里”），同一写作稿任何时候只有一个编辑器。`WritingWindowState.isOpen` 以 `onAppear` 和窗口自己的 `willClose` 通知为准，`onDisappear` 只在窗口确实不可见时才算关闭。新建写作稿（空状态和标题栏按钮、File 菜单、论文页的“关于这篇论文的新写作稿”）总是打开独立写作窗口，光标落在编辑器里（窗口还没出现时由 `WritingWindowState.focusEditorWhenShown` 等 `onAppear` 再聚焦）；窗口打开时，从论文页打开写作稿和“在写作稿中显示引用”也转到窗口；“引用到写作稿”照常插入当前写作稿，也就是窗口里那一篇。

引用格式：`[Vaswani et al., 2017, p. 2](readpaper://paper/{paperID}?att={attachmentID}&p={从 1 开始的页码}&anchor={rp-anchor 路径} "引文开头")`。链接目标只含 ASCII：中文与 `%20` 这类转义混排时，`URL(string:)` 和 JS 的 `encodeURI` 都会把 `%` 再编码一次；引文开头（`PaperCitation.quotePrefixLength` 个字符）放在链接 title 里，其他 Markdown 应用显示为提示，解析时兼容旧的 `q=` 参数。划词浮层的“引用到写作稿”（菜单 ⇧⌘E）在光标所在段落之后插入引用块和署名链接，按住 ⌥ 只在光标处插入链接；目标是“写作”页当前打开的写作稿，没有就新建。点击引用时，紧跟在引用块下的署名行用整段引文定位，否则用 title 里的开头。`PaperCitation.navigationRequest` 带 `paperID`：`ContentView` 换论文时保留指向新论文的请求，`ReaderPaneView` 在恢复新论文的阅读位置之后再跳转。

`readpaper://` 已在 `Info.plist` 注册：导出到 Obsidian/Typora 的写作稿里的引用点开会回到 App。App delegate 在 `applicationWillFinishLaunching` 自己接管 `kAEGetURL`，不要改回 SwiftUI 的 `onOpenURL` / `application(_:open:)`：SwiftUI 会为每个链接再开一个主窗口，链接启动 App 时还会多开一个。外部链接和独立写作窗口里点的引用都交给 `PaperLinkRouter`：它按 `NSApp.orderedWindows` 选最前面的主窗口（`ContentView` 用 `HostingWindowReader` 登记），通过 `delivery` 交给该窗口的 `openCitation`；外部链接会激活 App，写作窗口的引用只在写作窗口挡住主窗口时才把主窗口提到前面。没有主窗口时先用视图留下的 `openMainWindow`（主 `WindowGroup` 的 id 是 `MainWindowScene.id`），1 秒后仍没有主窗口登记（链接启动 App 时 macOS 发的是 GURL 而不是“打开应用”事件，SwiftUI 不会开启动窗口）就给自己发一个 reopen Apple Event，相当于点 Dock 图标。外部链接不带 title，所以只按页码/锚点定位，不高亮引文。被引论文已不在库里时提示“无法打开引用”。

被引段落标记：阅读器把写作稿引用过的段落用紫色下划线标出（HTML 用 CSS Custom Highlight API 的 `rp-citation`，PDF 用当前页前后各一页的内存临时 underline `PDFAnnotation`，和划词助手历史下划线同一套做法，不写进 `paper.html` 或 PDF）。数据来自 `WritingLibrary.citationMarksByPaper`：只在引用本身变化时才替换（按写作稿 ID 和序号排序，保存把写作稿移到列表最前也不算变化），所以打字自动保存不会重绘阅读器。HTML 匹配忽略全部空白（跨段落复制的引文有空格而页面元素之间没有），找不到时依次到最多四层父元素里找，最后只标开头；PDF 先用整段引文、再用 title 里的开头匹配，跨页的引文只标在起始页。单击（不是拖选、也不是双击的第一下：HTML 等 350 ms，PDF 等系统双击间隔、最多 350 ms 且要求鼠标已松开、没有选中文字；PDFView 可能自己跟踪鼠标，所以不依赖 `mouseUp`）被引段落会打开引用它的写作稿并选中、闪烁那条引用；被多篇写作稿引用时弹出菜单选择。划词助手历史下划线优先于引用标记。

写作编辑器是 TextKit 1 的 `NSTextView`（`WritingTextStorage` + `WritingLayoutManager`），存储始终是 Markdown 原文，“实时所得”只是显示方式：`MarkdownLiveSyntax` 按行识别（规则遵循 CommonMark，包括 `_` 不在词内生效、单个 `~` 不是语法，导出后效果一致；`$…$` 行内公式按 Pandoc 规则：开头 `$` 后、结尾 `$` 前不能是空白，结尾 `$` 后不能紧跟数字，所以“$5 和 $10”仍是普通文字；同一行的 `$$…$$` 是 display 公式；多行 `$$` 公式块暂不支持），光标所在的行显示语法标记，其他行把标记生成为 null glyph、把 `-`/`*`/`+` 画成圆点，引用竖条、代码块底色、行内代码和引用胶囊在 `drawBackground` 里画。重新着色在 text storage 的 `willProcessEditing` 委托里做，只移除和设置自己管理的属性（保留输入法 marked text 的下划线）；`.writingLineState` 记录每行开头的代码围栏状态，编辑后只重排到状态一致的那一行。从磁盘载入的初始文本没有经过 `processEditing`，必须 `fixAttributes`，否则 CJK 字符没有后备字体、完全不显示。编辑器自己处理 ⌘Z/⇧⌘Z（工具栏的 PDF 批注菜单也绑定了 ⌘Z）和 ⌘B/⌘I；Return 续写列表和引用，在空项上结束并留出空行（否则下一段会变成懒惰续行）。

公式和图片在 TextKit 1 里的做法（都已用测试验证过 TextKit 的实际行为）：公式用 `iosMath` 排版（`WritingMathTypesetter`，按 TeX、字号、display 缓存；iosMath 读不了的 TeX 保持源码并标红），TeX 的第一个字符在 glyph 生成时设为 `.controlCharacter`，委托返回 `.whitespace` 动作和公式宽度的 bounding box，其余字符和 `$` 都是 null glyph，公式在 `drawGlyphs` 里按该 glyph 的基线翻转坐标画出。control glyph 的 bounding box 只决定宽度、不会撑高行，所以高公式靠 `shouldSetLineFragmentRect` 加高行并下移 `baselineOffset`。图片只显示本地文件（相对写作稿文件夹的路径、绝对路径或 `file:`；网络图片、缺失或读不出的图片保持语法原样显示），整段 `![alt](path)` 都隐藏，画在该段最后一行下方，行高同样在 `shouldSetLineFragmentRect` 里加；段落只有图片且没在编辑时，用图片高度代替文字行高。图片语法的第一个字符也要保留为零宽 control glyph：一行全是 null glyph 时 TextKit 会把它并进上一行的 line fragment。粘贴（只有图片、没有文字时）、拖入图片文件或图片数据、“更多”菜单的“插入图片…”都会把图片复制进 `assets/` 再插入独立段落；主窗口最上层的 PDF 拖入遮罩会把非 PDF 拖拽转给鼠标下的写作编辑器。

LLM 配置现已拆成独立 SwiftData 模型：`LLMProviderProfile` 负责 provider 名称、`baseURL`、`apiKeyRef`、`testModel` 和启用状态，`LLMModelProfile` 负责模型名、所属 provider 和高级参数。`AppSettings` 只保留全局翻译偏好与当前选中的 HTML/PDF model profile；运行时路由解析不再依赖旧的单 Base URL / 多 legacy model name 配置。

翻译缓存位于 `TranslationSegment`，现在除 `paperID`、`sourceType`、`targetLanguage`、`sourceHash` 之外，还会记录 route identity（至少 `providerProfileID`、`modelProfileID`、`modelName`）。改缓存或查找逻辑时，不要让切换 provider/model 后继续命中旧译文。

## 翻译与外部工具

- OpenAI-compatible API 已改为多 provider / 多 model profile 结构。API key 仍然存于 Keychain，但通过 provider-specific `apiKeyRef` 关联；日志、错误和测试输出中不要泄露真实 key。
- `LLMConfigurationBootstrapper` 现在只负责确保 `AppSettings` 行存在，方便应用启动和设置页读取全局翻译偏好；不要再把它扩回 legacy LLM 配置迁移入口。
- `OpenAICompatibleLLMProvider` 负责 `/chat/completions` 调用，保留代理 base path，识别版本段，并在 `404 + /v1` 场景下尝试去掉尾部版本段回退。`LLMProviderValidationUseCase` 负责 base URL 规范化、模型名校验、连接测试和错误归类。
- Provider 的 API 协议 `LLMAPIStyle`（`chat-completions` / `responses` / `anthropic-messages`）按 provider 存在 UserDefaults，不进 SwiftData。`anthropic-messages` 由 `OpenAICompatibleLLMProvider` 以原始 HTTP 调用 `POST {base}/v1/messages`（`x-api-key` + `anthropic-version` 头，system 走顶层字段，`max_tokens` 缺省 16000，只取 `text` 块，`refusal` / `max_tokens` stop reason 视为失败）。新 Claude 模型会拒绝 `temperature` / `top_p`，调用方补默认采样值时要走 `LLMAPIStyle.samplingDefault(_:)`，不要直接写死 `?? 0.2`。BabelDOC 与 LaTeX 翻译共用 `resolvePDFRoute`；BabelDOC 通过 `LLMAPIStyle.babelDocAPIStyle` 映射成 helper 的 `--api-style`（macOS）或 `BabelDocOpenAIConfiguration.apiStyle`（iPad 进程内），`responses` 按历史行为走 `chat/completions`，`anthropic-messages` 由 BabelDocKit 的 `OpenAICompatibleILTranslator` 直接发 Messages 请求（语义同上）。helper 在 Anthropic 下不补默认 `temperature`。
- 阅读助手的实时联网搜索按 `LLMAPIStyle.supportsServerWebSearch` 开放给 `responses`（`web_search` 工具 + `web_search_call` 续答回放）和 `anthropic-messages`（服务端工具 `web_search_20250305`，`max_uses` 5，不强制 `tool_choice` 以兼容 extended thinking）。Anthropic 响应由 `LLMAnthropicMessagesContentAccumulator` 统一处理非流式与 SSE：遇到 `server_tool_use` / `web_search_tool_result` 块时丢弃之前的旁白文本，`web_search_result` 与 `web_search_result_location` citation 都进入 `webSearchSources`，citation URL 在对应文本块结束后追加到正文以便 `SelectionAssistantCitationFormatter` 编号；`pause_turn` 且无答案时报 `webSearchCompletedWithoutAnswer`（暂不回放 paused content）。DeepSeek 结果 URL 带纯数字 fragment（如 `#1`），`LLMWebSearchSource` 会去掉它，格式化器也会吞掉正文里残留的 `#数字`。真实联调可用 DeepSeek 的 Anthropic 兼容端点 `https://api.deepseek.com/anthropic`。
- `LLMRouteResolver` 从 `AppSettings`、`LLMProviderProfile`、`LLMModelProfile` 和 Keychain 解析 HTML/PDF 两条独立路由。`HTMLTranslationPipeline` 与 `BabelDocRunner` 必须消费 `TranslationPreferencesSnapshot` / `LLMModelRouteSnapshot`，不要再直接从 `AppSettings` 读取 provider base URL、模型名或 API key。
- `HTMLTranslationPipeline` 只翻译语义块，不翻译整份 HTML 字符串；当前候选选择器包括 `p`、`h1...h6`、`figcaption`、`blockquote`、`li`。
- HTML 全文翻译必须按语义块增量落盘和刷新展示：模型每译完一个块就插入 `.rp-translation-block`、写回 `paper.html` 并通知阅读器刷新；不要等所有段落翻译完成后再一次性展示。缓存命中例外：一次查出本篇论文的缓存（不要按段落各查一次整张 `TranslationSegment` 表），全部插入后只写一次文件、存一次 SwiftData，再调用 `onDocumentPrepared` 让阅读器重载页面显示它们（阅读器每次渲染只应用最新一条段落更新，同步连发的更新会丢）。`paper.html` 的解析、插入和写回都在 `HTMLTranslationPage` actor 里离开主线程进行：整页序列化在 Debug 下每次可达数百毫秒，放在主线程会让点击翻译后界面卡住、进度胶囊也出不来。
- HTML 翻译进度在阅读器中优先使用确定型进度条展示；如果已知总段数，至少同时显示线性进度和 `processed/total` 计数，不要只保留 `1/xxx` 这类纯文本进度提示。
- 翻译运行中的状态只在阅读器底部的浮动胶囊 `TranslationActivityCapsule` 里显示（与复制链接 toast 同一位置和玻璃样式）：进度以模糊光晕沿胶囊背景推进，右侧圆形玻璃取消按钮在进度前半段融进胶囊端部（必须在光晕的柔边到达连接处之前完全并入，否则光晕会溢出到两者之间的收窄处），结束时在端部显示对勾/叉；工具栏不再放取消按钮；胶囊只显示“翻译中 / 正在取消 / 完成 / 已取消”和计数，具体阶段文案放在 tooltip 里。各翻译流程把结果（`runOutcome`）交给 `endTranslationRun`，在清除 `isWorking` 的同一次更新里切换到结果，不要按状态文案字符串判断成败：完成（包括带警告的完成，PDF 常有少量段落失败）显示“完成”约 2 秒，取消显示“已取消”；警告、LaTeX 完成（那一行有“显示翻译后的 LaTeX 源码”按钮）和错误的文案另外留在顶部状态行，直到用户关闭。
- HTML 翻译会保护 `math`、`.ltx_Math`、`cite`、`code`，生成 `[PROTECTED_N]` 占位符；改 prompt 或渲染时必须保持占位符可恢复。
- 模型输出不可信：HTML 与摘要翻译统一走 `TranslationLLMClientProtocol.validatedTranslate`，由 `TranslationOutputValidator` 拦截回显 prompt 分隔标记、原样返回原文、复述相邻上下文和异常超长输出（失败会去掉相邻段上下文后重试）。仍无效的 HTML 段落跳过且不写入 `TranslationSegment`，整篇翻译继续并汇报跳过数；读取缓存时也要过同一校验并清除无效条目。改 prompt 分隔标签时同步 `AcademicTranslationPrompt.envelopeLabels`。
- LaTeX 翻译的输出校验在 `../arxivLatex` 的 `PromptingLaTeXTranslator` 内完成：不可用的槽位响应会按单元重试，只有完整结果才写 checkpoint，未完成单元以 `untranslated-unit` / `partially-translated-unit` warning 返回；ReadPaper 只通过 `ReadPaperLaTeXTranslationOutput.incompleteUnitCount` 汇报数量，不要在 host 侧另写一套 LaTeX 回显检测。
- PDF 翻译进度在阅读器中也优先使用确定型进度条和阶段文案。当前 `BabelDocRunner` 通过受控 Python bridge 订阅 BabelDOC 内部 progress events，把结构化事件以 JSON line 输出给 Swift 侧解析；不要回退成依赖 rich/tqdm 终端文本渲染结果做正则猜测。
- 增量 PDF 翻译时，BabelDOC 可能只产出当前批次的译文页，阅读器中的 `translatedPDF` 也可能暂时只覆盖前 N 页。改 BabelDOC 参数、译文合并或阅读器展示时，要保留“partial translation”语义：双栏模式允许原文继续翻到后续页，译文侧只在自己的可用范围内 clamp，并继续支持后续批次合并、刷新和续翻。
- 设置页中的翻译配置已拆成 `Translation`、`Providers`、`Models` 三个区块。后续扩展优先沿用这个结构，不要再加回“单 Base URL + 三个模型名”的旧表单。
- 设置页 `General` 顶部的“快速开始”是首次配置的连续流程：选择内置 provider（`LLMDefaultProfiles`，带 `apiKeyPageURL`）→ 填 API key → “测试并用于翻译”。`LLMQuickSetup.target` 优先用已保存的 provider/model（保留用户改过的 base URL、模型名），测试通过后 `apply` 才先存 key、再恢复/启用该 provider 和内置模型并把 HTML 与 PDF 路由都指向它；存 key 失败时不改 store。阅读助手路由不动。独立的 Providers / Models / Reader 页照常保留，其他服务和按用途分配模型仍在那里配置；并发数、QPS、每批页数放在 General 的“高级 › 翻译性能”，BabelDOC runtime 版本放在“高级 › 诊断”，默认折叠。
- 快速配置有两个 App 内入口，都经 `TranslationSetupNavigation.showQuickSetup`（切到 General，并重新显示被“跳过”的引导，再 `openSettings`）：阅读器翻译因 `LLMRouteError` 失败时，状态行出现“设置翻译…”；还没有可用路由时，阅读器底部浮层栈（与复制链接 toast、翻译胶囊同一处）显示一次性提示，点“设置…”或关闭后写入 `TranslationSetupNavigation.didHandleReaderNoticeKey`，不再出现，配置好路由也会自动消失。“可用”由 `LLMTranslationSetupStatus.hasUsableRoute` 判断：HTML 或 PDF 任一路由指向启用的模型和 provider，且钥匙串里有 key；只用 `KeychainStore.contains`，不读取 key，避免触发 Touch ID。
- 设置页中的 BabelDOC 区域要区分“当前已安装版本”和“目标版本”：当前版本应来自对本地 `babeldoc` 可执行文件的实际探测并只读展示，目标版本才是用户可编辑、用于 `uv tool install ... BabelDOC==<version>` 的配置值；不要把可编辑输入框误当成已安装状态展示。
- 设置页中的 BabelDOC 安装源支持官方 PyPI 与清华 TUNA mirror 切换。该偏好当前通过 `BabelDocInstallSource.userDefaultsKey` / `@AppStorage` 落到 UserDefaults，刻意不新增 `AppSettings` SwiftData 字段以降低旧 store 兼容风险。改 BabelDOC 安装链路时，不要重新硬编码单一 PyPI 源；`BabelDocToolManager` 应根据所选源同时切换 latest metadata URL 和 `uv tool install --default-index ... BabelDOC==<version>` 参数，阅读器里的自动安装也应沿用同一默认读取逻辑。
- macOS 设置页的字符串输入框在快速切换焦点，尤其配合中文输入法或其他有 marked text / suggestions / Writing Tools 参与的输入路径时，可能打出 `NSXPCDecoder validateAllowedClass:forKey:` 且 allowed classes 含 `NSObject` 的系统警告。当前经验判断这更像 AppKit / 输入法 / Writing Tools 的系统日志，而不是项目里某个业务 `NSSecureCoding` 白名单真的写错。遇到这类报错时，先排查是否发生在设置页输入焦点切换，而不要优先沿 SwiftData、Keychain 或业务解码链路误判。
- Reader 和设置页里的 LLM 错误要尽量按场景区分，例如 HTML 路由缺失、PDF 路由缺失、provider 被禁用、API key 缺失、测试模型不可用，而不是统一报成一个笼统的缺配置错误。
- 启动 PDF 翻译前，`PDFTextLayerInspector` 会用 CoreGraphics 检查字体：若整份文档没有任何可解码字体（无字体的扫描件，或 dvips/Distiller 那类无 `ToUnicode`、字形名无意义、编码按首次出现编号的 Type3 位图字体），不再把乱码送进 BabelDOC/LLM，而是弹出“翻译扫描版 PDF”的确认框（`PDFTextLayerError.noExtractableText`）。判定刻意保守：只要有一个可解码字体就放行；pdfTeX 风格（`/a65` 位于 code 65）的 Type3 字体视为可解码。
- BabelDOC 通过 `BabelDocRunner` 和 `ProcessRunner` 启动外部进程，参数中的模型、base URL 和 API key 来自 PDF route snapshot；API key 要使用现有 redaction 逻辑，不要把外部工具失败吞掉成静默失败。
- BabelDOC 的 launcher 可能是 `uv tool install` 生成的 `sh` 包装器，第一行 shebang 不一定就是实际 Python 解释器；改启动逻辑时要兼容“同目录 venv `python3`/`python` + shell wrapper `exec .../python3`”这类结构，不要简单假设 `#!/usr/bin/env python3`。
- ReadPaper 管理的 BabelDOC 安装应优先使用 uv-managed Python 3.13；已遇到 Python 3.14 下 BabelDOC 运行时报 `_WorkItem.__init__` 参数不匹配的兼容性问题。判断 BabelDOC 是否可用时不要只检查 `bin/babeldoc` 是否可执行，还要确认 launcher 背后的 Python 版本可用；如果用户把 `/Users/.../Library/Application Support/ReadPaper/Tools/BabelDOC/bin/babeldoc` 手工改成指向 `~/.local/bin/babeldoc` 一类工作版本的 symlink，后续改安装、探测或移除逻辑时要避免误判为内置版本已经健康。
- `ProcessRunner` 需要持续 draining stdout/stderr，并正确响应取消；改动时保留大输出和取消相关测试。
- arXiv 论文做 PDF 翻译时，`BabelDocSemanticHintService` 会下载 LaTeX 源码（含 `.bbl`），用 LaTeXTransKit 生成语义 sidecar 交给 BabelDOC 对齐。sidecar 按 `extractorAlgorithmVersion` 缓存在论文目录 `Resources/LaTeXSemantic/`；`../arxivLatex` 的语义抽取输出一旦变化，必须递增该版本，否则会继续命中旧 sidecar。helper 的 `translation_diagnostics` 事件里 `semantic_pdf_paragraphs` / `semantic_matched_pdf_paragraphs` 只统计正文流段落（不含表格、图内文字、fallback 行），状态文案也按这个口径展示。
- layout model 把高而窄的算法清单识别成 `plain text` 时，原生段落阶段会用至少 8 条物理行、多次函数调用以及控制流/赋值信号保守识别伪代码并标为 `code`；这类块不进入正文翻译或 LaTeX reading-flow 对齐，Typesetting 必须逐字符保留源坐标、缩进、换行和公式对象。证据不足的短代码与普通多行正文继续走原流程，不要只凭公式字体或单个运算符扩大识别范围。

- 扫描版 PDF 翻译（`ScannedPDFTranslationService`，仅 macOS）：
  - 实现在 `../rebuild-pdf` 的 Swift 包 `RebuildPDFKit`，是同仓库 Python 版 rebuild-pdf 的逐条移植；Python 版仍是规则的参照实现。规则、提示词或排版改动先在 Python 里做，再移植到 Swift，并用 `uv run python tools/export_swift_fixtures.py` 重新导出对照数据（`tests/RebuildPDFKitTests/Fixtures/parity.json`；本地重建过样例时另写不入库的 `local/samples.json`），在 `../rebuild-pdf` 里 `swift test`：生成的 `main.tex`、页面测量、文档版式、翻译保护与还原都要求与 Python 逐字节/逐值一致。提示词由 `tools/export_swift_prompts.py` 复制进包资源，不要手抄。字宽表 `line-metrics.bin` 来自 PyMuPDF 的 base14 字体（含 fallback），由 `tools/export_line_metrics.py` 生成。
  - 与 Python 版的有意差异：用 Apple Vision 代替 Tesseract 测量版心和给出 OCR 草稿（`TextRecognizing` 可注入）；页面渲染、裁剪用 CoreGraphics；单页失败不中止整次运行，该页在输出里保留原扫描页并记入 `fallbacks`，全部失败才抛 `noPagesRebuilt`；开跑前用 `TeXInstallationCheck` 排一张用到全部宏包和字体的探测页，缺包时先报错，不让用户为转写付费后才失败。Python 和 Swift 的校对候选若三次仍无法解析或排版，必须拒绝候选并保留已经成功排版的版本继续翻译，把拒绝原因、轮次和 token 用量写入检查点；不要因校对模型重复添加代码图等错误而丢弃可用初稿，也不要把拒绝伪装成“无需修改”。
  - 模型：转写用“设置 > 阅读器 › 翻译路由”里的“扫描页模型”（`ScannedPDFTranslationPreferences.transcriptionModelProfileIDKey`，存 UserDefaults，不进 `AppSettings`；未选时回退 PDF 模型），必须支持图像输入；翻译用 PDF 路由。`ReadPaperRebuildModelClient` 把页面 JPEG 作为 `LLMCompletionMessage(parts:)` 发送（Chat Completions `image_url`、Responses `input_image`、Anthropic base64 `image`），超时用 `.scannedPage`（思考可能持续数分钟才返回首字节），并设 `allowsTruncatedOutput`：输出被 `max_tokens` 截断时返回 `finishReason == .length`，由 RebuildPDFKit 把预算翻倍重试（32k 起，最多 128k），其他调用方仍按原来的方式报错。`identity` 写入检查点 key，只含端点、模型和采样设置，不含 key。
  - 排版用 XeLaTeX：优先 Settings > LaTeX 选中的工具链目录，再找 `/Library/TeX/texbin` 等常见位置；与 arXiv LaTeX 翻译开关无关。编译关闭 shell escape，`openin_any/openout_any=p`。目标语言目前只支持简体中文（`zh-CN`，Fandol 宋体/楷体），其他语言在确认框前就提示。
  - 检查点在论文目录 `Resources/ScanRebuild/`（`pages/`、`responses/`、`typeset/`、`translations/zh/`，布局同 Python 版）：重跑、取消后重跑只为没完成的页付费；页面标记 `typeset/page-NNNN.page.tex` 与 `translations/zh/typeset/page-NNNN.page.tex` 可手工修改，修改过的页不再调用模型。输出写到 `translations/scan-rebuild.zh.pdf`，与原稿页数相同（未选的页、失败的页是原扫描页），`translatedLastPage` 为 nil；重跑原地更新已有的 `scanRebuild` 附件记录（保留 ID，挂在上面的笔记和批注不丢，更新 `createdAt` 使其成为显示的译文）。
  - 同一次运行还会组装矫正转写版 `Resources/ScanRebuild/transcription.pdf`（`RebuildPipeline.run(sourceOutput:)`：校对后的原文页按原版面排版，有真实文字层；某页翻译失败但转写成功时，转写版里照样有这一页），以 `resource` + `scanRebuild` 附件记录（`ScannedPDFTranscription.attachment(in:)`）。有转写版时，单栏原文和双栏左侧的“原文”标签变成“扫描原稿 / 矫正转写”菜单，选择按论文存在 UserDefaults（`ScannedPDFTranscription.displayedPaperIDsKey`，只在用户切换时写入），默认扫描原稿。两版的批注、笔记锚点各自挂在自己的附件上；打开挂在另一版上的笔记或引用时会自动切到那一版。阅读助手的全文索引在有转写版时用转写版的页面文字（扫描件本身没有文字）。确认框说明会把页面图像发给模型并给出每页约 1 分钟、5 万 token 的估计；页数超过 PDF 每批页数时提供“翻译前 N 页 / 全部”。

## 实现约定

- 优先保持 SwiftUI + SwiftData 的现有风格，避免引入新的架构层，除非任务明确需要。
- UI 状态尽量留在 View 内，持久化状态进入 SwiftData model，外部副作用放到 `Services`。
- 应用内国际化当前采用 Mercury 风格的运行时 bundle 切换，而不是只依赖系统语言：SwiftUI View 优先从 `@Environment(\.localizationBundle)` 取 bundle，并用 `Text(..., bundle: bundle)`、`String(localized: ..., bundle: bundle)` 或 `LocalizedStringResource` 走字符串目录；不要在新增 UI 文案时直接写死字符串并假设后续再统一替换。
- 新增或修改用户可见文案时，默认同步更新 `ReadPaper/Localizable.xcstrings`；Info.plist 可见文案则更新 `ReadPaper/InfoPlist.xcstrings`。当前开发语言是英文，首批支持语言只有 `en` 与 `zh-Hans`；如果要扩语言，先沿用 `LanguageManager` 的规范化/回退规则，不要零散地在各处单独判断 locale。
- app-owned 的错误、校验提示、状态说明和阶段文案应优先通过 `AppLocalization` / 当前 localization bundle 统一生成；若消息中混有底层系统或第三方错误，保留底层 `localizedDescription` 原文，只本地化项目自己控制的前缀、模板和上下文。
- 设置页整体信息架构优先使用顶部 `TabView` 页签承载大类（如 `General`、`Reader`、`Providers`、`Models`），不要轻易回退成单页长表单或侧边栏式设置窗口，除非任务明确要求。
- 设置页 `General` 现已承载应用语言选择；后续如果新增全局语言相关偏好，优先放在这里，并保持“Follow System / English / 简体中文”这类运行时可切换、不要求重启的交互语义。
- 如果要改设置页输入框，优先保持当前 AppKit-backed 单行输入控件策略：关闭 text completion、smart quotes/dashes、自动替换、拼写检查和 character picker；在可用系统版本上关闭 Writing Tools / affordance；并在结束编辑前主动 `unmarkText()` / `discardMarkedText()`，尽量降低快速切换焦点时的系统输入服务噪音日志。不要轻易退回成默认 SwiftUI `TextField` / `SecureField` 而不处理这些输入系统细节。
- 阅读器不同模式的缺失态/空状态要保持一致的视觉语义；例如缺少 HTML、PDF 或翻译 PDF 时，优先复用统一的居中 unavailable 组件，不要一处是完整空状态卡片、另一处只显示一行占位文字。
- 与阅读模式切换相邻、语义上属于“二选一 / 多选一”或并列主操作的按钮，视觉上优先向阅读器里的 `htmlDisplayPicker` / segmented control 靠拢：保持紧凑、等权、成组展示，必要时使用共享圆角底板和分隔线；避免混入单个过强的 `.borderedProminent` 按钮破坏整组节奏。空状态里的并列 action 也优先遵循这套样式，并预留足够宽度保证文案完整展示。工具栏的 HTML/PDF、原文/双语/译文切换和 Inspector 的“论文/写作”切换都用 `ReadPaperSegmentedPicker`（选中段填强调色，窗口不活跃时变灰）：macOS 26 工具栏里的原生 segmented `Picker` 选中段总是灰色，`.tint` 只设置了 `selectedSegmentBezelColor`，工具栏并不使用它，不要改回原生 `Picker`。工具栏里要用 `segmentedPickerToolbarItem` 放置它：系统的共享玻璃底会把相邻的自定义 item 合并成一个胶囊（HTML/PDF 和原文/双语/译文会连成一组），所以该 item 隐藏共享底、由控件自己画胶囊；不要换成 `ToolbarSpacer`，那样间距是原来的两倍。HTML 和 PDF 模式共用同一组工具栏 item，而且每个 item 在两种模式下保持同一种控件：原文/双语/译文是同一个 `displayPicker`（PDF 模式下映射到 `ReaderMode`），字体菜单和 PDF 批注菜单合成同一个 `readerToolsMenu`。不要按模式换掉 item，也不要把 `Menu` 换成按钮或自定义视图：SwiftUI 会替换 `NSToolbarItem`，AppKit 随之重建整个工具栏并重新解析所有菜单图标，曾占 HTML↔PDF 切换主线程时间的近一半（Release 下约 320 ms 中的 140 ms）。目前只有 HTML 专用的“调整区域”按钮按模式出现，它插入或移除时工具栏会做动画、逐帧布局。
- 文内查找（⌘F）的匹配逻辑统一在 `DocumentTextSearch`：PDF 与 HTML 共用同一套"忽略空白/连字符后匹配，再按空白布局区分 exact / spacing-tolerant"的规则，不要在 JS 或各阅读器里另写一套规范化。HTML 高亮只用 CSS Custom Highlight API，不要用 `<mark>` 等方式改 DOM，否则会破坏按子元素下标计算的笔记锚点；PDF 高亮用 `PDFView.highlightedSelections`，不要改成写入 `PDFAnnotation` 或设置 `currentSelection`（会触发选区助手）。
- HTML 划选在 macOS 上只由 `rp-assistant-selection` CSS Custom Highlight 绘制：WebKit 原生选区跨段落时会连同段间和行尾空白涂成一整块并延伸到页面边缘，而且用的是网站自己的 `::selection` 颜色（例如 Anthropic 页面是半透明陶土色），和划词助手的蓝色高亮叠在一起。因此 `<body>` 内（不含 `input`/`textarea`）的 `::selection` 被设为透明，`selectionchange` 时立即把当前选区写进高亮；Swift 侧清除高亮时如果选区还在会重新画上；页面上按下鼠标时只清空高亮（此时旧选区还没折叠）。`rp-assistant-selection` 始终是同一个已注册的 `Highlight` 对象，用 `clear()`/`add()` 原地更新：WebKit 在 `CSS.highlights.set` 换成新对象或 `delete` 时不会重绘旧范围覆盖过的文字，拖选往回收缩时下方会残留蓝色（真实鼠标拖动才稳定复现，脚本里同步改选区会被原生选区的重绘掩盖）；其他按名字整体替换的高亮也可能有同样的残影。不支持 Highlight API 的 WebKit（macOS 14.2 之前）保留原生选区；iPad 由 UIKit 绘制选区，不受影响。
- 拖入 PDF 导入统一走 `ContentView` 上的 `pdfFileDropTarget`：AppKit 视图 `PDFFileDropCatcherView` 叠在整个窗口（含工具栏区域）最上层，只注册文件 URL 类型，`hitTest` 返回 nil，所以点击和滚动照常落到下层视图。不要改回 SwiftUI `dropDestination`，也不要改成给各阅读器过滤拖拽类型：AppKit 把拖拽交给最前面的已注册视图且不会向后传递，而 `WKWebView` 会认领自身范围内的所有拖拽，HTML 阅读时遮罩就不会出现。遮罩样式沿用阅读器浮层（玻璃卡片加发丝描边），纸张外观改用纸面底色和衬线字体。
- 阅读器只读页面、不执行页面代码：`HTMLReaderView.makeConfiguration` 和 `HTMLPDFExporter` 都设置 `allowsContentJavaScript = false`，页面自带的内联脚本、`on*` 事件属性、`javascript:` 链接和 iframe 内脚本一律不运行，`<noscript>` 内容按无脚本方式渲染；App 注入的 user script 与 `evaluateJavaScript` / `callAsyncJavaScript` 不受影响。新增阅读器能力必须写成注入脚本，不要依赖页面脚本。导入时 `HTMLLocalizer.removeActiveContent` 删除可执行 `<script>`、`on*` 属性、`javascript:` URL、`meta refresh` 和 preload/prefetch/preconnect 等资源提示，只保留 JSON-LD 与 `math/tex` 数据块；导入阶段抓取 JS 渲染型网页的 `WebPageHTMLRenderer` 仍需页面 JS，不要一并关闭。已导入论文的旧 `paper.html` 不回写清理：`<body>` 里的脚本节点参与 `rp-anchor:` 下标，删掉会让已有笔记锚点错位。
- 网页源站常用外链 MathJax/KaTeX 排版 `\(...\)` / `\[...\]` / `$$...$$` / AMS 环境，而 `HTMLLocalizer` 会移除可执行脚本，所以 `paper.html` 里只剩 TeX 源码。公式由阅读器注入的 `HTMLTeXRendering` user script（内置 Temml，输出原生 MathML，资源在 `ReadPaper/Resources/Temml/`）在 WebView 内渲染，`HTMLPDFExporter` 同样注入；不要把渲染结果写回 `paper.html`。渲染产物包在 `.rp-tex-math` 中，`instrumentationScript` 构建/解析 `rp-anchor:` 路径时必须跳过它（与 `.rp-translation-block` 同理）；增量插入译文块后要调用 `window.__rpRenderTeX(node)`。单个 `$` 刻意不作为定界符。Temml 的全局 `math` 样式只在页面确实渲染了 TeX 时注入，避免影响 arXiv 原生 MathML。纯公式段落（去掉 TeX 与 `[PROTECTED_N]` 后没有字母）不进入 HTML 翻译候选。
- 页边笔记（旁注）：HTML 旁注由 `HTMLReaderView.Coordinator.sidenoteScript` 渲染，卡片层挂在 `<html>` 下、`<body>` 之外，原文高亮只用 CSS Custom Highlight API，不要把旁注写进 `paper.html` 或 `<body>` DOM，否则会破坏 `rp-anchor:` 笔记锚点和查找；页边空间通过只补足缺口的 body 右内边距获得，不要回退成固定预留整列宽度（站点限宽 body 时会把正文挤窄）。PDF 旁注只在单栏 PDF（原文/纯译文）显示，位置由 `PDFReaderView` 写入 `PDFSidenoteLayoutModel`、由 `PDFSidenoteRail` 排版；笔记原文高亮与划词助手历史下划线一样是内存中的临时 `PDFAnnotation`（导出会从磁盘重新打开 PDF，橡皮擦只处理用户批注记录），这与文内查找必须用 `highlightedSelections` 的约定不冲突。
- 换论文时 `PDFReaderView` 按 `pageIndex`（恢复的页码或引用的页码）打开新文档，只有同一论文同一附件重新加载（例如增量翻译写出新文件）才保留当前滚动位置；不要回到“总用 PDFView 当前位置”，那样新论文会带着上一篇的页码，还会盖掉引用跳转。`HTMLReaderView` 在新页面开始加载时用 `queueNoteNavigationForNewDocument` 把随页面到来的跳转请求排队，`didFinish` 里在 `finishLoadIfNeeded` 之后才执行（之前执行会因仍在加载而重新排队），有待执行的跳转时不再恢复滚动比例。`ReaderPaneView` 在 `onChange(of: paper?.id)` 里恢复新论文的阅读状态，但 SwiftUI 会先带着上一篇的模式和页码渲染一次新论文，所以模式和页码要通过 `readerMode` / `pdfPageIndex` 访问器读取（底层是 `storedReaderMode` / `storedPDFPageIndex`）：恢复之前它们返回新论文保存的模式和页码，第一次渲染就用对的阅读器打开对的页，而不是先按上一篇的模式或页码打开、恢复后再打开一次（PDF 每多一次 `go(to:)` 都要同步等待页面渲染，约 15–30 ms）。渲染路径不要直接读 `stored*`；恢复之前 `readingStatePersistenceSnapshot` 返回 nil，避免把上一篇的位置存成这一篇的。`ReaderPaneView` 也是 `Equatable`（按对象身份比较论文、附件、笔记和 settings），binding 的值变化时它照常通过依赖跟踪刷新。
- HTML 区域调整（工具栏“调整区域”）：`HTMLRegionEditing` 注入脚本负责悬停描边、↑/↓ 扩大或缩小到父/子块、点击隐藏或恢复、⇧ 点击连选、页内撤销/重做；它只切换 `HTMLRegionVisibility.hiddenAttribute`，描边层（含提示 ↑ 目标的虚线父框）挂在 `<html>` 下，不要改成删除节点或往 `<body>` 插 DOM，否则会破坏 `rp-anchor:` 笔记锚点。层级规则：与内层边界相差不超过 2px 的包装层并入同一级，以最外层元素为隐藏对象（不留空边距）；已隐藏区域单独成级；表格部件和无盒元素不可选；译文模式下被隐藏的原文仍按块级处理。徽标只显示动作和类型（⇧ 连选时显示区域数），不显示源站 class/id 或占正文比例。⇧ 点击把上一次单击的隐藏/恢复动作应用到两点之间：一个容器只有首尾可见内容都落在区间内才整体隐藏，根包装层只进入不隐藏，整批只占一个撤销步；双击的第二下忽略。脚本用 instrumentation 暴露的 `__rpBuildNoteAnchor` / `__rpOriginalChildren` 生成路径，Swift 侧 `HTMLAnchorPath` 必须与之保持同一规则（跳过 `.rp-translation-block` 和 `.rp-tex-math`），并用 tag/id/子元素签名校验，签名不符的修改拒绝写入而不是误隐藏。页面加载时脚本发 `loaded` 消息报告隐藏数，工具栏提示据此显示；编辑条的“已隐藏”菜单经 `reveal` 命令滚动并描出该区域，再点击或回车即可恢复。修改由 `ReaderPaneView` 防抖后交给 `HTMLRegionWriter` 在主线程外按顺序写回 `paper.html`（整页解析重写，大页面在 Debug 下可达数百毫秒）；读取或重写 `paper.html` 的流程（翻译、导出）要先 `await HTMLRegionWriter.shared.waitForQueuedWrites()`，退出应用时调用同步的 `finishBeforeTermination()`；离开编辑、切换论文/模式、开始翻译、导出和退出应用前都会先落盘；编辑期间禁用翻译，因为翻译管线会整份重写 `paper.html`。隐藏区域不进入 HTML 翻译候选、阅读助手全文索引、文内查找和 HTML 导出 PDF。
- `DualPDFReaderView` 的双向页码同步要区分“共享的原文阅读位置”和“译文侧可显示范围”。如果翻译 PDF 只是 partial 文档，译文侧 `translatedPageIndex` 可以 clamp 到当前最大可用页，但不要把原文侧共享的 `pageIndex` 反向夹回 partial 范围，否则会导致 original PDF 无法翻到后续未翻译页面。
- PDF 阅读位置恢复与持久化时，`ReadingState` 中保存的 `pageIndex` 仍应表达用户在原文坐标系里的上次位置。双栏或纯译文视图在打开时，以及 translated page count 发生变化时，应把译文侧位置同步到 `min(savedOriginalPageIndex, translatedLastAvailablePage)`；但不要因此把 original `pageIndex` 改写成更小值。关闭应用后二次打开时，至少要保证译文侧落到与上次阅读位置对应的可用页，而不是回到首页。
- arXiv 导入进度要尽量使用确定型、分步骤的状态反馈；如果链路已知关键阶段，至少同时展示当前步骤标题和阶段性说明，不要退回成只有转圈、没有上下文的等待态。若 HTML 主源失败并回退到备用源，也要把“正在尝试备用源”明确告诉用户。
- 网页导入进度同样使用确定型、分步骤的状态反馈，通过 `WebPageImportProgress` 暴露 URL 校验 → 网页抓取 → 创建库条目 → 最终保存四个阶段。若下载时检测到 `Content-Type: application/pdf`，进度标题会切换到"Downloading PDF"。不要在导入过程中退回成无上下文的 spinner。
- 网络和子进程路径要可测试：通过可注入的 `URLSession`、`FileManager`、`ProcessRunner` 或配置快照传入依赖。
- 处理本地文件时使用 `URL`/`FileManager`，不要拼接易碎路径字符串，除非已有模型字段需要保存 `.path`。
- 涉及 SwiftData 的异步 UI 流程目前多在 `@MainActor` 上运行；改并发代码时显式考虑 actor 隔离和取消。
- 涉及 HTML 正文提取时优先复用 `HTMLLocalizer` 里的 `swift-readability` 路径；不要重新引入一套手写正文选择器去替代它。SwiftSoup 主要用于正文抽取之后的 DOM 本地化、资源重写和译文插入。
- `HTMLLocalizer` 对明显过短、价值很低的 readability 结果会回退到原始文档；不要为了统一外观强行把所有页面都包进 readability shell。
- 本地化 HTML 时优先隐藏或重写必要元素；但如果已经进入 `swift-readability` 的正文模式，允许直接替换为提炼后的正文包装页，不必强求保留原站完整布局。
- 不要把 PDF 解析扩展成“任意 PDF 全文结构化翻译”的承诺；完整 PDF 翻译应继续作为 BabelDOC 外部工具路径。
- 本地 PDF 的元数据识别要偏保守：如果只是从前几页文本里扫到形似 `1234.56789` 的数字片段，但没有 `arXiv:` 前缀或 arXiv/ar5iv 链接上下文，不要给 `Paper.arxivID` 赋值，也不要在 UI 中展示成 arXiv 论文。对于 DOI，可以作为回退标识展示，但不要拿它触发 arXiv 专属能力，例如 HTML 抓取或 arXiv 去重。

## 测试建议

窄改动优先跑相关测试文件；跨服务或模型改动跑完整 `ReadPaper` scheme 测试。

针对单个测试类做快速回归时，优先使用下面这种命令形式，避免每次都跑完整测试集：

```sh
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath /tmp/read-paper-derived-data -only-testing:ReadPaperTests/BabelDocToolManagerTests test
```

重点测试映射：

- arXiv ID、Atom XML：`ArxivClientTests`
- 文件目录和附件写入：`PaperFileStoreTests`
- 论文库文件夹（建/改名/删除、移动、分组排序、删除论文清理归属、新旧 schema 双向打开 store）：`PaperFolderServiceTests`
- 侧边栏筛选条件（交集匹配、译文判定、筛选后保留文件夹与顺序）：`PaperLibraryFilterTests`
- 分组与侧边栏的相等比较（侧边栏跳过无关刷新的依据）：`PaperFolderServiceTests`
- 选中论文的恢复与保存（回退到 `AppSettings`、不写标准 defaults）：`PaperSelectionStoreTests`
- 文献类型（导入来源推断、手动指定与重置、类型筛选、新旧 schema 双向打开 store）：`PaperItemTypeTests`
- 本地 PDF 导入、arXiv ID 误判回归、arXiv 导入进度阶段、网页导入与 Readability 正文抽取：`PaperImporterTests`
- HTML 导入、本地化与 Readability 回退、导入时清除页面代码：`HTMLLocalizerTests`
- 阅读器关闭页面 JavaScript 但注入脚本（选区、查找、旁注、区域调整、TeX）照常工作，划选只由高亮绘制、不用网站 `::selection`：`HTMLReaderPageScriptTests`
- HTML 候选抽取、占位符保护、译文插入：`HTMLTranslationPipelineTests`
- HTML 区域调整（JS 与 Swift 路径一致性、隐藏/恢复落盘、签名校验、层级与徽标、⇧ 连选、写回顺序与退出前落盘）：`HTMLRegionVisibilityTests`
- 翻译输出校验（prompt/原文/上下文回显、重试与回退）：`TranslationOutputValidatorTests`
- PDF 无文字层检测（Type3 无映射字体、扫描件、glyph name 判定）：`PDFTextLayerInspectorTests`
- 扫描版 PDF 翻译（模型适配、图像消息、截断映射、扫描页路由回退、错误映射、转写附件与显示选择、用真实 XeLaTeX 跑通整条路线并产出译文与矫正转写、复用检查点）：`ScannedPDFTranslationServiceTests`；全文索引优先用矫正转写的文字：`PaperFullTextSearchServiceTests`；RebuildPDFKit 本身（与 Python 的对照、XeLaTeX 排版、流水线检查点与失败页回退）在 `../rebuild-pdf` 里 `swift test`，`SampleReplayTests` 用 Python 运行留下的回答离线重放两篇样例（需本地 `.rebuild` 目录，约 1.5 分钟），`ThompsonReplayTests` 从三页真实模型回答重新转写排版，覆盖美分符号、图注后独立换栏和独立字号控制行；这些排版回归不能只用已完成的页面检查点验证，否则会跳过首次转写校验。
- BabelDOC 安装源、latest 版本解析、uv 安装参数：`BabelDocToolManagerTests`
- BabelDOC 参数、progress bridge、敏感信息遮蔽、子进程输出/取消：`BabelDocRunnerTests`
- provider 校验、base URL 规范化、连接测试：`LLMProviderValidationUseCaseTests`
- provider/model route 解析与缺配置错误：`LLMRouteResolverTests`
- OpenAI-compatible `/v1` 回退与代理路径保留、Anthropic Messages 请求/流式解析、三种协议的图像输入、finish reason / 用量解析与截断输出：`OpenAICompatibleLLMProviderTests`
- settings 初始化保障：`LLMConfigurationBootstrapperTests`
- 内置 provider/model 种子、默认路由激活、快速配置（沿用已编辑的 profile、恢复已删除的内置 profile、存 key 失败不改 store）、可用路由判断、打开设置时切到 General：`LLMDefaultProfilesTests`
- 阅读位置存储与 mode 回退：`ReadingStateStoreTests`
- 文内查找的文本规范化（PDF 空格/断词/连字容错、短词误命中保护、HTML 分段偏移）：`DocumentTextSearchTests`
- 拖入 PDF 的整窗接收、PDF 过滤、导入中拒收，以及 `WKWebView` 上方的拖拽归属：`PDFDropTargetTests`
- 写作稿存储与列表（`meta.json` 重建、新版本元数据不覆盖、删除后迟到的保存不会重建、引用与段落缓存及旧版元数据重建、引用标记只在引用变化时更新、图片导入命名与路径解析）、标题与字数、插入位置、列表续写、引文上下文：`WritingStoreTests`
- 引用链接（ASCII 目标地址、title 里的引文、旧 `q=` 参数）、作者年份标签与转义：`PaperCitationTests`
- 实时预览的语法识别（CommonMark 强调规则、链接 title、代码围栏、图片、Pandoc 公式规则）：`MarkdownLiveSyntaxTests`
- 写作编辑器的着色、语法隐藏、CJK 后备字体、输入法、撤销、引用插入与自动保存、公式宽度与行高、图片行高与缩放、粘贴来源、插入图片、居中列宽、在写作稿中显示引用、窗口打开时 Inspector 让位、新建写作稿打开的窗口聚焦编辑器：`WritingEditorTests`
- 打开引用时 PDF/HTML 阅读器落在被引位置，以及换论文时 PDF 按新论文的页码打开：`CitationNavigationTests`
- 被引段落标记（HTML 高亮与单击/双击、跨段落引文、PDF 当前页附近的下划线）和图片拖到主窗口写作编辑器上的转交：`CitationMarkTests`
- `readpaper://` 与写作窗口引用的窗口选择、没有主窗口时的等待与 reopen、写作窗口是否把主窗口提前：`PaperLinkRouterTests`
- 运行时语言选择、bundle 规范化/回退、代表性本地化行为：`LanguageManagerTests`、`LocalizationBehaviorTests`

涉及真实网络、OpenAI API、BabelDOC 安装或真实 PDF 翻译的测试不要默认加入单元测试；优先用可注入依赖、临时目录和小样本文本覆盖行为。

如果改到 `DualPDFReaderView`、`ReaderPaneView`、增量 PDF 续翻或 `translatedLastPage` 相关逻辑，至少补一条回归覆盖以下场景之一：partial translated PDF 不应限制 original PDF 翻到后续页面；或关闭应用后重开时，双栏中的 translated side 不应丢失到首页。

涉及本地化改动时，再额外注意两点：

- 不要让测试依赖执行环境当前系统语言；必要时像 `PaperImporterTests` 一样显式固定 language override，并在 `tearDown` 恢复。
- 变更 app-owned 错误、状态文案或语言切换逻辑时，优先补充 `LanguageManagerTests`、`LocalizationBehaviorTests` 或对应错误类型的定向断言，避免只在手工切语言时发现回归。
