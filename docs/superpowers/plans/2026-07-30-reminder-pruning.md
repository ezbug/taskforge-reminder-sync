# TaskForge 今日提醒自动清理实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用
> superpowers:subagent-driven-development（推荐）或
> superpowers:executing-plans 逐任务实现此计划。步骤使用复选框
>（`- [ ]`）语法来跟踪进度。

**目标：** 在 `TaskForge 今日` 列表内自动删除连续两次确认均不属于
TaskForge、未完成且不重要的提醒，同时提供本机备份和恢复能力。

**架构：** 把候选判定、源任务存在性和双扫描状态机放入可独立测试的
`TaskForgeReminderCore`；把 EventKit 查询、备份适配和删除协调放入新的
`TaskForgeReminderEventKit` 库。命令行程序在现有“反向 → 正向”之后调用
清理器，所有不可判定错误都失败关闭。

**技术栈：** Swift 5.9、Foundation、CryptoKit、EventKit、CoreLocation、
Swift Package Manager、LaunchAgent、macOS 13+

---

## 文件结构

### 新建

- `Sources/TaskForgeReminderCore/ReminderPruning.swift`
  - 重要标记判断、TaskForge 存在性枚举、候选策略、双扫描状态机。
- `Sources/TaskForgeReminderCore/ReminderPrunePersistence.swift`
  - 候选账本、备份 DTO、SHA-256 包装、权限 `0600` 的原子文件存储。
- `Sources/TaskForgeReminderEventKit/ReminderPruner.swift`
  - 只查询目标列表、将 EventKit 项目转成候选输入、执行二次确认删除。
- `Sources/TaskForgeReminderEventKit/ReminderBackupAdapter.swift`
  - EventKit 提醒与可恢复备份 DTO 之间的双向转换。
- `Tests/TaskForgeReminderEventKitTests/main.swift`
  - 使用随机命名临时列表的隔离 EventKit 端到端测试。

### 修改

- `Package.swift`
  - 增加 EventKit 库和隔离测试可执行目标。
- `Sources/TaskForgeReminderCore/Core.swift`
  - 增加源任务存在性检查，复用现有 TaskForge 源元数据。
- `Tests/TaskForgeReminderCoreTests/main.swift`
  - 增加候选、安全边界、状态机、源检查和持久化测试。
- `Sources/TaskForgeReminderSync/SyncEngine.swift`
  - 配置并调用清理器；保持“反向 → 正向 → 清理”顺序。
- `Sources/TaskForgeReminderSync/Command.swift`
  - 增加 `--prune-dry-run`、`--prune-once`、`--restore-last-prune`。
- `.gitignore`
  - 明确忽略清理候选、备份、盐值和测试运行数据的同名导出。
- `README.md`
  - 增加功能、判定表、命令、恢复方法和运行时目录。
- `docs/ARCHITECTURE.md`
  - 增加清理状态机、EventKit 隔离和同步顺序。
- `docs/TROUBLESHOOTING.md`
  - 增加候选未删除、恢复和权限故障排查。
- `PRIVACY.md`
  - 记录本机候选账本、备份字段、匿名日志和不上传承诺。
- `SECURITY.md`
  - 记录失败关闭、目标列表边界和删除前备份。
- `CHANGELOG.md`
  - 记录自动清理功能。

## 任务 1：建立重要标记与候选判定策略

**文件：**

- 创建：`Sources/TaskForgeReminderCore/ReminderPruning.swift`
- 修改：`Tests/TaskForgeReminderCoreTests/main.swift:782`

- [ ] **步骤 1：编写失败的候选判定测试**

在测试数组结尾、`completed source inspector...` 测试之后加入表驱动测试：

```swift
("prune policy protects non-target, completed and important reminders", {
    let target = "calendar-target"
    let protected = [
        ReminderPruneObservation(
            itemIdentifier: "other-list",
            calendarIdentifier: "calendar-other",
            isCompleted: false,
            priority: 0,
            title: "普通提醒",
            fingerprint: "a",
            taskPresence: .absent
        ),
        ReminderPruneObservation(
            itemIdentifier: "completed",
            calendarIdentifier: target,
            isCompleted: true,
            priority: 0,
            title: "普通提醒",
            fingerprint: "b",
            taskPresence: .absent
        ),
        ReminderPruneObservation(
            itemIdentifier: "priority",
            calendarIdentifier: target,
            isCompleted: false,
            priority: 1,
            title: "普通提醒",
            fingerprint: "c",
            taskPresence: .absent
        )
    ]
    for observation in protected {
        try require(
            !ReminderPruneCandidatePolicy.isCandidate(
                observation,
                targetCalendarIdentifier: target
            ),
            "\(observation.itemIdentifier) must be protected"
        )
    }
}),
("prune policy recognizes every approved title prefix", {
    for (index, prefix) in ["!", "！", "❗", "‼️", "⭐", "📌"].enumerated() {
        let observation = ReminderPruneObservation(
            itemIdentifier: "important-\(index)",
            calendarIdentifier: "calendar-target",
            isCompleted: false,
            priority: 0,
            title: "  \(prefix) 保留",
            fingerprint: "\(index)",
            taskPresence: .absent
        )
        try require(
            !ReminderPruneCandidatePolicy.isCandidate(
                observation,
                targetCalendarIdentifier: "calendar-target"
            ),
            "\(prefix) must protect the reminder"
        )
    }
}),
("prune policy only selects an unimportant absent TaskForge task", {
    let base = ReminderPruneObservation(
        itemIdentifier: "external",
        calendarIdentifier: "calendar-target",
        isCompleted: false,
        priority: 0,
        title: "普通提醒",
        fingerprint: "stable",
        taskPresence: .absent
    )
    try require(
        ReminderPruneCandidatePolicy.isCandidate(
            base,
            targetCalendarIdentifier: "calendar-target"
        ),
        "external reminder should become a candidate"
    )
    for presence in [
        TaskForgeReminderPresence.currentSnapshot,
        .sourceConfirmed,
        .indeterminate
    ] {
        let protected = base.withTaskPresence(presence)
        try require(
            !ReminderPruneCandidatePolicy.isCandidate(
                protected,
                targetCalendarIdentifier: "calendar-target"
            ),
            "\(presence) must fail closed"
        )
    }
})
```

- [ ] **步骤 2：运行测试并确认因类型未定义而失败**

运行：

```bash
swift run TaskForgeReminderCoreTests
```

预期：编译失败，包含
`cannot find 'ReminderPruneObservation' in scope`。

- [ ] **步骤 3：实现最小候选策略**

创建 `Sources/TaskForgeReminderCore/ReminderPruning.swift`：

```swift
import Foundation

public enum TaskForgeReminderPresence: String, Codable, Equatable, Sendable {
    case currentSnapshot
    case sourceConfirmed
    case absent
    case indeterminate
}

public struct ReminderPruneObservation: Equatable, Sendable {
    public let itemIdentifier: String
    public let calendarIdentifier: String
    public let isCompleted: Bool
    public let priority: Int
    public let title: String
    public let fingerprint: String
    public let taskPresence: TaskForgeReminderPresence

    public init(
        itemIdentifier: String,
        calendarIdentifier: String,
        isCompleted: Bool,
        priority: Int,
        title: String,
        fingerprint: String,
        taskPresence: TaskForgeReminderPresence
    ) {
        self.itemIdentifier = itemIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.isCompleted = isCompleted
        self.priority = priority
        self.title = title
        self.fingerprint = fingerprint
        self.taskPresence = taskPresence
    }

    public func withTaskPresence(
        _ value: TaskForgeReminderPresence
    ) -> ReminderPruneObservation {
        ReminderPruneObservation(
            itemIdentifier: itemIdentifier,
            calendarIdentifier: calendarIdentifier,
            isCompleted: isCompleted,
            priority: priority,
            title: title,
            fingerprint: fingerprint,
            taskPresence: value
        )
    }
}

public enum ReminderPruneCandidatePolicy {
    public static let importantPrefixes = [
        "!", "！", "❗", "‼️", "⭐", "📌"
    ]

    public static func isCandidate(
        _ observation: ReminderPruneObservation,
        targetCalendarIdentifier: String
    ) -> Bool {
        guard observation.calendarIdentifier == targetCalendarIdentifier else {
            return false
        }
        guard !observation.isCompleted, observation.priority == 0 else {
            return false
        }
        let title = observation.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !importantPrefixes.contains(where: title.hasPrefix) else {
            return false
        }
        return observation.taskPresence == .absent
    }
}
```

- [ ] **步骤 4：运行测试确认通过**

运行：

```bash
swift run TaskForgeReminderCoreTests
```

预期：现有 24 项和新增 3 项全部通过，末行是
`27/27 tests passed`。

- [ ] **步骤 5：提交候选策略**

```bash
git add Sources/TaskForgeReminderCore/ReminderPruning.swift \
  Tests/TaskForgeReminderCoreTests/main.swift
git commit -m "feat(清理): 添加提醒候选安全策略"
```

## 任务 2：实现真实源任务存在性检查

**文件：**

- 修改：`Sources/TaskForgeReminderCore/Core.swift:719`
- 修改：`Tests/TaskForgeReminderCoreTests/main.swift:782`

- [ ] **步骤 1：编写失败的源存在性测试**

```swift
("source presence confirms exact and uniquely moved inline tasks", {
    let task = TaskForgeTask(
        identifier: "inline",
        title: "保留任务",
        status: "todo",
        priority: nil,
        scheduled: nil,
        filePath: "/vault/note.md",
        sourceType: "markdownInline",
        originalLine: "- [ ] 保留任务",
        lineNumber: 2
    )
    try require(
        TaskSourcePresenceInspector.inspect(
            task: task,
            contents: "heading\n- [ ] 保留任务\n"
        ) == .present,
        "exact source line should be present"
    )
    try require(
        TaskSourcePresenceInspector.inspect(
            task: task,
            contents: "- [ ] 保留任务\nheading\n"
        ) == .present,
        "uniquely moved source line should be present"
    )
}),
("source presence distinguishes absent from ambiguous", {
    let task = TaskForgeTask(
        identifier: "inline",
        title: "保留任务",
        status: "todo",
        priority: nil,
        scheduled: nil,
        filePath: "/vault/note.md",
        sourceType: "markdownInline",
        originalLine: "- [ ] 保留任务",
        lineNumber: 3
    )
    try require(
        TaskSourcePresenceInspector.inspect(
            task: task,
            contents: "heading\nother\n"
        ) == .absent,
        "missing source line should be absent"
    )
    try require(
        TaskSourcePresenceInspector.inspect(
            task: task,
            contents: "- [ ] 保留任务\n- [ ] 保留任务\n"
        ) == .indeterminate,
        "ambiguous source lines must fail closed"
    )
}),
("source presence protects an existing TaskNotes file", {
    let task = TaskForgeTask(
        identifier: "note",
        title: "任务笔记",
        status: "todo",
        priority: nil,
        scheduled: nil,
        filePath: "/vault/TaskNotes/任务.md",
        sourceType: "taskNotes",
        originalLine: "tasknotes:{}",
        lineNumber: 1
    )
    try require(
        TaskSourcePresenceInspector.inspect(
            task: task,
            contents: "---\nstatus: open\n---\n"
        ) == .present,
        "readable TaskNotes source should be present"
    )
})
```

- [ ] **步骤 2：运行测试验证失败**

运行：

```bash
swift run TaskForgeReminderCoreTests
```

预期：编译失败，包含
`cannot find 'TaskSourcePresenceInspector' in scope`。

- [ ] **步骤 3：在完成检查器之前加入源存在性检查器**

在 `Core.swift` 的 `TaskCompletionSourceInspector` 前增加：

```swift
public enum TaskSourcePresence: String, Codable, Equatable, Sendable {
    case present
    case absent
    case indeterminate
}

public enum TaskSourcePresenceInspector {
    public static func inspect(
        task: TaskForgeTask,
        contents: String
    ) -> TaskSourcePresence {
        switch task.sourceType?.lowercased() {
        case "markdowninline":
            guard let originalLine = task.originalLine else {
                return .indeterminate
            }
            let lines = contents.components(separatedBy: "\n")
            if
                let lineNumber = task.lineNumber,
                lines.indices.contains(lineNumber - 1),
                lines[lineNumber - 1] == originalLine
            {
                return .present
            }
            let matches = lines.filter { $0 == originalLine }.count
            if matches == 1 {
                return .present
            }
            return matches == 0 ? .absent : .indeterminate
        case "tasknotes":
            return .present
        default:
            return .indeterminate
        }
    }
}
```

文件不存在、Vault 越界、读取失败和编码失败不传入此函数，由 EventKit
协调层分别映射为 `.absent` 或 `.indeterminate`。

- [ ] **步骤 4：运行测试确认通过**

运行：

```bash
swift run TaskForgeReminderCoreTests
```

预期：`30/30 tests passed`。

- [ ] **步骤 5：提交源检查**

```bash
git add Sources/TaskForgeReminderCore/Core.swift \
  Tests/TaskForgeReminderCoreTests/main.swift
git commit -m "feat(清理): 验证历史任务真实源"
```

## 任务 3：实现双扫描确认状态机

**文件：**

- 修改：`Sources/TaskForgeReminderCore/ReminderPruning.swift`
- 修改：`Tests/TaskForgeReminderCoreTests/main.swift:782`

- [ ] **步骤 1：编写失败的首次发现和二次确认测试**

```swift
("prune state requires two unchanged scans at least sixty seconds apart", {
    let firstDate = Date(timeIntervalSince1970: 1_000)
    let observation = ReminderPruneObservation(
        itemIdentifier: "external",
        calendarIdentifier: "calendar-target",
        isCompleted: false,
        priority: 0,
        title: "普通提醒",
        fingerprint: "stable",
        taskPresence: .absent
    )
    let first = ReminderPruneStateMachine.plan(
        observations: [observation],
        prior: ReminderPruneLedger(),
        targetCalendarIdentifier: "calendar-target",
        now: firstDate
    )
    try require(first.readyIdentifiers.isEmpty, "first scan must not delete")
    try require(first.firstSeenIdentifiers == ["external"], "candidate not recorded")

    let early = ReminderPruneStateMachine.plan(
        observations: [observation],
        prior: first.nextLedger,
        targetCalendarIdentifier: "calendar-target",
        now: firstDate.addingTimeInterval(59)
    )
    try require(early.readyIdentifiers.isEmpty, "59 seconds is too early")

    let ready = ReminderPruneStateMachine.plan(
        observations: [observation],
        prior: early.nextLedger,
        targetCalendarIdentifier: "calendar-target",
        now: firstDate.addingTimeInterval(60)
    )
    try require(ready.readyIdentifiers == ["external"], "candidate should be ready")
}),
("prune state revokes or restarts changed candidates", {
    let now = Date(timeIntervalSince1970: 2_000)
    let original = ReminderPruneObservation(
        itemIdentifier: "external",
        calendarIdentifier: "calendar-target",
        isCompleted: false,
        priority: 0,
        title: "普通提醒",
        fingerprint: "v1",
        taskPresence: .absent
    )
    let first = ReminderPruneStateMachine.plan(
        observations: [original],
        prior: ReminderPruneLedger(),
        targetCalendarIdentifier: "calendar-target",
        now: now
    )
    let changed = ReminderPruneObservation(
        itemIdentifier: "external",
        calendarIdentifier: "calendar-target",
        isCompleted: false,
        priority: 0,
        title: "改过的提醒",
        fingerprint: "v2",
        taskPresence: .absent
    )
    let restarted = ReminderPruneStateMachine.plan(
        observations: [changed],
        prior: first.nextLedger,
        targetCalendarIdentifier: "calendar-target",
        now: now.addingTimeInterval(120)
    )
    try require(restarted.readyIdentifiers.isEmpty, "changed item must restart")
    try require(
        restarted.nextLedger.entries["external"]?.firstSeen
            == now.addingTimeInterval(120),
        "changed item should receive a new firstSeen"
    )
}),
("prune state restarts after restore grace and rule changes", {
    let now = Date(timeIntervalSince1970: 3_000)
    let observation = ReminderPruneObservation(
        itemIdentifier: "restored",
        calendarIdentifier: "calendar-target",
        isCompleted: false,
        priority: 0,
        title: "恢复提醒",
        fingerprint: "stable",
        taskPresence: .absent
    )
    let prior = ReminderPruneLedger(entries: [
        "restored": ReminderPruneLedgerEntry(
            firstSeen: now.addingTimeInterval(-120),
            fingerprint: "stable",
            calendarIdentifier: "calendar-target",
            rulesVersion: ReminderPruneStateMachine.rulesVersion,
            graceUntil: now.addingTimeInterval(60)
        )
    ])
    let duringGrace = ReminderPruneStateMachine.plan(
        observations: [observation],
        prior: prior,
        targetCalendarIdentifier: "calendar-target",
        now: now
    )
    try require(duringGrace.readyIdentifiers.isEmpty, "grace must protect")

    let afterGrace = ReminderPruneStateMachine.plan(
        observations: [observation],
        prior: duringGrace.nextLedger,
        targetCalendarIdentifier: "calendar-target",
        now: now.addingTimeInterval(61)
    )
    try require(
        afterGrace.firstSeenIdentifiers == ["restored"],
        "expired grace must start a fresh first scan"
    )
    try require(afterGrace.readyIdentifiers.isEmpty, "grace expiry must not delete")

    let oldRules = ReminderPruneLedger(entries: [
        "restored": ReminderPruneLedgerEntry(
            firstSeen: now.addingTimeInterval(-120),
            fingerprint: "stable",
            calendarIdentifier: "calendar-target",
            rulesVersion: ReminderPruneStateMachine.rulesVersion - 1,
            graceUntil: nil
        )
    ])
    let versionReset = ReminderPruneStateMachine.plan(
        observations: [observation],
        prior: oldRules,
        targetCalendarIdentifier: "calendar-target",
        now: now
    )
    try require(
        versionReset.firstSeenIdentifiers == ["restored"],
        "rules change must restart confirmation"
    )

    let completed = ReminderPruneObservation(
        itemIdentifier: "restored",
        calendarIdentifier: "calendar-target",
        isCompleted: true,
        priority: 0,
        title: "恢复提醒",
        fingerprint: "completed",
        taskPresence: .absent
    )
    let revoked = ReminderPruneStateMachine.plan(
        observations: [completed],
        prior: prior,
        targetCalendarIdentifier: "calendar-target",
        now: now
    )
    try require(
        revoked.revokedIdentifiers == ["restored"],
        "completed reminder must revoke its candidate"
    )
    try require(revoked.readyIdentifiers.isEmpty, "revoked item must not delete")
})
```

- [ ] **步骤 2：运行测试验证失败**

运行：

```bash
swift run TaskForgeReminderCoreTests
```

预期：编译失败，包含
`cannot find 'ReminderPruneStateMachine' in scope`。

- [ ] **步骤 3：实现 Codable 账本和状态机**

在 `ReminderPruning.swift` 增加：

```swift
public struct ReminderPruneLedgerEntry: Codable, Equatable, Sendable {
    public var firstSeen: Date
    public var fingerprint: String
    public var calendarIdentifier: String
    public var rulesVersion: Int
    public var graceUntil: Date?

    public init(
        firstSeen: Date,
        fingerprint: String,
        calendarIdentifier: String,
        rulesVersion: Int,
        graceUntil: Date?
    ) {
        self.firstSeen = firstSeen
        self.fingerprint = fingerprint
        self.calendarIdentifier = calendarIdentifier
        self.rulesVersion = rulesVersion
        self.graceUntil = graceUntil
    }
}

public struct ReminderPruneLedger: Codable, Equatable, Sendable {
    public var entries: [String: ReminderPruneLedgerEntry]

    public init(entries: [String: ReminderPruneLedgerEntry] = [:]) {
        self.entries = entries
    }
}

public struct ReminderPrunePlan: Equatable, Sendable {
    public let firstSeenIdentifiers: [String]
    public let waitingIdentifiers: [String]
    public let readyIdentifiers: [String]
    public let revokedIdentifiers: [String]
    public let nextLedger: ReminderPruneLedger
}

public enum ReminderPruneStateMachine {
    public static let rulesVersion = 1

    public static func plan(
        observations: [ReminderPruneObservation],
        prior: ReminderPruneLedger,
        targetCalendarIdentifier: String,
        now: Date,
        confirmationInterval: TimeInterval = 60
    ) -> ReminderPrunePlan {
        var next = ReminderPruneLedger()
        var firstSeen: [String] = []
        var waiting: [String] = []
        var ready: [String] = []
        let candidates = observations.filter {
            ReminderPruneCandidatePolicy.isCandidate(
                $0,
                targetCalendarIdentifier: targetCalendarIdentifier
            )
        }

        for observation in candidates {
            let old = prior.entries[observation.itemIdentifier]
            let isSame = old?.fingerprint == observation.fingerprint
                && old?.calendarIdentifier == observation.calendarIdentifier
                && old?.rulesVersion == rulesVersion
            if !isSame {
                next.entries[observation.itemIdentifier] = ReminderPruneLedgerEntry(
                    firstSeen: now,
                    fingerprint: observation.fingerprint,
                    calendarIdentifier: observation.calendarIdentifier,
                    rulesVersion: rulesVersion,
                    graceUntil: nil
                )
                firstSeen.append(observation.itemIdentifier)
            } else if let old, let graceUntil = old.graceUntil {
                if now < graceUntil {
                    next.entries[observation.itemIdentifier] = old
                    waiting.append(observation.itemIdentifier)
                } else {
                    next.entries[observation.itemIdentifier] = ReminderPruneLedgerEntry(
                        firstSeen: now,
                        fingerprint: observation.fingerprint,
                        calendarIdentifier: observation.calendarIdentifier,
                        rulesVersion: rulesVersion,
                        graceUntil: nil
                    )
                    firstSeen.append(observation.itemIdentifier)
                }
            } else if let old, now.timeIntervalSince(old.firstSeen) >= confirmationInterval {
                next.entries[observation.itemIdentifier] = old
                ready.append(observation.itemIdentifier)
            } else if let old {
                next.entries[observation.itemIdentifier] = old
                waiting.append(observation.itemIdentifier)
            }
        }

        let active = Set(candidates.map(\.itemIdentifier))
        let revoked = prior.entries.keys.filter { !active.contains($0) }.sorted()
        return ReminderPrunePlan(
            firstSeenIdentifiers: firstSeen.sorted(),
            waitingIdentifiers: waiting.sorted(),
            readyIdentifiers: ready.sorted(),
            revokedIdentifiers: revoked,
            nextLedger: next
        )
    }
}
```

上述第三个测试同时固定 `rulesVersion` 变化、`graceUntil` 到期后的重新
计时，以及提醒完成后的候选撤销。

- [ ] **步骤 4：运行测试确认通过**

运行：

```bash
swift run TaskForgeReminderCoreTests
```

预期：至少 `33/33 tests passed`。

- [ ] **步骤 5：提交状态机**

```bash
git add Sources/TaskForgeReminderCore/ReminderPruning.swift \
  Tests/TaskForgeReminderCoreTests/main.swift
git commit -m "feat(清理): 添加双扫描确认状态机"
```

## 任务 4：实现本机候选账本和可校验备份

**文件：**

- 创建：`Sources/TaskForgeReminderCore/ReminderPrunePersistence.swift`
- 修改：`Tests/TaskForgeReminderCoreTests/main.swift:782`

- [ ] **步骤 1：编写失败的权限、原子读写和损坏拒绝测试**

使用 `FileManager.default.temporaryDirectory` 下的 UUID 目录，并在 `defer`
中删除。先在测试辅助函数区增加：

```swift
func pruneBackupFixture() -> ReminderPruneBackupBatch {
    ReminderPruneBackupBatch(
        identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        createdAt: Date(timeIntervalSince1970: 20),
        targetCalendarIdentifier: "calendar",
        targetCalendarTitle: "TaskForge 今日",
        items: [
            ReminderPruneBackupItem(
                originalItemIdentifier: "item",
                title: "普通提醒",
                notes: "本地测试",
                url: URL(string: "taskforge-test://item"),
                priority: 0,
                dueDateComponents: DateComponents(
                    calendar: Calendar(identifier: .gregorian),
                    timeZone: TimeZone(secondsFromGMT: 0),
                    year: 2026,
                    month: 7,
                    day: 30
                ),
                startDateComponents: nil,
                alarms: [],
                recurrenceRules: []
            )
        ],
        restoredAt: nil
    )
}
```

再加入测试：

```swift
("prune local store writes private ledger and verified backup", {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReminderPruneLocalStore(rootURL: root)
    let ledger = ReminderPruneLedger(entries: [
        "item": ReminderPruneLedgerEntry(
            firstSeen: Date(timeIntervalSince1970: 10),
            fingerprint: "fingerprint",
            calendarIdentifier: "calendar",
            rulesVersion: 1,
            graceUntil: nil
        )
    ])
    try store.saveLedger(ledger)
    try require(try store.loadLedger() == ledger, "ledger round-trip failed")

    let permissions = try requireValue(
        FileManager.default.attributesOfItem(
            atPath: store.ledgerURL.path
        )[.posixPermissions] as? NSNumber,
        "permissions missing"
    )
    try require(permissions.intValue & 0o777 == 0o600, "ledger must be 0600")

    let batch = pruneBackupFixture()
    let url = try store.saveBackup(batch)
    try require(try store.loadBackup(at: url) == batch, "backup verification failed")
}),
("prune local store rejects a modified backup", {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReminderPruneLocalStore(rootURL: root)
    let url = try store.saveBackup(pruneBackupFixture())
    try Data("tampered".utf8).write(to: url, options: .atomic)
    do {
        _ = try store.loadBackup(at: url)
        throw TestFailure(description: "tampered backup was accepted")
    } catch let error as ReminderPruneStoreError {
        try require(error == .checksumMismatch, "unexpected store error")
    }
})
```

- [ ] **步骤 2：运行测试验证失败**

运行：

```bash
swift run TaskForgeReminderCoreTests
```

预期：编译失败，包含
`cannot find 'ReminderPruneLocalStore' in scope`。

- [ ] **步骤 3：定义备份 DTO 和本地存储**

创建 `ReminderPrunePersistence.swift`，包含以下公开接口：

```swift
import CryptoKit
import Foundation

public struct ReminderLocationBackup: Codable, Equatable, Sendable {
    public var title: String
    public var latitude: Double?
    public var longitude: Double?
    public var radius: Double
}

public struct ReminderWeekdayBackup: Codable, Equatable, Sendable {
    public var dayOfTheWeekRawValue: Int
    public var weekNumber: Int
}

public struct ReminderAlarmBackup: Codable, Equatable, Sendable {
    public var absoluteDate: Date?
    public var relativeOffset: TimeInterval?
    public var structuredLocation: ReminderLocationBackup?
    public var proximityRawValue: Int?
}

public struct ReminderRecurrenceBackup: Codable, Equatable, Sendable {
    public var frequencyRawValue: Int
    public var interval: Int
    public var daysOfWeek: [ReminderWeekdayBackup]
    public var daysOfMonth: [Int]
    public var monthsOfYear: [Int]
    public var weeksOfYear: [Int]
    public var daysOfYear: [Int]
    public var setPositions: [Int]
    public var endDate: Date?
    public var occurrenceCount: Int?
}

public struct ReminderPruneBackupItem: Codable, Equatable, Sendable {
    public var originalItemIdentifier: String
    public var title: String
    public var notes: String?
    public var url: URL?
    public var priority: Int
    public var dueDateComponents: DateComponents?
    public var startDateComponents: DateComponents?
    public var alarms: [ReminderAlarmBackup]
    public var recurrenceRules: [ReminderRecurrenceBackup]
}

public struct ReminderPruneBackupBatch: Codable, Equatable, Sendable {
    public var identifier: UUID
    public var createdAt: Date
    public var targetCalendarIdentifier: String
    public var targetCalendarTitle: String
    public var items: [ReminderPruneBackupItem]
    public var restoredAt: Date?
}

public enum ReminderPruneStoreError: Error, Equatable {
    case invalidLedger
    case invalidBackup
    case checksumMismatch
    case permissions
    case noUnrestoredBackup
}

public final class ReminderPruneLocalStore: @unchecked Sendable {
    public static let defaultRoot = URL(
        fileURLWithPath:
            "\(NSHomeDirectory())/Library/Application Support/"
                + "TaskForgeReminderSync",
        isDirectory: true
    )
    public let rootURL: URL
    public var ledgerURL: URL {
        rootURL.appendingPathComponent("PruneCandidates.json")
    }

    public init(rootURL: URL = defaultRoot) {
        self.rootURL = rootURL
    }

    public func loadLedger() throws -> ReminderPruneLedger
    public func saveLedger(_ ledger: ReminderPruneLedger) throws
    public func saveBackup(_ batch: ReminderPruneBackupBatch) throws -> URL
    public func loadBackup(at url: URL) throws -> ReminderPruneBackupBatch
    public func latestUnrestoredBackup() throws -> (URL, ReminderPruneBackupBatch)?
    public func markRestored(at url: URL, date: Date) throws
    public func loadOrCreateHashSalt() throws -> Data
}
```

所有 DTO 都实现显式 `public init(...)`，参数顺序与上方属性顺序一致；不能依赖
Swift 默认的 internal memberwise initializer，否则测试目标无法构造 fixture。

实现细节：

1. 目录权限设为 `0700`，文件权限设为 `0600`。
2. 编码器使用 `.sortedKeys`。
3. 备份写成 `{checksum, payload}` 包装；checksum 是 payload JSON 的
   SHA-256。
4. 所有写入先写同目录 UUID 临时文件、`synchronize()`、设置权限，再
   `replaceItemAt` 或 `moveItem`。
5. JSON 解码、权限或校验错误不得返回空账本，必须抛出
   `ReminderPruneStoreError`，由上层失败关闭。

- [ ] **步骤 4：运行测试确认通过并检查无残留临时目录**

运行：

```bash
swift run TaskForgeReminderCoreTests
```

预期：新增持久化测试通过；测试内的 `defer` 删除 UUID 临时目录。

- [ ] **步骤 5：提交本机存储**

```bash
git add Sources/TaskForgeReminderCore/ReminderPrunePersistence.swift \
  Tests/TaskForgeReminderCoreTests/main.swift
git commit -m "feat(清理): 添加私有候选账本和备份"
```

## 任务 5：建立 EventKit 清理库和备份适配

**文件：**

- 修改：`Package.swift`
- 创建：`Sources/TaskForgeReminderEventKit/ReminderBackupAdapter.swift`
- 创建：`Sources/TaskForgeReminderEventKit/ReminderPruner.swift`

- [ ] **步骤 1：先增加 EventKit 目标并确认最小骨架可编译**

把 `Package.swift` 的 executable dependencies 改为：

```swift
.target(
    name: "TaskForgeReminderEventKit",
    dependencies: ["TaskForgeReminderCore"]
),
.executableTarget(
    name: "TaskForgeReminderSync",
    dependencies: [
        "TaskForgeReminderCore",
        "TaskForgeReminderEventKit"
    ]
),
.executableTarget(
    name: "TaskForgeReminderCoreTests",
    dependencies: ["TaskForgeReminderCore"],
    path: "Tests/TaskForgeReminderCoreTests"
),
.executableTarget(
    name: "TaskForgeReminderEventKitTests",
    dependencies: [
        "TaskForgeReminderCore",
        "TaskForgeReminderEventKit"
    ],
    path: "Tests/TaskForgeReminderEventKitTests"
)
```

先创建两个只含 import 的源文件和一个输出 `SKIP` 的测试入口，然后运行：

```bash
swift build
```

预期：`Build complete!`，证明新目标边界可编译。

- [ ] **步骤 2：实现 EventKit 备份双向适配器**

`ReminderBackupAdapter.swift` 的固定接口：

```swift
import CoreLocation
import EventKit
import Foundation
import TaskForgeReminderCore

enum ReminderBackupAdapter {
    static func capture(_ reminder: EKReminder) -> ReminderPruneBackupItem
    static func restore(
        _ backup: ReminderPruneBackupItem,
        into reminder: EKReminder
    )
}
```

逐字段映射：

- `title`、`notes`、`url`、`priority`；
- `dueDateComponents`、`startDateComponents`；
- `alarms` 的 absolute/relative/location/proximity；
- `recurrenceRules` 的 frequency、interval、weekday、月份/周/日位置和 end。

恢复时先清除新提醒的默认 alarms/recurrence，再按 DTO 重建。
EventKit 不允许写回的创建时间和原 ID只作审计，不伪装成已恢复字段。

- [ ] **步骤 3：实现只查询目标列表的清理器**

`ReminderPruner.swift` 的公共接口：

```swift
import CryptoKit
import EventKit
import Foundation
import TaskForgeReminderCore

public struct ReminderPruneConfiguration: Sendable {
    public var listName: String
    public var localRoot: URL
    public var confirmationInterval: TimeInterval
    public var restoreGraceInterval: TimeInterval

    public init(
        listName: String,
        localRoot: URL,
        confirmationInterval: TimeInterval = 60,
        restoreGraceInterval: TimeInterval = 86_400
    ) {
        self.listName = listName
        self.localRoot = localRoot
        self.confirmationInterval = confirmationInterval
        self.restoreGraceInterval = restoreGraceInterval
    }
}

public struct ReminderPruneCounts: Equatable, Sendable {
    public var scanned = 0
    public var firstSeen = 0
    public var waiting = 0
    public var ready = 0
    public var deleted = 0
    public var restored = 0
    public var protected = 0
    public var failed = 0
}

@MainActor
public final class ReminderPruner {
    public init(
        eventStore: EKEventStore,
        configuration: ReminderPruneConfiguration,
        log: @escaping @Sendable (String) -> Void,
        logError: @escaping @Sendable (String) -> Void
    )

    public func dryRun(
        snapshot: TaskForgeSnapshot,
        now: Date = Date()
    ) async throws -> ReminderPruneCounts

    public func advance(
        snapshot: TaskForgeSnapshot,
        now: Date = Date()
    ) async throws -> ReminderPruneCounts

    public func restoreLast(
        now: Date = Date()
    ) async throws -> ReminderPruneCounts
}
```

核心约束按此顺序编码：

1. 用 `store.calendars(for: .reminder).first { $0.title == listName }`
   找到唯一目标列表；找不到时返回零。
2. 只用 `predicateForReminders(in: [targetCalendar])` 查询，不获取其他列表。
3. marker 匹配当前快照时返回 `.currentSnapshot`。
4. marker 不匹配缓存时，解码 `TaskSourceReference`：
   - 源路径不在 Vault 内：`.indeterminate`；
   - 文件不存在：`.absent`；
   - 读取或 UTF-8 失败：`.indeterminate`；
   - `TaskSourcePresenceInspector` 的结果映射到 presence。
5. 指纹只包含目标列表 ID、item ID、完成、优先级、标题、notes 和 presence，
   先做 SHA-256，原内容不写账本。
6. `dryRun` 只读取账本并计算，不保存账本、不备份、不删除。
7. `advance` 先保存 nextLedger；ready 项逐条重新获取和分类，仍 ready 才加入
   备份批次。
8. 备份写入并回读校验后才调用 `remove(reminder, commit: false)`；
   最后 `commit()`。
9. commit 后重新读取目标列表，只把实际已不存在的 item ID 从 ledger 移除并
   再次原子保存；仍存在的 ready entry 保留以便下轮重试。
10. commit 抛错时同样重新读取目标列表，按实际存在情况统计，不能假定批次
    全成或全败；备份始终保留。
11. 日志只用本机盐对 EventKit ID 做 SHA-256 后截取前 12 位。

- [ ] **步骤 4：实现恢复与 24 小时宽限**

`restoreLast`：

1. 读取 `latestUnrestoredBackup()`；
2. 查找目标列表；不存在时用同一 EventKit source 创建；
3. 为每个备份项目创建 `EKReminder` 并调用 adapter；
4. commit 成功后重新读取恢复项，按与 advance 相同的函数计算 fingerprint，
   再把新 item ID 写入 ledger，`firstSeen = now`、
   `graceUntil = now + 86_400`；
5. 成功写入 ledger 后再 `markRestored`；
6. 任一步失败都保留未消费备份。

- [ ] **步骤 5：构建并提交 EventKit 边界**

运行：

```bash
swift build
swift run TaskForgeReminderCoreTests
```

预期：构建成功，Core 测试全部通过。

提交：

```bash
git add Package.swift Sources/TaskForgeReminderEventKit \
  Tests/TaskForgeReminderEventKitTests/main.swift
git commit -m "feat(EventKit): 实现可恢复提醒清理器"
```

## 任务 6：接入命令行和同步循环

**文件：**

- 修改：`Sources/TaskForgeReminderSync/Command.swift:5-329`
- 修改：`Sources/TaskForgeReminderSync/SyncEngine.swift:7-645`

- [ ] **步骤 1：添加命令解析分支并先确认编译失败**

在 `RunMode` 增加：

```swift
case pruneDryRun
case pruneOnce
case restoreLastPrune
```

在 parser 中映射：

```swift
case "--prune-dry-run":
    options.mode = .pruneDryRun
case "--prune-once":
    options.mode = .pruneOnce
case "--restore-last-prune":
    options.mode = .restoreLastPrune
```

把三种模式加入需要 EventKit 权限的 switch，然后在 `run` 中暂时调用尚未定义的
engine 方法。运行：

```bash
swift build
```

预期：编译失败，包含
`value of type 'SyncEngine' has no member 'prune'`。

- [ ] **步骤 2：让 SyncEngine 持有同一个 EventKit store 和清理器**

修改 imports 和属性：

```swift
import TaskForgeReminderEventKit

private let store: EKEventStore
private let pruner: ReminderPruner

init(configuration: SyncConfiguration, calendar: Calendar) {
    let store = EKEventStore()
    self.configuration = configuration
    self.calendar = calendar
    self.store = store
    self.pruner = ReminderPruner(
        eventStore: store,
        configuration: ReminderPruneConfiguration(
            listName: configuration.listName,
            localRoot: ReminderPruneLocalStore.defaultRoot,
            confirmationInterval: 60,
            restoreGraceInterval: 86_400
        ),
        log: log,
        logError: logError
    )
}
```

新增包装方法：

```swift
func prune(dryRun: Bool) async throws -> ReminderPruneCounts {
    let snapshot = try loadSnapshotWithRetry()
    return dryRun
        ? try await pruner.dryRun(snapshot: snapshot)
        : try await pruner.advance(snapshot: snapshot)
}

func restoreLastPrune() async throws -> ReminderPruneCounts {
    try await pruner.restoreLast()
}
```

- [ ] **步骤 3：固定协调顺序为反向、正向、清理**

在 `reconcile(reason:)` 中：

```swift
let reverseCounts = try await reverse(
    dryRun: false,
    taskIdentifier: nil,
    requireCandidate: false
)
let forwardCounts = try await forward()
let pruneCounts = try await prune(dryRun: false)
log(
    "清理同步：首次 \(pruneCounts.firstSeen)，"
        + "等待 \(pruneCounts.waiting)，删除 \(pruneCounts.deleted)，"
        + "失败 \(pruneCounts.failed)"
)
```

普通 `--sync` 同样在 forward 后调用 `prune(dryRun: false)`。
`--prune-dry-run` 只调用 dry-run；`--prune-once` 只推进一轮；
`--restore-last-prune` 只恢复最近批次。

- [ ] **步骤 4：补全帮助和匿名输出**

帮助文本加入三条命令；输出仅包含计数：

```swift
print(
    "清理预演：扫描 \(counts.scanned)，首次候选 \(counts.firstSeen)，"
        + "已满足二次确认 \(counts.ready)。"
)
print("预演模式：没有写候选账本，没有删除提醒。")
```

禁止在清理命令输出 `title`、`notes`、Vault 路径或原始 ID。

- [ ] **步骤 5：构建并运行回归测试**

```bash
swift build
swift run TaskForgeReminderCoreTests
.build/debug/TaskForgeReminderSync --help
```

预期：

- 构建和测试通过；
- help 中出现三个新命令；
- 默认 `--dry-run` 行为不变。

- [ ] **步骤 6：提交命令接入**

```bash
git add Sources/TaskForgeReminderSync/Command.swift \
  Sources/TaskForgeReminderSync/SyncEngine.swift
git commit -m "feat(同步): 接入自动清理和恢复命令"
```

## 任务 7：完成隔离 EventKit 端到端测试

**文件：**

- 修改：`Tests/TaskForgeReminderEventKitTests/main.swift`

- [ ] **步骤 1：编写带显式开关的隔离测试入口**

未设置环境变量时只输出：

```swift
import Darwin
import EventKit
import Foundation
import TaskForgeReminderCore
import TaskForgeReminderEventKit

struct IntegrationFailure: Error, CustomStringConvertible {
    let description: String
}

func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw IntegrationFailure(description: message)
    }
}

guard ProcessInfo.processInfo.environment[
    "TASKFORGE_RUN_EVENTKIT_TESTS"
] == "1" else {
    print("SKIP  EventKit integration tests require explicit opt-in")
    exit(0)
}
```

启用后：

1. 请求 reminders full access；
2. 创建 `TaskForgeReminderSync Test <UUID>` 目标列表和另一个列表；
3. 用 `defer` 删除两个临时列表；
4. 创建普通外来、priority=1、六个标题前缀、已完成、当前 TaskForge、
   有效源引用、其他列表外来提醒；
5. 在临时 Vault 写一个 `- [ ] 历史任务` 源文件，并把对应
   `TaskSourceReference` 放入历史提醒 notes；
6. 用临时目录保存 ledger 和备份；
7. 所有 EventKit fetch 都显式传入临时 calendar 数组，测试代码不得调用
   `predicateForReminders(in: nil)`。

- [ ] **步骤 2：断言第一次扫描不删除、第二次扫描只删除普通外来提醒**

调用时传入可控时间：

```swift
let first = try await pruner.advance(
    snapshot: snapshot,
    now: Date(timeIntervalSince1970: 10_000)
)
try require(first.deleted == 0, "first scan deleted immediately")

let second = try await pruner.advance(
    snapshot: snapshot,
    now: Date(timeIntervalSince1970: 10_061)
)
try require(second.deleted == 1, "only the plain external reminder should delete")
```

重新读取两个临时列表，逐项断言：

- 目标列表普通外来提醒不存在；
- priority、六个标题前缀、已完成、当前任务、历史源提醒仍存在；
- 另一个列表的提醒仍存在。

- [ ] **步骤 3：断言备份权限、字段恢复和宽限**

1. 检查最新备份文件权限为 `0600`；
2. 调用 `restoreLast(now:)`；
3. 重新读取目标列表，验证标题、notes、URL、priority、dates、alarms、
   recurrence；
4. 在 `now + 61` 再推进，断言 24 小时宽限阻止删除；
5. 在 `now + 86_401` 后首次扫描只登记，不立即删除。

- [ ] **步骤 4：运行隔离测试和普通构建**

```bash
swift build
TASKFORGE_RUN_EVENTKIT_TESTS=1 \
  swift run TaskForgeReminderEventKitTests
```

预期：测试输出只含临时列表名和 PASS 计数，不含生产提醒；末行
`EventKit integration tests passed`。退出后在 Apple 提醒事项中不存在测试列表。

- [ ] **步骤 5：提交隔离测试**

```bash
git add Tests/TaskForgeReminderEventKitTests/main.swift
git commit -m "test(EventKit): 验证清理隔离和恢复闭环"
```

## 任务 8：更新公共文档和隐私边界

**文件：**

- 修改：`.gitignore`
- 修改：`README.md:7-225`
- 修改：`docs/ARCHITECTURE.md:1-120`
- 修改：`docs/TROUBLESHOOTING.md`
- 修改：`PRIVACY.md:5-55`
- 修改：`SECURITY.md:24-32`
- 修改：`CHANGELOG.md`

- [ ] **步骤 1：更新 README 的功能、命令和安全规则**

必须明确：

- 只清理配置列表、未完成、不重要、TaskForge 缓存和源都不存在的提醒；
- 六个标题前缀和 EventKit priority 保护；
- 两次扫描至少相隔 60 秒；
- `--prune-dry-run`、`--prune-once`、`--restore-last-prune`；
- 备份和候选账本路径；
- 恢复后 24 小时宽限；
- TaskForge 源任务仍只改为 `done`，绝不因清理而删除。

删除 README 原来的“不会根据 TaskForge 删除操作自动删除 Apple 提醒事项”
限制，替换为新规则，避免文档自相矛盾。

- [ ] **步骤 2：更新架构、排障、隐私、安全和 changelog**

逐文件加入规格中的固定边界。`.gitignore` 增加：

```gitignore
PruneCandidates.json
PruneBackups/
PruneHashSalt
*.prune-test.json
```

注意这些运行文件正常位于仓库外，规则用于防止用户复制调试数据后误提交。

- [ ] **步骤 3：执行文档矛盾和隐私扫描**

```bash
rg -n "不会.*删除|不自动删除|其他.*列表|prune|清理|恢复" \
  README.md docs PRIVACY.md SECURITY.md CHANGELOG.md
rg -n "/Users/[^/]+/|/var/folders/|TaskForge-Task-ID: [A-Za-z0-9+/=]{16,}" \
  README.md docs PRIVACY.md SECURITY.md CHANGELOG.md
git diff --check
```

预期：

- 旧限制已被新边界替换，没有矛盾；
- 第二条命令无输出；
- `git diff --check` 无输出。

- [ ] **步骤 4：提交公共文档**

```bash
git add .gitignore README.md docs/ARCHITECTURE.md \
  docs/TROUBLESHOOTING.md PRIVACY.md SECURITY.md CHANGELOG.md
git commit -m "docs(清理): 说明自动删除和恢复边界"
```

## 任务 9：完整验证、生产部署和 GitHub 发布

**文件：**

- 验证：全部代码、测试、文档和运行时安装
- 不创建包含私人数据的新仓库文件

- [ ] **步骤 1：运行完整本地验证**

```bash
swift run TaskForgeReminderCoreTests
swift build
TASKFORGE_RUN_EVENTKIT_TESTS=1 \
  swift run TaskForgeReminderEventKitTests
./scripts/build-app.sh
plutil -lint dist/TaskForgeReminderSync.app/Contents/Info.plist
codesign --verify --deep --strict \
  dist/TaskForgeReminderSync.app
```

预期：Core 测试全部通过、EventKit 隔离测试通过、构建成功、plist 和签名通过。

- [ ] **步骤 2：在生产列表执行匿名预演**

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --prune-dry-run
```

记录并向用户报告扫描、首次候选和 ready 数量；不得输出标题、笔记或原始 ID。
如果命令输出任何私人字段，停止部署并修复。

- [ ] **步骤 3：安装并确认第一轮只登记候选**

```bash
./scripts/install-daily-sync.sh
launchctl print \
  "gui/$(id -u)/local.codex.taskforge-reminder-sync"
tail -80 "$HOME/Library/Logs/TaskForgeReminderSync.log"
```

预期：

- LaunchAgent state 为 `running`；
- 第一轮清理 `deleted 0`；
- 日志只有数量和截断哈希；
- `PruneCandidates.json` 权限为 `600`。

- [ ] **步骤 4：等待二次确认并核对可恢复备份**

等待 watcher 的下一次每分钟兜底，随后运行：

```bash
tail -120 "$HOME/Library/Logs/TaskForgeReminderSync.log"
find "$HOME/Library/Application Support/TaskForgeReminderSync/PruneBackups" \
  -type f -exec stat -f '%Sp %N' {} \\;
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync --audit
```

预期：

- 只有连续两次符合条件的数量被删除；
- 每个删除批次先有 `-rw-------` 备份；
- audit 仍显示重复状态通过。

如果生产 dry-run 为零，接受“没有需要删除的真实候选”；不创建生产测试提醒。

- [ ] **步骤 5：检查监听、计划时间和错误日志**

```bash
rg -n "Apple 提醒事项变化|每分钟漏失兜底|7:00|11:00|15:00|清理同步" \
  "$HOME/Library/Logs/TaskForgeReminderSync.log"
tail -80 "$HOME/Library/Logs/TaskForgeReminderSync.error.log"
```

预期：新清理和原有触发均存在；错误日志没有新的未处理错误。

- [ ] **步骤 6：执行推送前隐私和 Git 检查**

```bash
git status --short --branch
git diff origin/main...HEAD --check
git diff origin/main...HEAD --name-only
git diff origin/main...HEAD -- | \
  rg -n '(/Users/[^/]+/|/var/folders/|TaskForge-Task-ID: [A-Za-z0-9+/=]{16,})'
```

预期：

- worktree 干净；
- diff 检查无错误；
- 变更文件均在计划内；
- 隐私扫描无输出。

- [ ] **步骤 7：推送当前分支并检查 GitHub Actions**

```bash
git push origin HEAD
gh run list --limit 5
```

预期：push 成功；新 workflow run 最终为 `completed success`。如果 CI 失败，
先读取失败日志并修复，不把本机 EventKit 权限测试加入云端 CI。

- [ ] **步骤 8：最终交付报告**

向用户报告：

- GitHub commit 和仓库 URL；
- Core 与隔离 EventKit 测试数量；
- 生产 dry-run、首次扫描、二次确认删除的匿名数量；
- LaunchAgent listener/PID/state；
- 备份路径与权限；
- `--restore-last-prune` 用法；
- 其他提醒列表、已完成提醒和 TaskForge 源任务保持不变的验证证据。
