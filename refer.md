# PDF 论文结构化、翻译与展示实现参考

本文档总结当前项目中与“PDF 论文结构化处理、翻译、最终展示”相关的实现思路，便于在另一个版本中复刻或重新设计。结论先行：当前项目并没有实现一个通用的“任意 PDF -> 结构树 -> 全文翻译 -> 双语排版”的纯自研管线，而是把能力拆成三条互补路径：

- 本地 PDF：做轻量元数据抽取、补全、下载与阅读展示。
- arXiv 论文：优先拉取 arXiv/ar5iv HTML，将 HTML 作为结构化全文载体，按段落翻译并内嵌展示。
- 完整 PDF 翻译：调用外部 BabelDOC 命令生成翻译后的 PDF，再用双栏 PDF 阅读器展示。

## 1. 推荐总体架构

建议将实现拆成以下层次：

1. 采集层
   - 支持本地 PDF 导入、URL/DOI/arXiv ID 添加、外部列表源导入。
   - 本地 PDF 导入时只做轻量识别，不要试图一开始就完整解析 PDF 版面。

2. 元数据层
   - 从 PDF Info dictionary 提取标题、作者、主题等字段。
   - 从 PDF 前几页文本中用正则识别 DOI 和 arXiv ID。
   - 用 DOI/arXiv ID/title 走外部 API 补全元数据和开放获取 PDF URL。

3. 结构化全文层
   - 对 arXiv 论文，优先获取 HTML 全文：`https://arxiv.org/html/{id}`。
   - 失败时回退：`https://ar5iv.labs.arxiv.org/html/{id}`。
   - 将 HTML 中的图片、CSS 等资源内联，保存为本地 `paper.html`。
   - HTML 是后续段落翻译、批注、显示模式切换的主要结构载体。

4. 翻译层
   - 标题/摘要/划词翻译：调用 OpenAI-compatible Chat API，并缓存到数据库。
   - HTML 全文翻译：按 DOM 选择器抽取段落、标题、图注等元素，保护公式后并发调用 LLM，把译文块插回 HTML。
   - PDF 全文翻译：交给 BabelDOC 等外部 PDF 翻译服务，输出翻译后的 PDF。

5. 展示层
   - PDF：用 PDF.js 系生态渲染，支持批注、搜索、页码导航。
   - 翻译 PDF：左侧原文 PDF，右侧翻译 PDF，按页码和页内比例同步滚动。
   - HTML：iframe 加载本地 HTML，注入脚本支持批注、译文块插入、原文/双语/译文模式。

## 2. 本地 PDF 导入与轻量结构化

本地 PDF 导入流程建议如下：

1. 校验文件存在且扩展名为 `.pdf`。
2. 用 PDF 解析库读取 Info dictionary：
   - `/Title`
   - `/Author`
   - `/Subject`
   - 自定义 DOI 字段，如 `doi`、`DOI`
3. 从前 3 页提取纯文本：
   - 用 DOI 正则查找 `10.xxxx/...`
   - 用 arXiv 正则查找 `arXiv:2301.12345v2` 等形式
4. 如果标题不可用，则用文件名作为 fallback。
5. 创建论文目录，例如：
   - `metadata.json`
   - `paper.pdf`
   - `paper.html`，如果后续能获取 HTML
   - `attachments/`
   - `notes/`
6. 将 PDF 复制到论文目录并登记附件记录。
7. 后台启动元数据补全。

注意：这个阶段不要把“PDF 文本抽取”当成稳定的结构化全文来源。很多论文 PDF 的多栏、公式、表格、脚注、页眉页脚会让纯文本顺序不可靠。当前项目只用 PDF 文本做 DOI/arXiv ID 识别。

## 3. 元数据补全策略

推荐补全顺序：

1. 如果有 arXiv ID：
   - 直接生成 PDF URL：`https://arxiv.org/pdf/{id}`
   - 尝试拉取 arXiv HTML。

2. 如果有 DOI：
   - CrossRef：主元数据来源。
   - Semantic Scholar：补开放获取 PDF、外部 ID、摘要等。
   - OpenAlex：补开放获取信息或作为 CrossRef 失败时的 fallback。
   - Unpaywall：补 OA PDF URL。

3. 如果只有标题：
   - OpenAlex title search。
   - DBLP title search。
   - Semantic Scholar title search。
   - CrossRef bibliographic search。

4. 合并策略：
   - CrossRef 更适合作为正式出版元数据来源。
   - Semantic Scholar / OpenAlex 更适合作为补充来源。
   - 已有用户输入字段不要轻易覆盖，除非来源可信或字段为空。

## 4. arXiv HTML 获取与本地化

如果识别到 arXiv ID，建议自动尝试获取 HTML 全文：

1. 先请求 `https://arxiv.org/html/{arxiv_id}`。
2. 如果失败，请求 `https://ar5iv.labs.arxiv.org/html/{arxiv_id}`。
3. 解析 `<base href>` 或以 HTML URL 为基准解析相对资源。
4. 下载并内联图片：
   - `img[src]`
   - `source[srcset]`
   - 转为 `data:{mime};base64,...`
5. 下载并内联 CSS：
   - 处理 `<link rel="stylesheet">`
   - 递归处理 `@import`
   - 修正 CSS 内 `url(...)` 相对路径
6. 移除外部 `<script src="...">`，避免离线不可用和安全问题。
7. 保存为本地 `paper.html`。
8. 写入附件记录：`file_type = "html"`。

可以额外清理 HTML 中的导航、页脚、站点按钮等无关元素。当前项目采用“隐藏元素”而不是删除元素的方式，避免破坏文档布局。

## 5. HTML 全文翻译算法

HTML 翻译的核心不是“翻译整个 HTML 字符串”，而是按语义块翻译并回写：

1. 解析 HTML DOM。
2. 选择可翻译元素：
   - `p`
   - `h1` 到 `h5`
   - `figcaption`
   - `blockquote`
3. 跳过已经翻译过的元素：
   - 通过 `data-zotero-translation="true"` 标记。
4. 抽取元素文本：
   - 删除 `<cite>...</cite>`，避免翻译引用噪声。
   - 将 `<math>...</math>` 替换为 `[MATH_0]`、`[MATH_1]` 等占位符。
   - 保留粗体/斜体标记，可转成 Markdown 风格 `**bold**`、`__italic__`。
5. 对短文本设置长度阈值：
   - 段落、图注、引用块可要求至少 10 个字符。
   - 标题可放宽到 2 个字符。
6. 去重：
   - 如果一个元素的文本完全包含在更大的元素文本中，跳过小元素，减少重复翻译。
7. 并发调用 LLM：
   - 默认并发可设为 8。
   - 通过设置项允许用户调整。
8. 构建译文块：
   - 译文 HTML 使用同样的 tag。
   - 添加 class，例如 `.zr-translation-block`。
   - 添加属性 `data-zotero-translation="true"`。
   - 将 `[MATH_N]` 占位符恢复成原始 MathML。
9. 插入位置：
   - 根据 tag 和原文文本片段定位元素结束标签。
   - 在原文元素后插入译文块。
   - 给原文元素也加上 `data-zotero-translation="true"`。
10. 持久化：
   - 每插入一段后写回 HTML 文件，避免长任务中断后丢失进度。
11. 前端同步：
   - 每段插入后发事件给前端 iframe，前端即时插入译文块。
   - 完成后发完成事件，前端可刷新 HTML。

推荐 prompt 约束：

- 角色：专业学术翻译。
- 保持学术语气和术语准确性。
- 不要修改 `[MATH_N]` 占位符。
- 保留 `**bold**` 和 `__italic__` 格式。
- 只输出译文，不要解释。

## 6. 标题、摘要、划词翻译

标题/摘要/划词翻译可以走一个更轻的路径：

1. 统一使用 OpenAI-compatible Chat API。
2. 为不同任务配置不同模型：
   - quick：划词翻译。
   - normal：标题/摘要翻译。
   - heavy：全文 HTML 翻译。
   - glossary：术语抽取。
3. 翻译结果写入数据库缓存：
   - entity type，例如 `paper`、`subscription_item`、`note`
   - entity id
   - field，例如 `title`、`abstract_text`、`ai_summary`
   - target language
   - translated text
   - model
4. 列表页和详情页先读缓存；缺失时再后台翻译。
5. 支持显示模式：
   - original：只显示原文。
   - translated：只显示译文。
   - bilingual：双语显示。

## 7. 完整 PDF 翻译

完整 PDF 翻译建议作为可选能力，不要和 HTML 段落翻译混为一体。

当前项目的做法是调用 BabelDOC CLI：

1. 用户在设置中启用 PDF 翻译。
2. 配置：
   - BabelDOC 命令路径，默认 `babeldoc`
   - 是否复用主 AI 配置
   - 自定义 base URL / API key / model
   - QPS
   - 额外参数，例如 `--no-dual`
3. 找到要翻译的 PDF：
   - 优先使用用户指定 filename。
   - 否则使用 `paper.pdf`。
   - 否则寻找第一个 PDF 附件。
4. 输出文件名：
   - `{source_stem}.{native_lang}.pdf`
   - 例如 `paper.zh.pdf`
5. 创建临时输出目录，例如 `_babeldoc_temp`。
6. 启动 BabelDOC 子进程：
   - `--openai`
   - `--openai-model`
   - `--openai-base-url`
   - `--openai-api-key`
   - `--files`
   - `--output`
   - `--lang-out`
   - `--qps`
   - `--watermark-output-mode no_watermark`
7. 翻译完成后在临时目录寻找 PDF 输出。
8. 移动或复制到论文目录。
9. 登记为 PDF 附件，source 可设为 `pdf-translation`。
10. 发出 `paper-updated` 或类似事件让前端刷新附件列表。

注意事项：

- 桌面应用在 macOS/Linux GUI 环境里可能拿不到用户 shell PATH，需要主动解析命令路径。
- 建议支持绝对路径配置。
- 日志里要遮蔽 API key。
- 子进程失败时要清理临时目录。
- 该路径依赖外部工具能力，不保证每篇 PDF 都有稳定输出。

## 8. PDF 展示与双语展示

PDF 展示建议使用 PDF.js 生态：

1. 后端只返回本地文件绝对路径。
2. 前端用 Tauri FS 读取文件为 `Uint8Array`。
3. 创建 `Blob URL`。
4. 交给 PDF.js / `react-pdf-highlighter` 渲染。
5. 批注按 PDF 文件名分 scope 存储，避免原文 PDF 与译文 PDF 批注混在一起。

双语 PDF 展示：

1. 左侧：原始 PDF。
2. 右侧：翻译 PDF。
3. 每侧各自有批注状态。
4. 滚动同步按页码和页内比例实现：
   - 建立每页 `offsetTop` 和 `height` 缓存。
   - 源侧滚动时计算当前页和页内比例。
   - 目标侧滚到同页同等比例位置。
5. 使用 `MutationObserver` 和 `ResizeObserver` 在页面懒加载、缩放、窗口变化时刷新缓存。

## 9. HTML 展示与交互

HTML 阅读器建议用 iframe：

1. 前端读取本地 `paper.html`。
2. 通过 `srcDoc` 注入 iframe。
3. 注入脚本能力：
   - 外部链接拦截并交给宿主打开。
   - 锚点跳转。
   - 缩放。
   - 译文块增量插入。
   - 译文块双击编辑。
   - 原文/双语/译文模式切换。
   - 批注脚本。
4. 显示模式实现：
   - original：隐藏 `.zr-translation-block`。
   - translated：隐藏已经标记为 `data-zotero-translation="true"` 的原文元素，保留译文块。
   - bilingual：不注入隐藏规则，原文和译文都显示。
5. 如果 HTML 中仍有相对图片路径，前端可将其转换为本地 asset URL。

## 10. 关键外部依赖清单

运行时外部服务/工具：

- OpenAI-compatible Chat Completions API：所有 LLM 翻译能力的基础。
- BabelDOC CLI：完整 PDF 翻译。
- arXiv HTML：`https://arxiv.org/html/{id}`。
- ar5iv fallback：`https://ar5iv.labs.arxiv.org/html/{id}`。
- CrossRef：出版元数据。
- Semantic Scholar：外部 ID、摘要、开放获取 PDF 等。
- OpenAlex：元数据与开放获取 fallback。
- Unpaywall：开放获取 PDF URL。
- DBLP：计算机科学论文标题搜索 fallback。
- papers.cool：论文列表/摘要结构化来源，不是 PDF 全文结构化核心。

关键 Rust crate：

- `reqwest`：HTTP 请求。
- `tokio`：异步任务和后台任务。
- `lopdf`：PDF 元数据和前几页文本提取。
- `scraper`：HTML DOM 解析。
- `regex`：DOI、arXiv ID、HTML 片段、CSS URL 等匹配。
- `base64`：图片/CSS 资源内联时生成 data URI。
- `url`：解析相对 URL。
- `futures`：HTML 段落并发翻译。
- `rusqlite`：翻译缓存、附件、论文元数据存储。
- `serde` / `serde_json`：配置、事件和元数据序列化。

关键前端依赖：

- `pdfjs-dist`：PDF 渲染底层。
- `react-pdf-highlighter`：PDF 高亮、区域批注、渲染集成。
- `react-pdf`：PDF 相关前端生态依赖。
- `@tauri-apps/plugin-fs`：读取本地 PDF/HTML 文件。
- `@tauri-apps/api`：Tauri command 调用和本地 asset URL 转换。
- `zustand`：翻译、阅读器、批注等全局状态。
- `react-i18next` / `i18next`：前端 UI 文案国际化。

## 11. 另一个版本的最小可行实现顺序

建议按以下顺序实现：

1. 论文数据模型和本地目录结构。
2. 本地 PDF 导入：复制文件、生成 metadata、记录附件。
3. PDF 轻量元数据抽取：标题、作者、DOI、arXiv ID。
4. 元数据补全：先做 arXiv、CrossRef、OpenAlex，之后再扩展 Semantic Scholar、Unpaywall、DBLP。
5. PDF 阅读器：加载本地 PDF 并展示。
6. arXiv HTML 获取：保存 `paper.html`。
7. HTML 阅读器：iframe 展示本地 HTML。
8. 标题/摘要翻译：LLM 调用 + 数据库缓存 + 双语显示。
9. HTML 全文翻译：段落抽取、公式保护、并发翻译、译文块回写。
10. HTML 增量事件：翻译时即时插入 iframe。
11. PDF 全文翻译：接入 BabelDOC，生成 `paper.{lang}.pdf`。
12. 双语 PDF 模式：原文/译文双栏、滚动同步、分文件批注。

## 12. 风险点

- 任意 PDF 的版面解析非常难，不建议在第一版自研完整结构化。
- arXiv HTML/ar5iv 只覆盖部分论文来源；非 arXiv 论文需要 PDF 翻译或第三方 HTML 快照能力。
- HTML 翻译插入依赖文本片段定位，遇到重复段落、复杂嵌套时可能跳过或插错。
- LLM 并发过高会触发限流，建议支持配置。
- 公式和引用必须保护；否则译文容易破坏数学表达。
- BabelDOC 是外部工具，安装、PATH、版本、输出文件名都要做容错。
- API key 不应进入日志。
- 译文缓存要按 target language 和 model 记录，避免切换语言后误用旧译文。
