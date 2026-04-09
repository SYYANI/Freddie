# AGENTS.md

本文件适用于整个仓库。后续 agent 在本项目中工作时，优先遵守这里的项目约定，再结合具体任务做最小必要改动。

## 项目概览

ReadPaper 是一个 macOS SwiftUI 论文阅读应用，使用 SwiftData 做本地数据模型，PDFKit 处理本地 PDF 轻量文本抽取，`swift-readability` 处理 arXiv/ar5iv HTML 正文抽取，SwiftSoup 处理 HTML 本地化和 HTML 段落翻译。项目最低 macOS 版本为 14.0，Swift 版本为 6.0，Xcode 项目由 `project.yml` 描述，依赖 SwiftSoup、`swift-readability` 和 `SwiftOpenAI`。

核心能力分成三条路径：

- 本地 PDF：导入 PDF，抽取 Info dictionary 和前几页文本，只用于标题、作者和 arXiv ID 等轻量识别；不要把 PDF 纯文本当成稳定全文结构。
- arXiv 论文：通过 arXiv API 获取元数据和 PDF，优先保存 `https://arxiv.org/html/{id}`，失败后回退到 `https://ar5iv.labs.arxiv.org/html/{id}`；获取 HTML 后优先用 `swift-readability` 提炼正文，再把 HTML、CSS、图片等资源本地化，若正文抽取失败再回退到原始 HTML。
- 翻译阅读：HTML 走 SwiftSoup DOM 分段翻译并插入 `.rp-translation-block`；完整 PDF 翻译交给外部 BabelDOC CLI，输出翻译 PDF 后用双栏 PDF 阅读器展示。

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

如果沙箱或受限终端里 `xcodebuild` 因 Xcode/SwiftPM/clang 缓存目录权限失败，不要先判断为代码失败；换到可写 Xcode 缓存的环境或使用 Xcode 运行后再确认。

## 目录职责

- `ReadPaper/ReadPaperApp.swift`：应用入口和 SwiftData `modelContainer` 注册。
- `ReadPaper/Models/`：SwiftData 模型和枚举。新增模型时同步检查 `ReadPaperApp` 中的 model container。
- `ReadPaper/Views/`：SwiftUI 界面，包含主布局、导入面板、阅读工具栏、设置页和检查器。
- `ReadPaper/Readers/`：PDF、HTML、双语 PDF 阅读器。
- `ReadPaper/Services/`：导入、arXiv API、HTML 本地化、翻译、BabelDOC、Keychain、文件存储、子进程运行等业务服务。
- `ReadPaperTests/`：XCTest 单元测试，重点覆盖 arXiv ID/Atom 解析、文件存储、HTML 翻译管线、BabelDOC 参数和进程运行。
- `project.yml`：XcodeGen 的项目源配置。调整 target、依赖、构建设置时改这里并重新生成项目。
- `ReadPaper.xcodeproj/project.xcworkspace/xcuserdata/`：Xcode 用户状态。除非任务明确要求，不要编辑或整理这类文件。
- `ReadPaper.xcodeproj/project.xcworkspace/xcuserdata/yiyan.xcuserdatad/UserInterfaceState.xcuserstate`：本地 Xcode 窗口/界面状态文件，默认视为无需处理的噪音文件；不要因为它是 dirty 而额外清理、提交或回退。

## 数据与文件约定

`PaperFileStore` 把应用数据放在 Application Support 下的 `ReadPaper` 目录，库文件位于 `Library/{paper UUID}`，每篇论文目录中会创建：

- `paper.pdf`
- `paper.html`
- `Resources/`
- `translations/`
- `notes/`

`paper.html` 当前默认保存的是适合阅读和翻译的本地化 HTML；对于 arXiv/ar5iv 导入，它通常是 `swift-readability` 提炼后的正文包装页，而不是原站完整页面快照。改导入链路时要注意这一展示语义。

附件通过 `PaperAttachment` 记录，类型包括 `pdf`、`html`、`translatedPDF` 和 `resource`，来源包括 `arxivPDF`、`arxivHTML`、`localImport`、`babeldoc` 和 `generated`。改文件写入逻辑时，要同时维护附件记录和 SwiftData 保存时机。

LLM 配置现已拆成独立 SwiftData 模型：`LLMProviderProfile` 负责 provider 名称、`baseURL`、`apiKeyRef`、`testModel` 和启用状态，`LLMModelProfile` 负责模型名、所属 provider 和高级参数。`AppSettings` 只保留全局翻译偏好与当前选中的 HTML/PDF model profile；旧的 `openAIBaseURL` / `quickModelName` / `normalModelName` / `heavyModelName` 仅用于一次性 bootstrap 迁移，不应再作为新运行时读取源。

翻译缓存位于 `TranslationSegment`，现在除 `paperID`、`sourceType`、`targetLanguage`、`sourceHash` 之外，还会记录 route identity（至少 `providerProfileID`、`modelProfileID`、`modelName`）。改缓存或查找逻辑时，不要让切换 provider/model 后继续命中旧译文。

## 翻译与外部工具

- OpenAI-compatible API 已改为多 provider / 多 model profile 结构。API key 仍然存于 Keychain，但通过 provider-specific `apiKeyRef` 关联；日志、错误和测试输出中不要泄露真实 key。
- `LLMConfigurationBootstrapper` 会在首次发现旧配置时，把 legacy `AppSettings` 和旧 Keychain key 迁移成 provider/model profiles，并默认把 HTML/PDF 路由指向 legacy heavy model。涉及 `AppSettings` 新字段时，优先保持 SwiftData 迁移安全，避免再新增会阻塞旧 store 启动的必填列。
- `OpenAICompatibleLLMProvider` 负责 `/chat/completions` 调用，保留代理 base path，识别版本段，并在 `404 + /v1` 场景下尝试去掉尾部版本段回退。`LLMProviderValidationUseCase` 负责 base URL 规范化、模型名校验、连接测试和错误归类。
- `LLMRouteResolver` 从 `AppSettings`、`LLMProviderProfile`、`LLMModelProfile` 和 Keychain 解析 HTML/PDF 两条独立路由。`HTMLTranslationPipeline` 与 `BabelDocRunner` 必须消费 `TranslationPreferencesSnapshot` / `LLMModelRouteSnapshot`，不要再直接从 `AppSettings` 读取 provider base URL、模型名或 API key。
- `HTMLTranslationPipeline` 只翻译语义块，不翻译整份 HTML 字符串；当前候选选择器包括 `p`、`h1...h6`、`figcaption`、`blockquote`、`li`。
- HTML 全文翻译必须按语义块增量落盘和刷新展示：每完成一个块（包括缓存命中）就插入 `.rp-translation-block`、写回 `paper.html` 并通知阅读器刷新；不要等所有段落翻译完成后再一次性展示。
- HTML 翻译进度在阅读器中优先使用确定型进度条展示；如果已知总段数，至少同时显示线性进度和 `processed/total` 计数，不要只保留 `1/xxx` 这类纯文本进度提示。
- HTML 翻译会保护 `math`、`.ltx_Math`、`cite`、`code`，生成 `[PROTECTED_N]` 占位符；改 prompt 或渲染时必须保持占位符可恢复。
- 设置页中的翻译配置已拆成 `Translation`、`Providers`、`Models` 三个区块。后续扩展优先沿用这个结构，不要再加回“单 Base URL + 三个模型名”的旧表单。
- 设置页中的 BabelDOC 区域要区分“当前已安装版本”和“目标版本”：当前版本应来自对本地 `babeldoc` 可执行文件的实际探测并只读展示，目标版本才是用户可编辑、用于 `uv tool install ... BabelDOC==<version>` 的配置值；不要把可编辑输入框误当成已安装状态展示。
- Reader 和设置页里的 LLM 错误要尽量按场景区分，例如 HTML 路由缺失、PDF 路由缺失、provider 被禁用、API key 缺失、测试模型不可用，而不是统一报成一个笼统的缺配置错误。
- BabelDOC 通过 `BabelDocRunner` 和 `ProcessRunner` 启动外部进程，参数中的模型、base URL 和 API key 来自 PDF route snapshot；API key 要使用现有 redaction 逻辑，不要把外部工具失败吞掉成静默失败。
- `ProcessRunner` 需要持续 draining stdout/stderr，并正确响应取消；改动时保留大输出和取消相关测试。

## 实现约定

- 优先保持 SwiftUI + SwiftData 的现有风格，避免引入新的架构层，除非任务明确需要。
- UI 状态尽量留在 View 内，持久化状态进入 SwiftData model，外部副作用放到 `Services`。
- 阅读器不同模式的缺失态/空状态要保持一致的视觉语义；例如缺少 HTML、PDF 或翻译 PDF 时，优先复用统一的居中 unavailable 组件，不要一处是完整空状态卡片、另一处只显示一行占位文字。
- 网络和子进程路径要可测试：通过可注入的 `URLSession`、`FileManager`、`ProcessRunner` 或配置快照传入依赖。
- 处理本地文件时使用 `URL`/`FileManager`，不要拼接易碎路径字符串，除非已有模型字段需要保存 `.path`。
- 涉及 SwiftData 的异步 UI 流程目前多在 `@MainActor` 上运行；改并发代码时显式考虑 actor 隔离和取消。
- 涉及 HTML 正文提取时优先复用 `HTMLLocalizer` 里的 `swift-readability` 路径；不要重新引入一套手写正文选择器去替代它。SwiftSoup 主要用于正文抽取之后的 DOM 本地化、资源重写和译文插入。
- `HTMLLocalizer` 对明显过短、价值很低的 readability 结果会回退到原始文档；不要为了统一外观强行把所有页面都包进 readability shell。
- 本地化 HTML 时优先隐藏或重写必要元素；但如果已经进入 `swift-readability` 的正文模式，允许直接替换为提炼后的正文包装页，不必强求保留原站完整布局。
- 不要把 PDF 解析扩展成“任意 PDF 全文结构化翻译”的承诺；完整 PDF 翻译应继续作为 BabelDOC 外部工具路径。

## 测试建议

窄改动优先跑相关测试文件；跨服务或模型改动跑完整 `ReadPaper` scheme 测试。

重点测试映射：

- arXiv ID、Atom XML：`ArxivClientTests`
- 文件目录和附件写入：`PaperFileStoreTests`
- HTML 导入、本地化与 Readability 回退：`HTMLLocalizerTests`
- HTML 候选抽取、占位符保护、译文插入：`HTMLTranslationPipelineTests`
- BabelDOC 参数、敏感信息遮蔽、子进程输出/取消：`BabelDocRunnerTests`
- provider 校验、base URL 规范化、连接测试：`LLMProviderValidationUseCaseTests`
- provider/model route 解析与缺配置错误：`LLMRouteResolverTests`
- OpenAI-compatible `/v1` 回退与代理路径保留：`OpenAICompatibleLLMProviderTests`
- legacy 配置 bootstrap 迁移：`LLMConfigurationBootstrapperTests`

涉及真实网络、OpenAI API、BabelDOC 安装或真实 PDF 翻译的测试不要默认加入单元测试；优先用可注入依赖、临时目录和小样本文本覆盖行为。
