# LocalClips 代码验收

日期：2026-10-31。结论：**No-go，当前交付不通过代码验收。**

范围：当前 9 个 Swift 文件、Core Data V1/V2 模型、Xcode 项目、构建/安装脚本，以及交付方 ACCEPTANCE.md。目录不是 Git 仓库，因此这是当前源文件审查，不是相对某个提交的 diff 审查。没有修改实现、安装副本、用户数据库、权限或原验收报告。

## 验证结果

- 当前全部 Swift 源码以 Swift 6、arm64/macOS 27 目标执行 typecheck，通过。
- 在 /tmp/localclips-build-review-sizghb74 的隔离源码副本运行原有 build.sh，退出码 0，生成 arm64 app 并通过脚本内严格签名校验。原交付产物没有覆盖。
- 交付产物与已安装副本的可执行文件摘要均为 67911fc54ddd6fc3d4a15aef2dd7a717bb3a41d8c41f6bef6e4422e6e6719225；两份均通过严格签名校验。临时签名有效不等于 Developer ID 或公证。
- xcodebuild -list 仍在加载 IDE 插件时失败，退出码 70，缺少 DVTDownloads.framework。这是本机工具链限制，不能据此归咎项目语法，也不能宣称 Xcode 工程已经构建通过。
- 使用交付的 Domain.swift 和真实编译 Core Data 模型，在独立探针中验证纯文本优先级及关系删除时序；使用合成 SQLite 存储验证外置二进制统计。没有读取用户正文，未改 general 系统剪贴板。
- 未执行真实应用的粘贴、权限、登录和性能验收，不将探针或编译当成这些路径的通过证据。

## F01 — P1：自动粘贴等待期间不检查剪贴板竞争

位置：[PasteController.swift:179](../app/LocalClips/Sources/PasteController.swift#L179)，另见恢复后的计数记录及事件发送。

触发：选择历史 A 后，控制器已经写回剪贴板，但仍在等待修饰键释放或目标激活；另一应用此时写入 B。

代码只检查 operation generation、目标 PID 和修饰键，没有在发送前比较恢复时的 changeCount 或内容标记；recorder 的新捕获也不会取消该操作。因此会发送 ⌘V，目标应用读取 B 而非选中的 A。B 可能是用户不希望发送到该目标的内容。

证据：静态完整调用路径；仅存的一处 changeCount 读取在 restore 中，perform 等待及发送分支没有比较。这不是已执行的 GUI 竞争复现。

建议：让恢复返回本次写入身份，并在真正发送前核对；检测后续写入即取消，不重写用户最新内容。映射 AC11、AC12 和 ADR 12.4。

## F02 — P1：来源声明会绕过已排除前台应用

位置：[ClipboardRecorder.swift:115](../app/LocalClips/Sources/ClipboardRecorder.swift#L115) 和 sourceAttribution。

触发：前台应用被加入忽略列表，但剪贴板含 org.nspasteboard.source，声明为未被排除的另一个应用。

sourceAttribution 优先返回声明，只将这一个 bundle ID 交给排除判断；前台线索被丢弃。声明可被其他剪贴板工具保留或自行提供，不能可靠覆盖当前排除线索。与 ADR 8.3“合理线索命中被排除应用即跳过”的约定不符，可能将应排除内容写盘。

证据：静态分支；没有修改实际前台应用或用户排除设置来做集成测试。

建议：独立收集声明和前台线索，对排除规则作保守匹配，展示来源仍可保留可信度标签。映射 AC17。

## F03 — P2：读取竞争耗尽重试后会永久跳过最后的稳定内容

位置：[ClipboardRecorder.swift:225](../app/LocalClips/Sources/ClipboardRecorder.swift#L225)。

触发：读内容期间持续发生变化，有限重试耗尽；最后一个变化计数为 n，随后剪贴板稳定。

代码没有成功读取/提交 n，却直接将 lastChangeCount 设为 n。后续 tick 看到计数相等就返回，因此稳定内容不会被下轮采集，直到用户再复制一次。违反“耗尽后交给下一个调度周期”的约定。

证据：静态状态转移。建议区分已处理计数和待重试计数；保留跨 tick 的有限退避，不能把读取失败等同于已消费。映射 AC01、AC24。

## F04 — P2：保存完成回调会覆盖用户的暂停状态与新基线

位置：[ClipboardRecorder.swift:204](../app/LocalClips/Sources/ClipboardRecorder.swift#L204)。

触发：保存正在后台进行时用户暂停，或暂停后又恢复；原保存完成回调稍后返回。

回调无条件写 lastChangeCount=before 并发布 saved/failed 等状态，没有核对当前采集 generation 或 isPaused。仅暂停时，状态会从 paused 变为 saved；界面和菜单据 status 决定暂停/恢复，因此可再次调用 pause 而无法正常恢复。若用户已经恢复，旧回调还可能覆盖新基线并将暂停期间内容补录。

证据：静态异步时序，与 pause/resume 及 ManagerView 的按钮分支交叉核对。没有人为延迟真实用户数据库来复现。

建议：持久化结果与采集开关分开，旧回调不更新新会话基线；暂停状态不得被保存结果覆盖。映射 AC18。

## F05 — P2：先截取 5,000 条再搜索，旧内容和收藏可能无法访问

位置：[HistoryStore.swift:167](../app/LocalClips/Sources/HistoryStore.swift#L167)。

设置允许 50,000 条或无限历史，但查询先按 lastCapturedAt 取 5,000 条，再在内存中做关键词过滤。只匹配更早记录的查询会错误返回空；没有翻页接口。收藏夹同样先按复制时间截断，再按用户收藏顺序排序，较早收藏也可能被排除。

返回值还会通过 makeRow 立即加载所有匹配条目的原始二进制，面板隐藏后状态仍持有这些数据；不等同于 ADR 的分页与按需加载。

证据：静态查询/设置/返回数据路径；未伪造 5,001 条用户历史。建议在正确的完整结果集上应用查询和收藏排序，再分页，原始负载按需读取。映射 AC05、US12 和 ADR 10.1。

## F06 — P2：删除最后收藏关系时，孤儿清理早于 Core Data 关系传播

位置：[HistoryStore.swift:249](../app/LocalClips/Sources/HistoryStore.swift#L249)，删除收藏夹分支同样受影响。

对已不在历史的记录取消最后一个收藏，代码先 context.delete(membership)，随即 deleteOrphans。真实 Core Data 模型中，这个时点 record.memberships 仍含待删除对象，因此判断为非空而保留记录。删除整个收藏夹的级联也有相同问题。

模型级复现输出：

~~~text
CORE_DATA_DELETE membership membership_count_before_save 1 orphan_records_after_save 1
CORE_DATA_DELETE board membership_count_before_save 1 orphan_records_after_save 1
~~~

保存后关系确实删除，但原始孤儿记录继续留库、计入负载，直到下一次采集/维护清理；不是永久不可能回收。原报告 AC09 的静态 PASS 没有覆盖这个时序。

建议：在同一事务中先处理待删除关系或明确排除 deleted 关系，再回收失去全部持有者的记录。映射 AC08、AC09、AC32。

## F07 — P2：纯文本转换没有优先采用现成的纯文本表示

位置：[Domain.swift:88](../app/LocalClips/Sources/Domain.swift#L88)。

代码遍历表示原顺序，先遇到 HTML/RTF 就返回转换结果，即使后面有来源应用明确提供的 plain text。实际调用交付源代码，HTML 在前、plain text 在后时输出：

~~~text
DOMAIN_PLAIN_TEXT_ACTUAL DERIVED_HTML
DOMAIN_PLAIN_TEXT_EXPECTED AUTHORITATIVE_PLAIN
~~~

来源提供的纯文本与富文本提取值可以不同；当前会粘贴错误的表示。建议按“现成 plain text → RTF/RTFD → 无网络 HTML”独立选择，而不改变原始恢复的类型顺序。映射 AC13、ADR 7.3。

## F08 — P2：方向键选择没有连接到 Return 提交

位置：[ManagerView.swift:418](../app/LocalClips/Sources/ManagerView.swift#L418)。

selectedID 仅用于选择高亮；全文件没有 onSubmit、onKeyPress、默认提交动作或根据 selectedID 执行粘贴的 Return 处理。方向键改变高亮后，Return 无法据此保证粘贴选中的条目；至多执行当前焦点按钮，不是承诺的键盘选择流程。

证据：静态事件与状态引用检查，未宣称完成 GUI 键盘测试。建议在不干扰搜索文本/中文输入法组合的情况下接入面板级提交。映射 AC15、AC29、ADR 14.2。

## F09 — P2：物理占用统计漏掉 Core Data 的外置内容

位置：[HistoryStore.swift:562](../app/LocalClips/Sources/HistoryStore.swift#L562)。

physicalSize 使用 skipsHiddenFiles，而 Core Data 的外置二进制保存在隐藏的支持目录中。真实交付模型、独立合成 SQLite 存储和 8MiB Data 的探针结果：

~~~text
BYTES_WITH_CURRENT_ENUMERATION_OPTIONS 114864
ALL_REGULAR_FILE_BYTES 8503472
OMITTED_BYTES 8388608
~~~

设置页的“实际”占用因此恰好少算 8MiB 原始内容；图片历史增多时误差会扩大。建议统计本应用完整数据目录中的受管文件，并明确逻辑文件大小与文件系统分配大小的口径。映射 AC32。

## 复现材料及局限

- /tmp/localclips-code-review-2w5542yh/Probe.swift：直接编译交付 Domain.swift；独立命名剪贴板与内存 Core Data 模型检查。命名剪贴板已释放，general 剪贴板未改。
- /tmp/localclips-storage-review-qdf6_1lv/StorageProbe.swift：实际 Core Data SQLite 外置存储检查，仅生成合成数据。
- /tmp/localclips-build-review-sizghb74：现有 build.sh 的隔离构建。

交付方报告为 3 项 static PASS、1 项 PARTIAL、28 项 UNVERIFIED；本轮没有把任何真实路径或性能项升级为 PASS。其报告对“未完成”本身是诚实的，但不能据此接受成品。建议先修复上述代码问题并加入对应正确接口的回归验证，再按原 PRD 完成真实路径和性能验收。
