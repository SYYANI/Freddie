# AGENTS.md

本文件适用于整个仓库。后续 agent 在本项目中工作时，优先遵守这里的项目约定，再结合具体任务做最小必要改动。

## 项目概览

ReadPaper 是一个 macOS SwiftUI 论文阅读应用，使用 SwiftData 做本地数据模型，PDFKit 处理本地 PDF 轻量文本抽取，`swift-readability` 处理 arXiv/ar5iv HTML 正文抽取，SwiftSoup 处理 HTML 本地化和 HTML 段落翻译。项目最低 macOS 版本为 14.0，Swift 版本为 6.0，Xcode 项目由 `project.yml` 描述，依赖 SwiftSoup、`swift-readability` 和 `SwiftOpenAI`。

核心能力分成三条路径：

- 本地 PDF：导入 PDF，抽取 Info dictionary 和前几页文本，只用于标题、作者和 arXiv ID 等轻量识别；不要把 PDF 纯文本当成稳定全文结构。本地 PDF 里的 `arxivID` 只应在出现明确 arXiv 上下文时写入，例如 `arXiv:2303.08774` 或 `arxiv.org` / `ar5iv.labs.arxiv.org` 链接；不要把 DOI、Crossref 链接或其他编号片段误识别成 arXiv ID。若能从 PDF 正文或元信息中可靠提取 DOI，可把 DOI 作为无 arXiv 时的降级展示标识。
- arXiv 论文：通过 arXiv API 获取元数据和 PDF，优先保存 `https://arxiv.org/html/{id}`，失败后回退到 `https://ar5iv.labs.arxiv.org/html/{id}`；获取 HTML 后优先用 `swift-readability` 提炼正文，再把 HTML、CSS、图片等资源本地化，若正文抽取失败再回退到原始 HTML。通过 arXiv ID/URL 导入时，不要只给一个不透明的 loading spinner；应尽量向用户暴露当前所处阶段，例如 ID 规范化、元数据获取、PDF 下载、HTML 获取/回退、最终入库保存。
- 翻译阅读：HTML 走 SwiftSoup DOM 分段翻译并插入 `.rp-translation-block`；完整 PDF 翻译交给外部 BabelDOC CLI，输出翻译 PDF 后用双栏 PDF 阅读器展示。PDF 翻译进度也应尽量使用确定型进度条，而不是长期停留在无上下文的 spinner。

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
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath .DerivedData build
```

命令行测试：

```sh
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath .DerivedData test
```

GitHub Actions 构建 DMG：

- 仓库已包含 [`.github/workflows/release.yml`](/Users/yiyan/Desktop/read-paper/.github/workflows/release.yml)，支持在 GitHub Actions 上构建 DMG；触发方式为手动 `workflow_dispatch` 或推送 `v*` tag。
- 当前 workflow 运行在 `macos-26`，会先恢复本地 `swift-readability` 依赖，再安装 `xcodegen` 和 `create-dmg`，生成 Xcode 项目后执行无签名 Release 构建。
- CI 产物当前是 unsigned 的 `Freddie.app` 和 `Freddie-unsigned.dmg`；artifact 名为 `Freddie-unsigned-dmg`。若是 tag 触发，还会创建 GitHub Release 并附带该 DMG。
- 后续若调整 app 名称、scheme、产物路径、签名或打包方式，要同步更新 workflow 中的 `APP_NAME`、`APP_PATH`、`DMG_PATH` 和 release 上传逻辑，避免本地可构建但 CI 打包失效。

如果沙箱或受限终端里 `xcodebuild` 因 Xcode/SwiftPM/clang 缓存目录权限失败，不要先判断为代码失败；换到可写 Xcode 缓存的环境或使用 Xcode 运行后再确认。

## 目录职责

- `ReadPaper/ReadPaperApp.swift`：应用入口和 SwiftData `modelContainer` 注册。
- `ReadPaper/Models/`：SwiftData 模型和枚举。新增模型时同步检查 `ReadPaperApp` 中的 model container。
- `ReadPaper/Localization/`：运行时本地化基础设施，如 `LanguageManager`、bundle 解析和 SwiftUI environment 注入。
- `ReadPaper/Views/`：SwiftUI 界面，包含主布局、导入面板、阅读工具栏、设置页和检查器。
- `ReadPaper/Readers/`：PDF、HTML、双语 PDF 阅读器。
- `ReadPaper/Services/`：导入、arXiv API、HTML 本地化、翻译、BabelDOC、Keychain、文件存储、子进程运行等业务服务。
- `ReadPaperTests/`：XCTest 单元测试，重点覆盖 arXiv ID/Atom 解析、文件存储、HTML 翻译管线、BabelDOC 参数和进程运行。
- `ReadPaper/Localizable.xcstrings`：应用自有 UI、状态文案和错误文案的字符串目录，当前以英文 source string 为 key，并提供 `en` / `zh-Hans`。
- `ReadPaper/InfoPlist.xcstrings`：Info.plist 对用户可见文案的字符串目录，例如 `NSDocumentsFolderUsageDescription`。
- `project.yml`：XcodeGen 的项目源配置。调整 target、依赖、构建设置时改这里并重新生成项目。
- `.github/workflows/release.yml`：GitHub Actions 的 DMG 打包/发布流程；负责恢复 `swift-readability`、安装 `xcodegen` 与 `create-dmg`、构建 unsigned `Freddie.app`、产出 `Freddie-unsigned.dmg`，并在 tag 发布时上传到 GitHub Release。
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

SwiftData schema 变更要特别谨慎：历史上已经出现过“新版本删改 `AppSettings` 字段并写回 `ReadPaper.store`，随后旧版 `Freddie 0.1.8 (9)` 再打开同一份 store 时，在 `ReadPaperApp.init()` 创建 `ModelContainer` 阶段直接 `fatalError` 崩溃”的问题。对于会落盘的模型字段，尤其是 `AppSettings`、`LLMProviderProfile`、`LLMModelProfile` 这类启动早期就会参与建库/开库的类型，不要只改当前代码里的 `@Model` 定义；必须同时考虑旧 store 兼容、`SchemaMigrationPlan` / `VersionedSchema`、或至少临时保留兼容字段，避免发布后出现“新库打不开旧版 / 旧版打不开新库”的双向不兼容。

`paper.html` 当前默认保存的是适合阅读和翻译的本地化 HTML；对于 arXiv/ar5iv 导入，它通常是 `swift-readability` 提炼后的正文包装页，而不是原站完整页面快照。改导入链路时要注意这一展示语义。

附件通过 `PaperAttachment` 记录，类型包括 `pdf`、`html`、`translatedPDF` 和 `resource`，来源包括 `arxivPDF`、`arxivHTML`、`localImport`、`babeldoc` 和 `generated`。改文件写入逻辑时，要同时维护附件记录和 SwiftData 保存时机。

LLM 配置现已拆成独立 SwiftData 模型：`LLMProviderProfile` 负责 provider 名称、`baseURL`、`apiKeyRef`、`testModel` 和启用状态，`LLMModelProfile` 负责模型名、所属 provider 和高级参数。`AppSettings` 只保留全局翻译偏好与当前选中的 HTML/PDF model profile；运行时路由解析不再依赖旧的单 Base URL / 多 legacy model name 配置。

翻译缓存位于 `TranslationSegment`，现在除 `paperID`、`sourceType`、`targetLanguage`、`sourceHash` 之外，还会记录 route identity（至少 `providerProfileID`、`modelProfileID`、`modelName`）。改缓存或查找逻辑时，不要让切换 provider/model 后继续命中旧译文。

## 翻译与外部工具

- OpenAI-compatible API 已改为多 provider / 多 model profile 结构。API key 仍然存于 Keychain，但通过 provider-specific `apiKeyRef` 关联；日志、错误和测试输出中不要泄露真实 key。
- `LLMConfigurationBootstrapper` 现在只负责确保 `AppSettings` 行存在，方便应用启动和设置页读取全局翻译偏好；不要再把它扩回 legacy LLM 配置迁移入口。
- `OpenAICompatibleLLMProvider` 负责 `/chat/completions` 调用，保留代理 base path，识别版本段，并在 `404 + /v1` 场景下尝试去掉尾部版本段回退。`LLMProviderValidationUseCase` 负责 base URL 规范化、模型名校验、连接测试和错误归类。
- `LLMRouteResolver` 从 `AppSettings`、`LLMProviderProfile`、`LLMModelProfile` 和 Keychain 解析 HTML/PDF 两条独立路由。`HTMLTranslationPipeline` 与 `BabelDocRunner` 必须消费 `TranslationPreferencesSnapshot` / `LLMModelRouteSnapshot`，不要再直接从 `AppSettings` 读取 provider base URL、模型名或 API key。
- `HTMLTranslationPipeline` 只翻译语义块，不翻译整份 HTML 字符串；当前候选选择器包括 `p`、`h1...h6`、`figcaption`、`blockquote`、`li`。
- HTML 全文翻译必须按语义块增量落盘和刷新展示：每完成一个块（包括缓存命中）就插入 `.rp-translation-block`、写回 `paper.html` 并通知阅读器刷新；不要等所有段落翻译完成后再一次性展示。
- HTML 翻译进度在阅读器中优先使用确定型进度条展示；如果已知总段数，至少同时显示线性进度和 `processed/total` 计数，不要只保留 `1/xxx` 这类纯文本进度提示。
- HTML 翻译会保护 `math`、`.ltx_Math`、`cite`、`code`，生成 `[PROTECTED_N]` 占位符；改 prompt 或渲染时必须保持占位符可恢复。
- PDF 翻译进度在阅读器中也优先使用确定型进度条和阶段文案。当前 `BabelDocRunner` 通过受控 Python bridge 订阅 BabelDOC 内部 progress events，把结构化事件以 JSON line 输出给 Swift 侧解析；不要回退成依赖 rich/tqdm 终端文本渲染结果做正则猜测。
- 设置页中的翻译配置已拆成 `Translation`、`Providers`、`Models` 三个区块。后续扩展优先沿用这个结构，不要再加回“单 Base URL + 三个模型名”的旧表单。
- 设置页中的 BabelDOC 区域要区分“当前已安装版本”和“目标版本”：当前版本应来自对本地 `babeldoc` 可执行文件的实际探测并只读展示，目标版本才是用户可编辑、用于 `uv tool install ... BabelDOC==<version>` 的配置值；不要把可编辑输入框误当成已安装状态展示。
- macOS 设置页的字符串输入框在快速切换焦点，尤其配合中文输入法或其他有 marked text / suggestions / Writing Tools 参与的输入路径时，可能打出 `NSXPCDecoder validateAllowedClass:forKey:` 且 allowed classes 含 `NSObject` 的系统警告。当前经验判断这更像 AppKit / 输入法 / Writing Tools 的系统日志，而不是项目里某个业务 `NSSecureCoding` 白名单真的写错。遇到这类报错时，先排查是否发生在设置页输入焦点切换，而不要优先沿 SwiftData、Keychain 或业务解码链路误判。
- Reader 和设置页里的 LLM 错误要尽量按场景区分，例如 HTML 路由缺失、PDF 路由缺失、provider 被禁用、API key 缺失、测试模型不可用，而不是统一报成一个笼统的缺配置错误。
- BabelDOC 通过 `BabelDocRunner` 和 `ProcessRunner` 启动外部进程，参数中的模型、base URL 和 API key 来自 PDF route snapshot；API key 要使用现有 redaction 逻辑，不要把外部工具失败吞掉成静默失败。
- BabelDOC 的 launcher 可能是 `uv tool install` 生成的 `sh` 包装器，第一行 shebang 不一定就是实际 Python 解释器；改启动逻辑时要兼容“同目录 venv `python3`/`python` + shell wrapper `exec .../python3`”这类结构，不要简单假设 `#!/usr/bin/env python3`。
- `ProcessRunner` 需要持续 draining stdout/stderr，并正确响应取消；改动时保留大输出和取消相关测试。

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
- 与阅读模式切换相邻、语义上属于“二选一 / 多选一”或并列主操作的按钮，视觉上优先向阅读器里的 `htmlDisplayPicker` / segmented control 靠拢：保持紧凑、等权、成组展示，必要时使用共享圆角底板和分隔线；避免混入单个过强的 `.borderedProminent` 按钮破坏整组节奏。空状态里的并列 action 也优先遵循这套样式，并预留足够宽度保证文案完整展示。
- arXiv 导入进度要尽量使用确定型、分步骤的状态反馈；如果链路已知关键阶段，至少同时展示当前步骤标题和阶段性说明，不要退回成只有转圈、没有上下文的等待态。若 HTML 主源失败并回退到备用源，也要把“正在尝试备用源”明确告诉用户。
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

重点测试映射：

- arXiv ID、Atom XML：`ArxivClientTests`
- 文件目录和附件写入：`PaperFileStoreTests`
- 本地 PDF 导入、arXiv ID 误判回归、arXiv 导入进度阶段：`PaperImporterTests`
- HTML 导入、本地化与 Readability 回退：`HTMLLocalizerTests`
- HTML 候选抽取、占位符保护、译文插入：`HTMLTranslationPipelineTests`
- BabelDOC 参数、progress bridge、敏感信息遮蔽、子进程输出/取消：`BabelDocRunnerTests`
- provider 校验、base URL 规范化、连接测试：`LLMProviderValidationUseCaseTests`
- provider/model route 解析与缺配置错误：`LLMRouteResolverTests`
- OpenAI-compatible `/v1` 回退与代理路径保留：`OpenAICompatibleLLMProviderTests`
- settings 初始化保障：`LLMConfigurationBootstrapperTests`
- 运行时语言选择、bundle 规范化/回退、代表性本地化行为：`LanguageManagerTests`、`LocalizationBehaviorTests`

涉及真实网络、OpenAI API、BabelDOC 安装或真实 PDF 翻译的测试不要默认加入单元测试；优先用可注入依赖、临时目录和小样本文本覆盖行为。

涉及本地化改动时，再额外注意两点：

- 不要让测试依赖执行环境当前系统语言；必要时像 `PaperImporterTests` 一样显式固定 language override，并在 `tearDown` 恢复。
- 变更 app-owned 错误、状态文案或语言切换逻辑时，优先补充 `LanguageManagerTests`、`LocalizationBehaviorTests` 或对应错误类型的定向断言，避免只在手工切语言时发现回归。
