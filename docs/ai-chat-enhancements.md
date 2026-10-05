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

## 尚待环境验收

- 尝试 `flutter build macos --debug --no-pub`，因机器只有 Command Line Tools、缺少完整 Xcode，`xcrun xcodebuild` 不可用而失败。构建工具自动修改的 macOS 工程文件已恢复。
- 本机 macOS 26.5.1；App Store 安装 Xcode 被明确拒绝，提示需要 macOS 26.6。改用 Apple 官方兼容版 Xcode 26.5 下载页，目前需要用户完成 Apple 登录。没有升级操作系统，也没有覆盖 `/Applications/AnxReader.app`。
- 同书分屏、弹层收起、首页打开和跨书跳转的真实桌面 WebView 验收尚未运行。需在完整 Xcode 环境构建后逐项检查聊天保留、章节／CFI 定位、旧页面销毁和文件失效提示。
