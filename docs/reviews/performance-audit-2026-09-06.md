# Cadenza 性能审查（合并版），2026-09-06

本文合并两份独立审查。审查基线均为 `5f5fb685b241dbc399f02c9b20b5139282d35d32` 加当前工作区未提交改动。二稿吸收了 C 对 K 报告的复核意见，三稿再吸收 C 对二稿修法行为边界的复核，涉及 D1、M2、M3、M4、T2、T4、T8、U8 与验收矩阵，处理记录见第 6 节。

| 来源标记 | 审查线 | 证据来源 |
| --- | --- | --- |
| C | 调用链推导线 | 代码调用链推导，隔离合成数据探针；后续用只读统计与查询计划复核了真实库。未检查已安装 App。 |
| K | 实测核对线 | 代码逐行核对，真实数据库只读统计，已安装二进制字符串检查，运行进程内存画像。 |
| C+K | 两者独立得出 | 同上 |

两次审查都只新增报告，未修改产品代码，未替换 App。K 的一次只读查询曾把真实转录文本打进本会话的工具输出文件，已删除，报告未引用其内容；第 7 节记录了避免方式。

**结论：目前证据最充分、应优先处理的是数据层和一批"什么都没变却在反复刷新"的路径。** 转录引擎与 Liquid Glass 是否构成主要开销，尚无端到端测量支持，见第 5 节验收矩阵。证据最充分的一条是三环叠加的链：web 同步每分钟无条件写库，SwiftData 持久化历史从不清理，启动时的全表 SHA256 探针又恰好要哈希这堆历史。修复这条链不需要牺牲任何功能。

**产品红线**：不能用禁止新录音、取消说话人功能、移除 glass effect、缩短实时队列丢语音、降低模型精度来换取性能。当前集合已使用 lazy 容器，卡片层没有独立 glass，继续只优化卡片布局解决不了随库规模增长的数据库和后台工作；铬层 glass 悬在滚动内容之上的合成成本仍未测量，不能因卡片无 glass 就排除。

## 0. 证据等级

- "已确认"指调用链、复杂度或 SwiftUI 失效依赖由当前代码逐行确认，不等于已测出真实用户的卡顿时长。失效依赖可以静态确认，实际重算次数、耗时和掉帧仍需 SwiftUI Instruments 验证。
- "实测"仅限第 1 节列出的数据：K 的真实库统计与进程画像，C 的隔离探针。没有运行真实 App 的 Instruments、GPU trace 或 SQL 语句计数，因此不报告 FPS、首屏延迟或转录 RTF。
- P0 为已在真实机器上造成持续代价的结构性问题，P1 为随库规模增长的结构性瓶颈，P2 为浪费或调度问题。

## 1. 实测基线

### 1.1 真实库与进程，来源 K

| 项目 | 数值 |
| --- | --- |
| 录音数 / 转录数 / 摘要数 | 397 / 396 / 370 |
| 数据库文件 | 293 MB |
| 其中真实数据表 | 21 MB，转录 17 MB，摘要 1.8 MB |
| 其中持久化历史表与索引 | 272 MB，ATRANSACTION 61 MB，ACHANGE 50 MB，索引 7 个 |
| 历史事务数 | 179 万笔，53 天累积 |
| 历史写入速率 | 每小时 464 笔，全天恒定，99.8% 为 WebSyncRecord 更新 |
| 自动备份目录 | 826 MB，3 份，每份约 275 MB |
| quick_check 耗时 | 0.49 s |
| 单表全行扫描，不含哈希 | ATRANSACTION 0.72 s，ACHANGE 0.80 s |
| 已安装二进制中 quick_check 字符串 | 0 处，SQLiteLogicalDigest 2 处 |
| 运行 6 天后物理占用 / 峰值 | 381 MB / 1.46 GB |

取证命令均为只读，见第 7 节。

### 1.2 合成数据探针，来源 C

环境为本机 Apple Swift 6.4、Swift 6 语言模式、`-O`。数据为虚构内容，数据库刚创建，未清理 OS cache，样本量 3 次，不报告 P95。编译时直接使用仓库的 `SQLiteLogicalDigest.swift`。前三组每条一个 20KB 正文和约 59.5KB BLOB，第四组为 1000 录音加 300,000 条规范化 segment 行。均不是 Cadenza 的真实 schema。

| 合成数据 | 文件大小 | 单次 logical digest 中位数 | 单次 quick_check 中位数 |
| --- | ---: | ---: | ---: |
| 100 录音，BLOB 形态 | 8.34 MB | 5.87 ms | 2.66 ms |
| 1000 录音，BLOB 形态 | 83.31 MB | 37.70 ms | 12.01 ms |
| 5000 录音，BLOB 形态 | 416.51 MB | 188.04 ms | 57.27 ms |
| 1000 录音 + 300,000 segments | 61.56 MB | 372.56 ms | 26.37 ms |

行数比字节数更能放大 digest 的逐列哈希成本。这与 1.1 的真实数据互相印证：真实库里恰好有 179 万行历史小行，所以启动探针在真实机器上哈希的主要就是历史表。

其他探针：直接编译生产 `RecordingProcessingGate`，先 claimProcessing 再 claimRecording 均成功；直接编译生产 `AIGenerationGate`，3 个并发模拟任务峰值执行数为 1；SwiftData 最小模型验证 MainActor 创建的 ModelActor 查询仍在非主线程执行，因此"MainActor 创建 store 必然导致 SQL 在主线程"不列为发现。

## 2. 发现

### 2.1 数据层与启动

**D1 · P0 · web 同步每分钟无条件写库。** 来源 K。
[WebSyncCoordinator.swift:747](../../Cadenza/Services/WebSync/WebSyncCoordinator.swift#L747) 的 `syncedAudioProbeBudgetPerPass = 8`，`run()` 每 60 秒对 8 条已同步行做 audio probe。探测本身只是 stat，便宜。但结果不变也走 [RecordingsStore.swift:3172](../../Cadenza/Services/Persistence/RecordingsStore.swift#L3172) 的 `markWebSyncAudioProbe`，写 lastAttemptAt 并 save，一趟最多 8 笔独立事务，集中在同一趟内发生，历史表按天统计约 11,000 笔由此产生。是否每笔都 fsync 取决于 synchronous 设置，未测。[save():3488](../../Cadenza/Services/Persistence/RecordingsStore.swift#L3488) 开头 `detailCache.removeAll()`，因此每趟都会清空详情缓存。
注意：`lastAttemptAt` 同时承担调度语义，[audioProbeCandidateIDs:750](../../Cadenza/Services/WebSync/WebSyncCoordinator.swift#L750) 按它最旧优先排序并配合 15 分钟间隔，单纯不更新会让同一批 8 条每分钟反复被选中。
建议：把探测调度状态从内容变更通道分离。可选做法：调度时间戳放内存或独立轻量 sidecar；或仍持久化但一趟 8 条合成一笔事务，并像 `markAccessed` 那样绕开 `detailCache.removeAll()` 与镜像通知。保留 probe 语义、15 分钟间隔与最旧优先顺序。

**D2 · P0 · 持久化历史从不清理，备份跟着膨胀。** 来源 K。
代码库没有任何 deleteHistory 或 NSPersistentHistory 调用。历史约每天涨 5 MB，3 份自动备份全是膨胀副本。auto_vacuum 为 2，清完历史还要 incremental_vacuum 才缩文件。
建议：启动或定期用 `ModelContext.deleteHistory(HistoryDescriptor)` 清早于 N 天的历史，随后缩文件。保留备份策略与恢复点顺序。

**D3 · P0 · 启动在界面装配前同步扫描整个数据库，修复未上线。** 来源 C+K。
[ProfileBootstrap.swift:577](../../Cadenza/Services/Profiles/ProfileBootstrap.swift#L577) 在 `bootTargetProblem` 调用 `SQLiteLogicalDigest.digest` 且丢弃结果。已有 profile 路径在 [:341](../../Cadenza/Services/Profiles/ProfileBootstrap.swift#L341) 与 [:256](../../Cadenza/Services/Profiles/ProfileBootstrap.swift#L256) 各检查一次，`runPipeline` 为 MainActor 同步方法，在 `applicationWillFinishLaunching` 阶段执行。MCP 虽然在 `AppState.setup()` 开头启动，也要等 bootstrap 完成。
K 补充：`fix/boot-store-probe` 分支 2 个提交，2026-08-17，`git merge-base --is-ancestor` 为 NOT-MERGED；`/Applications/Cadenza.app` 二进制里查不到 quick_check，即已安装版本处于回归态。共享记忆库中"已部署"的记录已更正。
C 告诫：`quick_check` 也扫描数据库，且不验证 UNIQUE 与索引一致性，不能视为 digest 的完全等价。K 判断：digest 按 rowid 扫表同样从不读索引页，两者在索引一致性上都是零覆盖，quick_check 至少检查了索引页结构完整性，所以替换不会更弱；索引一致性需要另加低频 integrity_check。迁移、转移、retire 中真正比较值的 digest 必须保留。
建议：复核该分支的补丁，适配当前 master 并通过测试后再部署，不直接合并；仅作健康检查的调用改为轻量探针，允许先显示不接入数据服务的启动界面。

**D4 · P1 · 列表 lazy 了，列表数据仍是全量读取。** 来源 C+K。
[fetchRecordingDTOs:466](../../Cadenza/Services/Persistence/RecordingsStore.swift#L466) 无 limit；[recordingToDTO:3634](../../Cadenza/Services/Persistence/RecordingsStore.swift#L3634) 为 200 字预览读 `fullText`，触发整行 fault，segments blob 一并物化，真实库每次物化约 17 MB 的转录行，是否落盘取决于页缓存；[:3636](../../Cadenza/Services/Persistence/RecordingsStore.swift#L3636) 对每条 speakerMapping 单独发一次 [无 fetchLimit 的 SpeakerProfile 查询:3757](../../Cadenza/Services/Persistence/RecordingsStore.swift#L3757)。除默认日期外的排序在内存执行。[refreshRecordings:3254](../../Cadenza/App/AppState.swift#L3254) 每次独立 Task，不合并，启动阶段跑三次，转录、摘要、说话人记忆落库各触发一次，每次还重建 Smart Folder cache。
建议：列表专用轻量投影，持久化短预览与 hasTranscript/hasSummary，`propertiesToFetch` 限定到 DTO 标量集，speaker 名一次性建映射表；可表达的排序下推数据库。保留全库轻量 ID 索引供 Smart Folder、搜索、批量选择使用，不能用"只加载前 100 条"让其余录音不可达。刷新按变化 ID 合并，保持滚动位置和选中项。

**D5 · P1 · 搜索扫描整库正文，占用共享 store。** 来源 C+K。
[searchRecordingDTOs:474](../../Cadenza/Services/Persistence/RecordingsStore.swift#L474) 先 fetch 全部作用域录音，[recordingMatchesSearch:567](../../Cadenza/Services/Persistence/RecordingsStore.swift#L567) 用 localizedCaseInsensitiveContains 扫 transcript、summary、action items，为所有匹配构造 DTO。它跑在 store actor 上，详情、后处理落库、web 同步全部排在后面。[RecordingSearchCoordinator.swift:24](../../Cadenza/Services/Search/RecordingSearchCoordinator.swift#L24) 的 250ms debounce、取消与 generation 守卫值得保留。
建议：FTS5 影子表返回匹配 ID、snippet、总数和分页，按 profile 隔离，可重建，同步处理修改、回收站和删除；验证中文、词内匹配、变音符号及标签规范化语义。不要把 `tags.contains` 塞回 SwiftData predicate，代码记录了 NULL 数组崩溃的限制。

**D6 · P1 · 开启 Markdown 镜像后，任意保存触发整库内容扫描。** 来源 C+K。
`save()` 发出的通知不带 recordingID，[AppState.swift:1303](../../Cadenza/App/AppState.swift#L1303) 的观察者 500ms 后调用不带 ID 的 `refreshIfEnabled()`，[RecordingsStore+MarkdownMirror.swift:5](../../Cadenza/Services/Persistence/RecordingsStore+MarkdownMirror.swift#L5) 为每条构造完整 detail 并进入 detailCache，[MarkdownMirrorService.swift:78](../../Cadenza/Services/Export/MarkdownMirrorService.swift#L78) 再渲染、读文件、算 hash。勾一个 action item 也可能触发数千篇文档的读取校验。D1 的每次 probe save 与所有 MCP 写操作都会触发它。
建议：通知携带变化 ID，维护 dirty 集合，查询限制到受影响对象，使用 uncached DTO；完整 rebuild 留给显式功能。仍要校验用户手改文件。

**D7 · P2 · detail 缓存无上限，任意 save 清空全部，详情页监听全局 token。** 来源 C+K。
[detailCache:66](../../Cadenza/Services/Persistence/RecordingsStore.swift#L66)、[读取:588](../../Cadenza/Services/Persistence/RecordingsStore.swift#L588)、[RecordingDetailView.swift:406](../../Cadenza/Views/Recordings/RecordingDetailView.swift#L406)。浏览很多详情或 MCP 搜索会累积完整 transcript；写入任意录音又清空全部。详情页还监听全局 token，其他录音的变化也触发自己的 reload 并重建 timeline、turns、speaker profiles。`markAccessed` 已正确绕开这个清空，应成为规则而非例外。
建议：按字节和条目双重约束的 LRU，按 recording revision 定点失效，内容未变跳过派生数据重建。保留播放器 URL 比较，不能让后台刷新重置播放进度。

**D8 · P2 · 没有任何 `#Index`。** 来源 K。
按 id 查、按 trashedDate 过滤、按 startDate 排序、WebSyncRecord 按 userID 每 60 秒查询，全是全表扫描。库里只有 SwiftData 为关系自动建的索引。C 复核时用查询计划确认：按录音 ID 查询显示 `SCAN ZRECORDING`，按删除状态筛选加时间排序使用临时排序树。deployment target 为 macOS 26，加索引无兼容顾虑，纯增量变更。

**D9 · P2 · 存储上限为 0 也在启动时全盘扫描。** 来源 K。
[PostProcessingCoordinator.swift:2005](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L2005) 无条件调用 [cleanupStorage:867](../../Cadenza/Services/Persistence/RecordingsStore.swift#L867)，它 fetch 全部录音并递归遍历音频根目录，逐文件 realpath，limit 为 nil 时结果直接丢弃。加一个早退即可，Settings 显示路径不受影响。

**D10 · P2 · 零碎浪费。** 来源 K。
[addTag:1677](../../Cadenza/Services/Persistence/RecordingsStore.swift#L1677) 与 [:1684](../../Cadenza/Services/Persistence/RecordingsStore.swift#L1684) 一次调用两次全库 tagVocab 扫描；[folderToDTO:3749](../../Cadenza/Services/Persistence/RecordingsStore.swift#L3749) 为一个计数物化整个 recordings 关系；`fetchAIContext` 带显式 ID 时先取全表再过滤。

### 2.2 主界面与详情页

C 的专项结论先列在前面，作为现状基线：waterfall/grid/list 已分别使用 LazyVGrid/LazyVStack，卡片无独立数据库 task；`AppCollectionCardModifier` 是 fill 加 stroke，没有 glass sampler，面板和工具栏仍有真实 glass。这是当前代码现状，不能把当前卡片性能当成"每张卡片保留 glass"的验证；waterfall 也是自适应网格，非真正 masonry，未来优化不可默默把这些视觉变化当作必然代价。以下 K 的发现中，失效依赖与重算路径都可从代码直接确认；每次失效的实际耗时、重算次数与帧时间仍需 Instruments 验证，条目里的“整页重算”指 body 重新求值，不指已观测到的重绘或掉帧。

**U1 · P1 · 每 5 秒重算整个资料库 body。** 来源 K。
[AppState.swift:1348](../../Cadenza/App/AppState.swift#L1348) 的日历计时器每 5 秒调用 `refreshCalendarState()`，[:1359](../../Cadenza/App/AppState.swift#L1359) 无条件给 `upcomingMeetings` 赋新数组。它唯一的读者是 [RecordingsContentView.swift:401](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L401) 的 today strip，从根 body [:260](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L260) 调用。这正是 ARCHITECTURE §12.1 给 MeetingDetector 定过的规矩。
注意：strip 里的“进行中”与“下一场”是在 body 里拿当前时间算的，DTO 没有存储的 isHappening，现在靠这个 5 秒 tick 的副作用在更新。只加数组等值守卫会让会议开始那一刻 strip 不翻转。
建议：两件一起做。MeetingEventDTO 加 Equatable，赋值前比较，切断对网格的失效；strip 抽成只读它自己的小 struct，内部用 TimelineView 或按会议边界对齐的时钟驱动时间相关状态。`currentMeeting` 当前没有任何视图读者，同样无条件赋值。

**U2 · P1 · 框选拖拽每个鼠标事件都写 selectedIDs。** 来源 K。
[computeIntersection:1314](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L1314) 无条件回调，[:1108](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L1108) 写 State。每次 mouse-move 使整页 body 重新求值并重建全部可见卡片的右键菜单，且此时多选分支必然为真；单次求值的耗时待测。加等值守卫，并把提交合并到每帧一次。

**U3 · P1 · 每张卡片的右键菜单在 body 里提前构建。** 来源 K。
[.contextMenu:833](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L833) 的 ViewBuilder 在构造视图值时立即执行。多选状态下 [:837](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L837) 每张卡做一次全库过滤；[:916](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L916) 等处把 notionConnected、导出器 isBusy、批量变更状态接进每张卡，批量导出时每导一个文件全网格刷新一次。
建议：抽成只接收 Equatable 值的独立菜单 struct，服务级读取放进小 struct；多选解析用 `[UUID: RecordingDTO]` 索引。

**U4 · P1 · 后处理进度每个 chunk 都刷新网格。** 来源 K。
[jobs:313](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L313) 没有 `@ObservationIgnored`，卡片通过 [jobPhase(for:):428](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L428) 读它，而 [:474](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L474) 在每次 [chunk 进度回调:1133](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L1133) 整字典重赋值。
建议：jobs 设为 ignored，另发一个只在 phase 真变时才写的投影；chunksDone/Total 走单独属性给工具栏 pill。

**U5 · P1 · 详情页播放时每 0.25 秒重跑整页 body。** 来源 C+K。
[AudioPlayerService.swift:123](../../Cadenza/Services/Audio/AudioPlayerService.swift#L123) 的 tick 写 currentTime，[:1951](../../Cadenza/Views/Recordings/RecordingDetailView.swift#L1951) 在内联到 body 的 section 里读它。整页重跑包含：[:784](../../Cadenza/Views/Recordings/RecordingDetailView.swift#L784) 的 fileExists 系统调用；[visibleTranscriptTurns:2019](../../Cadenza/Views/Recordings/RecordingDetailView.swift#L2019) 全量过滤 turns；[activeTranscriptEntryID:2866](../../Cadenza/Views/Recordings/RecordingDetailView.swift#L2866) 每 tick 做一次线性定位；[:2415](../../Cadenza/Views/Recordings/RecordingDetailView.swift#L2415) 的 onChange 以这个定位结果为键，只在当前条目 ID 变化时才 scrollTo，即每隔几秒一次，这是正确设计，每 tick 付的是 body 求值加 O(T) 扫描而不是滚动；进度条 Canvas 闭包每次 body 求值重建，重绘的内容不依赖 currentTime。
建议：播放器时钟、进度条轨道、当前行高亮各抽独立 struct；音频 URL 只在 loadDetail 解析一次；过滤结果按 query/speaker/revision 缓存。已有 turns/timeline 缓存、lazy 行和播放器 URL 防重载应保留。

**U6 · P1 · 过滤、排序、按天分组每次都在 body 里全量重算。** 来源 C+K。
[TabContentView.swift:107](../../Cadenza/Views/TabBar/TabContentView.swift#L107) 过滤，[:182](../../Cadenza/Views/TabBar/TabContentView.swift#L182) 排序且与 store 已做的 SQL 排序重复，nameAZ 走 ICU collation；[dayGroups:1077](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L1077) 重新分组。每个搜索按键都付一遍，debounce 只保护了数据库。顶栏 speaker 与 tag 直方图同样每次全库重算。
建议：按 recordingsChangedToken、排序、过滤、搜索 generation 记忆化，SmartFolderCache 是现成模板。保留日期分组与排序语义，不简化为固定前 N 条。

**U7 · P2 · 卡片层无 glass；铬层 glass 可以更省，其合成成本待测。** 来源 C+K。
Tab 栏 [:370](../../Cadenza/Views/TabBar/TabContentView.swift#L370)、[:419](../../Cadenza/Views/TabBar/TabContentView.swift#L419)、[:466](../../Cadenza/Views/TabBar/TabContentView.swift#L466)、[:472](../../Cadenza/Views/TabBar/TabContentView.swift#L472)、[:537](../../Cadenza/Views/TabBar/TabContentView.swift#L537) 五到八个胶囊各自独立 glass pass，没有用已有的 [CadenzaGlassContainer](../../Cadenza/Utilities/PlatformCompatibility.swift#L17)，Trash 页和事件详情已用对。overlay 输入区 [:1312](../../Cadenza/Views/Main/RecordingOverlayPanel.swift#L1312) 与 [:1315](../../Cadenza/Views/Main/RecordingOverlayPanel.swift#L1315) 是嵌套双层 glass。工具栏录音 pill 通过 [statusText:111](../../Cadenza/Views/Main/MainWindow.swift#L111) 读秒表，`MainWindow.body` 录音期间每秒重算两次；overlay 用 TimelineView 隔离的做法应照搬。
卡片无独立 glass 只排除了每张卡一次采样这一种开销。工具栏、Tab 栏、overlay 的玻璃悬在滚动内容之上，滚动时要持续重采样下方内容，这部分随可见内容变化的合成成本尚未测量。
建议：保留玻璃位置、透明度、色调、hover 与焦点反馈；只做分组与局部刷新；用 Instruments 的 GPU 与帧时间在三种布局持续滚动下实测。若 SwiftUI lazy 容器仍达不到目标再评估 NSCollectionView，不预设需要 AppKit 重写。

**U8 · P2 · DTO 缺 Equatable。** 来源 K。
[RecordingDTO.swift:4](../../Cadenza/Shared/DTOs/RecordingDTO.swift#L4)、[MeetingEventDTO.swift:4](../../Cadenza/Shared/DTOs/MeetingEventDTO.swift#L4)。没有 Equatable 时 SwiftUI 只能依赖运行时字段比较；加上后才能写显式等值守卫，实际收益待验证。这本身不是修法，是 U1 等值守卫的前提。

**U9 · P2 · Trash 页仍是急切布局。** 来源 K。
[TrashContentView.swift:167](../../Cadenza/Views/Recordings/TrashContentView.swift#L167) 用 [WaterfallLayout](../../Cadenza/Views/Layouts/WaterfallLayout.swift#L11)，每帧测量两遍所有子视图；门禁测试只扫资料库文件。

### 2.3 转录、说话人与录音

**T0 · 前提。** 来源 C+K。
[RecordingProcessingGate.claimRecording:73](../../Cadenza/Shared/Services/RecordingProcessingGate.swift#L73) 只看录音 lease 不看处理 lease，[claimProcessing:98](../../Cadenza/Shared/Services/RecordingProcessingGate.swift#L98) 在录音 lease 存在时拒绝并延后。这是"已有后处理与新录音可重叠"，不是完全自由并发，两种情况要分别验证。K 补充：[RecordingEngine.swift:725](../../Cadenza/Services/Recording/RecordingEngine.swift#L725) 的 isStopping 在整个 merge 链结束前都拒绝新开始，窗口长度随上一段录音长度增长，[merge 预算:1103](../../Cadenza/Services/Recording/RecordingEngine.swift#L1103) 上限为分钟级。T2 直接缩短这个窗口，不需要动 gate。

**T1 · P1 · 说话人分析完整执行两遍，并挡住首份可读文本。** 来源 C+K。
[PostProcessingCoordinator.swift:1251](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L1251) 先 diarize，转录保存后 [SpeakerEmbeddingExtractor.swift:36](../../Cadenza/Services/SpeakerMemory/SpeakerEmbeddingExtractor.swift#L36) 只为拿 windowEmbeddings 再次调用相同 diarize，首轮结果被丢弃。共享 gate 串行两次推理，避免同时跑但不消除重复。[SpeakerDiarizer.swift:299](../../Cadenza/Services/Transcription/SpeakerDiarizer.swift#L299) 每次把完整音频加载为 Float 数组，16kHz mono Float32 一小时约 230 MB，两小时约 460 MB，不含模型与其他副本。首次 diarization 还在转录保存之前，云端文本已回来用户仍在等。
建议：首轮结果通过按音频 revision 绑定的短生命周期对象传给 speaker memory；窗口化加载并保持跨窗口身份一致；允许先显示标记为"说话人分析中"的转录，完成后原子更新标签，保留取消、重试、revision 防陈旧写与用户手动映射。

**T2 · P1 · merge 轮询睡眠，随后再整文件转码一次。** 来源 K。
[AudioSegmentMerger.swift:691](../../Cadenza/Utilities/AudioSegmentMerger.swift#L691) 用 10 毫秒睡眠轮询编码器背压，旁边 [AudioExporter.swift:301](../../Cadenza/Utilities/AudioExporter.swift#L301) 已用正确的 requestMediaDataWhenReady。merge 先写 [48k/128k:197](../../Cadenza/Utilities/AudioSegmentMerger.swift#L197)，[compressAudioIfNeeded:2096](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L2096) 再整文件转到 24k/48k，且它跑在 [摘要之后:1479](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L1479)，phase 卡在 summarizing，完成回调与自动导出全压在后面。
两部分要分开处理。可以立刻做的：轮询改事件驱动。压缩前先发完成回调并让 job 退出 jobs 是方向，但压缩当前跑在 job 持有的 [存储迁移 lease:1509](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L1509) 之下且会替换音频文件，提前结束 job 后必须由独立维护任务自行 claim 迁移 lease、支持取消、校验文件版本，并与导出、删除、目录迁移协调，否则会出现压缩仍在操作文件而其他流程已移动或删除它的情况。需要先验证的：merge 直接写 24k/48k。各路模型的实际输入是云端分块 16 kHz 32 kbps、本地 Whisper 16 kHz WAV、diarization 16 kHz，十分钟内短录音则直接上传原文件。模型最终收到 16 kHz 不代表不同的重采样与编码链等价：源采样率从 48k 变 24k，源码率从 128 kbps 变 48 kbps，再转 32 kbps 的二次有损起点都变了，短录音更是直接上传改后的原文件。用 `Cadenza/Services/Diagnostics/QualityComparisonRunner.swift` 把采样率、重采样与有损编码链一起纳入音质与识别质量对照后再决定。

**T3 · P1 · 说话人分配在主线程做嵌套循环。** 来源 K。
[SpeakerDiarizer.assignSpeakers:452](../../Cadenza/Services/Transcription/SpeakerDiarizer.swift#L452) 是 `@Observable @MainActor` 类的同步方法，[:477](../../Cadenza/Services/Transcription/SpeakerDiarizer.swift#L477) 对每个 entry 扫全部 span，两小时会议是数百万到千万次迭代，主线程完全阻塞。改为 nonisolated 静态函数，span 按时间排序后滑动窗口扫描。

**T4 · P1 · QoS 倒挂，后台转录压过正在录的会议。** 来源 K。
系统音频 tap 队列 [ProcessTapSystemAudioCapture.swift:17](../../Cadenza/Services/Audio/ProcessTapSystemAudioCapture.swift#L17) 为 `.utility`，麦克风 [MicrophoneCoreAudioCapture.swift:38](../../Cadenza/Services/Audio/MicrophoneCoreAudioCapture.swift#L38) 为 `.userInitiated`。WhisperKit 推理 [LocalWhisperPipelineRuntime.swift:519](../../Cadenza/Services/Transcription/LocalWhisperPipelineRuntime.swift#L519)、SpeechAnalyzer、后处理根任务 [:1158](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L1158)、diarization 解码 [:301](../../Cadenza/Services/Transcription/SpeakerDiarizer.swift#L301) 都是 userInitiated 或默认优先级，per-chunk 导出队列无 qos。停止时的 finalize 也是默认优先级。
建议：tap 队列提到 userInitiated；录音 lease 存在时把后处理根任务降到 utility。恢复时机不能用 [observeAllIdle:150](../../Cadenza/Shared/Services/RecordingProcessingGate.swift#L150)，它要求录音 lease 与全部处理 lease 同时为空，录音停止后仍在跑的转录得不到通知。应监听录音 lease 的变化，在后续分块或阶段调度时按 [hasRecordingLease:45](../../Cadenza/Shared/Services/RecordingProcessingGate.swift#L45) 调整资源预算。不推迟、不阻塞、不取消任何任务，只在真正冲突时重排 CPU。

**T5 · P1 · 并发按任务相乘，缺少跨任务资源预算，静音检测占住协作线程池。** 来源 C+K。
转录池为 2，OpenAI 每任务 [6 导出 6 请求:35](../../Cadenza/Services/Transcription/WhisperTranscriber.swift#L35)，Gemini [3 导出 5 请求:20](../../Cadenza/Services/Transcription/GeminiTranscriber.swift#L20)，两个长任务理论上 12 路导出，导出队列容量不受限制，新录音开始后已有任务不下调预算。K 补充：[AudioSilenceDetector.swift:46](../../Cadenza/Utilities/AudioSilenceDetector.swift#L46) 的解码循环无 await 无早退，整文件一遍加每个 chunk 再一遍，六路并发时占满协作线程池，能饿死实时音频投递任务。
建议：共享的 provider 请求池与解码导出预算，有界待上传队列；录音开始时减少后台计算不阻断录音；静音检测早退、vDSP、专用 utility 队列，chunk 路径去掉整文件预检；分块 checkpoint 避免失败整条重跑。

**T6 · P2 · Gemini 退避占着上传名额，请求体在重试内重建。** 来源 C+K。
[apiPermits.withPermit:369](../../Cadenza/Services/Transcription/GeminiTranscriber.swift#L369) 包住整个 [重试循环:245](../../Cadenza/Services/Transcription/GeminiTranscriber.swift#L245)，退避时仍占 slot，失败分块阻塞健康分块。base64 与 JSON 序列化在循环内重做，约四份音频副本；OpenAI 路径 [:188](../../Cadenza/Services/Transcription/WhisperTranscriber.swift#L188) 每次 attempt 也重读文件重建 multipart。此区域含未提交的 Gemini WIP。
建议：每次 attempt 单独申请 permit，退避时释放；base64 提到循环外；OpenAI 用 uploadTask(fromFile:)。保留针对退化时间戳响应的质量重试。

**T7 · P2 · 摘要 map-reduce 名义三并发，实际全进程串行。** 来源 C。
[SummaryGenerator.swift:311](../../Cadenza/Services/AI/SummaryGenerator.swift#L311) 上限为 3，但每个 map 调用都经过 [AIGenerationGate.swift:5](../../Cadenza/Services/AI/AIGenerationGate.swift#L5) 的单槽闸，quick、enrich、reduce、Recap、Meeting Prep 全共用，不同 provider 的任务也互相等候。K 已核对调用点。
建议：按 provider 与本地模型资源分别限流，加入前台后台优先级与取消感知。不能删掉所有 gate，本地模型与云端配额仍需保护；保留 quick 结果、流式反馈与最终持久化语义。

**T8 · P2 · 实时转录三处主线程开销。** 来源 K。
[RecordingEngine.swift:895](../../Cadenza/Services/Recording/RecordingEngine.swift#L895) 每个音频 buffer 一个 `Task { @MainActor }`，[sendAudio:343](../../Cadenza/Services/Transcription/TranscriptionManager.swift#L343) 每 buffer 两次 UserDefaults 读；[每秒 flush:1495](../../Cadenza/Services/Recording/RecordingEngine.swift#L1495) 把整段转录重建 DTO，用 String(format:) 拼 UUID，并因暂存引用诱发一次 copy-on-write 全拷贝；[rebuildFullText:973](../../Cadenza/Services/Transcription/TranscriptionManager.swift#L973) 每条 final delta 全量重拼，录音期间没有任何 UI 读者。
建议：减少每 buffer 一次的 MainActor 回调，但合并窗口不能定成固定的 200 到 500 毫秒，那会直接加大实时延迟。要与现有 [低延迟模式:953](../../Cadenza/Services/Transcription/TranscriptionManager.swift#L953) 协调，用最大等待时间加字节阈值双重上限，暂停与停止时立即冲刷尾包，并验证首字延迟与尾包完整性。设置值按会话缓存；flush 只重映射变化的尾部；fullText 增量维护或停止时再算。已有有界队列、批量发送与过期 session 防护应保留，不能靠缩短队列丢语音。

**T9 · P2 · 同一音频每个 job 解码四到六次。** 来源 C+K。
静音整文件检查、每 chunk 导出、每 chunk 静音检查、diarization、speaker memory、压缩各自从同一个 m4a 重新解码。本地 Whisper [LocalWhisperTranscriber.swift:164](../../Cadenza/Services/Transcription/LocalWhisperTranscriber.swift#L164) 在窗口推理前先整段转 16k WAV 再删掉，而 diarization 想要的正是这份音频；长录音首块开始被推迟并消耗临时磁盘。
建议：每个 job 一份规范 16k PCM 产物，供静音检测、chunk 导出、diarization、speaker memory 共用，处理 lease 释放时删除；本地 Whisper 评估按窗口转换，保留格式兼容、边界去重和时间戳。

**T10 · P1 · Gemini 实时路径采样率声明错误。** 来源 K。
混音器统一送出 [24k PCM](../../Cadenza/Services/Audio/AudioConverter.swift#L10)，[GeminiRealtimeTranscriber.swift:311](../../Cadenza/Services/Transcription/GeminiRealtimeTranscriber.swift#L311) 却声明 rate=16000，中间没有重采样。这是正确性问题，位于未提交的工作树改动中。应让目标格式随 provider 变化。

**T11 · P2 · 其他。** 来源 K。
[IOProc 内分配内存:275](../../Cadenza/Services/Audio/ProcessTapSystemAudioCapture.swift#L275)，实时线程不安全；[摘要期间每 200 毫秒空转:1536](../../Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift#L1536)，注释说为触发观察更新，实际什么也不触发；本地 Whisper 只有 [一个 pipeline 许可:613](../../Cadenza/Services/Transcription/LocalWhisperPipelineRuntime.swift#L613)，转录池设 2 只是白占一个槽位；Gemini 实时 WebSocket 逐字节掩码，在 actor 内阻塞 delta 接收。

### 2.4 MCP

**M1 · P1 · 页面上限没有限制数据库工作量。** 来源 C+K。
[list_recordings:334](../../Cadenza/Services/MCP/MCPToolRegistry.swift#L334) 每页全量 fetch 加过滤排序 fingerprint 再截取，1000 条按 20 条取完等于 50 次整库列表构造，且付 D4 的全套预览成本后把预览丢掉。[fetchActiveDetail:1652](../../Cadenza/Services/MCP/MCPToolRegistry.swift#L1652) 为判断单条是否已删除先构造整个回收站 DTO 列表，get_transcript 每页都付一次，toggle_action_item 付两次。[search_transcripts:216](../../Cadenza/Services/MCP/MCPToolRegistry.swift#L216) 先取全部匹配再截取，为 snippet 又读完整 detail，而匹配位置在扫描时已算出。
建议：O(1) 的 isTrashed，专用分页查询，snippet 直接来自索引。用 revision 或有界快照维持 cursor 变化检测，不能删除 cursor 一致性保护、权限边界或精确总数。

**M2 · P1 · get_meeting_context 是最重的工具。** 来源 K。
[MCPToolRegistry.swift:1057](../../Cadenza/Services/MCP/MCPToolRegistry.swift#L1057) 两次调用 fetchAIContext。第一次 [RecordingsStore.swift:4840](../../Cadenza/Services/Persistence/RecordingsStore.swift#L4840) 把最新 200 条录音的每个 segment 装进数组再 prefix(0) 丢掉；第二次按说话人筛选时不限 fetchLimit，对全库每份转录做 segment 级子串匹配。
建议：maxTranscriptEntries 为 0 时只跳过随后会被丢弃的 excerpt 构造，不能跳过整个循环，因为循环同时在累计 speakerRecordingCounts 并决定返回的 speakers；要么保留说话人统计，要么新增明确的 metadata-only 查询接口。说话人匹配先看 speakerMappings 标量，只在需要原始标签时才走 segment。

**M3 · P2 · bridge 串行处理，MCP 关闭时每请求空等。** 来源 C+K。
[CadenzaMCPMain.swift:62](../../CadenzaMCP/CadenzaMCPMain.swift#L62) 读下一行前 await 上一请求，一个慢工具挡住后续轻请求最长 300 秒；HTTP 层 32 连接上限抵消不了 bridge 层串行。K 补充：[waitForServer:321](../../CadenzaMCP/CadenzaMCPMain.swift#L321) 在 app 运行但 MCP 关闭时，每个请求都轮询满 10 秒才失败，负结果不缓存。此文件为未提交新增内容。
建议：有界并发读取、按 request ID 回应、独立取消；负结果带 TTL 缓存并快速失败，TTL 到期重新探测，重新启用 MCP 后必须自动恢复而不需要重启客户端。`Connection: close` 是额外开销但优先级低于数据层。

**M4 · 做对的与一处正确性观察。** 来源 C+K。
读写工具的调用链不经过 MainActor，不触发任何 SwiftUI 失效，唯一例外是日历上下文闭包用 `MainActor.run` 取 upcomingEvents 与就绪状态；[鉴权:174](../../Cadenza/Services/MCP/MCPClientAccessStore.swift#L174) 全在内存，请求路径零 Keychain 访问；HTTP 分帧正确有界。MCP 写操作不通知 UI 也不通知 web 同步，打开着的详情页保持陈旧；修复时走单录音通知，不要重新引入 D6。

## 3. 已经做对、不应回退

- 资料库三种布局都是真正的 lazy 容器，[卡片零 glass 零 hover](../../Cadenza/Utilities/ColorHex.swift#L92) 且有 [门禁测试](../../CadenzaTests/UI/RecordingsChromeLayoutTests.swift#L946)。
- anchorPreference 自激环已彻底移除，只剩注释；替代的 [CardFrameRegistry](../../Cadenza/Views/Recordings/RecordingsContentView.swift#L50) 只读 AppKit frame，从不写 SwiftUI 状态。ARCHITECTURE §8.1.3 在这一点上已滞后于代码。
- 搜索有 250ms debounce、取消与 generation 守卫；智能文件夹是记忆化的；`markAccessed` 拆成独立只读安全写；每 60 秒的 web 同步 candidates 查询已用 propertiesToFetch。
- 实时路径：AudioConverter 缓冲池零稳态分配、音量在源头节流并有 0.02 死区、delta 批处理与 1Hz flush、有界音频队列、Timer 用 assumeIsolated。
- merge 是流式的，单段直接拷贝不重编码；尾部静音修剪会早退；转录落库是一次批量写；本地 Whisper 有 10 分钟窗口、5 秒 overlap 与 Fenwick 去重，pipeline 跨任务复用。
- 启动备份已脱离 MainActor 且在恢复清理前完成，这是数据恢复要求，不能移除。
- 现有布局、搜索调度、取消、并发排除和部分规模/渲染测试存在，但它们不等于数千录音与录音、转录、MCP 同时运行的端到端验收。

## 4. 落地顺序

顺序按 C 复核后的意见调整：先修正确性，再修写放大与启动扫描，随后查询与 UI，质量相关改动放到验证之后。

1. 修 Gemini 实时采样率声明，目标格式随 provider 变化。T10。复核 `fix/boot-store-probe` 的补丁，适配当前 master 并通过测试后再部署，分支基于三周前的 master，不直接合并。D3。
2. 探测调度状态与内容变更分离，历史清理与缩文件，一起把库缩回二十几 MB。D1、D2。
3. upcomingMeetings 等值守卫加 strip 内部时钟、框选等值守卫、两个 DTO 加 Equatable。U1、U2、U8。
4. 列表投影：预览列反规范化加 propertiesToFetch 加 speaker 映射表，刷新按变化 ID 合并，同时补 `#Index`。D4、D8。
5. 去掉重复 diarization 并让首份文本先出。T1。
6. jobs 改 ignored 加 phase 投影，右键菜单抽 struct，详情页播放时钟隔离，视图层记忆化。U3 至 U6。
7. merge 轮询改事件驱动，压缩前先发完成回调；assignSpeakers 移出主线程；QoS 按 lease 门控。T2 的可立刻做部分、T3、T4。
8. MCP：isTrashed、bridge 有界并发与负缓存、Markdown 镜像通知带 ID、meeting_context 短路。M1 至 M3、D6。
9. 需要质量或行为验证后再做：merge 直接写 24k，Gemini attempt 级 permit，摘要 gate 分域，跨任务资源预算，静音检测早退。T2 的验证部分、T5 至 T7。
10. 之后：FTS5 与 revision 缓存，每个 job 共享一份 16k PCM 产物。D5、T9。
11. 保持玻璃视觉方案，先按 Instruments 实测铬层 glass 在滚动下的合成成本，再决定刷新与渲染范围的收窄方式。U7。

## 5. 验收矩阵

以下为待执行的验收矩阵，不是已通过结果。来源 C。

| 场景 | 必测指标 | 体验与正确性门槛 |
| --- | --- | --- |
| 100/1000/5000 录音冷启与热启 | 可交互外壳/首屏数据/MCP ready 各自时间，读取行数与字节 | 门禁继续 fail-closed，不能闪现空库作为最终结果 |
| 三种布局持续滚动、缩放和框选 | 帧时间 P50/P95/P99、hitch、SwiftUI body 耗时、GPU、RSS/峰值 | 保留目标 glass 外观、hover、键盘、多选、排序与返回位置 |
| 搜索中文/英文/无匹配/高频词 | 包含 debounce 的响应时间、SQL 次数、取消耗时 | 全库可检索，旧结果不覆盖新结果，标签语义不变 |
| 浏览 200 个长录音详情再返回 | 缓存字节、RSS 稳态、派生数据重建次数 | 播放位置不重置，内存不随访问总量无限增长 |
| 15 分钟/1/4/8 小时音频 | 解码/导出/上传/服务端/diarization 各阶段耗时，首文本、RTF、峰值内存/临时空间 | 保留录音、时间戳、说话人、中文可读分段与重试结果 |
| 两个长转录 + 开始新录音 + 浏览 + 两个 MCP 读请求 | 开始录音延迟、capture 丢帧/写入错误、队列等待、UI 帧时间 | 新录音必须成功，文件时长与内容完整，原始音频持续保存 |
| MCP 顺序分页及 bridge 并发 | 工具 P50/P95、每页 rows/bytes、排队、取消和断连后的剩余工作 | cursor 一致性、权限、写入顺序、请求 ID 对应关系保留 |
| Markdown 镜像/后台同步/备份开启 | 单对象改动导致的读取/渲染/哈希/写入量 | 用户修改冲突保护、备份和恢复能力保留 |
| 闲置 24 小时，来源 K | 持久化历史行数增量、事务次数、库文件增量、资料库 body 求值次数，并单独统计日历变化、同步恢复、后台处理完成等必要活动 | 输入与业务状态不变时不产生重复内容写入，不使无关网格失效；必要的后台活动单独计数而不计入违规 |

性能预算应在同机同配置基线之后定值。60Hz/120Hz 的单帧时间分别约 16.7/8.3ms 可作帧时间参照；网络转录应拆分本地开销与 provider 等待，不能拿模型精度降低造成的缩时作为通过证据。

## 6. 分歧与判断

- **quick_check 是否等价于 digest。** C 认为不等价，K 认为对结构可读性而言不弱于 digest，索引一致性两者都不覆盖。结论：复核并适配该分支的轻量探针后部署，另加低频 integrity_check。
- **glass 是否是瓶颈。** 两者一致：没有证据证明 glass 本身是主要瓶颈，也没有证据证明数千录音时已达稳定帧率。K 补充的 U1 至 U6 是可从代码确认的无效重算，与 glass 无关，应先修再测。
- **lazy 容器。** 两者一致：已完成，不再当成待办。
- **C 对 K 报告的六条复核。** 卡片无 glass 不等于担忧不成立，采纳，见 U7；部分源码风险被写成已测后果，采纳，见第 0 节、U2、U5；探测不保存会破坏调度语义，采纳，见 D1；日历等值守卫会让时间相关 UI 停住，采纳，见 U1；merge 直接写 24k 需先做质量对照，采纳，见 T2；quick_check 适用范围限定于算完即丢的健康检查，双方一致，见 D3。
- **C 对二稿的复核。** 压缩移出 job 需独立任务接管迁移 lease 与文件版本检查，采纳，见 T2；all-idle 回调恢复不了录音停止后仍在跑的转录，采纳，见 T4；maxTranscriptEntries 为 0 不能跳过整个循环，采纳，见 M2；固定合并窗口会加大实时延迟，采纳，见 T8；闲置验收改为输入不变则无重复写入与无关失效，采纳，见第 5 节；另收紧 D1 的频率与 fsync 表述、U8 的绝对化表述、M3 的负缓存恢复、M4 的 MainActor 例外、开头的证据记录，并把探针分支从直接合并改为复核适配后部署。
- **C 对三稿的复核。** D3 与第 6 节的分支处理统一为复核适配后部署；开头结论与 U8 降到证据强度之内；T2 删去采样率不构成差异的断言，采样率、重采样与编码链一起纳入质量对照。报告认可不代表性能已验收，实际收益以同场景前后对照确认。

## 7. 取证材料

C 的临时探针（`ExecutorProbe.swift`、`DigestProbe.swift`、`GatingProbe.swift`）与对应的原始输出留在仓库外的临时目录，未入库。SwiftData 宏插件最初被 sandbox 阻止，之后在隔离数据上完成，不是产品构建失败。

K 的真实库统计使用 `sqlite3 -readonly` 对 `Profiles/<UUID>/Cadenza.store` 查询，只取行数、字节数与时间戳分布，未打印内容：

```
select name, sum(pgsize) from dbstat group by name order by 2 desc limit 12;
select ZENTITY, ZCHANGETYPE, count(*) from ACHANGE group by 1,2 order by 3 desc;
select strftime('%H', ZTIMESTAMP + 978307200, 'unixepoch', 'localtime'), count(*)
  from ATRANSACTION where date(ZTIMESTAMP + 978307200, 'unixepoch') = date('now') group by 1;
pragma quick_check;
```

不要对 ZTRANSCRIPT 做 `select *`，那会把真实转录内容打进终端或工具输出。进程画像来自 `footprint` 与 `heap -s`，二进制检查来自 `strings`。根因链与探针部署状态已写入共享记忆 `issue_cadenza_store_history_bloat.md`。

## 8. 实施状态，2026-09-06 晚

以下改动已在工作树实现并通过测试，未提交、未部署。完整套件 2652 个测试，唯一失败是 `MCPBridgeRuntime.swift:42` 触发的路径 seam 门禁，属于既有的 MCP 桥 WIP，未改动。每项附验证方式。

| 条目 | 做了什么 | 验证 |
| --- | --- | --- |
| T10 | Gemini 实时 mimeType 采样率改为跟随 `AudioConverter.transcriptionFormat`，文档确认 Live API 按声明值重采样 | GeminiRealtimeTranscriberTests 新增回归 |
| D3 | `fix/boot-store-probe` 补丁套用到当前 master，quick_check 替换算完即丢的 digest | 探针、M1、启动序列 89 个测试；真实库 digest 6.2 s 对 quick_check 0.39 s |
| D1 | 探测调度改为进程内 `audioProbeAttempts`，保留 15 分钟间隔与最旧优先，只在 probe revision 变化时落库 | WebSyncCoordinatorTests 新增三条，含单趟集成 |
| D2 | `pruneHistorySlice` 每次调用只删一个按天切片并返回，AppState 在切片间 await 让出 store，录音进行时暂停；启动 20 秒后开始；`SQLiteStoreMaintenance` 在容器创建前 incremental_vacuum | 真实库副本干跑：39 切片共 3.76 s，WAL 不到 1 MB，293 MB 到 66 MB，再压缩 50 ms 到 31 MB；切片 API 有测试 |
| U1 U2 U8 | today strip 独立 struct 加会议边界时钟；`upcomingMeetings`、`currentMeeting`、框选三处等值守卫；RecordingDTO、MeetingEventDTO、EventAttendeeDTO、ChapterDTO 加 Equatable | TodayMeetingStripTests，门禁禁止根视图读日历镜像 |
| D4 D8 | Recording 加 `transcriptPreview`、`summaryPreview` 列，写转录和摘要时维护；回填每次只取一批候选（预览列为 nil 的行）并返回，没有内容的行写空串标记，AppState 在批次间 await；`recordingToDTO` 不再 fault 转录行，speaker 名一次建表；`#Index` 覆盖 id、startDate、trashedDate 与复合键，SpeakerProfile、WebSyncRecord、SpeakerVoiceSample 各加索引 | ListProjectionTests 含分批回填；真实库副本迁移 0.31 s，回填 316 行 0.15 s，query plan 为 covering index |
| T1 | 首轮 diarization 映射为 SpeakerEmbeddingResult 传给 speaker memory，`PrecomputedSpeakerEmbeddingExtractor` 不再二次解码推理 | PrecomputedSpeakerEmbeddingExtractorTests 与 speaker memory 套件 |
| U4 | `jobs` 加 `@ObservationIgnored`，`jobPhases` 与 chunk 进度投影只在真变时写 | 源码门禁 PostProcessingObservationGateTests，协调器 24 套件 |
| U3 | 右键菜单多选集合改为点击时求值，导出子菜单抽成 `RecordingExportMenu` 隔离服务级观察 | 门禁测试 |
| U5 | `PlaybackControlsBar`、`PlaybackEntryObserver`、`PlaybackChapterObserver` 三个小 struct 承接播放时钟；音频 URL 只在 loadDetail 解析；进度条轨道 `ScrubberTrackCanvas` Equatable | 门禁：详情页文件里 `audioPlayer.currentTime` 为零处 |
| U6 | `RecordingSorting` 共享排序；AppState 用 `TokenKeyedMemo` 记忆化排序与直方图；按天分组用 Equatable 输入做精确缓存 | RecordingSortingTests 与门禁 |
| T3 | `assignSpeakers` 改为按起点排序加二分的扫描，云端路径经 `assignSpeakersOffMain` 在 detached 任务执行 | SpeakerAssignmentSweepTests 对原嵌套循环做 40 轮随机等价 |
| T4 | `ProcessingWorkPriority` 由 gate 的录音 lease 驱动，只在阶段任务创建时生效（转录根任务、摘要生成、本地 Whisper worker、diarization 解码）；tap 队列提到 userInitiated；导出队列 utility。被更高优先级任务 await 的子任务会被提升，所以这不是对在飞工作的动态限流，真正的分块预算仍是 T5 | ProcessingWorkPriorityTests 只验证策略值，不验证实际执行优先级 |
| M1 M2 | `isRecordingTrashed` O(1) 判断；零预算 AI context 只跳过丢弃的 excerpt，保留说话人统计 | MCPToolsTests |
| M3 | 桥在 app 运行但 MCP 关闭时记 30 秒宽限窗口快速失败，探测成功即清除 | 未单测，属 WIP 文件 |
| D6 | save 通知携带本次事务触及的 recordingID；`MarkdownMirrorRefreshQueue` 做 debounce 与不丢失的 drain：只重启尚未开始的 debounce，正在进行的刷新不被后续保存取消，结束后继续处理新到的 ID；纯簿记写入不再触发 | MarkdownMirrorRefreshQueueTests 含刷新途中再次保存的交错用例 |

**实现复核（`performance-implementation-review-2026-09-06.md`）的处理**

- R1 Whisper 分块导出的 detached 包装丢失取消传播：已撤掉该包装，恢复 task group 子任务直接调用，导出队列 utility 保留。
- R2 定向镜像刷新被后续保存取消时丢 ID：改为 `MarkdownMirrorRefreshQueue`，见 D6 行。
- R3 维护循环在 store actor 内一次跑完：历史清理与预览回填都改为每次一批返回，由 AppState 在批次间 await 驱动，历史清理在录音期间暂停；回填只查预览列为 nil 的候选。
- R4 await detached 子任务会提升其优先级：撤掉逐 chunk 的 detached 包装，`ProcessingWorkPriority` 的作用范围按实际改写，见 T4 行。

**未做，附原因**

- **T2 merge 事件驱动。** writer input 跨所有 segment 共用，`requestMediaDataWhenReady` 要求整个 merge 用一个回调状态机驱动，属于录音正确性关键路径的重构，需要真实多段录音验证后再做。压缩前置完成回调同样依赖迁移 lease 交接，一并留待。
- **M3 桥的有界并发。** `BridgeSession` 是单任务类，并发化要改成 actor 并串行化 stdout，该文件是未提交的 WIP，避免交叉修改。
- **T4 本地 Whisper 逐窗口优先级。** 逐窗口 detached 包装被 Swift 6 的 Sendable 检查拒绝，WhisperKit pipeline 不能跨任务捕获；当前只有 worker 根任务在创建时读取优先级。
- **T5 至 T7、T9、D5、U7。** 按第 4 节属于验证先行或后续项。

**部署与提交**：以上均未部署到 `/Applications`，未提交。部署后第一次启动 20 秒后开始清历史并回填预览列，第二次启动前压缩文件；schema 变更在首次打开库时做轻量迁移，副本实测 0.31 秒。
