# 论文库同步

Mac 与 iPad 共用原生同步客户端，入口是 **设置 → 同步**。现有 iPad target 仍只支持 iPad；
同步层可以供以后适配的 iPhone 界面复用。

Freddie 不内置同步服务器，也没有默认地址。需要有人部署自托管的
[Freddie Sync Server](https://github.com/SYYANI/freddie-sync-server)，并为每台设备签发凭证；
部署、签发和撤销凭证见该仓库的 README。

## 连接设备

1. 从服务器部署方拿到这台设备自己的凭证文件（JSON，含服务器地址和设备 token）。
2. 在“设置 → 同步”点击“导入设备凭证并连接…”，选择该文件。iPad 先把文件放进“文件”App。
3. App 显示凭证里的服务器地址，确认后才连接并上传论文库。之后重新导入同一服务器的凭证
   不再询问，换到另一台服务器时会再次确认。

每台设备使用各自的凭证，不要在设备之间复制同一份。

Windows、Linux 和 macOS 上的跨平台版 Freddie（Electron）在“设置 → 同步”用同样的凭证接入
同一个库，同步的内容与 Mac/iPad 相同，包括 PDF 批注和翻译缓存。它采用与原生相同的存储格式，
同一模型的翻译缓存在两端互相命中。

凭证导入后存入 Keychain，不打包进 App，不写进 SwiftData 或同步数据。iOS Keychain
使用 `AfterFirstUnlockThisDeviceOnly`，恢复到另一台设备后应导入新的设备凭证。

自动同步通常每 30 秒检查一次，回到前台时立即检查；也可以暂停自动同步，单独点
“立即同步”。设置页显示阶段、进度、待处理数量、最近成功时间、错误和冲突。

## 同步内容

- 论文元数据、收藏、文件夹归属、手动文献类型。
- PDF、HTML、译文 PDF、网页本地资源、译文诊断文件。
- PDF 高亮、下划线、文本批注和带压力宽度的笔迹，按单条批注 UUID 同步。
- 旁注、翻译缓存、阅读位置；缩放比例留在各设备。
- Markdown 写作稿和 `assets/` 图片，保留原 UUID 和论文引用链接。

不上传 LLM API Key、provider/model 配置、窗口与外观偏好、BabelDOC runtime、
LaTeX/扫描重建中间文件、全文索引或可重新生成的目录缓存。

附件的主文件和 `translatedLastPage` 作为同一数据项应用。partial 译文不会把原文的
阅读位置夹到已翻译页数之内。HTML 与 Markdown 按校验后的原始文件字节导入；写作稿只
重建本地 `meta.json`，不重写下载的 Markdown。

## 离线、冲突和恢复

本地库始终可独立使用。状态位于 Application Support/ReadPaper/Sync，未修改 SwiftData
schema。客户端比较可版本化 DTO 和文件指纹，不依赖 `Paper.modifiedAt` 检测收藏或移动。
文件哈希和快照在后台 actor 中处理；元数据和文件批量应用后只保存一次模型上下文。

待上传意图、固定请求 ID、服务器游标和未应用的远端记录都会落盘。连接恢复或 App 重启后
可继续处理；超时重试不会重复创建条目。限流按退避重试。已校验文件按 SHA-256 复用，
当前客户端在单个下载中断后会重试该文件，尚未持久化单文件的字节级续传进度。

论文的不同字段修改可以三方合并，阅读位置与翻译缓存有各自的合并规则。同一字段、
正文或文件的冲突会保留两个版本，设置页可选择“保留此设备的版本”或“使用服务器版本”；
写作稿还可“保留两篇写作稿”，复制稿保留自己的图片。

另一台设备删除论文时，如果本地还有未同步笔记等内容，会先保留论文及附件并要求处理
冲突。“保留此设备的版本”会一起恢复该论文仍需保留的子项。接受远端版本时，本地恢复
副本保存在 Sync/Recovery；远端删除的本地文件也会先移到该目录。

正在翻译、标注、调整 HTML 区域或编辑旁注/写作稿的文档会延后应用远端修改。
翻译任务的保护独立于阅读器视图生命周期；关闭阅读器不会让仍在运行的任务失去保护。
接收阅读位置不会强制跳动当前正在阅读的页面。服务器历史标识变化时暂停自动覆盖，
经“核对已变化的服务器历史”重新对账，保留本地库和旧状态副本。

原始文件、本地 `ReadPaper.store` 和同步状态都需要保留。不要把数据库放进网盘共同打开，
也不要单独删除 Sync 目录来强制同步。

## 开发与验证

实现位于 `ReadPaper/Services/LibrarySync/`；共享设置视图为
`ReadPaper/Views/LibrarySyncSettingsView.swift`。

协议 v1 的原生 payload 包含 `schemaVersion`、`documentHash` 和可选的 `scope`。
`documentHash` 指向版本化原生 DTO，引用的文件 hash 与 DTO hash 一起列入 record.blobs。
文件路径均为受验证的相对路径，拒绝绝对路径、父目录逃逸、符号链接和保留目录覆盖。
新增不能被旧客户端安全处理的字段/变体时须升级 DTO schemaVersion。

```sh
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper \
  -destination 'platform=macOS' -derivedDataPath /tmp/read-paper-derived-data \
  -only-testing:ReadPaperTests/LibrarySyncTests CODE_SIGNING_ALLOWED=NO test
```

默认回归使用两套临时 SwiftData 库和可注入服务，不访问生产论文库或真实服务。
真实 HTTPS 测试需显式提供**独立测试库**的两份凭证，测试文件应放在私有临时目录，
避免测试宿主直接读取桌面触发 macOS 目录访问授权：

```sh
TEST_RUNNER_READPAPER_SYNC_TEST_CREDENTIAL_A=/tmp/private-sync-test/a.json \
TEST_RUNNER_READPAPER_SYNC_TEST_CREDENTIAL_B=/tmp/private-sync-test/b.json \
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper \
  -destination 'platform=macOS' -derivedDataPath /tmp/read-paper-derived-data \
  -only-testing:ReadPaperTests/LibrarySyncTests/testLiveHTTPSRoundTripWhenCredentialsAreProvided \
  CODE_SIGNING_ALLOWED=NO test
```

真实网络测试覆盖 8 MiB 附件、中文旁注、收藏和删除的双客户端完整往返。协议 v1 的
请求格式、错误码和客户端约定见服务器仓库 README 的“协议 v1”和“客户端约定”。
