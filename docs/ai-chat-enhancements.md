# 聊天增强实现与验收记录

## 使用方式

- Provider 设置新增 **OpenAI Responses**，与 **OpenAI Chat Completions** 分开选择；已有配置保持原协议。
- 聊天输入栏的调节按钮包含模型入口，以及 OpenAI 协议的推理档位「默认／低／中／高」和服务档位「默认／优先」。选择只影响当前会话，历史恢复会恢复选择。Claude、Gemini 不显示档位。
- 回答中的「查看原文」「查看章节」链接使用工具登记的位置。生成结束或停止后可点击；同书直接定位，跨书会先关闭旧阅读页。打开书籍保留聊天会话。
- 流式输出时向上拖动或使用滚轮会暂停自动跟随，滚回底部后恢复。发送新消息、恢复历史会滚到底部。

## 实现要点

- `OpenAiHttpModel` 实现共同的单轮模型接口，Chat Completions 和 Responses 共用现有工具循环；Claude、Gemini 继续使用原 LangChain 适配器。未修改外部 LangChain 分支，也未新增依赖。
- Responses 请求使用 `store:false` 和 `reasoning.encrypted_content`；保存原生 output 项、函数调用与结果，续聊不以展示文字替代协议上下文。工具 schema 显式指定 `strict:false`。
- 会话历史增加 `session`，包含档位、运行状态、原生上下文、重新生成检查点及引用。旧记录使用默认值；切换 Provider、地址、协议或模型会清除原生上下文。失败或取消的回合不会作为完整协议上下文提交。
- 每次生成固定参数。仅在服务端明确拒绝档位参数、且尚未产生回答／推理／函数调用时重试，每项参数最多移除一次。成功后才把会话对应选项改为默认。认证、限流、普通请求错误不会触发回退。
- 停止会中断 HTTP 连接、限速等待和后续工具循环；已经开始的工具可能完成自身操作，但不会再执行剩余工具或发起下一轮模型请求。
- 引用绑定书籍 ID、可用 MD5、章节、CFI/href、摘录和程序生成的 ID。搜索和笔记登记精确引用，目录和整章读取登记章节引用。客户端只接受当前会话登记的引用；无效引用、书籍删除、文件缺失或已登记指纹不符会提示。
- WebView 导航参数使用 JSON 编码；跨书等待旧路由销毁及清理完成，再建立新阅读状态，目标阅读器就绪后定位。引用打开不触发自动前文总结。
- Pi、自动压缩、整章逐段定位、临时高亮和模糊重定位未纳入本次实现。

## 自动验证

验证环境：Flutter 3.47.2 / Dart 3.13.2，与项目 CI 的 Flutter 版本一致。

- HTTP/SSE：任意字节拆包、中文、工具参数分片、多个调用、原生推理回传、历史恢复与重新生成、正常终止／不完整／中断。
- 回退：两种协议字段、默认省略、逐项回退、重复拒绝终止、失败不改档位、输出后不重试、认证／限流不回退，工具执行后重试不重放工具。
- 真实 loopback HTTP mock：流式连接取消、非聊天文本生成、模型列表获取。另验证工具执行中停止不会启动剩余工具。
- 会话与引用：快照隔离、旧历史、状态恢复、搜索／笔记／章节引用、未知 ID、特殊字符、跨会话隔离。
- Widget：四种协议的菜单、会话选择与恢复、生成期间菜单锁定及停止恢复、Markdown 引用点击、拖动与轻微滚轮暂停跟随、回到底部恢复。

执行命令：

```sh
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n
flutter test
flutter analyze --no-pub
git diff --check
```

全量离线测试 41 项通过；4 项真实端点测试默认跳过，需显式启用。全量静态检查没有 error；仍有仓库原有的 4 条 warning（旧插件配置和其他文件的未使用 import）及既有 info，未作为本次变更扩展清理。

## 真实端点验收（2026-10-05）

使用本机 Anx 已配置的 `gpt-6.1-sol`，同一网关分别请求 `/v1/chat/completions` 和 `/v1/responses`，直接运行项目实际 HTTP 适配器和 Agent 循环。仅使用合成记录，不发送个人书库内容，不修改 Provider 配置。

- 4 项真实测试全部通过：两种协议分别执行两次工具、回传结果、正确回答并续聊；工具均只执行一次。
- Responses 原生上下文经 JSON 序列化恢复后续聊成功；回退检查点后重新生成成功，没有混入上一轮函数调用。
- 默认、低、中、高推理和优先服务参数请求成功，网关未明确拒绝，因此未触发回退。这只能证明接口接受参数，不能证明上游实际采用了对应服务调度。
- 两种协议在收到流式数据后取消，3 秒内结束，没有继续输出。
- 网关未返回加密 reasoning 项；加密状态保留与回传仍只有 mock 验证。参数拒绝后的回退、认证及限流错误分支也以 mock 验证，未刻意制造真实限流。

真实验收发现并修复：网关在 `response.output_item.done` 返回完整项，却在 `response.completed` 省略 output。适配器现在保留已完成项，在结束帧缺少 output 时按输出索引恢复，避免遗漏工具调用与历史上下文；新增离线回归测试。只保存 done 项，不使用 added 帧中的不完整加密内容。

手动启用真实验收：准备权限为 `600` 的私密 JSON 文件，包含 `url`、`model`、`apiKey`，然后运行：

```sh
ANX_LIVE_CONFIG=/private/path/provider.json flutter test --no-pub test/service/ai/live_provider_test.dart --reporter expanded
```

凭据文件不进入仓库；日志只记录档位、计数及合成文本。

## GitHub Actions 构建与本机安装（2026-10-05）

按用户要求停止本机 Xcode 安装，改为手动触发 `.github/workflows/build-macos-manual.yaml`。工作流使用 macOS 15、Xcode 26.2、项目指定 Flutter 版本，执行代码生成、静态检查、全量测试、release 构建和临时签名，上传带提交号及 SHA256 的 ZIP；不发布 Release。

- [最终构建成功记录](https://github.com/slovx2/anx-reader/actions/runs/37262110429)，源码提交 `801c4de6d90a6d3e7901461a2569601780ae3d4a`。
- CI 41 项离线测试通过，4 项真实端点测试按预期跳过；静态检查无 error，已有 warning/info 保留。
- 校验 ZIP SHA256 和应用签名后，覆盖安装到 `/Applications/AnxReader.app`。版本 1.15.0，支持 arm64/x86_64；采用非商店数据目录，与原有安装一致。
- 旧应用、数据库、配置及聊天历史保存在 `/Volumes/workspace/anx-reader-backups/20261005-114956`。未升级系统、未关闭系统安全保护。验收包使用临时签名，未做 Apple 公证。

## 桌面 E2E 实证与边界

使用两本自建 EPUB 和专门的引用会话，避免把个人书籍正文发送给服务端。最终包验证了：

- 启动后原书库、Provider 和个人历史可用；重启后能恢复引用集合。
- 聊天菜单恢复会话的「中／优先」选择。
- 首页引用打开目标书；分屏引用定位至精确 CFI，正文显示预置暗号，聊天保留。
- 跨书引用打开另一测试书的指定章节，重新展开聊天后仍为同一会话。
- 弹层点击原文引用后自动收起，正文准确定位；未知引用显示明确提示。
- 真实长文本流式回答期间上滚后，连续两次截图视口保持不变；手动滚回底部可查看最终回答。生成中的恢复跟随行为另由 Widget 测试覆盖。

验收发现 WebView `evaluateJavascript` 对异步导航返回 Promise 时报告不支持的结果类型。已改为 `callAsyncJavaScript` 等待导航完成并返回空值，最终包同书、跨书及弹层回归通过，未再出现该错误或重复 GlobalKey 错误。

运行中记录到 Flutter 辅助功能树刷新错误（`Failed to update ui::AXTree`），部分控件的辅助功能状态滞后，坐标点击仍可操作。弹层自动化文本输入也未稳定成功，因此没有把「桌面真实搜索生成引用」计为通过；工具登记由单元测试覆盖，真实协议工具循环由前述接口测试覆盖。辅助功能错误的根因尚未确定，不能据此宣称完整无障碍验收通过。

仍未做真实 Claude/Gemini 调用、真实 encrypted reasoning 回传和所有文件失效场景的桌面验收。凭据或上游行为相关限制见真实端点记录，不用 mock 结果代替。

测试结束已定向移除两本合成书、对应阅读记录和三个测试会话，保留两条原有个人会话，恢复原来的自适应聊天显示模式。Provider 地址、密钥、协议和模型未改动；正常请求更新的密钥轮转索引及更新时间保留。截图及运行日志位于备份目录的 `e2e-evidence` 子目录，未提交含本机数据的日志。

## Android 与 fork Release（2026-10-08）

- [Android APK 构建与完整检查](https://github.com/slovx2/anx-reader/actions/runs/37650059090)通过。Ubuntu 24.04 构建 APK，macOS 15 执行完整测试，避免在项目未适配的 Linux 桌面环境运行 Widget。41 项离线测试通过，4 项真实接口测试默认跳过；静态检查没有 error。
- 新增手动工作流 `build-android-manual.yaml`，固定 Flutter、Java 17.0.17+10 和 Actions 版本，支持指定源码提交。产物包括 universal、arm64-v8a、armeabi-v7a、x86_64 四种 APK。
- APK 使用 fork 的固定发布密钥，四个产物均经 `apksigner` 验签，证书 SHA256 与保存的发布密钥一致；下载后核对 SHA256、ZIP 完整性及对应原生架构。尚未做 Android 真机安装验收。
- DMG 使用前述已验收的 macOS 应用生成，未重新编译；镜像校验、挂载、应用签名与双架构检查通过。
- 两端功能源码均为 `801c4de6d90a6d3e7901461a2569601780ae3d4a`；[fork Release](https://github.com/slovx2/anx-reader/releases/tag/fork-v1.15.0-chat.1)提供 APK、DMG、SHA256SUMS 和 BUILDINFO。
- 固定 Android 密钥在本机 `~/.config/anx-reader-release` 和 fork 的 Actions Secrets 中保存，不进入仓库。与官方 APK 签名不同，不能直接覆盖官方安装；后续 fork 构建沿用同一密钥。
