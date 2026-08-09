# Cadenza 架构总览

Last updated: 2026-03-27

> 本文档是 Cadenza 的唯一架构入口。
> 任何影响录音生命周期、后处理、持久化、详情页加载、用户可见状态、权限、AI 上下文装配的改动，都必须同步更新本文件。

## 0. 文档目的

这份文档不追求逐行解释代码，而是用来回答这些架构问题：

- 这个 app 现在有哪些核心模块，各自负责什么？
- 哪些状态由谁拥有，谁只是转发，谁只是展示？
- 录音、停止、合并、转录、摘要、导出、恢复的全链路是怎么串起来的？
- 哪些地方是热路径，哪些地方会拖慢性能，哪些地方最容易改漏？
- 新功能上线前，必须检查哪些影响面？

如果下面这些内容发生变化，就要更新本文档：

- 录音状态机
- 会议检测
- 转录 / 摘要 / 后处理
- SwiftData schema / DTO / 恢复逻辑
- `RecordingDetailView` 加载逻辑
- toolbar / overlay / detail 页的用户可见状态
- 权限敏感 API 的调用方式
- AI assistant / project AI 的上下文装配

## 1. 模块总览

### 1.1 单进程架构

```text
Cadenza app process
├── AppState
│   ├── RecordingEngine
│   │   ├── AudioMixer
│   │   │   ├── AudioCaptureService
│   │   │   ├── SegmentedAudioFileWriter
│   │   │   │   └── AudioFileWriter
│   │   │   └── AudioSegmentMerger
│   │   └── TranscriptionManager (实时转录)
│   ├── MeetingDetector
│   ├── CalendarManager
│   ├── ExportService
│   └── ChatHistoryManager
├── PostProcessingCoordinator
│   ├── TranscriptionManager (文件转录)
│   ├── SpeakerDiarizer (SpeakerKit, on-device)
│   ├── SummaryGenerator
│   └── ExportService
└── RecordingsStore (SwiftData ModelActor)
```

当前设计是单进程。没有 XPC service，也没有 CoreEngine 单独进程。

### 1.2 模块职责表

| 模块 | 主要类型 | 职责 | 关键说明 |
| --- | --- | --- | --- |
| App 壳层 | `CadenzaApp`, `AppState`, `MainWindow`, `ContentView` | 启动装配、导航、全局 UI 状态、终止保护 | `CadenzaApp` 在 UI 出现前创建 `ModelContainer`、`RecordingsStore`、`PostProcessingCoordinator` |
| 会议检测 | `MeetingDetector`, `MeetingSignals`, `CalendarManager`, `AudioProcessMonitor` | 判断会议是否正在进行，驱动自动录音 / 提示 | 置信度评分 + debounce + grace period + 自适应轮询 |
| 录音热路径 | `RecordingEngine`, `AudioMixer`, `AudioCaptureService`, `SegmentedAudioFileWriter`, `AudioFileWriter`, `AudioSegmentMerger` | 音频捕获、分段写入、停止、合并、恢复 | 设计目标是“主线程快切状态 + 后台做重活” |
| 后处理 | `PostProcessingCoordinator`, `TranscriptionManager`, `SummaryGenerator`, AI service 实现 | 转录、摘要、自动丢弃、自动导出、启动恢复 | 并发池：transcription=2, summary=1 |
| 持久化 | `RecordingsStore`, `Recording`, `Transcript`, `MeetingSummary`, `Folder`, `Project`, `SpeakerProfile`, `DatabaseBackup` | SwiftData 数据存储、DTO 转换、备份、恢复 bookkeeping | 视图层尽量不直接持有 SwiftData model |
| Recordings UI | `RecordingsContentView`, `RecordingCardView`, `RecordingListRow`, `RecordingDetailView` | 列表、卡片、详情、手动重试 / 重生摘要、播放、speaker mapping | detail 页是按需 reload，不是 live object 绑定 |
| Project UI / memory | `ProjectDetailView`, `ProjectMemoryService` | 项目聚合视图、项目级 AI brief / ask AI | 走结构化上下文，不是简单拼 prompt |
| AI assistant | `AIChatView`, `ChatHistoryManager` | 对近期录音做问答、流式回复、聊天历史 | 当前不是索引检索，而是先加载 detail DTO 再拼上下文 |
| 导出 / OAuth | `ExportService`, `NotionExportService`, `CraftExportService`, `GoogleCalendarService`, `ZoomMeetingService`, `OAuthTokenManager` | 导出与第三方连接 | 仍然都在主进程内 |
| 权限 / 工具 | `Permissions`, `KeychainManager`, `StoreRepair` | 权限判断、密钥、容错工具 | `StoreRepair` 存在，但当前主 DTO 路径没有真正用上 |

### 1.3 不可轻易打破的架构约束

- `MeetingDetector` 必须留在主进程，因为依赖 `NSWorkspace.runningApplications`
- Keychain 读取在主进程里直接完成
- `UserDefaults` 直接在主进程读取
- SwiftData 访问统一经过 `RecordingsStore`

## 2. 状态归属与用户可见状态

### 2.1 Source of Truth

- `AppState`：UI 根状态，负责把底层组件状态投影到视图层
- `RecordingEngine`：录音状态机、当前录音 ID、录音时长、实时转录片段、音量、电平、自动停止倒计时
- `PostProcessingCoordinator`：后处理阶段、手动摘要 / 重转录 busy 状态、完成 token、discard 提示
- `RecordingsStore`：所有持久化对象和 DTO 转换

### 2.2 `recordingState` 的真实含义

`AppState.recordingState` 不是简单转发。

它的逻辑是：

1. 如果 `RecordingEngine.recordingState != .idle`，直接返回 engine 状态
2. 如果 engine 已经 `.idle`，但 coordinator 的 `postProcessingPhase` 是 `"transcribing"` 或 `"summarizing"`，就把状态投影成 `.transcribing` / `.summarizing`
3. 否则返回 `.idle`

也就是说，用户看到的是“录音生命周期的统一投影”，不是底层对象的单一状态。

### 2.3 主要用户可见状态

| 状态 | 来源 | 用户看到什么 | 备注 |
| --- | --- | --- | --- |
| idle / ready | `AppState.statusText` | `Ready` | 默认状态 |
| idle / 检测到会议 | `MeetingDetector` -> `RecordingEngine` -> `AppState.statusText` | `Meeting detected — <app>` 或 `<app> detected` | 录音前的提示态 |
| recording | `RecordingEngine.recordingState == .recording` | toolbar 红色录音 pill、overlay、实时时长、实时 transcript | detail 页显示 recording placeholder |
| paused | `RecordingEngine.recordingState == .paused` | `Paused mm:ss` | pause-aware duration 单独追踪 |
| transcribing | coordinator `postProcessingPhase == "transcribing"` 或手动重转录 | toolbar spinner、detail transcript spinner、summary precondition spinner | 由 coordinator 投影回 UI |
| summarizing | coordinator `postProcessingPhase == "summarizing"` 或手动摘要 | toolbar spinner、detail summary spinner | `summaryStreamedText` 由 coordinator 持有 |
| complete | `postProcessingCompletedToken` | toolbar 临时 success pill | `MainWindow` 的本地 UI 状态 |
| discarded | `recordingDiscardedReason` | toolbar 临时 discard pill，详情页关闭 | 短录音 / 空录音 / 无有效内容会走这里 |

### 2.4 重要但不属于 `recordingState` 的状态

- `isPostProcessing`
- `isGeneratingSummary`
- `isRetryingTranscription`
- `recordingsChangedToken`
- `projectsChangedToken`
- `postProcessingCompletedToken`
- `recordingDiscardedReason`

这些值经常是功能改动时最容易漏掉的地方，因为它们不在同一个 enum 里，但会直接影响 UI 是否显示正确。

## 3. 录音管线

### 3.1 音频格式

| 参数 | 录音文件 | 转录上传 |
| --- | --- | --- |
| 采样率 | 48 kHz | 16 kHz 或 24 kHz |
| 声道 | 1 (mono) | 1 (mono) |
| 编码 | AAC (MPEG-4) | AAC / PCM16 |
| 码率 | 128 kbps | 32 kbps 或 provider-specific |
| 容器 | `.m4a` | `.m4a` / 实时 PCM |

录音文件包含两条独立 audio track：

- 系统音频
- 麦克风

当前不做预混音。

### 3.2 捕获链路

```text
Core Audio process tap (系统音频, 48kHz mono, private aggregate device)
  → AudioDevice IOProc
  → utility callback queue
  → AudioMixer.onSystemAudio
    → SegmentedAudioFileWriter.appendSystemAudio()
    → AudioLevelSampler.sample()
    → TranscriptionManager.sendAudio()   // 若开启 realtime

Core Audio HAL (麦克风, AudioDeviceCreateIOProcIDWithBlock 直接挂在 input device)
  → AudioDevice IOProc
  → userInitiated callback queue
  → AudioMixer.onMicrophoneAudio
    → SegmentedAudioFileWriter.appendMicrophoneAudio()
```

麦克风设备选择：`AudioMixer` 从 UserDefaults 读取 `selectedMicrophoneID`，传给 `AudioCaptureService.startCapture(microphoneDeviceID:)`，最终落到 `MicrophoneCoreAudioCapture.startCapture(deviceUID:)`。设备通过 `kAudioHardwarePropertyDeviceForUID` 解析；UID 解析失败（设备拔了）静默回退到 `kAudioHardwarePropertyDefaultInputDevice`（有日志告警）。读 device 的 `kAudioDevicePropertyStreamFormat`（input scope）拿 ASBD，验证 `mSampleRate > 0` 且 `mChannelsPerFrame > 0`，无效则抛 `MicrophoneCoreAudioError.invalidFormat`。

**为什么 mic 不走 AVAudioEngine**：曾尝试 `AVAudioEngine.inputNode + installTap`。在 macOS 26 某些设备组合下（Continuity iPhone Mic + Teams 虚拟设备 + USB-C dock + 合盖事件残留），touching inputNode 触发 macOS 建一个 `CADefaultDeviceAggregate`（mic + speakers），它在 bus 1 上做 channel layout 查询时拿到 `kAudioDeviceUnsupportedFormatError (-10877)`，连锁失败"input hw format invalid" → 引擎初始化 `-10868`。aggregate 在 OS 层就是坏的，user code 怎么重试 / 重派生 format 都救不了。`MicrophoneCoreAudioCapture` 直接 `AudioDeviceCreateIOProcIDWithBlock` 挂在 device 上，完全不碰 inputNode，绕开整个 aggregate path。

格式约束：`MicrophoneCoreAudioCapture` 拒绝 `kAudioFormatFlagIsNonInterleaved + mChannelsPerFrame > 1` 的输入（IOProc copy path 只读 `mBuffers[0]`，多 buffer 非交错会丢声道）。Mono 设备无论 flag 都安全。IOProc 运行时还有 `mNumberBuffers == 1` 兜底，防止 driver 谎报 format flags。

**mic 暂停/恢复**：`setMicCapture(enabled:)` → `MicrophoneCoreAudioCapture.setActive(_:)` → `AudioDeviceStart` / `AudioDeviceStop`（不销毁 IOProc）。`isIOProcActive` 跟踪状态，避免重复 Start/Stop 触发 `kAudioHardwareNotRunningError` 噪声日志。目的：mic-probe 路径靠 `kAudioDevicePropertyDeviceIsRunningSomewhere` 判断 meeting app 是否还在用 mic，我们 pause 自己就让该 property 干净反映其他 app 的状态。

系统音频默认走 `ProcessTapSystemAudioCapture`：

- `CATapDescription` 创建 private process tap，默认 mono + mixdown + unmuted
- 有会议 app bundle ID 时只包含目标进程；Teams 额外包含 `com.microsoft.teams2.modulehost`
- 无目标 bundle ID 时创建 global tap，但排除 Cadenza 自身
- tap 接入 private aggregate device，通过 `AudioDeviceCreateIOProcIDWithBlock` 收样本
- IOProc 生成 `CMSampleBuffer` 后转到 `.utility` callback queue，保持后续写文件/转码不跑在 UI 线程
- 不使用 `SCStream`，不进入 `replayd`，因此不会持续 publish capture attribution 给 `systemstatusd`

`SCStream` fallback 已移除。录音期间保留任何 ScreenCaptureKit runtime path 都会让 Cadenza 与 Teams 同时经过 `replayd`，而 macOS 26.4 上 `replayd` 的 capture attribution publish 会触发 `systemstatusd`/`reportd` CPU 病态；因此当前架构只允许 Core Audio process tap 路径。

> **历史教训（2026-04）**：曾尝试保留 fallback `SCStream` 并用 dummy `.screen` output 兼容 Teams。它能缓解 Teams 共享失败，但仍会让 `replayd` 持续驱动 `systemstatusd` 的 attribution 缓存热点，所以最终移除了 fallback，而不是继续调 SCK 配置。

### 3.3 开始录音顺序

`AppState.startRecording()` -> `RecordingEngine.startRecording()`

顺序非常关键：

1. 精确验证用户所选的录后转录 provider；配置无效时在权限和 capture 前失败，不检查或替换成其他 provider
2. 判断是否允许录麦克风
3. 如开启 realtime transcription，先安装 `audioMixer.onTranscriptionAudio`（`AudioMixer` 会在 capture 启动时快照 callback）
4. `audioMixer.startRecording(...)`，让分段磁盘录音成为权威数据源
5. 持久化 `Recording` 行
6. 只有保存成功后才设置 UI 状态为 `.recording`
7. 用 tracked、可取消的后台 task 精确解析并启动用户所选 realtime provider；它不会阻塞 `startRecording()` 返回

这一步的设计重点不是“能不能录上”，而是“录上之后立刻 crash 时，恢复链路是否还能找到这次录音”。

#### 启动失败语义与 `isStarting` 反馈（2026-06-10）

历史事故：用户点 menubar "Start Recording" 完全没反应——auto-start 已在进行（`isStarting=true`），手动点击被开头的 guard **静默 `return`**；同时 realtime session（OpenAI key 失效 → 401）把第 3 步拖了数秒，`recordingState` 迟迟不变 `.recording`，UI 无任何"正在启动"状态。修复后的语义：

- **录后转录配置类失败 throw**：`TranscriptionProviderResolutionError` 精确描述无效 provider、所选 provider 不支持的模式/语言、缺失的本地模型或所选云端 provider 的 API key。调用方统一走 `AppState.presentStartRecordingError(_:)`；缺 key 时只弹该 provider 的专用 alert，其余错误只走 `recordingError`，不会双弹。
- **busy 路径不 throw**（already recording/starting/stopping 不是错误），由 UI 感知：`isStarting` 改为 `private(set)` observable（驱动 UI，故**不加** `@ObservationIgnored`），menubar 与主窗口按钮在 `isStarting` 时显示禁用的 "Starting…"。
- **realtime 是可选旁路**：磁盘 capture、持久化和 `.recording` 状态先完成；之后才异步启动 realtime。配置、网络或超时失败只设置用户可见的 `realtimeHint`，**录音继续**，也不会借用另一个 provider。初次连接和重连复用同一份不可变 provider/key/language/recording start date 配置。
- **realtime 启动硬超时 5s**：initial 与每次 reconnect 共用 `HardAsyncDeadline`（不是 task-group "first child wins"——那会等所有 child）。超时/失败放弃 realtime；半开 session 用精确 attempt token 非阻塞拆除。重连 B 若在 start 返回前已经 end/fail，该 failure 会先合并、待 in-flight guard 释放后重放，不会误报成功或永久吞掉。stop/reset/下一次 start 会取消 startup 与 reconnect task；recording ID 约束 UI，`RealtimeAttemptID` 再区分同一录音内互相竞速的 initial/reconnect，旧 attempt 不能清理新 owner。

### 3.4 分段写入

`SegmentedAudioFileWriter` 的关键配置：

- 分段时长：30 秒
- 双写器轮转：zero-gap rotation
- manifest 文件：`segments.json`
- manifest 写入：`.atomic`
- 线程模型：串行 DispatchQueue

轮转流程：

1. 定时器 30 秒触发 `rotateSegment()`
2. 创建新 writer B 并切成 `activeWriter`
3. 旧 writer A 变成 `retiringWriter`
4. 过渡期 A/B 同时吃 buffer，避免切段丢音
5. A 在后台 Task 中 `stopWriting()`
6. manifest 标记这一段完成

### 3.5 停止录音：Two-Phase Stop

`RecordingEngine.stopRecording()` 明确分成两段。

Phase 1：同步 UI 切换

- `isStopping = true`
- 停止 realtime transcription
- 停止 duration/audio-level timer
- `recordingState = .idle`
- 清空 `currentRecordingID` / `currentMeetingName`
- `audioMixer.beginStop()` 抓取停止上下文并清空可观察状态

Phase 2：后台 finalize

- `AudioCaptureService.stopCapture()`
- `SegmentedAudioFileWriter.stopWriting()`
- `AudioSegmentMerger.mergeAndCleanup()`
- 回到 MainActor：`store.finalizeRecording(...)` → 返回 `FinalizeResult`
- 清除 `isStopping`
- 根据 `FinalizeResult` 分支：
  - `.saved` → kick off `PostProcessingCoordinator.startPostProcessing(...)`
  - `.discarded` → 通知 UI "录音太短"（`coordinator.notifyRecordingDiscarded()`）
  - `.failed` → 如有音频文件仍尝试后处理（存储问题不应阻止转录）

`FinalizeResult` 是三态枚举（`saved / discarded / failed`），避免把存储失败误判为自动丢弃。

这就是为什么用户点 Stop 后 UI 很快，而真正的文件停止 / 合并 / 后处理仍在继续。

#### 捕获错误与系统休眠处理

- `onStreamError` 回调触发 `stopRecording()`，保存已有 segments（不再只弹窗）
- `NSWorkspace.willSleepNotification` 监听系统休眠，提前 stop recording
- 两者都确保录音数据不丢失

### 3.6 分段合并

`AudioSegmentMerger` 采用流式合并：

- 单段：直接 `copyItem`
- 多段：逐段 `AVAssetReader` -> `AVAssetWriter`
- 内存复杂度近似 O(1 segment)
- timeout：`max(120, segmentCount * 5)` 秒

关键策略：

- merge 失败时不删 segments 目录
- 下次启动交给 crash recovery

### 3.7 Silence watchdog & trailing trim（2026-07 静音尾部处理）

会议结束后检测信号可能全程不掉（实锤案例：Teams Town Hall 的 "Meeting join" 窗口 + Cadenza
自身录音撑住 systemMic fallback，2026-07-06 多录 50 分钟），信号层无区分度，唯一可靠判据是
音频内容。两层处理，判定都是 RMS 纯静音（-45dB / 线性 0.006）：

**录音中（silence watchdog）**：`AudioMixer` 双路电平（系统 tap + 麦克风，`AudioLevelMeter`
格式感知：Float32/Int16，未知格式 fail-open 算有声）喂 `SilenceTracker`（归一化阈值 0.03）。
`RecordingEngine` 的 0.5s duration timer 每 tick 调 `silenceWatchdogTick()`，用
`SilenceWatchdogPolicy` 判定：连续静音 ≥ `silenceWatchdogMinutes`（UserDefaults，默认 15，
≤0 关闭，无设置 UI）且 (a) autoStopOnMicClose 开、(b) 本录音是 auto-start
（`currentRecordingIsAutoStarted` latch，成功进 .recording 才置位）、(c) session 从未有
per-process mic（Zoom/FaceTime 受保护；Teams 永远探不到 pmic，watchdog 覆盖全部 auto Teams
录音——by design）、(d) 用户未按 keep recording——则走标准 5s auto-stop countdown
（`source = .silenceWatchdog`）。countdown 期间音频恢复由 tick 自查取消（detector 此场景
恒 active，handleMeetingRecovered 不会来救）。暂停不累计静音（resume 时 reset tracker）。

**合并前（trailing trim）**：`AudioSegmentMerger.merge` 入口 `trimTrailingSilentSegments`
从尾往头用 `AudioSilenceDetector.hasAudibleContent`（逐 track、500ms 窗口 @16kHz、任一窗口
≥阈值即有声、一切异常 fail-open 算有声）丢弃全静音尾段；全部静音不裁（交给空转录自动丢弃）；
单 segment copy 快路径不裁。`MergeResult.mergedDuration` 用流式写入的 cumulativeOffset
（跳过的损坏段不计入），正常停止与 crash recovery 都用它回填 `Recording.duration`
（0 时回退计时器值）；`endDate` 保持 wall-clock 不变。merge 失败仍保留 segments 目录。

### 3.8 `forceReset()` 约束

`AudioFileWriter.forceReset()` 与 `SegmentedAudioFileWriter.forceReset()` 必须通过内部串行队列收口，避免与 `stopWriting()` 的同步代码路径打架。

当前策略：

- 不主动 `cancelWriting()`
- 标记 input finished
- 丢引用，让 `AVAssetWriter` 自行在 dealloc 后清理

这是”尽量保住部分文件”的策略，不是”立刻抛弃文件”的策略。

### 3.9 Crash Recovery

启动恢复分两类：

1. interrupted recording
   - 条件：`audioSegmentsDirectory != nil`
   - 操作：读 manifest、找有效 segment、合并、finalize
2. unprocessed recording
   - 条件：已经 finalize，有 audio file，但缺 transcript 或 summary
   - 操作：重新排入 `startPostProcessing()`

音频文件和 SwiftData 是两层 durability：

- SwiftData 保存元数据和流程状态
- 文件系统保存真正的音频恢复面

## 4. 录音性能特征

这些是结构性性能结论，不是 benchmark 数字。

### 4.1 当前设计里做得对的地方

- 录音热路径没有 XPC hop
- 音频回调不跑在 MainActor 上
- 音量采样被节流，不是每个 buffer 都刷 UI
- Stop 是两阶段，UI 不等合并
- merge 是流式，不会把所有 segment 一次性读进内存
- 单段录音不做无意义重编码
- `AudioFileWriter.stopWriting()` 有 10 秒超时保护，防止永久卡死

### 4.2 当前仍然贵的地方

- merge 时间与录音长度、segment 数量正相关
- 长录音意味着更多磁盘对象和更长合并时间
- 开 realtime transcription 时，捕获链路上额外增加了格式转换和网络发送
- 当前设计天生只支持一次一条录音

### 4.3 稳定性护栏

- writer / mixer / engine 都有 `forceReset()`
- merge 失败保留 segments 目录
- stop continuation 只在 finalize / post-process kick-off 边界之后 resume
- 录音停止后有 10 秒 meeting detection cooldown，防止立即重触发
- **Back-to-back 会议**：`handleMeetingActivity` 先检查 `isStopping`（存入 `pendingMeetingAutoStart`），再检查 cooldown。这保证 finalization 期间检测到的新会议不会被 cooldown 吞掉，finalization 完成后自动重新评估
- `MeetingDetector.resetNotificationState()` 执行完整 cleanup（cancelGraceTimer + 恢复慢速轮询），与 `handleStateTransition` 的 ending→idle 路径一致

## 5. 转录管线

### 5.0 AI 模型总表

| 功能 | Provider | Model ID |
| --- | --- | --- |
| 录后转录 | OpenAI（默认） | `gpt-4o-transcribe-diarize` |
| 录后转录 | Gemini | `gemini-3.1-flash-lite-preview` |
| 录后转录 | Whisper Local | `tiny` / `base` / `small` / `medium` (CoreML) |
| 录后转录 | Apple | 系统 SpeechTranscriber |
| 实时转录 | OpenAI（推荐） | `gpt-4o-transcribe` |
| 实时转录 | Gemini | `gemini-2.5-flash-preview-native-audio-dialog` |
| 实时转录 | Apple | 系统 SpeechAnalyzer |
| 说话人识别 | SpeakerKit (Local) | PyannoteModels (on-device) |
| Summary | OpenAI | `gpt-5.4` |
| Summary | Claude | `claude-sonnet-4-6` |
| Summary | Gemini | `gemini-3.1-pro-preview` |
| Summary | MiniMax | `MiniMax-M2.7` |
| Summary | Apple (Local) | FoundationModels (~4K token context) |
| Chat | OpenAI | `gpt-5.4`（与 summary 同；team 确认 mini ID 后可切） |
| Chat | Claude | `claude-haiku-4-5`（fast tier，~5x 便宜，~3-5x 快） |
| Chat | Gemini | `gemini-3.1-pro-preview`（与 summary 同；team 确认 flash ID 后可切） |
| Chat | MiniMax | `MiniMax-M2.7`（本身较快，与 summary 同） |
| Chat | Apple (Local) | FoundationModels |
| AI Context Budget | Claude/OpenAI | ~30k tokens |
| AI Context Budget | Gemini | ~20k tokens |
| AI Context Budget | MiniMax | ~8k tokens |
| AI Context Budget | Apple (Local) | ~2k tokens (map-reduce for long transcripts) |

用户不选具体模型（Settings UI 没有 AI model 选择入口），每个场景使用固定最优模型。

`AIProvider` 暴露两个独立默认值：

- `defaultModel`：Summary 路径用，accuracy-first（flagship tier）。`SummaryGenerator` / `PostProcessingCoordinator` / `RecapGenerator` 调用
- `defaultChatModel`：Chat 路径用，latency-first（fast tier when available）。`AIChatView` / `FloatingAIChatButton` / `ChatPanelView` / `RecordingOverlayPanel` / `ProjectDetailView` 调用

目前仅 Claude 拆出独立 chat tier (`claude-haiku-4-5`)，其它 provider `defaultChatModel` 默认 fall back 到 `defaultModel`，待 team 确认 mini/flash 模型 ID 后只需在 `AIProvider.defaultChatModel` switch case 里加一行即可扩展。

`AIProvider.makeChatService(apiKey:)` 统一创建服务实例。

### 5.1 后录制转录提供者

#### OpenAI `WhisperTranscriber`

| 参数 | 值 |
| --- | --- |
| 默认模型 | `gpt-4o-transcribe-diarize` |
| 文件上限 | 25 MB |
| diarize 最大时长 | 1400s |
| diarize 分块触发 | `>600s`（10min）或 `>25MB` |
| diarize 每块时长 | 300s（5min，块大小已与触发阈值解耦：缩小块以填满 6 路并发，1.5h 会议 ~18 块/3 波而非 ~9 块/2 波，缩短尾延迟；代价 ~2× 请求数） |
| 普通分块时长 | 1200s |
| 并发请求数 / 导出并发 | 6 / 6（导出并发由 3 提到 6 以喂满上传槽） |
| 每 chunk 重试次数 | 3 |
| 请求超时 | 300s |
| 资源超时 | 600s |

特点：

- 默认使用 `gpt-4o-transcribe-diarize`，自带说话人识别（`diarized_json` response format）
- 大文件自动分块
- chunk 导出会压成 16kHz mono AAC 32kbps，减小上传体积
- `mergeSameSpeakerSegments()` 将同一说话人的连续 chunk 合并为一段

#### Gemini `GeminiTranscriber`

| 参数 | 值 |
| --- | --- |
| 默认模型 | `gemini-3.1-flash-lite-preview` |
| 分块 | `>10min` 或 `>15MB` 自动分 5 分钟 chunk |
| chunk 并发 | 5 |
| 上传方式 | 单文件直传，或 chunk 导出后逐块上传 |
| 请求超时 | 300s |
| 资源超时 | 600s |

当前行为：

- duration 读取失败但文件很大时，会按文件大小估算时长，避免错误退回单请求路径
- chunk 导出会压成 16kHz mono AAC 32kbps，减小上传体积
- 通过 `onProgress(done, total)` 回传 chunk 级进度，toolbar 显示 `Transcribing 0/7...` → `Transcribing 3/7`
- Prompt 要求按说话人切换分段，同一说话人连续发言合成一段

剩余瓶颈：

- 单个 chunk 仍然是 base64 JSON 上传，不是流式上传
- 首个 chunk 有冷启动延迟（模型加载），后续 chunk 复用连接秒完

#### Apple `AppleSpeechTranscriber`

- 完全本地
- 无网络依赖
- 需要 speech authorization
- 依赖 macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`
- 语言不支持时返回所选 Apple provider 的明确配置错误；不会把音频发送给云端 provider

#### Claude `ClaudeService`

- Summary/Chat only（不支持转录）
- Base URL: `https://api.anthropic.com/v1/messages`
- 默认模型: `claude-sonnet-4-6`
- 认证: `x-api-key` + `anthropic-version: 2023-06-01`
- **Prompt caching**：`summarize` / `streamSummarize` / `streamChat` 的 `system` 字段统一通过 `cacheableSystem(_:)` 包成 `[{type:"text", text:..., cache_control:{type:"ephemeral"}}]` 单 block 数组。Anthropic 缓存按 prefix 匹配，命中时该部分 token 仅按 ~0.1× 收费且跳过首 token 延迟（5 分钟 TTL）。Sonnet 4.6 最低可缓存 prefix = 2048 tokens，更短的 prompt 静默不缓存（不会报错）。`message_start` 事件中读取 `usage.cache_read_input_tokens` / `cache_creation_input_tokens` 通过 `print` 输出便于验证。AI chat 的 system prompt 在同一 session scope 不变时可命中

#### MiniMax (via OpenAI-compatible endpoint)

- Summary/Chat only（不支持转录）
- Base URL: `https://api.minimax.io/v1/chat/completions`
- 复用 `OpenAIService`，通过 `baseURL` 参数切换
- 默认模型: `MiniMax-M2.7`
- 认证: Bearer token

#### Apple Foundation Models `AppleFoundationModelService`

- Summary/Chat only
- 完全本地，无网络依赖
- 依赖 macOS 26 `FoundationModels` framework（`SystemLanguageModel.default`）
- ~4K token 上下文限制，输入截断到 2000 字符
- 长 transcript 使用自定义 map-reduce（小 chunk + compact prompt）
- `requiresAPIKey = false`
- **`streamChat` delta 转换**：`LanguageModelSession.streamResponse` 的 `partial.content` 是**累积全文**快照，但 `AIServiceProtocol.streamChat` 的消费方按 delta `+=` 追加。`AppleFoundationModelService.streamChat` 内部维护 `emittedScalars`（`unicodeScalars` 视图），每次只 yield 新增 scalar。用 scalars 而非 grapheme，避免 `"cafe"`→`"café"`、`"👍"`→`"👍🏻"` 等扩展末位 grapheme 的快照 break `String.hasPrefix`。否则会触发 O(n²) 字符串增长 → 长回复时主线程卡死

#### AI Service Factory

`AIProvider.makeChatService(apiKey:)` 统一创建 chat/summary 服务实例，消除各 View 中重复的 switch 分支。对 `.whisperLocal` 返回 nil（仅转录 provider）。`makeService()` 返回 `Optional`，无可用 provider 时返回 nil。

#### Local Whisper `LocalWhisperTranscriber`

- 完全本地，无网络依赖，无需 API key
- 基于 WhisperKit（CoreML），Apple Silicon ANE 加速
- 仅支持录后转录，不支持实时
- 模型管理由 `WhisperModelManager` 负责

| 参数 | 值 |
| --- | --- |
| 可选模型 | tiny (~40MB), base (~80MB), small (~250MB), medium (~800MB) |
| 默认模型 | base（首次使用时自动下载） |
| 下载源 | Hugging Face `argmaxinc/whisperkit-coreml`（WhisperKit.download API） |
| 模型存储 | WhisperKit 默认缓存位置，路径持久化在 UserDefaults |
| Pipeline 缓存 | 首次加载 ~2-3s，之后复用；切换模型时释放旧 pipeline |
| 分段方式 | WhisperKit 内部 30s sliding window，无需手动分块 |
| Speaker diarization | 不支持（speaker 字段为 nil） |

- 模型完整性校验：`modelPath()` 检查 AudioEncoder/MelSpectrogram/TextDecoder 三个 `.mlmodelc` 都存在
- 转录前自动转码为 16kHz mono WAV（兼容各种音频格式）
- 静音检测：跳过静音文件避免无意义转录
- 清理 Whisper 特殊 token（`<|startoftranscript|>`、时间戳标记、`[BLANK_AUDIO]`）

Whisper (Local) 只支持录后转录，不支持 realtime。录后与 realtime 各自精确使用设置中选择的 provider：realtime 若选了不支持的 Whisper、语言不受 Apple 支持或所选云端 key 缺失，本次仅禁用实时字幕并显示原因；磁盘录音继续，且不会自动改用 Apple 或另一家云端 provider。

#### 静音检测 `AudioSilenceDetector`

转录前扫描音频 RMS 能量（-45dB 阈值，约 0.006 linear）。静音文件/chunk 跳过 API 调用。

- 整文件检测：`transcribeFile()` 入口
- 逐 chunk 检测：chunked 路径中每个 chunk 导出后、上传前
- 防止 API 从静音中幻觉出内容，节省 API 费用
- 实现：`AVAssetReader` 16kHz mono PCM → 计算平均 RMS，<100ms/10min

#### API Key 验证

连接 provider 时发送轻量验证请求：
- OpenAI / MiniMax: `GET /v1/models`
- Gemini: `GET /v1beta/models?key=...`
- Claude: `GET /v1/models` with x-api-key header
- 401 → "Invalid API key"，429 → 视为有效（限流但 key 正确）

### 5.1.1 Segment 数据流

API 返回的 `TranscriptResultSegment` 带有 `startTime` + `endTime`。中间模型 `TranscriptSegment` 有 `timestamp`（= startTime）+ `endTime: TimeInterval?`（nil 表示实时转录，非 nil 表示后录制 API 结果）。最终持久化为 `TranscriptEntry`（startTime + endTime）。

`endTime` 传递链：API → `TranscriptResultSegment` → `TranscriptSegment.endTime` → `TranscriptEntry.endTime`。UI 播放高亮依赖 `startTime <= t < endTime` 判定当前段落。

OpenAI `gpt-4o-transcribe-diarize` 使用 `diarized_json` response format（不是 `json` 或 `verbose_json`）。Speaker 从 API response 的 `seg["speaker"]` / `chunk["speaker"]` 提取。

`buildEntries()` 推导缺失的 endTime：优先用下一段的 startTime，最后 fallback 到 startTime。

### 5.2 实时转录提供者

#### OpenAI `RealtimeTranscriber`

| 参数 | 值 |
| --- | --- |
| 会话就绪等待 | 10s |
| VAD 阈值 | 0.5 |
| 静音窗口 | 1200ms |
| commit 间隔 | 2.8s |
| commit 字节阈值 | 144,000 bytes |
| 最小 commit | 20,000 bytes |

#### Gemini `GeminiRealtimeTranscriber`

| 参数 | 值 |
| --- | --- |
| 模型 | `gemini-2.5-flash-preview-native-audio-dialog` |
| 连接超时 | 10s |
| TCP keepalive | 30s |
| 单次 raw send deadline | 10s |
| audio-stream-end deadline | 2s |
| 音频格式 | `audio/pcm;rate=16000` |
| responseModalities | `["AUDIO"]`（必须，否则 inputAudioTranscription 不生效） |
| 转录配置 | `inputAudioTranscription: {}` |

转录文本提取优先级：`inputTranscription` → `outputTranscription`。不使用 `modelTurn`（那是模型的语音回复，不是转录结果）。实现为 actor，不再依赖 legacy `@unchecked Sendable`；raw send/receive 的 callback、deadline、caller cancellation 共享 resume-once 状态，timeout/cancel 只撤销本 session 的 exact transport。stop 先 finish stream、取消 retained receive task 和 transport，绝不等待 WebSocket close frame。startup catch 还会同时校验 generation 与 transport identity，A 的迟到失败不能撤销复用同一 service 实例后的 B。

注意：Gemini Live API 本质是对话模型，转录是 `inputAudioTranscription` 附带功能，延迟高于 OpenAI 专用转录 API。

#### Apple 本地 realtime

- `SpeechAnalyzer` + `AsyncStream<AnalyzerInput>`（bounded buffer: 64 items）
- 优先级 `.userInitiated`
- 模型保留 `.processLifetime`
- 限制：系统音频（会议 app 声音）识别效果差，最适合麦克风输入

### 5.3 `TranscriptionManager` 音频队列

| 参数 | 正常模式 | 低延迟模式 |
| --- | --- | --- |
| 队列上限 | 960 chunks | 220 chunks |
| 尾部保留 | 320 chunks | 56 chunks |
| 批次字节 | 128,000 | 64,000 |
| 批次块数 | 32 | 16 |
| drain 批次数 | 2/pass | 2/pass |
| 低延迟额外 sleep | 无 | 40ms |

这条队列是“保低延迟优先”的，不是“保完整无丢包优先”的。

当 producer 比网络快时：

- 队列会主动丢旧 chunk
- 保留尾部数据，避免延迟无限拉长

### 5.4 delta 合并与 flush 规则

- `isFinal` 立即 flush
- pending ≥ 4 flush
- 与上次 flush 相隔 ≥ 180ms flush
- final 段之间时间间隔短、长度短时会合并
- 尾部 final 段会再做 compact
- 8 秒无文本输出但有音频发送时，watchdog 会报 realtime failure

### 5.5 实时转录启动顺序

```text
RecordingEngine.startRecording()
  → 精确验证录后转录 provider
  → 安装 audioMixer.onTranscriptionAudio callback
  → audioMixer.startRecording() + 持久化 Recording + UI=.recording
  → launchRealtimeStartup()（tracked async task，不阻塞 startRecording 返回）
```

callback 必须在 capture 前安装，因为 `AudioMixer` 会在启动时快照它；它同时捕获本次 `recordingID`，所以 A 已排队的音频/错误不能进入或停止 B。realtime session 本身必须在权威磁盘 capture 和持久化成功后再异步连接。启动失败或超时时按 attempt token 清理半开 session，但不停止录音，也不替换 provider。

`RecordingEngine` 的 recording-ID guard 负责 UI 归属；每次 initial/reconnect 另有不可变 `RealtimeAttemptID`，解决同一录音内多个 attempt 的竞态。`TranscriptionManager` 同时维护 session generation：service 在握手完成前只存在于 pending 集合；只有 generation 与 attempt 都仍 current 才能原子提交为 active。延迟 cleanup 必须 `beginRealtimeStop(matching:)`，stop/reset 则在排队异步 close 前同步捕获精确 pending/active service。即使 provider 握手忽略 cancellation 后迟到，也只能关闭自己，不能覆盖新 session 的 stream、task、delta、watchdog 或 audio queue 状态。

生产 stop 采用安全优先语义：立即 detach A，允许 B 启动，A 在 detach 后到达的 delta 丢弃，录后批量转录仍是权威结果。显式 Quality Comparison 采用不同的 draining 语义：A 保持 owner、阻止 B、接收 provider stop 时的 final delta；总 drain deadline 为 3s，且只发起一次 provider stop，完成或超时后都释放 owner。Quality 的连接和通用 test timeout 也使用 hard deadline，realtime timeout cleanup 只匹配自己的 attempt。

### 5.6 说话人识别 `SpeakerDiarizer`

基于 SpeakerKit（on-device PyannoteModels），在后处理阶段为 transcript entries 标注说话人。

- 启用/禁用由 `isEnabled` 存储属性控制（`didSet` 同步 UserDefaults）
- 模型管理：`SpeakerKitModelManager` 负责下载/加载模型，`prepare()` 有 single-flight guard
- 流程：`diarize(audioURL:)` → `DiarizationResult` → `applySpeakersAligned()`（WhisperKit 对齐）或 `applySpeakers()`（IoU overlap fallback）→ `mergeConsecutiveSpeakers()`
- IoU 匹配：`SpeakerSegment` 的 `Float` 时间戳转 `TimeInterval`，逐 entry 找最大重叠的 speaker segment
- 合并：同 speaker 连续段落合并，cap 在 30s / 500 chars 防止 SwiftUI 渲染巨型文本块
- 空白 entry 过滤：合并前先 `removeAll` 纯空白 entries

### 5.8 实时转录 UI 节流

`onSegmentsChanged` 回调频率约 5Hz。为避免主线程 SwiftUI 过载：

- 回调只暂存 raw `[TranscriptSegment]` 引用（零拷贝）
- 1 秒定时器触发时才做 DTO 映射 + 赋值到 `liveTranscriptSegments`
- DTO 使用基于 index 的稳定 UUID，SwiftUI 只 diff 变化部分
- overlay 只渲染最近 20 条 segment
- `_throttleTask` 在 stop/reset/new-start 时被 cancel 并清理，防止跨 session 泄漏

### 5.9 录音中 AI Chat 上下文预算

录音 overlay 的 AI chat 有上下文限制防止 prompt 无限增长：

- 实时 transcript：最多 12,000 字符（取最近的段落）
- 对话历史：最多最近 6 条消息（~3 轮）
- assistant 回复在历史中截断到 500 字符
- streaming 期间用纯文本渲染，完成后才解析 markdown

如果先开录音再等 realtime 会话 ready，开头几百毫秒的音频会直接被 guard 掉。

## 6. 摘要与后处理

### 6.1 自动后处理全链路

`PostProcessingCoordinator.startPostProcessing(...)` 的顺序是：

0. 验证音频文件存在（不存在则跳过，不报错）
1. 录音时长 < 30s 时直接丢弃，不调 API（`minimumTranscriptionDuration = 30`）
2. 解析转录 provider
3. 转录音频文件
4. 说话人识别（如已启用）：`SpeakerDiarizer` → `applySpeakersAligned` / `applySpeakers` → `mergeConsecutiveSpeakers`
5. 如 provider 输出过粗，合成更可读的 transcript entries
6. `subdivideCoarseSegments()`：将 >60s 的段落按句子边界（`.!?。！？…`）拆分，时间按字数比例分配；支持 CJK 句子边界和 CJK/Latin 混排拼接
7. 过滤空白 entries（`text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`）
8. 保存 transcript
9. transcript 为空则自动 discard
10. 流式生成 summary，并在同一次 LLM 请求里 inline 分类 meeting type
11. 验证 summary 是否”有意义”
12. 保存 summary + meetingType（单次写入，`chaptersJSON = nil`）
13. 音频压缩（48kHz → 16kHz M4A，`replaceItemAt` 原子替换，仅在压缩后更小时替换）
14. chapters 不再自动生成，改为用户打开 detail 页时按需触发（`generateChaptersIfNeeded`）
15. 如已配置则 auto export
16. 增加 `postProcessingCompletedToken`

#### `buildEntries()` — Segment 到 Entry 转换

从 `TranscriptSegment` 构建 `TranscriptEntry`，推导缺失的 endTime：
1. 有 API endTime 且 > startTime → 使用
2. 否则用下一段的 startTime
3. 最后一段无法推导 → endTime = startTime

#### `subdivideCoarseSegments()` — 粗段细分

将 >60s 的段落按句子边界拆分：
- 句子终结符：`.!?。！？…`
- 按字数比例分配时间戳
- CJK 文本无空格拼接，Latin 文本空格拼接
- 保留 speaker 标签

### 6.2 `SummaryGenerator`

- 支持 OpenAI / Claude / Gemini
- 摘要是 transcript-based，不是 audio-based
- UI 可以看到流式 `streamedText`
- prompt 组装、网络 I/O、response parsing 已移出 MainActor 重路径
- chapters 已拆成独立异步 API，按需生成（用户打开 detail 页时触发），不随 summary 自动生成
- 持久化发生在完整结果 parse 成功之后
- 流式 summary 中途失败时保留已流出的 partial text，不清空

#### Map-reduce for long transcripts

Transcripts exceeding 40,000 characters (~30 min meeting) automatically use map-reduce:

1. `SummaryPrompt.splitForMapReduce` 按段落/句子边界切成 ~15K char chunks
2. Map phase: 每个 chunk 通过 `streamChat` 并行生成纯文本摘要（`withThrowingTaskGroup`）
3. Reduce phase: chunk summaries 组合后流式传给 reduce prompt，输出标准 JSON 格式

Fallback: map phase 失败时自动回退到 single-prompt 路径，调用者不会看到退化。

UI 体验：短暂等待（map 并行处理）→ 流式输出最终摘要。

#### Two-stage summary (quick + enrich)

For transcripts ≤ 40K chars (single-prompt path), summary generation uses two API calls:

1. **Quick phase**: `quickSystem` prompt → JSON with title/overview/key_points/action_items/tags/meeting_type
2. **Enrich phase**: `enrichSystem` prompt (transcript + quick context) → JSON with decisions/follow_ups
3. **Merge**: combine into full `SummaryResult`

UI shows quick results immediately; decisions/follow-ups sections display a spinner during enrich. DB write happens once after merge.

Enrich failure is graceful: quick result is returned as-is (decisions/followUps empty). Map-reduce path does NOT use two-stage (reduce already produces full JSON).

### 6.3 summary 验证

现在的判断标准比较硬：

- `overview` 不能只是空白
- `keyPoints` 不能为空

验证失败：

- recording 会被自动丢弃，理由是没有 meaningful content

### 6.4 `PostProcessingCoordinator` 的并发池模型

当前是分阶段限流池：

- transcription pool: 2（最多 2 条录音同时转录）
- summary pool: 1（最多 1 条录音同时摘要）

每个 job 在自己的 Task 里运行，通过 continuation-based semaphore 等待 slot。

```swift
private var jobs: [UUID: ActiveJob] = [:]
```

含义：

- 多条录音可同时转录（减少积压等待时间）
- summary 仍串行（避免 LLM provider 限流冲突）
- 每个 job 拥有独立的 TranscriptionManager 和 SummaryGenerator 实例
- `isPostProcessing`、`postProcessingPhase`、`transcriptionChunksXxx` 均为 computed properties，从 `jobs` 字典派生
- cancel 一次取消所有活跃 job，resume 所有 blocked continuation，重置 slot 计数
- detached task handle 存储在 ActiveJob 上，cancel 可传播到实际网络 I/O

### 6.5 音频导入

用户可导入外部音频文件，自动触发转录+摘要。

支持格式：MP3, WAV, AIFF, FLAC, M4A, AAC, MP4, MOV, CAF

流程：
1. `ImportRecordingSheet`（弹窗，支持拖放 + Browse Files）
2. 可在导入前选择 transcription language 和 summary language
3. 文件复制到 `~/Documents/Cadenza/`（UUID 前缀防冲突）
4. 创建 Recording 记录 → 提交 `PostProcessingCoordinator` 自动后处理
5. 导入后跳转到 All Recordings

入口：sidebar 底栏 Import 按钮 + 菜单 File → Import Audio Files (⇧⌘I)

**非 M4A 导入的音频提取（`AudioExporter.exportToM4A`）**：用 `AVAssetReader`(PCM) → `AVAssetWriter`(AAC) 把任意格式整轨转码成 M4A。AVURLAsset 创建时带 `AVURLAssetPreferPreciseDurationAndTimingKey: true`（精确时长 + 精确 seek）。
> ⚠️ **静默截断坑（已修）**：某些外部文件（典型是 Teams 会议录像 MP4）的 AAC 轨中间有 AVFoundation 解码器拒绝的帧（`-11800` / OSStatus `-50`），`AVAssetReader` 会在该处失败、`copyNextSampleBuffer()` 返回 nil。旧实现把 nil 当成正常 EOF → 静默把 44min 截成 23min 还当成功保存（DB duration 仍是原 44min，UI 与音频不一致）。现 `exportToM4A` 检测 reader 失败后**跳过 ~0.2s 坏帧、用新 reader 从其后续读**，恢复完整音频（只丢坏帧瞬间），有跳过时打 `[AudioExporter] recovered audio across N decode gap(s)` 日志。`GeminiTranscriber.exportChunk` 有同类 nil=EOF 模式，但导入已先经 `exportToM4A` 产出干净 M4A，故 Gemini 分块读的是干净文件、不触发；非导入录音由 Cadenza 自编码 AAC 也干净（低风险，未改）。

### 6.6 手动动作与自动后处理的互斥

手动重试 / 重生摘要按录音级别互斥：

- `generateSummary()`：该 recordingID 正在处理时直接 return
- `retryTranscription()`：该 recordingID 正在处理时直接 return

其它录音的自动后处理不受影响。手动操作使用独立的 `manualTranscriptionManager` / `manualSummaryGenerator` 实例。

### 6.7 取消支持

- `cancelCurrentJob()` 取消所有活跃 job 的 Task + detached task
- resume 所有 blocked continuation（防止 task 永久挂起）
- 重置 slot 计数到最大值
- 各阶段用 `jobs[recordingID] != nil` 检查取消（job 被移除 = 已取消）

### 6.8 标签规范化（Tag Normalization）

tag 由"软复用（喂词表给模型）+ 硬兜底（落库前确定性归一化）"两层管理，解决变体泛滥（`1on1`/`one_on_one`/`oneonone`）、中英混杂、无区分度词（`meeting`/`security`）。

**核心 `TagNormalizer`**（`Cadenza/Services/Tags/`，纯函数可测）：
- **两层 key**：`formatKey` = trim + NFC + 全角折半 + 小写 + dash 统一 + 仅保留 letters/numbers/语义符号(`+#:/.&`)、折叠分隔符 → 判等键（`one-on-one`==`oneonone`，但 `c++`≠`c`、`a/b`≠`ab`）。`defaultSurface` = 展示形（连字符折叠；纯 CJK 去分隔符，靠 `isCJKScript` 判断 Han/Kana/Hangul，不误判重音拉丁/西里尔）。
- **normalize 管线**：超长(>64)拒绝 → formatKey 无字母数字拒绝(纯标点/emoji) → blocklist(raw 侧) → alias(formatKey 集合 + `1\s*[:/-]\s*1` 正则覆盖 `1:1`/`1/1`/`1-1`) → 纯数字拒绝(除非命中 alias) → vocab 复用既有 surface → defaultSurface → blocklist(canonical 侧，拦截 aliased)。
- **canonicalize**：批内按 `formatKey(canonical)` 去重（先到先得），用于写入与迁移。

**复用机制**：生成摘要前 `RecordingsStore.distinctTags(language:)` 取库内 tag（非 trashed、过滤 blocklist、按 script 分桶只喂同语言、频次降序 + tie-break），`PostProcessingCoordinator` 截断 top-80 注入三处 prompt（`SummaryPrompt.tagInstruction`）+ `AIServiceProtocol.summarize/streamSummarize`（覆盖 Apple FM，best-effort top-20）。模型被要求优先精确复用、跟随摘要语言、避开角色显而易见的宽泛词（用 `userJobTitle`）。**alias 表兼两职：① 拼写/分隔符变体合并；② curated 英→中会议/业务词映射（技术术语/工具/缩写/jargon 如 1on1/standup 不映射，保留英文）。词形/近义靠复用收敛**。

**落库**：`saveTranscript` / `saveSummary`(merge，保留手动 tag) / `addTag`(MCP+UI 共用) 写入前过 `canonicalize`。过滤/删除入口（`fetchRecordingDTOs(tagFilter:)`、`removeTag`、MCP `list_recordings`、`TabContentView`）统一按 `formatKey` 比，**仍全程内存过滤**（严守 §7 "#Predicate 不碰 tags" segfault 铁律）。

**迁移**：`normalizeAllTagsIfNeeded(force:)` 启动时跑（`AppState.setup` 中 backup 后、recover 前），`tagNormalizationVersion` + blocklist fingerprint 守卫，幂等。canonical surface 由 `buildMigrationVocab`（全库聚合 + defaultSurface 候选 + count/最短/字典序）确定性选定，**不复用脏 raw surface**。单次事务 save，fetch/ save 失败 rollback + 不写版本号（下次重试）。blocklist 经 Settings 或 `defaults write` 改 → fingerprint 变 → 下次启动 force 重跑清历史。

**配置**：blocklist = `UserDefaults` 键 `tagBlocklist`（`stringArray`；`CadenzaApp` register 默认含角色泛词 `meeting`/`security` + 通用过程/动作词如 `跟踪`/`状态`/`规划`/`测试`/`敏捷`/`工程` 等——对同质会议零区分度；**user domain 显式值（Settings/`defaults write`）覆盖 register 默认**）。Settings → Transcription → Tags（`TagManagementCard`）可编辑 blocklist + 看词表 + 一键 Hide。生成 prompt 同步要求"只产具体工具/项目/主题/会议类型，不产过程动作词"。alias 表代码内置 seed（`1on1` 族 + 英→中映射），扩展即加行 + bump 版本号。

测试：`CadenzaTests/Services/TagNormalizerTests`、`CadenzaTests/Persistence/RecordingsStoreTagTests`。

## 7. 数据库层

### 7.1 Schema

```swift
Schema([
    Recording.self,
    Transcript.self,
    MeetingSummary.self,
    Folder.self,
    Project.self,
    SpeakerProfile.self
])
```

`Recording` 核心字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | `UUID` | 主键 |
| `audioFilePath` | `String?` | 合并后的最终音频路径 |
| `audioSegmentsDirectory` | `String?` | 分段目录，录音中 / crash recovery 用 |
| `trashedDate` | `Date?` | 软删除标记 |
| `transcript` | `Transcript?` | cascade delete |
| `summary` | `MeetingSummary?` | cascade delete |
| `folder` | `Folder?` | nullify |
| `project` | `Project?` | nullify |

### 7.2 存储路径

- 主路径：`~/Library/Application Support/Cadenza/Cadenza.store`
- 旧路径：`~/Library/Application Support/default.store`
- 迁移方式：若新路径不存在但旧路径存在，则复制 store + `-wal` + `-shm`
- **测试隔离（2026-06-12）**：CadenzaTestHost 的 `@main` 就是 `CadenzaApp`，`@State appState` 初始化器在任何 `isRunningTests` UI guard 之前运行。该初始化器中的容器创建为 `makeContainer(inMemory: AppState.isRunningTests)`——否则每次跑测试都会打开真实 store，且 dev build 的新 schema 会直接迁移用户数据库（与正在运行的主 app 并发）。测试套件自建 in-memory 容器，从不使用这一份。

### 7.2.1 音频路径引用层（Phase 1A）

音频文件与 segments 目录的 DB 列仍是 String，编码语义见 spec
`2026-08-02-profiles-accounts-storage-export-design.md` §10：

- **编码规则**：`/` 开头 = `legacyAbsolute`（升级前的历史行），否则 = `relative`
  （相对当前音频根，POSIX）。`AudioFileReference`（`Cadenza/Services/Storage/`）
  是该列的类型化视图，分类是全函数——任何存量字符串都可解码，decoder 永不移除（INV-16）。
- **解析唯一入口 `ProfileStorageResolver`**：canonical 只用于 containment 校验，
  **身份一律词法**。relative 解析 = 在规范化后的根上词法拼接、副本整体规范化后
  逐段比较包含关系（防 `..`、防根内 symlink 穿出、防 `/var` vs `/private/var`
  拼写分叉——两侧独立规范化对不存在的目标不成立），校验通过后**返回词法路径而非
  symlink 解析目标**；`makeReference` 落库的 subpath 同为词法身份（引用 symlink
  存 link 本身，删除只删 link）。**legacyAbsolute 一律原样解析，绝不按文件名猜测**
  ——解析结果同时喂删除/导出/同步/播放，身份错位=删错文件。
- **正常写路径严格 relative**（`makeReference` throwing）：根外 URL 视为编程错误，
  写操作失败并保留 segments 证据（换目录经 gate 与录音/后处理互斥，正常运行不出现
  根外写）。仅有两条显式改写路径允许触碰 reference 形态：拆根 pin（→ legacyAbsolute）
  与迁移 relocation（→ relative），二者都是 throwing + 失败 rollback 的事务操作。
- **DTO 层封死**：`RecordingDTO.audioFile` / `RecordingDetailDTO.audioFile` 是
  `AudioFileReference?`，全项目无裸路径字符串消费；门禁
  `CadenzaTests/Storage/AudioReferenceSealTests` 扫源码，白名单只有 Recording 模型
  与 RecordingsStore 两个边界文件。
- **换存储目录**（Settings）：经 MainActor 上的 `StorageMigrationGate` 与
  录音（start 至 stop finalize 全程持 lease）、crash recovery、后处理入口
  （startPostProcessing / retryTranscription / generateSummary / backfill）**双向互斥**，
  Settings 原子 claim。
  - move 分支 copy-first 有序执行：目标目录创建 + bookmark preflight（失败=零改动）→
    copy + 逐项校验（碰撞/失败丢弃副本中止——静默跳过会让引用指向同名的另一个文件；
    源目录缺失=空迁移，fresh install 合法）→ `relocateAudioReferences`（显式 copy
    mapping：覆盖行必须改写为 relative，任一解析失败整体 throw 并丢弃副本；coverage
    判定用词法 subpath，不以 canonical 成功为前提；mapping 外的行保留 legacy 与源文件）
    → 根切换 commit → 清源（失败仅留重复，记日志）。commit 前旧根始终完整；
    relative 行无需改写（天然跟随根）。旧的前缀替换 hack（`updateAudioPaths`）已删除。
  - "Keep Existing"拆根分支：bookmark preflight 先行，再
    `pinRelativeReferencesToAbsolute(root: 旧根)` 把 relative 行钉死在旧根
    （否则换根后悬空），pin 失败保持旧根并报错。
- crash recovery 的合并输出必须落在当前根内（根外的 legacy 目标改为根内新路径），
  否则严格 relative 写会拒绝提交。
- legacy 行数经 `countLegacyAudioReferences()` 进诊断报告（Settings → Diagnostics）；
  存量行的整体改写属于 Phase 1B（M1 迁移），未被迁移操作验证过的 legacy 行由
  Phase 3 的"重新关联"工具显式修复。
- Phase 3 修复面（两个独立工具，均不猜测）：
  - **根 bookmark 修复**（`AudioRootRelinkCoordinator` + `ProfileAudioRootWriter.
    applyRelinkedBookmark`）：仅当 userSelected 音频根的 security-scoped bookmark
    无法解析/授权时提供。用户必须重选与记录词法路径**逐字节一致**的同一目录
    （不解析 symlink/alias，canonical 等价拼写也拒绝），只经 classified 写路径替换
    bookmark 字节——路径与 kind 保持，任何 recording reference 不改写；registry
    身份在写时不符则 `rootChanged` 拒绝，零写入。bookmark 会跟随被移动的目录，
    词法路径才是身份：健康探针与 `StorageLocationManager` 的实际解析都把 bookmark
    解析结果与冻结路径逐字节比对，不符即不健康——不经 moved URL 读写、不 refresh、
    不 adopt，解析退回冻结词法路径并交由修复面接管。
  - **per-recording legacyAbsolute 重新关联**（`relinkLegacyAudioReference`，第三个
    sanctioned reference-rewrite 操作；入口在 detail 的 legacy 音频面，文件存在与否
    都提供）：候选按文件名逐字节匹配、递归搜索当前根（文件遍历在 detached task
    上执行，不占 MainActor），以 UTF-8 字节序确定性排序；单个候选也必须显式确认，
    多候选必须显式选择，候选集之外的 URL 拒绝。coordinator 持有在途搜索任务：
    取消或离开页面会 cancel 任务本身（cancellation 显式桥接进 detached walk，
    遍历中逐项检查并及时退出），而非仅丢弃结果。改写仅限所选行的 audio reference
    （resolver 推导 relative + containment 校验；文件名/路径身份一律字节判等），
    ownership、segments 与其余字段不动，save 失败 rollback 后行保持原样。
- 测试注入：store 的 `setAudioRootForTesting`（DEBUG；显式 per-store 测试根，允许
  disk-backed 测试 store——resolver 读该根而非进程全局存储位置，跨 await 不共享
  全局状态；根必须是 scoped 目录）、`setRawAudioReferencesForTesting`（DEBUG、仅
  in-memory 容器）、`PostProcessingCoordinator` 的 `recordingsDirectory` 注入沿用。

### 7.3 Actor 隔离

`RecordingsStore` 是 `@ModelActor actor`。

这意味着：

- SwiftData 读写被一个 actor executor 串行化
- UI 基本只拿 DTO，不直接拿 live model

这是当前数据库线程安全的核心基础。

### 7.4 数据完整性措施

当前保护手段：

1. capture 启动并成功建立 `Recording` 行后才切 UI 状态；当前仍存在一个已知的
   crash gap：进程若在 capture 启动后、行提交前退出，可能留下没有 SwiftData 行的
   segments 目录，现有 orphan 扫描不会自动导入该目录
2. segment manifest 原子写入
3. merge 失败时保留 segments 目录
4. 启动时做 store 备份，保留最近 3 份
5. interrupted recordings 启动时自动恢复
6. finalized 但未处理完的 recording 启动时自动重排队
7. 删除先走 trash，再按用户配置的 3/7/15/30 天保留期自动清理
8. `OrphanAudioRecovery` 扫描当前 active profile 解析出的音频根：时长 ≥30s、
   未被任何行引用的音频文件按 `unknownLegacy` 所有权导入（INV-18：来源不可证明的
   文件字节永不改动）

### 7.5 备份策略

- 路径：当前 profile 的 `Profiles/<UUID>/Backups/`；升级安装还可能保留同级旧
  `Cadenza-Backups/`
- 触发：`AppState.setup()` 启动阶段
- 保留：最近 3 份
- 一致性：通过 SQLite online backup API 把已提交 WAL 内容折叠进单文件 snapshot，
  先写同目录唯一 staging，再用 exclusive rename 发布；成功发布后才 rotation
- 并发：创建、rotation 与清理共享进程内 execution lease；下次 backup 会清理受控
  crash staging

限制：

- execution lease 不是跨进程文件锁；产品依赖单个运行实例
- 当前 UI 可以清理自动备份，但没有 database restore 命令
- portable archive 是可验证 export，当前也没有产品级 importer

### 7.6 数据库性能画像

便宜的部分：

- 列表页只取 `RecordingDTO`
- 详情页按需取 `RecordingDetailDTO`
- project 列表只取 `ProjectDTO`
- 视图层不长期持有 SwiftData model

不够可扩展的部分：

- `fetchRecordingDTOs()` 对很多排序仍然是取出后内存排序
- `searchRecordingDTOs()` 是内存全量扫描 title / tags / transcript / summary / decisions / follow-ups / action items
- 文本搜索复杂度基本是 O(录音数 × 内容大小)

目前对小到中等规模本地库够用，但不是大规模索引架构。

### 7.7 隐藏的写放大

`fetchRecordingDetail(recordingID:)` 现在是纯只读。

`lastAccessedDate` 写入已拆为独立的 `markAccessed(recordingID:)`，只在 `RecordingDetailView.onAppear` 调用一次。自动 reload、AI chat 上下文装配、后台后处理路径不再触发写入。

### 7.8 当前数据库防损坏仍不够强的地方

- `StoreRepair.safeTranscript` / `safeSummary` 存在，但主 DTO 转换路径仍然直接访问 `recording.transcript` / `recording.summary`
- `save()` 失败目前主要是 log + `false` 返回，没有集中 repair / degrade 模式

## 8. UI 状态管理与详情页加载

### 8.1 toolbar / overlay 状态映射

```text
.recording    → ToolbarRecordingPill
.paused       → ToolbarRecordingPill
.transcribing → ToolbarStatusPill
.summarizing  → ToolbarStatusPill
.idle + meetingLikelyActive → "Meeting detected — <app>"
.idle         → "Ready"
```

完成态和 discard 态不是 `recordingState` 本身，而是 `MainWindow` 基于 token / reason 做的本地 UI 状态。

### 8.1.1 录音 overlay 与显示器配置变化

`RecordingOverlayController` 在 `show()` 时根据 `NSScreen.main` 决定走 notch overlay（有刘海屏）还是 regular overlay。`notchPanel` 的 frame、`NotchShape` mask 都基于该屏幕的 `frame`/`safeAreaInsets` 计算，window level 是 `.screenSaver`，`collectionBehavior = [.canJoinAllSpaces, .stationary]`。

**显示器配置变化处理**：controller 监听 `NSApplication.didChangeScreenParametersNotification`，触发时 tear down 现有 panel 并按当前 `NSScreen.main` 重新创建。覆盖场景：合盖 / 拔接外接屏 / 切换到无刘海外接屏。
- observer token 通过 `NotificationObserverHandle`（私有 RAII class）持有，`dismiss()` 显式 invalidate；deinit 是兜底
- `installPanelsForCurrentScreen` 用 `NSScreen.main ?? NSScreen.screens.first` 作为 fallback，避免显示器切换瞬间 main 为 nil 时 panel 落到 (0,0)
- 通知 block 在 `.main` queue 触发但不是 Swift main-actor 隔离，所以用 `Task { @MainActor }` hop 后再读 `@MainActor` 状态
- 不监听窗口跨屏拖动（`NSWindow.didChangeScreenNotification`），overlay 仍跟随 `NSScreen.main`

### 8.1.2 AnimatedGradientBorder 与 macOS 26 RenderBox 提交风暴

`RecordingOverlayPanel` 的彩色流动 border 用 `AnimatedGradientBorder` 实现。此前实现是 `Canvas { ctx, _ in ctx.fill(path, with: .conicGradient(...)) }` 嵌在 `TimelineView(.animation)` 里：每个 display refresh frame（60-120 Hz）都重新 rasterize 一次 conic gradient。

**为什么这是 macOS 26 上的禁忌**：在 macOS 26 RenderBox 管线下，每个 SwiftUI layer commit 同步等待 WindowServer 通过 `CAContext waitForCommitId:timeout:` 确认。Canvas 每帧重画 → 每帧 commit → 每帧同步等。当录音 overlay 长时间显示且其它 `@Observable` 属性（`recordingState`/`autoStopCountdown`）随会议结束发生变化时，commit 队列饱和，主线程被 `mach_msg2_trap` 阻塞 8-15 秒，把会议结束信号到 auto-stop countdown 触发的延迟从 ~3s 拉到 18-22s（实测 macOS 26.4.1，debug build）。

**当前实现**：
```swift
@State private var phase: Double = 0

AngularGradient(gradient: ..., startAngle: .degrees(phase), endAngle: .degrees(phase + 360))
    .mask(shape.stroke(...))
    .onAppear {
        phase = 0
        withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
            phase = 360
        }
    }
```

让 SwiftUI 的动画引擎接管 phase 变化，commit 与 display refresh 对齐而不是每帧 fresh rasterize。`onAppear` 显式 `phase = 0` 是为了防止 view identity 复用（`phase` 已为 360）时动画静止不启。颜色数组首尾相同（`.blue.opacity(0.6)`）所以 0°↔360° wraparound 视觉无 seam。

**通用规则**：在 macOS 26 上，floating/overlay 类窗口里**永远不要**用 `Canvas` + `TimelineView(.animation)` 做高频动画。要么用 SwiftUI 原生的 `withAnimation(...).repeatForever()` + state-driven shape，要么直接用静态 view。如果实在需要 per-frame 自定义绘制，先确认这个 view 不会在录音/主要交互场景里持续显示。

### 8.1.3 浮动 AI Chat panel 的 ViewGraph 物理隔离（独立 NSPanel）

**症状（四次实测、本地长期无法复现的主线程 100% hang）**：在"所有录音"网格页（26+ 卡）打开右下角浮动 AI chat panel，流式回复**第二条** prompt 时主线程钉死数分钟。

**根因**：旧实现把展开的 chat panel 用 `.overlay(alignment:.bottomTrailing)` 挂在主窗 `ContentView` 上（`MainWindow.swift` 的 `NavigationStack { ContentView() }.overlay { FloatingAIChatButton }`），与录音卡片网格（`RecordingsContentView`，每卡 `anchorPreference(.bounds)` + `overlayPreferenceValue(CardFrameKey)` 聚合 + `glassEffect`）**共享同一个 `NSHostingView`/`GraphHost`/`ViewGraph`**。streaming 期间 panel 内 ~3-8Hz 的 snapshot 失效，经共享 `GraphHost.flushTransactions` 把网格的 preference reduction + lazy 重测量拖进**每一轮 commit**；叠加 §8.1.2 的 `CAContext waitForCommitId` 同步等待，commit 队列饱和、主线程数分钟 100%。对照：`RecordingOverlayPanel`（录音 HUD）用独立 NSPanel + 独立 NSHostingView，从不 hang。

**修复（结构性，不是节流）**：把展开 panel 迁入**独立 NSPanel（独立 NSHostingView）**，物理隔离 ViewGraph——panel 的 streaming commit flush 的是另一个 graph，永远不碰网格。相关文件：
- `Cadenza/Views/Chat/FloatingChatPanel.swift` — `FloatingChatPanel`（NSPanel 子类）、`FloatingChatPanelController`（`@Observable @MainActor`，owns panel+hosting，AppState 持有，pattern 照搬 `RecordingOverlayController`）、`MainWindowAccessor`（NSViewRepresentable，从 capsule 视图层捕获主窗）。
- `Cadenza/Views/Chat/FloatingAIChatButton.swift` — 拆成两个 struct：瘦身后的 `FloatingAIChatButton`（只剩**收起态 capsule**，留在主窗 overlay 原位，低频、非问题源，点击驱动 controller）+ `FloatingChatPanelRoot`（展开内容，原 `expandedPanel` body 原样搬入，由 NSPanel 托管，所有 chat `@State`/messages/streamState 随 panel 生命周期存续）。

**设计要点**：
- **child window**：panel 用 `anchorWindow.addChildWindow(panel, ordered:.above)` 挂为主窗子窗，自动跟随主窗**移动**；child window 不跟随 **resize**，故监听 `didResizeNotification` 重新 pin 到右下角（content area 内 trailing 28 / bottom 16，复刻旧 overlay padding）。
- **收起不丢会话**：`collapse()` 只 `orderOut` 隐藏（不销毁 hosting/`@State`），`@State` 存活；只有 `dismiss()`（窗口/app teardown）才 `contentView=nil` 释放。
- **焦点**：`nonactivatingPanel` + `canBecomeKey=true`、`canBecomeMain=false`，**不设** `becomesKeyOnlyIfNeeded`（该 flag 要求命中视图返回 `needsPanelToBecomeKey`，SwiftUI 托管命中视图不返回 → 会**废掉 TextField 键盘输入**；与 `RecordingOverlayPanel` 一致）。仅 panel 真正持 key 且主窗可见+app active 时 `collapse()` 才 `makeKey()` 交还，避免生命周期清理时抢焦点。
- **observer 生命周期分两类**：resize observer 是**可见性**作用域（attach 时装、collapse 时拆）；close observer（`willCloseNotification`→`dismiss()`）是**所有权**作用域（只要 panel 存在+有 anchor 就装，**跨 collapse 存活**），否则"开→收→关窗"会让 collapsed-but-installed 的 panel 漏掉 teardown、保留 `AppState→controller→panel→root→controller` 引用环。`MainWindowAccessor` 只上报**非 nil** 窗口（异步回调可能在 capsule 被移除后读到 nil，不能让瞬时 nil 拆掉所有权 anchor——teardown 由 `willClose` 负责）。
- **环境注入**：独立 hosting 树不继承主窗的 `.environment`，故 `installPanel` 显式重注 `.environment(appState)` + `.environment(\.uiScale, …)`（从 UserDefaults `uiScale` 读 preset）。
- 导航到全页 AI Assistant（`expandToFullPage` 或 capsule 因 `!isOnAIAssistantPage` 被移除）时 `collapse()`，避免 panel 悬在全页助手上。

**复现 harness** `CadenzaTests/AI/ChatHangReproTests`（synthetic 结构 stand-in，不直接引用本次改动的文件）：其 `layoutCostMatrix` 量化出 shared-vs-separate hosting 在单 offscreen 窗里 per-commit 成本**持平**（~31ms，与卡数无关），说明它测的是 facet(2)——history TextKit 重排成本（属另一工程师 ChatStreaming 域，本次未动）；本次结构隔离针对 facet(1)——**生产**环境跨 graph 在 WindowServer commit 路径上的串行化，单次 `CATransaction.flush()` 的 synthetic 测量无法建模（harness 注释 50-57 行预测的正是"必须 host 到独立 NSPanel/window 来 decouple"）。

**演进（2026-06-14，NSPanel → in-window 右侧 sidebar）**：为做出 Craft 那样从右侧顺滑滑入的 sidebar（独立 NSPanel 的 window 瞬间显/隐做不出 SwiftUI 原生过渡），把展开 panel 从独立 NSPanel 改回 **in-window 视图**，但**不再挂在 `ContentView` 的 overlay 上**——而是作为 `MainWorkspaceView` 里 `NavigationSplitView` 的**兄弟**（`HStack { NavigationSplitView{网格} ; FloatingChatPanelRoot }`）。隔离从"物理独立 window"改为"**拓扑兄弟子树**"：streaming 的 `@State` 在 `FloatingChatPanelRoot` 子树内，`MainWorkspaceView.body` 只读 `controller.isExpanded`（streaming 不改它），故 streaming tick 不重评 `NavigationSplitView → ContentView → RecordingsContentView` 的 `overlayPreferenceValue(CardFrameKey)` 链——与旧 overlay 方案的耦合点正好错开。`FloatingChatPanelController` 随之**简化为纯状态**（只剩 `isExpanded`，删 `FloatingChatPanel`(NSPanel)/child-window/observer/`MainWindowAccessor`）；展开/收起用 `.transition(.move(edge:.trailing))` 原生 slide。**取舍**：(1) `if isExpanded` 条件挂载——收起即卸载 `FloatingChatPanelRoot`，本地 `@State`(messages/input/stream)结束，**不再**像 NSPanel `orderOut` 那样跨收起存续；完成的对话已存 `appState.chatHistory`，可从 history 恢复（关闭=新会话）。(2) 物理隔离最强但动画受限，兄弟拓扑隔离动画自然但依赖 SwiftUI 失效传播的精确性（已 codex 复查 + 真机实测 streaming 不卡确认）。**若日后兄弟拓扑被证明仍把失效泄漏到网格**，回退选项是给 `RecordingsContentView` 加 `compositingGroup`/`drawingGroup` 把两条 commit 路径彻底分开（而非退回 NSPanel）。

### 8.2 `RecordingDetailView` 的加载模型

detail 页不是 live object 订阅，而是 pull-style reload：

- `onAppear`
- `onChange(recordingState)`
- `onChange(postProcessingCompletedToken)`
- `onChange(recordingsChangedToken)`

### 8.3 `loadDetail()` 流程

```swift
private func loadDetail() {
    if isActiveRecording { return }
    detailLoadSequence &+= 1
    let sequence = detailLoadSequence
    appState.fetchRecordingDetail(recordingID: recordingID) { dto in
        guard sequence == detailLoadSequence else { return }
        if let dto {
            detail = dto
            if let path = dto.audioFilePath {
                audioPlayer.load(url: URL(fileURLWithPath: path))
            }
            appState.recordingDetailTitle = dto.title
            loadLinkedEvent()
            loadSpeakerProfiles()
        }
    }
}
```

### 8.4 为什么这里没有明显竞态

`detailLoadSequence` 是 detail 页的关键防线：

- 每次 load 自增序号
- callback 返回时序号不一致就丢弃结果

这能挡掉 out-of-order async 返回导致的 stale UI。

### 8.5 三态渲染

```text
detail != nil     → 完整详情内容
isActiveRecording → Recording in Progress placeholder
其它情况          → Loading...
```

### 8.6 busy 状态不是单点判断

detail 页会合并：

- 本地 manual flags：`isRetryingTranscription`、`isGeneratingSummary`
- 全局 pipeline 状态：`recordingState == .transcribing/.summarizing`

这避免 detail 页和 toolbar 对同一条 recording 的理解不一致。

### 8.7 detail 页的性能与副作用

优点：

- transcript / summary 只在 detail 页按需加载
- 录音进行中不会错误切到静态 placeholder
- stale async 结果会被丢弃

成本：

- `lastAccessedDate` 只在 `onAppear` 写一次（不再每次 reload 都写）
- 只有 audio path 变化时才会 `audioPlayer.load(...)`，避免普通 reload 重置播放状态
- linked calendar event 和 speaker profiles 是额外 follow-up load
- 多个 token 连续触发时，会出现较密集的 reload

### 8.8 这页最容易改漏的点

- 只改了按钮 busy 状态，没改全局 `recordingState`
- 只改了 `recordingsChangedToken`，没改 detail reload 触发
- 改了 summary / transcript 保存逻辑，但没改 detail 页 placeholder 分支
- 忘了 `audioPlayer.load(...)` 的副作用

### 8.9 详情页内联编辑（标题 / 日期）

- **标题**：双击标题或 pencil 按钮进入编辑（`beginRename`/`commitRename`），提交走
  `AppState.updateRecordingTitle` → `store.updateTitle`。不刷新列表（标题不影响排序）。
- **日期**：header 日期 Label 可点击（hover 变 tint），popover 内 graphical 日历 + 时间
  stepper 编辑，Done 提交，点外部 dismiss = 取消。提交链：
  `commitDateEdit()` → 本地更新 `detail.startDate/endDate`（即时反馈）+ `loadCandidateEvents`
  （日历候选按新日期重拉）→ `AppState.updateRecordingDate` → `store.updateStartDate`
  （`endDate` 随同一 delta **平移**而非重算为 `startDate + duration`——live 录音暂停过时
  `endDate - startDate != duration`（`finalizeRecording` 写的是墙钟 `Date()`），区间长度必须保留；
  `save()` 失效 detailCache）→
  `refreshRecordings()`（日期变更影响列表排序）→ `recordingsChangedToken` bump →
  detail 页 reload 校准。
- `linkedCalendarEventID` 在日期变更时**保持不动**（用户改日期 ≠ 解绑日历事件）。
  主要场景：导入的历史录音（文件名/creationDate 推断不准）手动修正到实际会议时间。

### 8.10 字体语义分层（Typography）

字体经 `Font.cadenza` / `Font.cadenzaBody` 两入口（`Cadenza/Utilities/ScaledFont.swift`），均系统字体（无自定义字体文件）：

- **`cadenza(...)`** — UI 文本，默认 `design: .rounded`（SF Pro Rounded）。按钮 / 标题 / section title / label / 输入栏 / 胶囊 / 数字 / timestamp / 状态文字 / preview / assignee 等 meta。圆体让字形与 Liquid Glass 圆角玻璃同构。
- **`cadenzaBody(...)`** — 阅读型长正文，固定 `design: .default`（SF Pro Text），长段落可读性 / 专业感优先。
- **CJK 权衡**：`.rounded` 仅作用拉丁 / 数字，苹方等 CJK 无圆体变体、自动 fallback —— 本质是「拉丁 / 数字界面圆体化」，CJK 界面观感基本不变。

**正文渲染清单**（新增正文务必用 `cadenzaBody`，否则随 UI 默认变圆、毁长读）：

| 类别 | 组件 / 位置 |
|------|------------|
| markdown | `MarkdownBlocksView`（含 `StreamingMarkdownMessageView` 委托）+ flattened 长消息路径 |
| 转录 | `TranscriptBubble`、`RecordingDetailView`（translated / fullText / segment text）、`RecordingOverlayPanel`（live transcript） |
| 摘要 | `RecordingDetailView`（overview / keyPoints / actionItems.task / chapter.summary / decisions / followUps / yourTasks / action-items tab）、`RecapDetailView`、`ProjectDetailView`（task / decision / brief）、`MeetingDetailView`（流式摘要） |

**判定**：AI / 转录的「内容句子」= 正文（`cadenzaBody`）；section title / chapter title / category / assignee / deadline / 来源 / 状态 / timestamp = meta（`cadenza` 圆体）。显式 `.monospaced`（代码 / 时间戳）与已有 `.rounded` 不受默认变更影响。chat 输入栏在玻璃上用 `weight: .medium`（全页 16pt / 浮动 13pt / 录音浮层 12pt）。

### 8.11 macOS 版本兼容边界（deployment target 26.0）

app 当前最低系统 **macOS 26.0**（`project.yml` 的 `deploymentTarget` + `MACOSX_DEPLOYMENT_TARGET`
+ `Info.plist` 的 `LSMinimumSystemVersion`，三处一致）。26-only 依赖分布在**四个边界**上，
其中 UI 与两个 Apple provider **已收口**（裸调用清零、有门禁看守），Core Audio process tap
**尚未收口**。目的是把"真要降版本时得改哪里"变成已知量。

| 边界 | 位置 | 26-only API | 旧系统分支现状 |
|------|------|-------------|--------------|
| UI ✅ | `Cadenza/Utilities/PlatformCompatibility.swift` | `glassEffect`、`GlassEffectContainer`、`buttonStyle(.glass)`、`safeAreaBar`、`scrollEdgeEffectStyle` | **no-op**（`safeAreaBar` 除外，落 `safeAreaInset`） |
| 本地 AI ✅ | `AppleFoundationModelFactory`（`AppleFoundationModelService.swift`） | `FoundationModels` / `SystemLanguageModel` | 返回 nil，provider 列表自动隐藏 |
| 本地转录 ✅ | `AppleSpeechFactory`（`AppleSpeechTranscriber.swift`） | `SpeechAnalyzer` / `SpeechTranscriber` | 返回 nil / false，调用方 throw `.notSupported` |
| Core Audio tap ❌ | `ProcessTapSystemAudioCapture.makeTapDescription` | `CATapDescription` 的 `bundleIDs` / `isProcessRestoreEnabled` | **无分支**——4 处裸调用，`MACOSX_DEPLOYMENT_TARGET=15.0` 诊断编译的 4 个错误全部来自这里 |

tap 这一格没有收口不是疏漏：它只有一个构造点（已在工厂方法内），且旧系统路径不是加个
`#available` 分支就够（见下方剩余工作 2），提前封装反而会造出一个空壳。

**三条门禁**（源码扫描，防止边界腐化）：
`RecordingsChromeLayoutTests.macOS26VisualAPIsStayBehindCompatibilityBoundary` 扫全部
`Cadenza/*.swift` 禁止裸 UI 调用；`AIContextAssemblerTests` 与
`TranscriptionProviderResolverTests.appleSpeechFactoryOwnsAvailabilityBoundary` 各禁止
`AppleFoundationModelService` / `AppleSpeechTranscriber` 出现在实现文件之外。三个测试都把豁免
文件路径写死，**移动或改名边界文件必须同步改测试**。`AppleFoundationModelService.isAvailable`
另外收成 `fileprivate`，编译期堵死绕过 factory 的路。

> ⚠️ **收口 ≠ 已支持旧系统。** 用 `MACOSX_DEPLOYMENT_TARGET=15.0` 做诊断编译目前只剩 4 个
> 错误（全在 `ProcessTapSystemAudioCapture.makeTapDescription`），但**编译通过不等于 15 上能用**：
> UI 边界的旧分支是 no-op，真跑起来玻璃面全部消失、控件没有任何背景、文字直接浮在内容上。

**真要降 deployment target，剩余工作（收口没有降低这部分成本）**：

1. **UI material fallback** —— `PlatformCompatibility.swift` 的 `else` 分支写实（`.background(.regularMaterial, in: shape)` 一类），外加 `MainWindow` 的 window chrome：现在刻意不设 `backgroundColor`/`isOpaque` 是为了配合 26 的 Liquid Glass 自动管理，旧系统要补回来。
2. **Core Audio process tap** —— `CATapDescription` 的 `bundleIDs` / `isProcessRestoreEnabled` 都是 26 新增。15 的等价路径是用 `[AudioObjectID]`（`stereoMixdownOfProcesses:`，14.2+），bundleID → AudioObjectID 的解析可复用 `AudioProcessMonitor` 的 `readProcessList` + `readBundleID`。**`isProcessRestoreEnabled` 没有替代**：目标 app 重启后 tap 失效，需自行监听进程列表变化重建。这是唯一动核心录音管线的改动。
3. **真机验证** —— 开发机是 26，tap + TCC 在 VM 里的行为不等同真机，这块比写代码更花时间。

功能面影响：15 上 Apple 本地模型与 Apple 转录不可用，退到云端 provider 或 WhisperKit 本地
（WhisperKit 自身声明 macOS 13+，不构成约束）。

### 8.12 命中区域边界（`CadenzaPlainButtonStyle`）

SwiftUI 的命中测试只认 **真正画出像素的地方**。这条规则在本 app 上尤其致命，因为表面基本都是
Liquid Glass：

| label 里的东西 | 参与 hit test |
|---------------|--------------|
| `Text` / `Image` 的字形与图元 | ✅ |
| `.background(Shape().fill(...))` 实心填充 | ✅ |
| `VStack` 行距、`.padding` 留白、`Spacer()` | ❌ |
| `glassEffect` / `cadenzaGlass` 的玻璃面 | ❌（渲染效果，不是绘制内容） |

后果：一张 `appCard` 玻璃卡片配 `.buttonStyle(.plain)`，看着是整块可点面板，实际只有标题和摘要
那几行文字能点中，行间距和内边距全是死区。同一屏里用了实心背景的按钮却整块能点——**同一个 app
里两种命中行为并存**，这正是 2026-08-02（设置侧边栏）和 2026-08-06（Recaps 卡片）两次撞上的问题。

**修法只有一个位置有效**：`.contentShape` 必须在 **label 内部或 ButtonStyle 内部**。写在
`Button { } label: { }` 外面的 `.contentShape` 对按钮命中区完全无效——它改的是 Button 整体在父视图
里的形状，而按钮自身的命中区早由 style body 决定了。

统一入口 `Cadenza/Utilities/CadenzaButtonStyle.swift`：

- `.buttonStyle(.cadenzaPlain)` —— 矩形命中区，覆盖绝大多数场景；
- `.buttonStyle(.cadenzaPlain(in: Circle()))` —— 圆形 / 胶囊 / 圆角矩形按钮，命中区跟着可见形状走，
  免得矩形四角吃掉相邻控件的点击（浮动 chat 的圆形工具按钮、录音浮层的 stop 按钮属此类）；
- style 内部同时补了 `.plain` 交给系统、自定义后就丢失的两个反馈：按下 `opacity 0.72`、
  禁用 `opacity 0.5`。

`appCard` 自带 `.contentShape(shape)`（`ColorHex.swift`），否则调用方紧随其后的 `.onHover` 同样
只在文字上触发——hover 高亮和点击是同一套命中区。`appCollectionCard` 是实心填充，天然不受影响。

门禁 `CadenzaTests/UI/ButtonHitTestingTests.swift` 扫描 `Cadenza/` 全部源码，禁止裸
`.buttonStyle(.plain)`。确有必要的（`Menu` 的 label 不是 Button，自定义 ButtonStyle 会干扰菜单
渲染）在同一行标注 `// hit-test-exempt: <理由>` 豁免，当前仅 `RecordingOverlayPanel` 的两个
麦克风菜单在列。

### 8.13 导航返回栈（覆盖式页面的出口）

`NavigationDestination` 有两个正交属性：

- **`sidebarDestination`** —— 该页面在 sidebar 上对应哪一项（recordingDetail / recapDetail 为 nil）；
- **`requiresExplicitExit`** —— toolbar 必须给关闭按钮。三个覆盖式页面（recordingDetail /
  recapDetail / settings）因为不在 sidebar 上、没出口就是死胡同；**aiAssistant 也在列**——它虽在
  sidebar 上有位置，但整页接管工作区，用户期待明确的退出（2026-08-07 用户明确要求）。

出口靠 `AppState.navigationReturnStack`：

| 入口 | 语义 | 对返回栈 |
|------|------|---------|
| `navigate(to:)` | sidebar 式换位置 | 清空（旧返回链作废），并清 `searchQuery`；**目标若 `requiresExplicitExit` 则转 `present`** |
| `present(_:)` | 覆盖式进入，记住来路 | push 当前页；**不碰 `searchQuery`** |
| `closeDetail()` | 关闭当前页 | pop 回上一层 |

`openRecordingDetail` / `openSettings` 都走 `present`。栈深上限 8（异常路径兜底，正常最多
回顾 → 回顾详情 → 录音详情三层）。栈空时按 `fallbackReturnTarget` 兜底：recapDetail → `.recaps`，
其余 → `.allRecordings`。toolbar 的 `showDetailCloseButton` =
`requiresExplicitExit || !navigationReturnStack.isEmpty`。

**sidebar 双向同步的回声**：`selectedDestination` 与 `activeDestination` 互相同步，`present` 之后
activeDestination 会把选中值推给 sidebar，那次变化回到 `onChange(of: selectedDestination)` 时
**必须被认出是回声**——否则会当成用户点了 sidebar 而调用 `navigate`，刚压进去的返回栈当场清空
（全页 AI 助手的返回按钮因此永远不出现，2026-08-07）。判定是 `isSidebarEcho(of:)`（按值，
aiAssistant 忽略 `initialQuery`），**不要用同步标志位**：标志在闭包结尾就置回 false，而 onChange
是下一个 update 周期才跑，跨周期挡不住。两个方向都按值收敛，天然不成环。

**踩过的坑（2026-08-06）**：`showDetailCloseButton` 逐个 case 列举，漏了 recapDetail，回顾详情页
既没有关闭按钮、`sidebarDestination` 又是 nil（sidebar 无高亮），进去就是死胡同；`closeDetail`
的前身 `closeRecordingDetail()` 硬编码 `activeDestination = .allRecordings`，从回顾 / 文件夹 /
标签点进的录音，关掉一律掉到「全部录音」。回归测试 `CadenzaTests/UI/NavigationReturnTests.swift`
（14 个），其中 `everyPageOffTheSidebarHasAnExit` 是不变量门禁：**新增的 destination 只要
`sidebarDestination == nil` 就必须 `requiresExplicitExit`**，漏了会被拦下。

## 9. 启动序列

`AppState.setup()` 的大体顺序：

| 阶段 | 主要动作 | 是否可能阻塞 |
| --- | --- | --- |
| 1. 装配 | `hasBeenSetUp`、聊天历史加载、store/coordinator/engine 连线 | 否 |
| 2. 权限 | `await checkPermissions()` | 是 |
| 3. 检测器 | `MeetingDetector` 回调连线、`startMonitoring()`、快捷键注册 | 否 |
| 4. 本地数据 | `refreshRecordings()`、`refreshFolders()`、`refreshTrash()` | 否 |
| 5. 恢复 | `coordinator.recoverInterrupted()`（必须在 auto-trash 前） | 是 |
| 6. 备份与清理 | `DatabaseBackup.performBackup()`、auto-trash 短录音 | 部分 |
| 7. 恢复（续） | orphaned audio 恢复、purge trash | 部分 |
| 7. 日历 | `calendarManager.startMonitoring()` + 30s AppState 同步 | 否 |

## 10. 线程模型总览

| 组件 | 隔离方式 | 线程安全来源 |
| --- | --- | --- |
| `AppState` | `@MainActor` | UI 根状态在主线程 |
| `RecordingEngine` | `@MainActor` | 录音状态机在主线程 |
| `AudioMixer` | `@MainActor` | 可观察状态在主线程，回调本身跑后台队列 |
| `AudioCaptureService` | `@unchecked Sendable` | 内部自己管理后台回调和对象生命周期 |
| `ProcessTapSystemAudioCapture` | main-owner + Core Audio IOProc | IOProc 只生成 sample buffer，后续回调转 `.utility` queue |
| `SegmentedAudioFileWriter` | `@unchecked Sendable` | 串行 DispatchQueue |
| `AudioFileWriter` | `@unchecked Sendable` | 串行 DispatchQueue |
| `AudioSegmentMerger` | nonisolated static | async/await + 局部对象 |
| `RecordingsStore` | `@ModelActor actor` | actor 序列化 |
| `TranscriptionManager` | `@MainActor` | 状态在主线程 |
| `PostProcessingCoordinator` | `@MainActor` | 队列和 UI 相关状态在主线程 |

## 11. 关键数值常量

### 11.1 录音

| 常量 | 值 | 位置 |
| --- | --- | --- |
| 分段时长 | 30s | `SegmentedAudioFileWriter` |
| duration timer | 0.5s | `RecordingEngine` |
| audio level poll | 0.25s | `RecordingEngine` |
| 自动停止倒计时 | 5s | `RecordingEngine` |
| meeting detection cooldown | 10s | `RecordingEngine` |
| merge timeout | `max(120, segmentCount * 5)` | `RecordingEngine` |
| `finishWriting()` 超时 | 10s | `AudioFileWriter` |
| AVAudioEngine tap buffer | 8192 samples | `AudioCaptureService` |

### 11.2 文件转录

| 常量 | 值 | 位置 |
| --- | --- | --- |
| `maxConcurrency` | 6 | `WhisperTranscriber` |
| `GeminiTranscriber maxConcurrency` | 5 | `GeminiTranscriber` |
| diarize chunk | 触发 `>600s`/`>25MB`，每块 300s (5min) | `WhisperTranscriber` |
| 普通 chunk | 1200s | `WhisperTranscriber` |
| Gemini chunk | 300s (5min) | `GeminiTranscriber` |
| `maxRetries` | 3/chunk | `WhisperTranscriber` / `GeminiTranscriber` |
| `maxExportConcurrency` | 6 (Whisper，与 maxConcurrency 对齐) | `WhisperTranscriber` |
| request timeout | 300s | `WhisperTranscriber` / `GeminiTranscriber` |
| resource timeout | 600s | `WhisperTranscriber` / `GeminiTranscriber` |
| segment 细分阈值 | 60s | `PostProcessingCoordinator.subdivideCoarseSegments` |
| `minimumTranscriptionDuration` | 30s | `PostProcessingCoordinator` |
| `silenceThreshold` | 0.006 (-45dB) | `AudioSilenceDetector` |
| unprocessed recovery window | 72h | `RecordingsStore` |

### 11.3 实时转录

| 常量 | 值 | 位置 |
| --- | --- | --- |
| realtime ready wait | 10s | `RealtimeTranscriber` |
| commit interval | 2.8s | `RealtimeTranscriber` |
| commit byte threshold | 144,000 | `RealtimeTranscriber` |
| no-delta watchdog | 8s | `TranscriptionManager` |
| UI throttle interval | 1s | `RecordingEngine._throttleTask` |
| overlay transcript cap | 20 segments | `RecordingOverlayPanel` |
| AI chat transcript budget | 12,000 chars | `RecordingOverlayPanel` |
| AI chat history cap | 6 messages | `RecordingOverlayPanel` |
| Apple realtime buffer | 64 items | `AppleSpeechTranscriber` |
| queue limit normal | 960 | `TranscriptionManager` |
| queue limit low latency | 220 | `TranscriptionManager` |
| flush 条件 | `final` / `>=4` / `>=180ms` | `TranscriptionManager` |

### 11.4 数据库与存储管理

| 常量 | 值 | 位置 |
| --- | --- | --- |
| 备份保留数 | 3 | `DatabaseBackup` |
| trash purge | 30 天 | `RecordingsStore` |
| auto-discard 短录音 | `<30s`（UserDefaults `autoDiscardThreshold`） | `RecordingsStore.finalizeRecording` |
| storage limit | UserDefaults `storageLimitMB`（0=无限） | `RecordingsStore.enforceStorageLimit` |
| 音频压缩 | 48kHz → M4A，仅压缩后更小时替换 | `PostProcessingCoordinator.compressAudioIfNeeded` |
| orphaned file 最小长度 | `>=30s` | `AppState.recoverOrphanedAudioFiles()` |
| CalendarManager poll | 60s | `CalendarManager` |
| AppState calendar sync | 5s | `AppState.startCalendarPolling()` |

## 12. 其它模块的架构备注

### 12.1 MeetingDetector

当前检测模型：

- per-process mic input
- calendar match
- window heuristic（Teams 主路径是结构识别，见下）
- tHelperOut output keep-alive（sustain-only，见下）
- minimum active hold 90s
- debounce 1s
- grace 3s
- active/ending poll 5s
- idle/detected poll 10s（事件驱动负责低延迟，poll 只是兜底）

#### Teams 窗口结构识别（2026-06-10，Town Hall 事故修复）

事故：2026-06-09 用户参加 "Global Security Town Hall - Quarterly (2026)"，`teamsInMeeting` 三条旧路径全部失败——(1) 标题关键词（"call"/"webinar"…）：真实会议窗口标题是会议名，从未命中；(2) control bar：新版 Teams 通话期间根本不再产生浮动控制条窗口（三天诊断日志证实，每次通话只有 2 个大窗口）；(3) 日历标题匹配：Town Hall 窗口名 ≠ 当时日历上下文事件名（`currentMeetingForDetectionContext` 用 `upcomingMeetings.first`，重叠事件时易选错）。win=0 连锁导致 sfallback=0，score 卡 2 < 3，自动开始/停止全灭。

修复：`teamsHasStructuralMeetingWindow` 作为第 4 条路径（旧路径保留）——大窗口（≥520×320）+ 标题以 `" | microsoft teams"` 结尾 + 首段（`" | "` 分割）不在 `mainAppTabNames`（chat/calendar/activity/teams/calls/files/onedrive/apps）+ 排除 pre-join 通用屏（`"microsoft teams meeting | microsoft teams"`）和 chat 窗口。识别依据是窗口**结构**而非与日历的字符串匹配。Teams 改版新增 tab 名时需要更新 `mainAppTabNames`。

#### Minimum active hold（90s）

事故同上：win=0 时瞬时信号 `teamsAdhocStart`（只活 1 个 tick）把状态机拉到 active 并 auto-start 录音，1 秒后信号消失 → ending → idle → auto-stop → 录音 9 秒 → `<30s` 被静默丢弃，用户完全无感知。修复：`isWithinMinimumActiveHold`——active 后 90s 内 score 跌破阈值 floor 到阈值（不转 ending）。guard 检查的是 **session 自己的 app**（`sessionState.currentApp`）仍在运行：active app 退出必须立即结束 session，不能被别的运行中 meeting app 钉住。

这块的性能目标是：

- 不在所有阶段高频轮询
- 不在每次 tick 都触发 SwiftUI observable 更新
- 只在 phase 真变化时发状态变更

#### `isContinuityAudioActive` 的生命周期门

Teams 在通话中开启屏幕分享时会重新组织窗口（call 主窗口和控制条会瞬时消失或换 title），window heuristic 此时短暂为 0，分数掉到阈值以下会立即把 active 推进 ending → 触发不该出现的 auto-stop。`isContinuityAudioActive()` 解决这个：检查 Teams helper 进程（`com.microsoft.teams2.modulehost`）是否在用 mic input，是则 `score = max(rawScore, threshold)`，把 active 钉住直到屏幕分享结束。

**生命周期门**：guard `sessionState.isActive || sessionState.isEnding`。这是有意设计的不对称：
- idle/detected 阶段**不**用 helper audio 当信号，因为 modulehost 即使非通话期间 `isRunningInput` 也可能为 true，用它会引入 false-positive 检测
- active/ending 阶段才允许它当 keep-alive，因为此时已确认在会议中，sticky helper 持续报告 input 也不会让我们误启动一个新会议

历史上有过加 `isTeamsMainAudioActive` / `isTeamsScheduledAudioActive` 两个无 lifecycle gate 的版本试图覆盖更多场景，但实测都没触发（Teams 主进程 audio 不通过 per-process API 暴露），且让 sticky helper 在 idle 也能 pin score → 移除回归到当前简洁形态。

#### Teams keep-alive 的 cap 与"通话结束"判定（重要）

`modulehost` 的 `isRunningInput` **通话结束后仍为 true**，且 Cadenza 自己录音时 `systemMicActive` 也恒为 true，所以一个无日历、无窗口的 Teams quick call 结束后 **input 侧没有任何信号会掉下来**。2026-06-10 起首选判定是 output 探针（见下节，挂断同 tick 归 false → ~8s 内 auto-stop）；`teamsUncorroboratedKeepAliveCap` 降级为 output 探针失效场景（屏幕共享+远端全静音）的兜底：blackout 持续超过上限后 score 不再被 floor，状态机走 `active → ending → idle` 触发 auto-stop。

- **cap = 10 min**（曾为 30 min）。对"quick call 结束后录死气"最坏情况的钝性时间界。自 output 探针接入后，正常挂断不再依赖它。
- **受 cap/gate 约束的 flooring 路径现有三条**：`teamsUncorroboratedKeepAliveActive`（受 10min cap）、`teamsHelperOutputKeepAliveActive`（sustain-only，受 4h cap，见下节）、`minimumActiveHold`（90s，见 §12.1）。历史教训：曾有一条独立的 `continuityAudioActive && !expired` 分支，当 keepalive candidate 因非过期原因为 false（如日历显式指向别的 app）时，会无视 cap 把会议**无上限**钉死——已删除。回归测试：`teamsActive_continuityWithoutKeepAliveCandidate_progressesToEnding`。新增任何 flooring 路径都必须自带退出条件（cap、gate 或信号本身会掉）。

#### `isTeamsHelperOutputActive` —— 通话结束判别探针（✅ 已验证并接入评分，2026-06-10）

**实测结论**（2026-06-08 ~ 06-10 三天真实 Teams 会议的 `/tmp/cadenza_meeting_diagnostics.log`）：`tHelperOut` 通话期间恒为 true，**挂断的同一个评估 tick 立刻归 false**，Teams 闲置时为 false。"modulehost 输出也 sticky"的风险被排除。

接入方式（`shouldUseTeamsHelperOutputKeepAlive`，**sustain-only**）：

- 仅当 session 已 `active`/`ending`、session app 是 Teams 且仍在运行、`rawScore < threshold` 时，floor score 到阈值。**绝不参与从 idle 启动**——这是有意的不对称（与 `isContinuityAudioActive` 的 lifecycle gate 同理）：output 信号只用来"维持已确认的会议"，不用来"发现会议"。
- 不受 10min uncorroborated cap 约束（output 活跃本身就是 corroboration），但有独立 4h 硬 cap（`teamsHelperOutputKeepAliveCap`）防探针意外 sticky；该 cap **仅当 output 是唯一 flooring 路径时才计时**（`!otherFlooringActive` gate），避免长会（日历/min-hold 同时撑着）白白烧 4h 预算。
- 诊断字段：`toutKeep`（keep-alive 生效）/ `toutExp`（4h cap 到期）。
- 效果：quick call / Town Hall 这类窗口与日历都靠不住的会议，挂断后 output 掉 → score 掉 → `active→ending→idle` → auto-stop 在 ~grace(3s)+countdown(5s) 内完成，不再等 10min cap。
- **仍未实测的场景**：演讲者共享屏幕 + 远端全静音（无远端音频 → output 可能 false）。此时 output keep-alive 不生效，session 退化到旧的 10min uncorroborated cap——**降级而非误停**（min-hold 90s 和窗口结构识别也还在撑）。下次屏幕共享会议记得看 `tHelperOut` 在共享期间的行为并回填这里。

#### 日历同步与 `reevaluateNow`

`AppState.calendarStateSyncTimer` 每 5 秒同步一次 calendar cache（不打 provider，只重算 `currentMeeting`）。**只有在 `meetingDetector.currentCalendarMeeting?.id` 实际变化（进入或退出一个会议窗口）时才调 `reevaluateNow(reason: "calendarSync")`** 触发一次 fresh window enumeration；否则跳过，把检测压力留给 detector 自己的 3s poll。

历史上这里是 30s 同步无条件 reevaluate，再激进改成 2s 无条件 reevaluate 一度让录音期间 main actor 长时间被 `CGWindowListCopyWindowInfo` + 后续 SwiftUI commit 占满。当前 5s + 条件触发是性能与"会议刚开始时检测能在几秒内启动"之间的折中。

外部 calendar provider（EventKit / Google）的轮询保持在 60s（`CalendarManager.startMonitoring`），所以新增/修改的 event 最久 60s 才进 cache，不是 5s 同步能加速的。

#### Observable 收紧（重要）

`MeetingDetector` 是 `@Observable`，但内部缓存/计时器/回调如果默认被追踪，每次 poll 重赋值都会让所有通过 `AppState` 间接观察到 detector 的 SwiftUI 视图失效（如 `FloatingAIChatButton` 用了昂贵的 Liquid Glass `.interactive()` capsule，在录音的高负载下重渲染会明显卡顿）。

规则：**只有 view 真正消费的属性保持 observable，其余一律 `@ObservationIgnored`**。

当前 observable 的属性（共 3 个）：
- `runningMeetingApps` — 仅在 app 启动/终止时 append/remove，不会每 tick 写
- `activeMeetingApp` — 每次写入前都做 `if activeMeetingApp != next` guard
- `sessionState` — 已有 `isSamePhase` guard

所有内部状态（`cachedScWindows`、`cachedWindows`、`nextWindowFetchAllowedAt`、`appPollTimer`、`graceTimer`、`eventEvalWorkItem`、`workspaceObservers`、`currentPollInterval`、`lastWindowDumpAt`、`perProcessMicEverDetected`、`lastActivatedMeetingApp`、`audioListener`、`audioQuery`、`scoreThreshold`、`windowDumpEnabled`、`windowDumpInterval`、`currentCalendarMeeting`）和 5 个回调闭包（`onMeetingActivityDetected` 等）都标了 `@ObservationIgnored`。

写入 guard 模式（覆盖所有 4 处）：
```swift
if activeMeetingApp != next {
    activeMeetingApp = next
}
```
位置：`pollRunningApps`（两个分支）、`handleWorkspaceAppActivation`、`updateActiveMeetingApp`、`scanRunningApps`。

> 不变量：`MeetingDetector` 不会在没有真值变化的情况下使任何 SwiftUI 视图失效。修改这个类时务必保持。

### 12.1.5 AI 模型配置（2026-06-11）

所有 model ID 统一经 `AIProvider` 的四个 resolver（`summaryModel` / `chatModel` / `transcriptionModel` / `realtimeModel`）解析：UserDefaults 覆盖（`model.*` / `transcriptionModel.*` / `realtimeModel.*`）?? 代码默认（`default*Model`，注释含选型理由）。空/空白/换行覆盖视为未设置。设置 UI 的 `ModelOverrideRow`（SettingsView，三处：批量转录 / Live Transcription / Summary & AI）可编辑；`CadenzaApp.migrateLegacyGeminiModelDefaults` 启动时清理已废弃默认值的用户残留（pattern：废弃旧默认时把旧值加进 legacy 集合）。**禁止在 transcriber/service init 给 model 默认参数**——历史上 realtime 模型四处硬编码，升级要改代码重发版；2026-06-11 已全部收口（含 chat 切 provider 菜单、RecapGenerator、generateChapters 等旁路）。回归测试 `AIProviderModelConfigTests`。

### 12.2 AI Assistant

#### Chat markdown 渲染性能（2026-06-11 主线程 100% hang 修复）

事故：AI chat 第二条 prompt 时主线程 100% CPU 永久卡死（sample 栈：SwiftUI 布局循环——ZStack `explicitAlignment` 深递归 + ScrollView/LazyVStack `measureEstimates`）。复合根因：(1) `MarkdownMessageView.body` 每次布局重跑 `MarkdownMessageParser.parse` + 每 block 重跑 `AttributedString(markdown:)`，历史消息**无任何缓存**；(2) streaming 每 0.12-0.4s 一次 render，`renderRevision` 每次递增 → 三个 chat view 的 onChange 每次 `proxy.scrollTo`（强制全量 lazy-stack 布局）。第一轮回复（长 markdown）躺进历史后，单次布局成本 > 渲染间隔 → 主线程积压永不恢复。**第一句没事、第二句必死**的特征 = 历史里有没有长消息。

修复（保持此不变量）：
- `MarkdownRenderCache`（@MainActor，NSCache×2：content→blocks、inline string→AttributedString，各 8MB totalCostLimit）——消息内容不可变，缓存命中后历史消息的重布局降一个量级；
- `ChatStreamState.render`：snapshot **等值去重**（@Observable 赋相等值也会失效观察者）+ `renderRevision`（唯一消费者是 scrollToBottom）独立节流 0.3s，`forceFull`（stop/finish/truncate）必发保证最后一滚；
- **flatten 阈值降级（2026-06-12，单次成本侧根治）**：缓存+节流后次日同场景复发，二次 sample 证明热点是**布局本身**（栈里 0 个 parse 符号）——每个 block 一个 baseline-aligned HStack + bubble background ZStack，几百块的消息单次布局 pass 秒级，节流无济于事。`MarkdownBlocksView.flattenThreshold = 48`：超过即把全部 blocks 拼成**单个 AttributedString 用一个 Text 渲染**（TextKit 排版毫秒级，布局引擎只见 1 个视图），样式近似（前缀 bullet/等宽代码/次要色引用）；普通消息保持逐块精排。flatten 结果按 blocks+字号指纹缓存。
- **失效风暴侧（同日第三轮，flatten 后仍复发才补齐）**：三次 sample 中 `AG::UpdateStack::update` 约 2/3 样本散布在海量小分支 = AttributeGraph 失效传播风暴。两个漏网高频源：(1) `ChatStreamState.text` 每 tick 赋值而 `hasVisibleContent`（每个 streaming 气泡都读）依赖它 → 3-8Hz 全树失效。修复：`text` 仅在 `forceFull`（finish/stop/truncate）写，`hasVisibleContent` 只看 snapshot。(2) 钉底判定阈值 32pt：streaming 增长 → "离底" → pin @State 写 → scrollTo 拉回 → 再写，6-7Hz 振荡 × 4 个 chat view。修复：`ChatStreamState.scrollPinSlack = 240`。**教训：hang = 高频失效 × 单次布局成本，两个因子都要打**；只降一边，另一边的余量会被吃掉。
- 回归测试 `ChatRenderPerfRegressionTests` + `FlattenedMarkdownTests` + `StreamingInvalidationTests`。
- **第四轮复发 → 全面审查定案（2026-06-12，三 agent：复现/UI 拓扑/数据层）**：用户会话仅 8 条消息/12.8k 字符——前三轮的"长消息"模型全错。真根因三件套：(A) panel 与 26 卡网格共享 GraphHost（见 §8.1.3，已迁独立 NSPanel 根治）；(B) 历史消息数是 commit 成本放大器（复现 harness `ChatHangReproTests` 量化：0→4 条 = 1.5→31ms/commit，TextKit 重排不被任何缓存跳过）；(C) accumulator 每 tick O(response) 扫描 + 节流锚点错误导致积压全价重放（已改两段式存储 `committed+pendingTail`，每 tick 只扫 ≤1800 字符 tail；fence 内有界 verbatim 提交；mid-line 切分有跨 tick 标记防块标记误读；节流锚移至 render 完成时刻）。等价性回归 `AccumulatorIncrementalScanTests`（分块流式终态 == 整体 parse）。**方法论：先复现再修；sample 全是框架符号时查"谁共享 GraphHost"；"为什么只有这个入口撞"的对照组就是答案。**

排障手册：app "死掉"先 `ps -o state,%cpu`——**state R + 100% CPU = 布局/计算忙转**（不是死锁），立即 `sample <pid> 3` 看栈；SwiftUI 栈里 `flushTransactions → Subgraph.update` 占满 + 同一符号深递归 = 单次布局 pass 失控,找"每次 body 重算的昂贵纯函数"和"高频布局触发器"（scrollTo/@Observable 赋值）。

#### Chat 上下文组装（AIContextAssembler，2026-06-12 更新）

> 旧文档说"取 `recordings.prefix(20)` 拼 prompt"——早已过时。现状是 `AIContextAssembler`（actor，30s TTL 缓存）+ `QueryAnalyzer`（意图分析：时间词/speaker/关键词/@mention）+ `RecordingsStore.fetchAIContext`（按范围/关键词取数）+ 按 `provider.contextTokenBudget`（openai/claude 30k、gemini 20k、apple 2k）做优先级填充（summaries → action items → decisions → transcript excerpts；targeted 查询时 transcript 优先）。

**搜索时间范围**：问题里有显式时间词（"last week"/"昨天"/"所有录音"…，见 `QueryAnalyzer.timePatterns`，具体时间词优先于 all-time 词条）→ 用它；否则用 UserDefaults `aiChatDefaultTimeRange`（Settings → Summary & AI → "AI chat searches"：allTime[默认]/last90Days/last30Days）。`nil` dateRange = 全库（fetch 按 startDate 降序，token 预算内新者优先装入，旧录音在预算耗尽后截断）。历史教训：默认曾硬编码 `last30Days`，30 天前的录音对 chat 完全不可见（2026-06-12 用户报告"AI chat 只会找最近一段时间的录音"）。`TimeRange.allTime` 走 nil 路径，`resolveDateRange(.allTime)` 仅为穷尽性兜底。

仍存在的架构方向（未做）：全局 AI 是 prompt 拼接而非结构化检索/索引；大库（数百条+预算截断）下"全部"实际是"预算内最新的全部"，需要两阶段检索（先目录后取详情）才能真正全库问答；folder 级 AI 的 `fetchFolderContext()` + `ProjectMemoryService` 路径更健康，全局 AI 未复用。

### 12.3 Folder / Project Memory

folder 级 AI 路径比全局 AI 更健康：

- `fetchFolderContext()` 先做结构化聚合
- `ProjectMemoryService` 再转 prompt

这是未来全局 AI 更合理的方向。

### 12.4 Chat History

聊天历史不是存 SwiftData，而是：

- 每个 session 一个 JSON 文件
- 原子写入
- 低复杂度
- 与录音主数据库低耦合

### 12.5 导出与日历

- `ExportService` 负责 Notion / Craft
- `CalendarManager` 聚合 Apple / Google / Zoom
- 日历事件先聚合成 `MeetingEventDTO`
- 自动 link calendar event 在 post-processing 完成后触发
- Notion `clientSecret` 存储在 Keychain（`KeychainManager`），不再是 UserDefaults。读取时 Keychain 优先，UserDefaults fallback（兼容旧版数据）

#### 批量导出（Export All，2026-06-12）

Settings → Integrations 的 Notion / Craft 行内各有 "Export all recordings"，
把所有尚未导出的录音补导到对应目标。核心：`BulkExportCoordinator`
（`Cadenza/Services/Export/BulkExportCoordinator.swift`，@Observable @MainActor，
挂在 `ExportService.bulkExporter`，AppState 生命周期——关 Settings 页不中断）。

去重判定（"问目标端缺什么"，不做客户端单方面标记）：
- **Notion**：backend 持久化 export-page 的 Idempotency-Key（= recording UUID），
  客户端经 `GET integrations/notion/exported-ids` 拉账本 diff，只推缺的。
  手动单条导出 / auto-export 走同一条带幂等键的 export-page 路径，自动入账。
  端点 404（backend 未升级）→ 显式报错（两种 error 形态都映射：带 envelope 的
  `CadenzaAPIError.backend(_, 404)` 与裸 body 的 `AuthError.server(status: 404)`），
  不 fallback 全量推。
- **Craft**：craftdocs:// URL scheme 是单向写入，无读取面 → 本地 ledger
  （UserDefaults `craft.exportedRecordingIDs`，单条导出成功也写入）。
  ledger 只增不删：录音删除后残留的 stale UUID 无害（已删录音不会再出现在
  diff 左侧），`compactMap(UUID.init)` 容忍坏条目。换机器/重装后 ledger 丢失
  会重复建 Craft 文档（已知局限，Craft 无更好选项）。

执行（`run(destination:ids:)` 串行循环）：dateOldest 正序（Notion 页面创建顺序 =
会议时间线）、串行（Notion 代理 rate limit；Craft 每条间隔 0.4s 防止连环唤起）、
单条失败聚合继续、auth 失败（unauthorized / notSignedIn /
integrationReauthRequired）立即中断、跳过 transcript+summary 均空的录音、
两目标互斥（isBusy）、Disconnect Notion 时 `cancelActiveRun(for: .notion)`。
错误文案统一走各 error 的 localized errorDescription（仅 404 端点缺失特判），
不在 coordinator 重复映射。

状态机：idle → preparing → confirming(pending) → running(done/total)
→ finished(succeeded/failed) | cancelled(exported) | failed(message)；
upToDate 为无缺漏时的短路结果态。**确认按钮必须走同步入口
`beginConfirmedRun()`**（同步 claim：.confirming → .running + snapshot ids，
再 spawn run Task）——alert 的 dismiss binding 会在同一 MainActor turn 内同步触发
`dismissConfirmation()`，若 phase 翻转延迟到 Task body，run 会被静默扼杀
（回归测试 `beginConfirmedRunSurvivesAlertDismissRace`）。异步入口
`confirmAndStart()` 供测试直接 await 全程。

测试：`CadenzaTests/Services/BulkExportCoordinatorTests.swift`（20）、
`CraftExportLedgerTests.swift`（3）、`NotionExportedIDsTests.swift`（4）。
backend 合同由 web API 的导出端点与 `NotionExportService`/`BulkExportCoordinator` 的契约测试共同约束。

### 12.6 AI Context Layer

`AIContextAssembler` (actor) 统一了 `AIChatView` 和 `FloatingAIChatButton` 的上下文装配：

- `QueryAnalyzer` 从用户问题中提取时间范围、说话人、关键词（纯本地 regex，无 API 调用）
- `store.fetchSpeakerNamesAndAliases()` 预查询已知说话人（displayName + aliases）
- `store.fetchAIContext()` 一次 store API 拿到 summaries、action items、decisions、follow-ups、transcript excerpts
- 按优先级填充直到 provider 的 token 预算用完（summaries > action items > decisions > transcript）
- 输出 `AIContextPacket`（systemPrompt + `messages: [ChatMessage]` + metadata），直接喂给 `AIServiceProtocol.streamChat(systemPrompt:history:model:)`

**Multi-turn + caching**：
- `messages` 字段保留最近 6 轮 history（assistant 截断到 500 字符）+ 当前 user 问题
- `AIServiceProtocol` 提供 `streamChat(systemPrompt:history:model:)` 多轮版，default extension 把 history 拼成单字符串 fallback 到老的 `streamChat(systemPrompt:userMessage:model:)`
- `ClaudeService` / `OpenAIService` override 多轮版。Claude 在最后一条 user message 上额外打 `cache_control` breakpoint，让 turn 1..N-1 都进 prefix 缓存（5 分钟 TTL）。OpenAI 自动 cache ≥1024 token 前缀，无需 marker
- 其它 provider（Gemini / Apple FM）走 default extension fallback

**Last-call cache**（actor 内部实例状态）：
- key = `(scope_ids_sorted, keywords_sorted, dateRange-quantized-to-minute, speakerQueries_sorted, tokenBudget)`
- 缓存的 value 是 `contextText`（SwiftData fetch + sections 拼装的产物），**不是**完整 `systemPrompt`
- 命中时跳过 `store.fetchAIContext()` + `buildContextSections()`，复用 contextText + metadata，仅现场拼接 identity + assemble systemPrompt + 重建 messages
- 同一 chat session 内连续问相似 scope 的问题（典型场景）几乎零开销
- dateRange 量化到分钟：`last30Days` 的 now-anchor 每秒变会破坏 cache，按分钟量化即可

**User identity injection**（`identityBlock()`）：
- 从 `UserDefaults["userName"]` + `UserDefaults["userJobTitle"]`（Settings → Your name / Job title）读取
- 拼成一段 "You are speaking with Andy (Engineer). When discussing action items..." 注入 system prompt
- **每次现算**，不进 cache value：用户改名 → 下条消息立即生效
- 同一用户内 userName 不变 → Anthropic prompt cache 仍命中（identity 是稳定 prefix 的一部分）
- 三处 chat 入口都注入：`AIContextAssembler` (主 AI chat)、`RecordingOverlayPanel.buildSystemPrompt` (live recording chat)、`ProjectMemoryService.buildSystemPrompt` (project memory chat)

**Output language directive**（`languageDirective()`）：
- 从 `UserDefaults["summaryLanguage"]` 读取（Settings → Summary language，跟 summary 共用一个偏好）
- 非 `auto` 时拼一句 "Respond in Chinese (简体中文)." 加到 system prompt 末尾
- `auto` 时不强制（让模型自然按用户输入语言回答）
- 主 chat 和 overlay chat 都注入

**RecordingOverlayPanel — in-meeting urgency**：
- system prompt 额外加 "user is IN the meeting right now — be terse, 1-3 sentences default, no preambles"
- Quick prompts 区分两类：有 live transcript 时显示 4 个**急救型** (溜号 / 轮到我 / 提到我 / 现在的分歧)，无论何时都显示 2 个**辅助型** (follow-up questions / notes template)

不在此 layer 内的：
- `RecordingOverlayPanel`：录音中走 live transcript 12k cap 路径，仍用单消息 + `packHistory` 字符串拼接（live transcript 频繁变化，cache 命中率低，无需多轮）
- `FolderDetailView`：走 `fetchFolderContext()` + `ProjectMemoryService`

### 12.x MCP Server(外部 AI 访问转录,2026-06)

代码位于 `Cadenza/Services/MCP/`，协议行为由 `CadenzaTests/MCP/` 覆盖。

```
MCP 客户端 (Claude Code / Gemini CLI / Claude Desktop via mcp-remote)
   │ HTTP POST /mcp + Bearer token (JSON-RPC 2.0, MCP Streamable HTTP 子集)
   ▼
127.0.0.1:8585  MCPServer (actor, NWListener, requiredInterfaceType=.loopback)
   ├─ MCPHTTPConnection (actor/连接)  receive 循环 + Content-Length 分帧
   ├─ MCPRouter        方法白名单: initialize/initialized/ping/tools/list/tools/call
   ├─ MCPToolRegistry   5 核心读 + 6 核心写(含 set_speaker_name 回写说话人映射)
   │                    + 2 meeting-context 读 + 1 meeting-prep 写(write_artifact,共 14 个)
   └─ MCPClientConnector 一键写入客户端配置(Claude Code 走官方 CLI;Gemini/Desktop JSON 无损 merge)
   ▼
RecordingsStore (actor) → SwiftData
```

- **生命周期**:`AppState.syncMCPServer()`(setup 末尾 + Settings 变更时调用);UserDefaults 键 `mcpServerEnabled` / `mcpWritesEnabled` / `mcpServerPort`(均默认关/8585);server 开关与端口是设备级配置，但 bearer token 和逐客户端 scope 以 active profile 命名空间存储，切换 profile 后必须重新连接。固定端口**无自动回退**——被占即 `.failed` 红字,防客户端配置静默失联。
- **HTTP 层硬约束**:严禁单次 `receive` 解析(OAuthCallbackServer 的 4KB 模式只能活在无 body GET;TCP ~1.4KB 即分片)。必须循环收到 `\r\n\r\n` 再按 `Content-Length` 收满。每响应 `Connection: close`(无 keep-alive 状态机)。上限:header 16KB(431)、body 1MB(413)、无 Content-Length 的 POST → 411、30s watchdog。无 SSE(GET→405)、无 session、batch→-32600。
- **安全**:loopback-only;Bearer token SHA256 常时比较;Host/Origin 白名单防 DNS-rebinding(`MCPHTTPConnection.isAllowedHost/isAllowedOrigin`,纯函数有单测)。威胁模型边界:app 未 sandbox,本机进程本就能直读 SQLite——token 防的是浏览器侧与无差别扫描,不防本机恶意进程。
- **工具层**:cursor 为全局 segment index(时间窗只过滤不重编号);speaker 经 `speakerMappings.profileName` 解析真名,`get_transcript` 响应带 `speakers` roster(`resolvedName: null` = 未识别占位符),AI 可经 `set_speaker_name` 回写映射(label 必须真实出现在该转录中,防幻觉;profile 按 displayName 不区分大小写复用,否则新建);trashed 一律隐藏(`fetchActiveDetail` 显式查 trash 列表,因 detail DTO 无 trashedDate);写工具双重把关(开关关闭时 tools/list 隐藏 + call 拒绝),每次写经 `os.Logger`(subsystem `com.shuiandy.Cadenza`,category `mcp`,`.notice` 可 `log show` 回查)。
- **一键连通(`MCPClientConnector`)**:Settings 的 Connected clients 五行(Claude Code / Gemini CLI / Claude Desktop / Codex (GPT) / Hermes)。检测纯文件系统(`~/.claude.json` / `~/.gemini/settings.json` / `~/Library/Application Support/Claude/claude_desktop_config.json` / `~/.codex/config.toml` / `~/.hermes/config.yaml`,home 与 /Applications 可注入测试),状态四态:notInstalled / disconnected / connected / stale(token 或 URL 不匹配,reset token 后变 Update 按钮)。连接:Claude Code 经 `zsh -lc` 跑官方 `claude mcp add -s user`(它的 ~/.claude.json 是活状态文件,不直接写);Gemini/Desktop JSON 无损 merge(只 upsert `mcpServers.cadenza`,其余键全保留);Desktop 用 mcp-remote 的 `env.AUTH_HEADER` 形式(其 args 按空格分割的已知 bug);Codex 是 TOML **文本级整段 upsert**(Swift 无 TOML 库;只动我们自己的 `[mcp_servers.cadenza]` 段,边界=下一个行首 `[`),用 config.toml 的静态 `http_headers` 字段;Hermes 是 YAML **文本级块替换**(同样无 stdlib parser):重生成 `mcp_servers.cadenza` 的 `url:` + `headers.Authorization:`,保留其它子键(timeout/connect_timeout)与文件注释/空行;cadenza 仅匹配 `mcp_servers` 的**直接子项**(嵌套同名键忽略),url/headers 用带前瞻的 subtree-skip 删除(消除跨空行的 stale Authorization 但不吃尾部分隔注释),tab 缩进 / inline-flow / 多行 scalar 一律抛 `configUnrecognized` → 退回手动片段。**ChatGPT 桌面版无法接入**:其 connectors 由 OpenAI 云端发起,127.0.0.1 不可达;GPT 侧正解就是 Codex。**connect 失败(抛错)时 UI 在该客户端行下方展示系统错误 + 对应客户端的手动配置片段**,正常路径不显示任何手动配置。
- **⚠️ tags 谓词陷阱**:`#Predicate { $0.tags.contains(x) }` 会被 SwiftData 编译成 SQL 字符串搜索,空 tags 行(NULL 列)直接 `_NSCoreDataStringSearch` → `CFStringGetLength(NULL)` segfault(2026-06-12 测试中实锤,crash report 在案;当晚 MCP 层先做了内存过滤 workaround,但 store 层谓词仍在,UI 的 tag 过滤 + 搜索路径照样能崩主 app)。2026-06-12 已根治:`RecordingsStore.fetchRecordingDTOs` 的 tagFilter 改为 fetch 后内存过滤(谓词只保留 trashedDate/folder),MCP 层的 `listRecordings` 仍传 `tagFilter: nil` 并自做内存过滤(双保险),回归测试 `RecordingsStoreTests.tagFilterSurvivesUntaggedRows`。新代码不要把数组 `contains` 写回 #Predicate。
- **测试**:`CadenzaTests/MCP/`(71 个:Models/Router/Tools/HTTP/Connector),HTTP 测试起真 listener(ephemeral port)并含 TCP 分片到达用例;工具测试共享单一内存容器(macOS 26 并发建 ModelContainer 会 SIGTRAP,见 TestHelpers 注释);connector 测试注入 temp home,merge 纯函数直接测。

## 12.y Meeting Prep(agent-authored artifacts)

实现位于 meeting-prep artifact、scheduler 与 MCP tool 三条共享路径中。

会前自动(或 agent 手动)生成一段准备简报,存成通用 `AgentArtifact` 槽位(`kind=meetingPrep`,复用 Phase 1 的 acquire/commit 原子语义,而非 meeting-prep 专属表)。

```
CalendarManager (tick, 复用现有 60s 轮询)
   ▼
MeetingPrepScheduler.tick(events:now:)          — 每场会一次
   ├─ MeetingPrepFingerprint.compute(event)      纯函数:标题/时间/参会人+状态/notes/URL → SHA256
   ├─ store.markStaleIfChanged(slot, fp)         内容变化时标 stale(UI 徽章,双 provenance 通用)
   ├─ MeetingPrepScheduleDecision.decide(...)     纯状态机:eligible? lead-window 内? 现有槽位状态?
   │   ├─ MeetingPrepEligibility.isEligible       非 all-day、非 declined、非 free/OOO、有其他参会人或会议链接
   │   └─ 现有槽位:external → 恒 skip(不 auto 覆盖);ready → 指纹变才 generate;
   │                generating → TTL(600s)内 skip 否则 generate;failed → retryable 且 retryAfter 到期才 generate
   └─ .generate → single-flight(inFlight set 去重)
       ├─ store.acquireBuiltinSlot(...)           占位 .generating,拿 generationID
       ├─ MeetingPrepContextBuilder.assemble(event:store:)   ← 唯一装配入口,MCP get_meeting_context 共用
       ├─ MeetingPrepGenerator.generatePrep(...)  经 AIGenerationGate 走默认 provider(与摘要同一套配额/重试语义)
       └─ store.commitBuiltin(...)  成功→ready + 发 .cadenzaArtifactsChanged + 会前提醒通知;
                                     失败→failed(errorClass 分类,retryable 记 5min retryAfter 退避)
```

- **手动 `generateNow(event:)`**(UI "立即(重)生成"按钮,`MeetingPrepSection.swift`):绕过 eligibility/lead-window/decision,out-of-band 生成(不占 tick 的槽,失败不改动现有槽位)。成功后走 `overrideWithBuiltin(candidate, expectedPriorExternalUpdatedAt:)`——若生成期间外部(agent)已用更新的 `external` 覆盖同一槽位,放弃自己的结果(external 优先于 auto/manual builtin)。不发通知(用户已在看卡片)。
- **MCP 三工具**(`MCPToolRegistry`,均受 `mcpMeetingContextEnabled` 门控,`write_artifact` 额外受 `mcpWritesEnabled` 门控):`list_upcoming_meetings`(时间窗内会议 + prep 状态/来源/是否 stale)、`get_meeting_context`(单场会的完整 prep context,与 scheduler 共用 `MeetingPrepContextBuilder.assemble`)、`write_artifact`(agent 写回 prep,走 `writeExternalArtifact` 无条件覆盖当前槽位——external 写永远赢,builtin/auto 不会覆盖回去)。
- **两个 feature gate,默认都关**:`meetingPrepEnabled`(Settings → Transcription & Summary → Meeting Prep,控制 auto 生成是否跑;lead time 由 `meetingPrepLeadMinutes` 控制)、`mcpMeetingContextEnabled`(Settings → Integrations → AI Access (MCP),控制 meeting-context 读域是否对外可见/可调——比 transcript 读权限更敏感,日历/参会人/跨会历史全量暴露给外部 agent)。`write_artifact` 额外要求 `mcpWritesEnabled` 也开(两者都开才在 tools/list 出现、才能调用)——关掉 meeting-context 即关闭整个 meeting-prep MCP 面,含写。
- **隐私护栏**(`MeetingPrepContextBuilder`,铁律,勿绕过):excerpt 只按参会人姓名过滤;无其他参会人时**禁用** excerpt(避免 speakerQueries=nil 退化成"不过滤"= 全库泄露);全库 `summaries`/`actionItems` 必须经 `scoped(_:eventTitle:)` 收窄到"该会真正相关"的 recordings(excerpt 命中 或 标题 token-Jaccard ≥ 0.6),漏配优于误伤。scheduler 与 MCP `get_meeting_context` 共用同一个 `assemble` 入口,任何新增消费方都必须走它,不得各自拼 context。
- **常量表**:

| 常量 | 值 | 位置 |
| --- | --- | --- |
| 默认提前量(lead) | 30 min(可选 15/30/60) | `meetingPrepLeadMinutes`,`MeetingPrepScheduler.leadMinutes` |
| generating TTL | 600s | `MeetingPrepScheduler.generatingTTL` |
| 失败重试退避(retryable) | 300s | `MeetingPrepScheduler.failed(...)` |
| 标题相似阈值(token Jaccard) | ≥ 0.6 | `MeetingPrepContextBuilder.titleSimilar` |
| 指纹字段 | title / startDate / endDate / attendees(email+status) / notes / meetingURL | `MeetingPrepFingerprint.compute` |

- **关键文件**:`Cadenza/Services/AI/{MeetingPrepScheduler,MeetingPrepEligibility,MeetingPrepScheduleDecision,MeetingPrepFingerprint,MeetingPrepContextBuilder,MeetingPrepGenerator}.swift`、`Cadenza/Views/Calendar/MeetingPrepSection.swift`、`Cadenza/Services/Persistence/RecordingsStore+Artifacts.swift`(通用 artifact 槽位原语)、`Cadenza/Services/MCP/MCPToolRegistry.swift`(meeting-context 工具)。
- **测试**:`CadenzaTests/AI/MeetingPrep*Tests.swift`、`CadenzaTests/MCP/MCPMeetingPrepToolsTests.swift`。

## 12.z 本地导出与 Portable Archive(Phase 0)

这是 Profiles/账号体系的 Phase 0，格式和恢复约束由 portable-archive 测试固定。
——在任何存储结构变更(相对路径/per-profile)之前先给用户完整备份工具。**本模块刻意不依赖路径解析层
(Phase 1A),按现状把 `audioFilePath` 当绝对路径读,文件缺失走 failures。**

两种产物(§12 spec 的拆分,命名有意区分):

- **Human-readable Export**(给人看的):单条(DetailView 导出菜单:txt/SRT/md/摘要 md/音频 m4a,
  经 `ExportSavePanel`)+ 批量(`BatchFileExporter`,Settings → General → Export & Backup)。批量输出
  每录音一个目录(`yyyy-MM-dd - 标题/`:audio.m4a + transcript.{txt,srt,md} + summary.md + metadata.json),
  重名目录 ` -2` 后缀。
- **Portable Archive**(可验证备份,**不叫 Restorable**——产品级导入是 Phase 5,round-trip 承诺前不改名):
  `PortableArchiveWriter` 产出 `Cadenza Archive <date>.cadenza-archive/` 目录:manifest.json(schema 版本、
  每文件 size/SHA-256、failures 清单、unmerged 标记)+ entities/*.json(独立版本化结构,见
  `PortableArchiveSchema`,**与 app DTO 解耦**)+ audio 原件 + unmerged segments(仅无合并音频的录音)+
  chat-history + embeddings(隐私敏感,UI 勾选才含,默认关)。**永不包含**:API keys、token、session、诊断日志。

关键机制与硬约束:

- **失败语义**:单条失败不断整批;"DB 引用了音频但文件没了"= failure,"录音本就没有转录/摘要/音频"≠ failure;
  失败条目的其余文件保留(部分成功可见,不静默)。
- **原子性**(archive):staging 目录写入 → **全量重读每个文件算 hash** → manifest 最后写 → `moveItem` 原子
  改名;取消/失败清 staging,半成品 final 目录不可能存在。
- **preflight**:磁盘估算(音频 Σ + 文本估算 + 余量),经 `DiskSpaceProviding` 协议注入(测试模拟磁盘满);
  不足直接失败,零副作用。
- **确定性**:实体 JSON 一律 `PortableArchiveSchema.makeEncoder()`(sortedKeys + **日期为 epoch 秒数字**
  ——ISO 字符串的 format→parse 不幂等,截断级联每轮掉 1ms,round-trip 门禁实锤后弃用),同输入两次
  导出字节级一致(含 embeddings.json,有测试);store 侧所有归档枚举带 UUID tie-breaker,
  voice sample 用 rawLabel→createdAt→embeddingData 全稳定排序。
- **线程**:状态机在 MainActor(`BatchFileExporter`/`PortableArchiveExporter`,模式同 `BulkExportCoordinator`,
  含 beginConfirmedRun 的 alert-dismiss 竞争防护);文件 IO 走 `Task.detached(.utility)`;archive 取消经
  `OSAllocatedUnfairLock` 跨线程 flag。
- **一致性**:store 级实体(folders/recaps/artifacts/speaker profiles + sizing)经 `fetchArchiveCatalog`
  **单次 actor 调用原子捕获**;录音随后逐条取(内存原因)。录音引用了 catalog 快照之外的 folder /
  speaker profile(含 voice sample 的 profile 链接)→ 归档内清除该引用 + 记 failure,
  **绝不产出 dangling 引用的"已验证归档"**(Recap.recordingIDs 例外:历史性引用,合法)。
  所有 store 读取 throwing(禁 `try?` 吞错):fetch 失败 = 归档失败,不允许"0 条录音的成功归档";
  逐条 fetch 的"抛错"与"行不存在"可区分(前者 failure 带错误文本,后者 = 导出期间被删)。
  `calendarAutoLinkState` 随档(`.userCleared` 是用户意图,丢了会让恢复后的录音重新进自动关联候选)。
- **staging 清扫安全**:`.owner` marker(写入进程 pid)**先于目录创建**写入,且 sweep 对新鲜的中间态
  (marker-only / 无 marker 目录)留 **15min 宽限期**——marker 先行仍有极短窗口可被第二实例的 sweep
  抢先(偷走 marker 后活目录变"无 marker"),宽限期把两个方向的竞态都堵死;只清超龄残留与
  pid 已死的确证残留(目录整体超龄 24h 兜底)。PID 重用的误判方向是"跳过"(泄漏保留到下次),
  永不误删活目录。
- **CI restore validator**(测试 target,非产品):`PortableArchiveValidator` 校验 manifest hash/size、无未登记
  文件(独立 enumerator 遍历,不复用 writer 代码防循环验证)、实体解码、计数、引用完整性;
  `ArchiveNormalizer` 从 store 侧与归档侧**各自独立**构建每录音关系图并比对;
  `PortableArchiveRestorer` + `StoreSnapshot` 把归档**真正重建**成 in-memory store 并做全字段快照比较
  ——归档 schema 少存任何用户字段即红(schema 完整性门禁;刻意排除清单见 `PortableArchiveSchema` 注释)。

- **关键文件**:`Cadenza/Services/Export/{ExportContentRenderer,ExportFileNaming,BatchFileExporter}.swift`、
  `Cadenza/Services/Export/PortableArchive/{PortableArchiveSchema,PortableArchiveWriter,PortableArchiveExporter}.swift`、
  `Cadenza/Services/Persistence/RecordingsStore+Archive.swift`、`Cadenza/Views/Settings/ExportBackupSection.swift`、
  `Cadenza/Views/Components/ExportSavePanel.swift`。
- **测试**:`CadenzaTests/Export/`(渲染快照、批量引擎、writer 原子性/确定性、round-trip + 防篡改)。

## 12.z1 Profile Registry 与 M1 存储迁移(Phase 1B)

设计 spec 同上 §4/§8/§9(§9.1 已按实施修订:backup API 取代三件套复制),模块目录
`Cadenza/Services/Profiles/`。Phase 1B 交付:**单 standard profile 承接全部现有数据 + M1 存储迁移**;
认证零触碰(token/`cadenza.session.user.json`/Keychain 不读不改不迁移),无多 profile、无切换 UI。

- **路径唯一出处 `ProfilePaths`**(注入 base;ephemeral 用 temp 唯一子目录):`profiles.json`、
  `Migration/{lock,journal.json,snapshots,staging}`、`Profiles/<id>/{Cadenza.store,ChatHistory,Backups}`、
  legacy 源位置(`Cadenza/Cadenza.store` 与跳版本的 `default.store`)。
- **Registry = commit point**:`ProfileRegistryDocument`(schema v1;`pendingBinding`/`pendingTransfer`
  显式 JSON null;日期一律 epoch 秒 Double)。`DiskProfileRegistry` 原子写(temp 0o600 + fsync +
  rename + fsync 父目录,INV-14);`InMemoryProfileRegistry` 供 ephemeral,同 coder 同版本门。
- **M1 六态状态机**(`M1StorageMigration`):`started → snapshotVerified → staged → targetVerified →
  registryCommitted → done`。一致性 = SQLite Online Backup API(`SQLiteBackupDriver` seam,
  NOFOLLOW + realpath 父目录——`resolvingSymlinksInPath` 不解析 `/var`,新版 SQLite 的 NOFOLLOW
  查全路径);freeze lease(`BEGIN IMMEDIATE`)贯穿窗口;`SourceEvidence`(base+wal 的
  inode/size/SHA-256,**不含瞬态 `-shm`**)commit 前与 retire 前复核。staged 变更全部先于
  targetVerified:ownership backfill(nil→`unknownLegacy`)+ §10.3 legacyAbsolute→relative 改写
  (词法可证明才改,单事务)+ ChatHistory copy+hash 校验(源目录保留)。**恢复分叉**:
  registry 写入前任意失败 → 源不动、boot 走 legacy + Settings 提示;写入后 → target 即 authority,
  绝不回退 legacy,retire 下次启动收敛(`resumeRetireAfterCommit` 只做 retire,绝不触碰已 place
  的 profile 目录;source 从白名单重新推导——journal 路径仅 hint,retire/重建 registry 前必须过
  `validateCommittedTarget`;跨启动决策用 `SQLiteLogicalDigest` 逻辑内容摘要,内容有变永久保留
  duplicate)。retire 协议:lease 持有中 `prepareForRetire`(checkpoint TRUNCATE + journal_mode=
  DELETE,base 成为单一自包含、只读可开文件;需独占,受阻 fail-safe)→ 摘要复核 → 关闭 SQLite
  lease(禁止移动本进程仍打开的 vnode)→ base 按已记录 generation 改名 → 校验 retired 内容摘要
  → 清理零内容 sidecar。
  registry 存在但不可读 → 仅可经可信 journal + 已验证 target 恢复,否则显式 halt。全部 IO 经
  `FileOperations` seam(ENOSPC 注入 + 路径审计)。
- **`ProfileBootstrap`**:任何 ModelContainer 打开前决定 boot 目标——registry presence 三态分类:
  present → 加载校验后 profile boot(+ 收敛未完成 retire + 音频根 mirror reconciliation +
  开容器前 `bootTargetProblem` 验证 store 可读,失败 halt);definite absent → 交给 M1,而 M1
  在动任何数据前先做 **commit-evidence 分类**:journal ≥ registryCommitted → 按状态要求验证
  target 后 durable 重建 registry(失败 halt);journal definite absent → **committed-residue
  探测**(Profiles/ 下任何条目、`Cadenza.store.migrated-*` / `default.store.migrated-*` 任一
  存在或不可探测 → halt),三重 definite absent 的 positive proof 才许 legacy/fresh;
  unprobeable registry / journal / Migration 目录 / 锁竞争一律 halt。**materialization 一次性
  边界**在 registry per-profile 字段 `storeMaterialized`(迁移 commit=true、fresh=false、
  容器首次创建后写数据前原子翻 true、save 失败 halt;仅显式 false 允许缺失 store 首次
  materialize)。**TestHost 结构性不可达**
  (CadenzaApp 只在非测试分支调用 + runLive precondition);TestHost 的 auth 面也是 in-memory
  (`EphemeralAuthSecretStore`/`EphemeralUserStore`,INV-8)。
- **音频根 authority(本 phase)**:UserDefaults(bookmark/path)仍是运行时唯一 operative source;
  registry.audioDirectory 是记录性镜像,每次启动 bootstrap 的 reconciliation 只回写 bookmark/path,
  **kind 保持不变**——目录 kind 只能由未来的显式 settings transition 改变;M1 初值一律
  `userSelected`(默认目录在用户 Documents 下、app 无法证明独占管理)。2B 翻转 authority。
- **`ProfileScopedDefaults`**:M1 commit 时把精确 key 清单(Markdown Mirror/Notion/Craft/AI 身份/
  UI 实体引用/Recap 调度 + `folderSort.` 前缀族)复制为 `<key>.profile.<id>`(spec §4.3 格式);
  只取显式设置值(persistentDomain,绝不带入 registered defaults);marker
  `defaultsMappingComplete.v1` 保证 commit 附近崩溃可由 bootstrap 幂等补齐;类型保持、
  全局键保留(回滚可用)、缺失不造默认值。**消费方读取仍走全局键(单 profile 语义等价),2B 收口**。
- **AudioFileOwnership(INV-18)**:`Recording.audioFileOwnership` 三态列,nil/未知值防御性读作
  `unknownLegacy`。写入规则:finalize → `appCreated`;import copy/transcode → `appCreated`;
  import reuse 与 orphan recovery → `unknownLegacy`;M1 backfill → `unknownLegacy`。CoW:
  `compressAudioIfNeeded` 按 ownership 分流,非 `appCreated` 原文件字节不动,压缩产物写入存储根 +
  `replaceAudioFile` 原子换引用。Portable Archive 携带 ownership(additive 可选字段,schema 仍 v1)。
- **测试**:`CadenzaTests/Profiles/`——registry/快照/journal 单测、M1 端到端与边界恢复、§9.3 失败
  矩阵(含逐 journal 边界中断、post-commit journal 失败保持 authority)、`MigrationStoreSnapshot`
  全图对比(独立字段清单,modulo 两类声明式归一化)、隔离三条 + auth 字面量源扫描;
  `CadenzaTests/Storage/AudioOwnershipTests`。

## 12.z2 Per-profile Session 与本地账户模型（Phase 2A+2B，单一发布）

设计 spec 同上 §5/§6/§7，模块目录 `Cadenza/Services/Profiles/` + `Cadenza/Services/Cadenza/`。
2A（session 核心/绑定事务/迁移）与 2B（Local/切换/UI）**同一发布不可拆**：启动管线与 UI 无任何
2A-only 的 feature/build flag（Profiles 源仅含 DEBUG 测试 seam），验收测试断言每条升级路径结束时
系统 Local 已确立。

- **启动顺序（§5.3，`ProfileBootstrap.runPipeline`）**：M1 存储迁移 → 绑定事务恢复 →
  M2（全局 session → 绑定 sole M1 profile；global user 记录是 re-entry beacon，最后删除）→
  M3（确立永久系统 Local：unbound M1 就地升格 / bound 旁建空 Local）→ ActiveProfileResolution
  （active 缺失/locked → durable 回落写 Local，写失败 halt）→ `ProfileBootContext`（含 resolved
  `profile` 快照）。此后才构造 `CadenzaAuthService`（仅 `bootstrapped(...)`/`ephemeral()` 两个
  工厂；bound 必须持 registry 句柄）、容器与 UI —— 不存在 ProfileContext 之前的任何认证读取。
- **Session 构成（INV-5/7）**：token 在 Keychain `cadenza.session.token.<profileID>.<originKey>`
  （originKey = 规范化 issuer origin 的 SHA-256 前 16 hex）；身份在 `Profiles/<id>/session-user.json`
  （原子写、严格 schema、绑定期携带 transactionID 所有权证据）；`issuerOrigin` 与 `apiBaseURL`
  分开保存。启动经 throwing 的 `loadSessionSnapshot` 分类（valid/expired/definite-absent；
  未知/损坏/撕裂 → halt）；运行时 token 单一内存源；bearer 构造唯一入口 `makeBearerRequest`
  校验目标 URL 被 issuer origin 覆盖（debug fatal / release 拒绝）。
- **三态 disposition（INV-3）**：`active`/`explicitlySignedOut`/`tokenInvalidated`（durable 过期
  记录，正确重登清除）。`active` + token 缺失/过期 = `.expired`（数据可见，绝不锁定）；只有显式
  sign out 依 `lockOnSignOut` 锁定（首次绑定即置 true）。sign out 保留 binding 与 session-user
  文件，仅清 credential（remove → expired-overwrite 链，全部失败显式 `sessionCleanupFailed`）。
- **绑定两阶段事务（§5.5/§6.5）**：A（pending 写入，含 tokenDigest/createdProfile/来源快照；
  创建型 profile 与 pending 同一原子写）→ B（token+session-user）→ B2（全量 recordings 打
  `awaitingHistoricalConsent` 标记，携带 transactionID）→ C（boundAccount+解锁+清 pending）。
  每步 classified：save 抛错后按字节指纹重读证明 committed/old/third-shape；恢复按所有权证据
  完成或回滚，foreign artifact 一律 halt 零删除。phase A 内证明运行时来源权威（source 快照：
  active ID/kind/未锁/byte-exact bound 元组；迁移模式为 nil）。
- **身份判等**：服务端 userID 是不透明字节串——所有身份/所有权比较走 `AccountIdentity.matches`
  （UTF-8 字节判等，杜绝 NFC/NFD 规范等价串联）；registry 唯一性用 byteKey；派生存储键
  （syncKey/偏好键）经 `keyComponent`（安全 ASCII 原样保兼容，其余 `u8x:`+hex 转义）。
- **切换（§7，仅 relaunch）**：INV-13 守卫 → `prepareProfileTransition`（phase `preparing`：
  WebSync `stopAndWait` + MCP 连接 drain，有界；失败 resume 且零 commit）→ post-drain 单同步跨度
  内 fresh 复证（来源权威 + 目标完整冻结元组）→ 才写目标 artifact → classified active commit →
  phase `relaunching`（证明新实例启动后才退出；启动失败仅 proven rollback 回 idle，否则 halt）。
  **halt vs resume 分类**：registry 不可读 / 来源 slot 失守 / pending 出现 = 权威未知或易主 →
  halt（绝不 resume 与新 owner 相争）；来源已证明仍属本进程后的目标不符 / artifact 写失败 =
  安全拒绝 → resume。解锁走 target-scoped `beginUnlock`（按目标行冻结 backend 授权，错账号零写入）。
- **偏好与音频根权威**：profile-scoped 偏好经 `ActiveProfileDefaults`（unresolved fail-closed、
  一次性激活、TestHost ephemeral）；音频根经 registry `audioDirectory` + `ProfileRootAuthority`
  （per-profile UUID 默认根、ownership-conditioned bookmark 刷新、registry-present boot 绝不读
  全局键）。三个运行时 registry writer（音频根/disposition/lockOnSignOut）全部 classified +
  fresh 权威复证；音频根 indeterminate 直接 poison `StorageMigrationGate`（terminal，重启前
  拒录音/迁移）。
- **历史同步 consent（INV-15）**：三态（undecided/textOnly/withAudio）per-profile scoped；
  标记行在 consent 前零上传（唯一上传路径 WebSyncCoordinator.run 过滤）；音频上传开关独立且
  default-off，任何登录/迁移/consent 路径不得代开。M2 映射旧 disclosure：absent audio 偏好
  fail-closed 到 textOnly。
- **归档 chat 目录权威**：`archiveExporter.makeSource` 严格随 boot 模式——profile 用
  `profileBootContext.chatHistoryDirectory`，legacyFallback 用 legacy 目录，halted/无 context
  省略 chat；profile 模式下绝不读取全局 chat 路径。
- **测试**：`CadenzaTests/Profiles/`（session 核心/绑定事务与恢复/M2/M3/管线 e2e/切换与登录/
  scoped 偏好与音频根/隔离封印）、`CadenzaTests/Services/CadenzaAuthServiceTests`（boot 分类/
  重登矩阵/disposition 权威）、WebSync consent 矩阵与字节身份、`AppStateSignOutTests`、
  `AppStateArchiveSourceTests`、spec §13 隔离回归（list/search/MCP/Mirror/Archive 真实生产面）。

## 12.z3 Local → Account Whole-store Transfer（Phase 3）

- **专用启动模式**：`pendingTransfer` 在任何正常 `ModelContainer`/service 构造前进入
  `ProfileTransferExecutor`；每一步 fresh reload registry、逐字节复证旧 checkpoint，再以
  classified save 推进。完成后重新跑完整 bootstrap，失败则 halt，绝不打开中间态 store。
- **证据链**：SQLite online backup 产出唯一 snapshot artifact；source trio evidence、逻辑
  digest、post-rewrite target digest+SHA、move replacement digest+SHA、全量音频树 manifest
  分层持久化。snapshot work copy 在任何改写前必须与冻结 source 的逻辑摘要一致，不能用一份
  被同步篡改的 receipt 重新背书。manifest 的源路径每次从 snapshot 行和冻结 profile root
  重新推导；userSelected root 始终由 security-scoped bookmark 授权且必须与冻结路径逐字节一致，
  registry payload 只作证据，不作路径 authority。
- **placement ownership**：profile store 与 audio root 各有独立、版本化、带 transactionID+
  claim token+role 的 marker；缺失、foreign、malformed、unprobeable 都分类处理。目标不存在时
  `RENAME_EXCL` 放置；目标已存在但全实体为空时用同步关闭的 raw SQLite 计数复证，checkpoint
  成单文件后与 staged store 做同卷 `RENAME_SWAP`。swap 后旧空库仍须再次证明为空，跨窗口写入
  会阻止 commit；已存在的 placed store 必须带原 `profileStore` role claim，内容相同不能补领。
  第一次 audio claim 前 transaction namespace 必须确定不存在；非空目标始终零覆盖。
- **move**：先生成并验证全新空 Local replacement；源在 lease 下 checkpoint+逻辑摘要复核，
  随后关闭 SQLite lease，再做原子 swap，避免移动本进程仍打开的 vnode。swapped-out 源的摘要
  复核通过后才退役；canonical Local 再以 raw SQLite 全实体零计数验证。音频只清理 snapshot
  记录为 `appCreated` 且当前 hash 仍匹配的文件，删除走系统 Trash；同一路径只要存在任一
  `userOwned`/`unknownLegacy` 引用就整体保留，避免共享引用被另一行的所有权误删。
- **恢复与测试**：snapshot/stage/verify/place/rebuild/retire/commit 每个 checkpoint 可重入；raw
  staged/replacement 只有在证明 `-wal/-shm` 不存在后才推进 checkpoint，失败重试会先清理该
  transaction 自有 trio。音频先复制到 transaction-owned partial，校验 size+hash 后再
  `RENAME_EXCL`，kill-9 不会把半文件伪装成最终产物。Migration 根及嵌套 scratch 路径禁止
  symlink；打开过的 SwiftData scratch 在本进程只保留，下一进程才 sweep。
  `ProfileTransferExecutorTests` 覆盖 copy/move、空目标 swap、marker claim、manifest lattice、
  audio tree、kill-window、scratch 生命周期和 final seal；M1/transfer rename 路径同时检查无
  SQLite vnode API violation。
- **发起与 consent**：transfer 只能从登录绑定流的独立 transfer-choice 步发起（keep
  separate / copy / move；move 需二次确认）。consent 在 durable 意图确立后才写入；staged
  rewrite 给每一迁移行盖 `awaitingHistoricalConsentBindingID`（取自目标 profile 冻结证据的
  创建绑定事务 ID），staged verification 逐行校验，WebSync 在 consent 允许历史同步前对
  这些行零上传。中断的 setup 由 registry durable 事实复活（!storeMaterialized + 创建
  事务 provenance + 与本次授权的完整四元组字节匹配），一次性 transfer 资格不因重登录
  而消耗；begin 失败按 notCommitted（停留可重试）/ indeterminate（halt）分类。durable
  pendingTransfer 写入后 relaunch 走专用路径（`performTransferRelaunch`）：spawn 失败
  只能 halt 本会话、保留 pendingTransfer、绝不做 switch 式 rollback（activeProfileID
  本就未动，rollback 是 no-op）也绝不 resume 源 WebSync/MCP——下一次启动的 authority
  属于 transfer 执行器。
- **halt shell**：`AppBootSequence` 在构造任何 AppState/service 之前解析 boot
  disposition（TestHost 分支不触 live bootstrap）；transfer 完成后重新 bootstrap，
  且唯一合法后继是 **transferred target profile 本身**（mode 与 context 行双重比对）——
  解析成其它 profile、legacyFallback、nil 或残留 transfer 模式一律 halt；
  halted 则进入零服务 halt 窗口——scene 强制 presented（login-item suppression 只属
  正常启动）、activation policy 强制 `.regular`、AppDelegate 生命周期在语言写入/
  defaults 注册/迁移/图标/睡眠 observer 之前早退、custom commands 不注册、关窗即
  退出进程。halt 面只承诺本会话不再有进一步更改——halt 前的 bootstrap/transfer
  可能已留下可恢复的 durable 进度。
- **多账号呈现**：`AccountIdentityPresenter` 从冻结 `BoundAccount` 派生展示身份
  （email → displayName → 本地化占位符）与 backend 标签：官方 origin（代码常量比较，
  不读可变配置）→ 品牌名；有效 self-host → 完整 canonical origin（scheme + 显式端口，
  http/https 同 host 不坍缩，IPv6 无歧义）；畸形冻结值原样展示不猜测。当前卡与所有
  bound 行（含锁定）展示 `identity · backend`。All Profiles 卡对 bound active profile
  提供 add-or-switch 入口；授权结果与 active profile 绑定账号**四元组逐字节一致**时
  不给 switch-and-restart——丢弃预决策授权、显示 already-active、零 registry/session
  写；四元组任何漂移（如同 origin 不同 API path）拒绝而非宣称未变。

## 12.z4 Entitlements 契约（Phase 4）

- 客户端契约类型在 `Cadenza/Services/WebSync/EntitlementsContract.swift`：
  `GET /me/entitlements` 的版本化响应解码（未知字段/枚举值容忍原文保留；
  显式版本 <1、负值度量、空 plan、versioned-v1 缺必备字段一律判 malformed）、
  分类结果 `EntitlementsResolution`——`classify(status:body:service:)` 必须
  携带调用方自证的 service 分类：**只有 self-host origin 的 404 才是全功能
  开放**，官方 origin 的 404 是 unavailable（故障形态，绝不授予任何权益）；
  更新版本/malformed → unsupported（保持 last-known 状态不猜测）；其余 →
  unavailable 重试。拒绝码分类 `EntitlementRejection` 优先 canonical `code`
  键、回退 legacy `error` 别名（append-only，未知码保留原文）。协议正文
  （错误 envelope 过渡、生效性/生命周期字段分族、text 配额单位与周期边界、
  storage reserved 并发口径、幂等、rollout gating、未决商业数值）见
  `docs/entitlements-contract.md`，与 cadenzapp-web 仓库同文同步维护。
  enforcement 全在服务端（INV-12），客户端只据此做 UI；契约层独立于 UI
  与支付集成存在，服务端 endpoint 随 schema-backed grants/usage 一起挂载。

## 12.z5 DebugDataRoot（数据平面重定位，DEBUG-only）

`Cadenza/Utilities/DebugDataRoot.swift`。设 `CADENZA_DATA_ROOT=<绝对路径>` 让整个数据平面
落到一个临时根下（registry / stores / backups / ChatHistory / 音频），用于拿 fixture 数据跑
第二个实例（文档截图、手动走查）。未设置以及 release 构建下，所有路径解析与该类型不存在时
完全一致（启动时读一次——数据平面在任何 store 打开前就已定型）。

**为什么必须是单一入口**：数据平面有多个解析点（`ProfilePaths.live()`、`StorageLocationManager`、
`DatabaseBackup`、`ChatHistoryManager`、`RecordingsStore` 的 legacy container、
`ProfileAudioRootWriter.appManagedDefaultPath`）。**只重定位一部分比完全不重定位更危险**：
读 fixture store 却解析到真实音频根的实例，会用 `OrphanAudioRecovery` 扫描并导入用户的
真实录音目录（2026-08-06 实测踩到）。门禁 `DebugDataRootTests.userDataPathsRouteThroughTheSeam`
扫源码禁止绕过（豁免仅 `DebugDataRoot` 自身、`StorageLocationManager.defaultDirectory` 的
非重定位分支、`WhisperModelManager` 的只读模型缓存）。

三条硬性约束：
1. **全局 bookmark 绝不继承**：`recordingsDirectoryBookmark` 与 profile 的 `userSelected` kind
   都描述真实库的目录；`ProfileBootstrap.operativeAudioDirectoryState()` 在重定位下返回
   `bookmark: nil` + `.appManaged`，`resolveRecordingsDirectory()` 直接跳过全局 bookmark 分支。
2. **越界即拒**：`profileRootState` 的 authority 路径若不在重定位根内（词法包含判定，与存储层
   其余部分同一身份规则），回落到重定位的默认目录并记日志——registry 万一携带外部路径也不会
   把实例指回真实录音。
3. **HOME 环境变量不是隔离手段**：macOS 的 `FileManager.urls(for:in:)` 走 getpwuid，
   `HOME=...` 对 Application Support / Documents 的解析完全无效（实测）。

配套 fixture：`CadenzaTests/DemoSeedTests.swift`，仅当 `CADENZA_DEMO_SEED_STORE` 指向真实库
之外的 store 时才写入，否则空跑。

## 13. 当前架构优势

- 单进程去掉了 XPC 带来的控制路径延迟和复杂度
- Stop 设计成“两阶段”，让 UI 响应和 I/O 重活分离
- segment + manifest 让 app 具备真实的 crash recovery 能力
- DTO 边界把 SwiftData model 与视图层隔开了
- 自动后处理和手动重试有明确互斥
- 权限敏感区域大多有显式 gate

## 14. 当前已知问题、瓶颈与高风险区

> 来源：2026-03-10 code review，经人工筛选确认。
> 分为三类：**Confirmed issue**（代码证据充分，可直接修）、**Needs profiling**（结论合理但需 Instruments 验证）、**Architecture tradeoff**（设计层面取舍，不是 bug）。

### 14.1 Confirmed issue（已全部修复 2026-03-10）

#### ~~[P1] 后处理转录工作卡在 MainActor 上~~ ✅ Fixed

~~PostProcessingCoordinator 用 Task.detached 替代 withCancellableLocalTask；TranscriptionManager.transcribeFile() 在 MainActor 解析 model 后调 nonisolated static runTranscription() 执行重活。~~

#### ~~[P1] Merge 流程忽略 `AVAssetWriterInput.append()` 返回值~~ ✅ Fixed

~~AudioSegmentMerger.streamSegment() 现在检查 append 返回值，失败时抛 MergeError.exportFailed。~~

#### ~~[P1] Gemini 文件转录无分块~~ ✅ Fixed

~~GeminiTranscriber 重写：>10min 或 >15MB 自动分 10 分钟 chunk，3 并发 AsyncSemaphore，chunk 导出 16kHz mono AAC 32kbps，指数退避重试。~~

#### ~~[P2] Merge `finishWriting()` 无超时保护~~ ✅ Fixed

~~AudioSegmentMerger.merge() 用 ContinuousClock 计时 finishWriting()，>30s 输出警告日志。~~

#### ~~[P2] `fetchRecordingDetail()` 不是纯读~~ ✅ Fixed

~~新增 RecordingsStore.fetchRecordingDuration() 只读方法，PostProcessingCoordinator 改用它获取 duration。~~

#### ~~[P2] Detail reload 重置播放器~~ ✅ Fixed

~~RecordingDetailView.loadDetail() 比较 previousAudioPath，路径不变时跳过 audioPlayer.load()。~~

#### ~~[P2] Writer 失败后上层不知道正在丢音频~~ ✅ Fixed

~~AudioFileWriter 新增 onWriterFailure 回调，writer 进入 failed 状态时触发一次。~~

### 14.2 ~~Needs profiling~~ ✅ All resolved

#### ~~录音热路径格式转换与 Data 分配~~ ✅ Mitigated

~~`AudioConverter` 已有 buffer pool（`cachedInputBuffer`/`cachedOutputBuffer`），steady state 零 AVAudioPCMBuffer 分配。剩余的 `pcmBufferToData()` Data copy（~960 bytes/call at 24kHz mono Int16）是必要的，因底层 buffer 被复用，调用方需要独立副本。~~

#### ~~`SystemAudioProcessQuery.readBundleID()` 的 CFString 桥接~~ ✅ Fixed

~~改用 `Unmanaged<CFString>.takeRetainedValue()` 正确接收 CoreAudio 返回的 +1 retained CFStringRef，消除每次 poll 的内存泄漏。~~

#### ~~`SystemAudioStateListener.stopListening()` listener 生命周期~~ ✅ Fixed

~~存储所有 listener block 引用，`stopListening()` 和 `deinit` 中用 `AudioObjectRemovePropertyListenerBlock` 显式移除，不再依赖 weak self 兜底。~~

### 14.3 Architecture tradeoff

#### ~~后处理全局串行队列~~ ✅ Resolved (Phase 2A)

~~已改为并发池：transcription=2, summary=1。per-job 状态追踪 + continuation-based semaphore。UI 用 computed properties 向后兼容。~~

#### 数据库搜索是内存全量扫描

`fetchRecordingDTOs()` 和 `searchRecordingDTOs()` 对标题/标签/转录文本/摘要做内存扫描。小到中等规模（<1000 录音）够用，大规模需要 FTS 索引。

#### Backup restore 仍缺少产品入口

Snapshot 已使用 SQLite online backup API、唯一 staging、原子发布和三份 rotation；
剩余产品缺口是没有 in-app database restore，也没有 portable-archive importer。

## 15. 下一步性能优化路线图

### 15.1 目标

接下来的性能优化不再以单点 micro-opt 为主，而是以三个目标排序：

1. 缩短用户从 Stop 到看到 summary 的首屏等待时间
2. 提高多录音积压时的后处理吞吐
3. 降低 detail load / 搜索 / 录音热路径的结构性浪费

### 15.2 Phase 1：一周内可落地的收益项（已完成 2026-03-10）

#### ~~合并 summary 落库写入~~ ✅ Done

`meetingType` 已合并进 `saveSummary(...)` 的 `meetingType:` 参数，单次写入完成 summary + meetingType 持久化。不再需要 `updateMeetingType()`。

同时，meetingType 分类已从独立 API 调用合并到 summary prompt 的 inline 分类（省去 2-5s API 延迟）。

#### ~~增加只读 detail fetch~~ ✅ Done

`fetchRecordingDetail(recordingID:)` 改为纯只读。新增 `markAccessed(recordingID:)` 方法，只在 `RecordingDetailView.onAppear` 调用一次。

#### ~~chapters 改成按需生成~~ ✅ Done

chapters 不再随 summary 自动生成。改为用户打开 detail 页时，`generateChaptersIfNeeded(recordingID:)` 检查是否有 summary 但没 chapters，按需触发。省去了用户从未查看的录音的 chapters API 调用。

### 15.3 Phase 2：吞吐与体感重构

#### ~~后处理从全局串行改成小并发流水线~~ ✅ Done (Phase 2A)

`isPostProcessing + pendingQueue` 已替换为并发池：

- transcription pool: 2, summary pool: 1
- continuation-based semaphore 限流
- per-job TranscriptionManager / SummaryGenerator 实例
- detached task handle 存储用于取消传播
- computed properties 向后兼容 UI
- detail 页使用 per-recording `isProcessing(recordingID:)` 判断 busy

#### ~~summary 改成 quick / full 两阶段~~ ✅ Done (Phase 2C)

已实现两阶段 summary（single-prompt path only）：

- Quick phase: title/overview/key_points/action_items/tags/meeting_type
- Enrich phase: decisions/follow_ups（后台运行，UI 显示 spinner）
- 全部完成后一次性写库
- Enrich 失败时 graceful fallback（只保留 quick 结果）
- Map-reduce path 不变（已经输出完整 JSON）
- 新增 10 个测试（TwoStagePromptTests + TwoStageParsingTests）

#### ~~长 transcript 改成 map-reduce~~ ✅ Done (Phase 2B)

已实现自动 map-reduce：

- 阈值：40,000 chars，chunk 大小 ~15K chars
- `SummaryPrompt.splitForMapReduce` 按段落/句子边界切分
- Map: `withThrowingTaskGroup` 并行 `streamChat`，纯文本输出
- Reduce: 流式 `streamChat` + `reduceSystem` prompt → 标准 JSON
- Fallback: map 失败时自动回退 single-prompt
- 新增 8 个测试（SplitForMapReduceTests + MapReducePromptTests）

### 15.4 Phase 3：库规模与录音稳定性

#### 搜索与排序引入索引层

当前 `fetchRecordingDTOs()` 和 `searchRecordingDTOs()` 仍然依赖内存排序和全量文本扫描。

中长期建议：

- 标题 / 日期 / 最近访问排序尽量下推到 fetch 层
- transcript / summary 搜索改成 SQLite FTS sidecar 或专门索引表

这是本地库规模上来之后最先会被用户感知到的瓶颈。

#### ~~录音热路径减少内存分配~~ ✅ Done (Phase 3B — buffer pool)

`AudioConverter.convert()` 新增 AVAudioPCMBuffer 池化：

- `cachedInputBuffer` / `cachedOutputBuffer`：按 format + frameCapacity 复用
- `bufferLock: NSLock` 保护并发安全
- 稳态下（format 不变、frame count 稳定）：**零 buffer 分配**
- 消除 ~40 次/秒 AVAudioPCMBuffer 堆分配（录 1.5h ≈ 216K 次）
- `pcmBufferToData()` 的 Data 分配保留（被下游 transcription queue 持有，无法复用）
- 已有的 AVAudioConverter cache 和 mic format description cache 不变

### 15.5 推荐落地顺序

推荐按下面顺序推进：

1. ~~只读 detail fetch~~ ✅
2. ~~合并 summary 同步写库~~ ✅
3. ~~chapters 按需生成~~ ✅
4. ~~后处理小并发池~~ ✅
5. quick / full summary 两阶段（Phase 2C — 条件性评估）
6. 长 transcript map-reduce
7. 搜索 / 索引层
8. 录音热路径 buffer pool

### 15.6 性能之外，这个 app 下一步还能做什么

如果不只盯着“更快出 summary”，而是看当前代码里已经长出来的能力，这个 app 下一步最自然的方向有 5 条。

#### 方向 A：把全局 AI 从“拼 prompt”升级成“上下文引擎”

现状：

- folder 级 AI 已经有 `fetchFolderContext()` + `ProjectMemoryService`
- 全局 AI 还在 `AIChatView` 里直接拉 detail DTO 再拼文本

下一步应该做的不是继续调 prompt，而是补一个统一的 `LibraryContextService` / `AIContextAssembler`：

- 输入：用户问题、时间范围、folder/tag/filter、token 预算
- 检索源：recording summary、transcript excerpt、weekly/monthly recap、open action items、recent decisions、known speakers
- 输出：结构化 context packet，再交给 chat service

这样做的收益：

- 全局 AI 和 folder AI 终于走同一条架构路径
- 以后加 FTS / embeddings / rules-based retrieval 时，不用重写 UI
- “问整个资料库”会从 demo 功能变成可持续迭代的核心能力

#### 方向 B：把 Folder 从“分类容器”升级成“工作流 / 项目记忆”

现状里 folder 已经不只是文件夹：

- 有 `status`
- 能聚合 recordings / action items / decisions / follow-ups
- 有 AI brief tab

这说明它天然适合继续长成工作流对象。最值得补的不是更多字段，而是 3 个能力：

- folder brief 持久化，而不是每次现算
- folder 级 open loops：未完成 action items、未关闭 follow-ups、最近 blockers
- folder 级时间视角：本周发生了什么、下周要推进什么、最近一次 meeting 之后有哪些变化

一旦这层成立，Cadenza 就不只是“会议录音器”，而会开始接近“本地优先的工作记忆工具”。

#### 方向 C：把 Speaker Mapping 继续做成 People Layer

现在已经有：

- diarized transcript
- `SpeakerProfile`
- `speakerMappings`
- folder context 里的 `knownSpeakers`

下一步可以把“谁说过什么”做成一等能力：

- 跨录音复用 speaker identity
- 人名维度的 action items / decisions 聚合
- AI 能回答“某人最近负责了什么”“某个问题是谁先提的”

这条线的价值在于，它直接把 transcript 从“文本”升级成“带人物关系的会议记忆”。

#### 方向 D：补一个用户可见的 Processing Center / Recovery Center

现在后处理能力已经很强：

- 并发池
- crash recovery
- interrupted / unprocessed recovery
- manual retry / cancel

但这些大多还停留在内部状态机里。下一步最应该补的是一个显式的“后台处理中心”：

- 当前队列里有哪些录音，卡在哪个 phase
- 失败原因是 provider / quota / parse / save / permission 哪一类
- 可以单条 retry、改 provider、改语言、跳过 summary、只导出 transcript
- 所选转录 provider、配置失败原因和 retry 操作对用户可见；provider 不会被后台静默替换

这会显著提高 app 的可信度，因为用户终于能理解“它现在在干什么”。

#### 方向 E：补索引层，让 Search / AI / Recap 共用同一套检索基础设施

当前的瓶颈已经很明确：

- 搜索是内存全量扫描
- 全局 AI 是 N 次 detail fetch + prompt 拼接
- recap 是按固定周期聚合，不是按查询动态复用

下一步值得做一个轻量索引层，哪怕先不上 embeddings，也至少要有：

- 标题 / tags / summary / transcript / decisions / follow-ups / action items 的统一文本索引
- 按录音、folder、时间窗口、speaker 的过滤能力
- 可供 Search、AI、Recap 共用的检索 API

这会是库规模继续上升后的分水岭。

### 15.7 如果只做三件事，优先级应该是这样

1. 统一 AI context layer
   原因：它同时改善 AI Assistant、folder AI、未来 recap 和搜索联动，是复用价值最高的一层。
2. 做 Processing Center
   原因：这会直接改善用户体感和信任感，也能把现有恢复/重试能力真正产品化。
3. 做索引层
   原因：这是大规模资料库、全局 AI 和高级检索继续往前走的基础。

People layer 和 folder 工作流记忆都值得做，但更适合作为上面三层站稳之后的扩展，而不是先把更多对象堆进 schema。

## 16. 改功能前的检查清单

每次上新功能，至少把下面 10 个问题过一遍：

1. 新行为的 source of truth 是谁？
2. toolbar / overlay / detail / list / alert 中，哪些用户可见状态要同步改？
3. 是否影响 start / pause / stop / merge / crash recovery？
4. 是否影响自动后处理、手动 retry、discard 或 queue 行为？
5. 是否新增了 schema 字段、DTO 字段、迁移说明、恢复逻辑？
6. 是否引入了权限敏感 API，并且它是否用户主动触发、是否有 gate？
7. 是否要调整 `recordingsChangedToken`、`projectsChangedToken`、`postProcessingCompletedToken`、`recordingDiscardedReason` 的触发？
8. 是否会让 `RecordingDetailView.loadDetail()` 的触发频率或副作用变得更糟？
9. 是否会影响 search、sort、AI context、project context 的复杂度？
10. 是否需要更新测试和本文件？

## 17. 验证基线

当前项目约定基线：

- 284 tests
- 25 suites
- 测试框架是 Swift Testing，不是 XCTest

常用命令：

```bash
xcodebuild build -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=macOS'

xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

改动影响面较小时，至少跑对应子集：

- persistence：`CadenzaTests/Persistence/*`
- post-processing：`CadenzaTests/PostProcessing/*`
- meeting detection：`CadenzaTests/Meeting/*`
- audio writer / merge：`CadenzaTests/Utilities/AudioFileWriterTests.swift`

## 18. 维护规则

以后只维护仓库根目录的 [ARCHITECTURE.md](ARCHITECTURE.md)。

如果功能改动影响了下面任一项，就必须同 PR 一起更新：

- 模块职责
- 生命周期顺序
- 状态归属
- 用户可见状态
- 持久化形态
- 恢复策略
- 性能特征
- 已知风险面

最低要求：

- 改对应章节
- 更新 `Last updated`
- 增删不再准确的 checklist / risk item

如果功能已经是跨模块的，就给它新开一个章节，不要把关键决策只留在某个 plan 文档里。
