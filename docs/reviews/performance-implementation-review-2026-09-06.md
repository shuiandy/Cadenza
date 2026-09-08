# 性能整改实现复核，2026-09-06

审查对象：`5f5fb685b241dbc399f02c9b20b5139282d35d32` 上未提交的性能整改。沿用本会话整改前的工作区清单区分既有 Gemini/MCP WIP。本文新增报告，未修改产品实现，未提交或部署。

当前结论：同日修复后复核，R1–R3 的实现缺陷已修复，R4 的错误实现与过度表述已纠正；本轮未发现新的阻断问题。分块资源预算及端到端性能仍未验收。下文 R1–R4 保留首次审查证据，最新状态见文末“修复后复核”。

## R1 · P1 · Whisper 分块导出新增 detached 任务，丢失取消传播

位置：`Cadenza/Services/Transcription/WhisperTranscriber.swift:295–302`。

导出从 task-group 子任务直接调用，改成 `Task.detached(priority: ...).value`。调用方取消不会自动取消 detached 任务。用户取消转录，或同组另一个分块失败时，已经开始的导出仍继续，导出内部 `CancellableCallbackOperation` 无法收到父任务的取消；task group 要等这些导出完成或其 30 秒超时后才能退出。期间仍占着导出 permit 和处理生命周期。

隔离 Swift 6 探针使用相同的 detached/value 调用形式：父任务在 50 ms 后取消，250 ms 后子任务仍完成，`child cancelled=false`，而父任务 `cancelled=true`。这是任务语义验证，未使用真实音频，也不是实际导出延迟测量。

建议：保留导出任务 handle，用 cancellation handler 显式传播取消，处理取消早于子任务开始的竞态，并在继续静音分析、上传前检查取消。补充“导出期间取消”和“同组分块失败”的行为测试，验证 reader/writer 停止、permit 释放及临时文件清理。

## R2 · P1 · 增量镜像在刷新被取消时丢失待更新 ID

位置：`Cadenza/App/AppState.swift:1404–1413`；配合 `Cadenza/Services/Export/MarkdownMirrorService.swift:78–83`。

现在刷新先把 `markdownMirrorPendingIDs` 取走并清空，再等待服务完成。任意下一次保存都会取消整个刷新任务，而服务遇到取消会停止处理剩余记录。已经取走但没有完成的 ID 没有重新入队。

可触发顺序：录音 A 的 debounce 到期，取走 A 并等待 store 查询；录音 B 保存，取消 A 的刷新；A 的服务恢复后看到取消并退出；下一轮只包含 B。A 的镜像保持旧内容，直到 A 再次发生变化或用户手动全量重建。此前全库刷新会在下一轮重新覆盖 A，改成定向刷新后失去了这个兜底。

同结构隔离探针用受控的 store 等待点重现，结果为 `Written=["B"], pending=[]`。探针验证队列算法，不代表运行了 App 的完整通知链。

建议：只取消尚未开始的 debounce，不取消已经取走 ID 的刷新；使用单个 drain worker 合并后续 dirty 集合。另一种做法是返回未完成 ID 并重新入队。保留手改冲突保护，补充刷新途中再次保存的确定性交错测试。

## R3 · P1 · 维护按事务分批，但没有在批次之间让出 store actor

位置：`Cadenza/Services/Persistence/RecordingsStore+HistoryMaintenance.swift:25–50`；`Cadenza/Services/Persistence/RecordingsStore.swift:3691–3717`。

`pruneHistory` 和 `backfillListPreviews` 都是同步 actor 方法。循环中的 `deleteHistory` 或 `save()` 不构成 Swift 并发的挂起点。即使由 utility detached 任务发起，进入共享 store 后，所有切片仍一次执行到底，其他列表、详情、录音创建/落库和 MCP 请求无法在切片之间执行。两个方法的“interleave”注释与实现不符。

历史清理在启动 20 秒后发起，届时用户可能已经开始浏览或录音；预览回填还会在每次启动全量取出 Recording 后检查。现有副本基准记录清历史耗时约 3.76 秒，但本轮未重新测量真实库，也不将其作为所有机器上的阻塞时长。

建议：store 每次仅执行一个有界批次并返回，由外部异步调度下一批；在批次间检查取消、前台工作与录音状态，保留历史清理的进度及失败保护。预览回填应只查询未完成候选，避免每次启动全量遍历。补充维护期间并发查询能在维护全部完成之前返回的测试。

## R4 · P2 · 等待 detached 结果会提升任务优先级，动态降级并不可靠

位置：`Cadenza/Services/Transcription/WhisperTranscriber.swift:295–302`；`Cadenza/Services/Transcription/SpeakerDiarizer.swift:463–465`。

`ProcessingWorkPriority` 正确选出 `.utility`，不等于执行任务会保持该优先级。较高优先级调用方等待 `.value` 时，Swift 会提升被等待任务的优先级。本机隔离探针中 utility 原始值为 17，userInitiated 为 25；以 utility 创建的子任务从开始到结束实际均为 25。

因此当前测试只检查 `current` 返回哪个枚举值，还不足以证明录音开始后的实际计算被降级。音频 tap 提优先级、导出 DispatchQueue 明确设 utility 仍有独立作用，本条不否定这些改动。

建议：将录音期间让出计算资源落实为分块/阶段的并发预算及受控工作队列，并测试实际执行优先级和 capture 指标；不要只依赖创建 Task 时传入的 priority。

## 验证与限制

- 独立执行相关 15 个 suite，173 个测试全部通过，包含录音并发排除、历史维护、列表投影、WebSync、MCP、说话人分配、Gemini 实时和 UI 门禁。编译和测试均禁止签名，未安装正式 App。
- 首次运行受沙箱限制，无法写 SwiftPM/Clang 缓存；解除该命令的沙箱限制后通过。这是环境问题，不是产品失败。
- 本轮结果：`173 tests in 15 suites passed`。
- 隔离探针 `TaskProbe.swift`、`MirrorProbe.swift` 留在仓库外，未入库。
- 另核对完整套件日志：2655 个测试中 1 个既有 `DebugDataRootTests.userDataPathsRouteThroughTheSeam` 失败，指向此前已存在的 MCP bridge 路径代码。本轮没有声称完整套件全绿。
- 未运行真实音频、已安装 App 的 UI/GPU profile 或生产 MCP；不能据此确认滚动帧率、录音丢帧或转录 RTF 已改善。

## 修复后复核，2026-09-06

对象仍为上述 HEAD 上的未提交工作树，包含随后的四项修正。只更新本审查记录，未修改产品实现、提交或部署。

| 条目 | 结论 | 本轮核对 |
| --- | --- | --- |
| R1 | 已修复 | Whisper 分块直接在 task group 子任务中调用 `exportChunk`，不再新增 detached 层；导出内部 cancellation handler 仍取消 reader/writer，utility 导出队列保留。 |
| R2 | 已修复 | `MarkdownMirrorRefreshQueue` 将 debounce 和 drain 分开；后续保存只重启 debounce，已取走的批次继续完成，随后消费新 ID。受控刷新测试覆盖 A 刷新期间 B 入队的交错。AppState 重新配置时取消并替换整个队列。 |
| R3 | 已修复原先全库占住 actor 的问题 | 生产路径每次调用 `pruneHistorySlice` 只删一个时间切片，切片之间等待并在录音期间暂停；预览每次最多处理 50 条后返回，外层异步循环调度。候选为任一预览列为 nil 的行，无内容写空串并在列表 DTO 中转回 nil。同步全量 `pruneHistory` 仅供诊断和测试，生产调用已移除。 |
| R4 | 错误实现与过度表述已纠正 | 逐 chunk detached 包装撤掉，源码、整合报告与 ARCHITECTURE 均说明优先级在任务创建时选择、等待可能提升优先级。真正的分块预算仍列为 T5，不能视为已实现动态降级。 |

独立执行 9 个套件、47 个测试，全部通过：镜像队列与镜像服务、列表投影、历史维护、优先级策略、录音与后处理并发、permit、可取消回调、Whisper。取消回调测试覆盖主动取消及同组任务失败；它们不等于真实 AVAssetReader/Writer 端到端验收。历史测试验证切片 API 和内容保留，未测量大库中前台请求的等待时延。

- 本轮结果：`47 tests in 9 suites passed`，xcodebuild 退出码 0。
- 核对最新完整套件日志：2659 个测试、303 个套件，仍只有 `DebugDataRootTests.userDataPathsRouteThroughTheSeam` 一项失败，指向 MCPBridgeRuntime 直接使用 applicationSupportDirectory。完整套件没有全绿。
- 编译和测试均禁止签名，未安装或启动正式 App；未重测真实音频、保留 glass 的千条列表滚动、数据库/MCP 延迟。
- 非阻断文档差异：整合报告第 8 节末尾写“启动 20 秒后开始清历史并回填预览列”，但 AppState 的回填在启动期间立即发起，20 秒延迟仅用于历史清理。该句应按代码分别说明两者时机。
