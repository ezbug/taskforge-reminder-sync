import Dispatch
import Darwin
import Foundation
import TaskForgeReminderCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(
    _ condition: Bool,
    _ message: String
) throws {
    guard condition else {
        throw TestFailure(description: message)
    }
}

private func requireValue<T>(
    _ value: T?,
    _ message: String
) throws -> T {
    guard let value else {
        throw TestFailure(description: message)
    }
    return value
}

private var shanghaiCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

private typealias TestCase = (name: String, body: () throws -> Void)

private indirect enum FixtureValue {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([FixtureValue])
    case map([(FixtureValue, FixtureValue)])
}

private func encodeFixture(_ value: FixtureValue) -> Data {
    var bytes: [UInt8] = []

    func appendLength(_ value: Int, shortPrefix: UInt8, longPrefix: UInt8) {
        if value < 16 {
            bytes.append(shortPrefix | UInt8(value))
        } else {
            bytes.append(longPrefix)
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
    }

    func append(_ value: FixtureValue) {
        switch value {
        case .null:
            bytes.append(0xC0)
        case let .bool(flag):
            bytes.append(flag ? 0xC3 : 0xC2)
        case let .int(number):
            if (0...127).contains(number) {
                bytes.append(UInt8(number))
            } else {
                bytes.append(0xCD)
                bytes.append(UInt8((number >> 8) & 0xFF))
                bytes.append(UInt8(number & 0xFF))
            }
        case let .string(string):
            let utf8 = Array(string.utf8)
            if utf8.count < 32 {
                bytes.append(0xA0 | UInt8(utf8.count))
            } else if utf8.count <= 255 {
                bytes.append(0xD9)
                bytes.append(UInt8(utf8.count))
            } else {
                bytes.append(0xDA)
                bytes.append(UInt8((utf8.count >> 8) & 0xFF))
                bytes.append(UInt8(utf8.count & 0xFF))
            }
            bytes.append(contentsOf: utf8)
        case let .array(values):
            appendLength(values.count, shortPrefix: 0x90, longPrefix: 0xDC)
            values.forEach(append)
        case let .map(entries):
            appendLength(entries.count, shortPrefix: 0x80, longPrefix: 0xDE)
            for (key, value) in entries {
                append(key)
                append(value)
            }
        }
    }

    append(value)
    return Data(bytes)
}

private func taskDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int? = nil,
    minute: Int? = nil
) -> FixtureValue {
    let time: FixtureValue
    if let hour, let minute {
        time = .array([.int(hour), .int(minute)])
    } else {
        time = .null
    }
    return .array([
        .array([.int(year), .int(month), .int(day)]),
        time,
        .null,
        .null,
        .int(0),
        .bool(false),
        .bool(false)
    ])
}

private func taskRecord(
    id: String,
    title: String,
    status: String,
    scheduled: FixtureValue,
    sourceType: String = "markdownInline",
    originalLine: String? = nil,
    onCompletion: String = "keep",
    recurrence: String? = nil
) -> FixtureValue {
    var fields = Array(repeating: FixtureValue.null, count: 33)
    fields[0] = .string(id)
    fields[1] = .string(title)
    fields[3] = .array([.string(status), .null])
    fields[4] = .string("none")
    fields[12] = scheduled
    fields[18] = .string("/vault/journal/2026-07-26.md")
    fields[20] = .string(sourceType)
    fields[25] = .string(onCompletion)
    if let recurrence {
        fields[30] = .string(recurrence)
    }
    fields[31] = .string(originalLine ?? "- [ ] \(title)")
    fields[32] = .int(12)
    return .array(fields)
}

private func taskStoreFixture() -> Data {
    encodeFixture(
        .array([
            .int(6),
            .map([]),
            .int(1),
            .string("/vault"),
            .array([
                taskRecord(
                    id: "task-1",
                    title: "示例任务",
                    status: "todo",
                    scheduled: taskDate(2026, 7, 26)
                ),
                taskRecord(
                    id: "task-2",
                    title: "带时间任务",
                    status: "inProgress",
                    scheduled: taskDate(2026, 7, 26, hour: 22, minute: 45)
                ),
                taskRecord(
                    id: "task-3",
                    title: "已经完成",
                    status: "done",
                    scheduled: taskDate(2026, 7, 26)
                ),
                taskRecord(
                    id: "task-4",
                    title: "明天任务",
                    status: "todo",
                    scheduled: taskDate(2026, 7, 27)
                )
            ])
        ])
    )
}

private func pruneBackupFixture() -> ReminderPruneBackupBatch {
    ReminderPruneBackupBatch(
        identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        createdAt: Date(timeIntervalSince1970: 20),
        targetCalendarIdentifier: "calendar",
        targetCalendarTitle: "TaskForge 今日",
        targetSourceIdentifier: "source",
        backupSchemaVersion:
            ReminderPruneRestorePolicy.currentBackupSchemaVersion,
        rulesVersion: ReminderPruneStateMachine.rulesVersion,
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
                recurrenceRules: [],
                taskPresence: .absent
            )
        ],
        actuallyDeletedIdentifiers: nil,
        restoreAttemptIdentifier: nil,
        restoredItemIdentifiers: [:],
        restoredAt: nil
    )
}

private let legacyPruneBackupEnvelopeFixture = Data(
    """
    {"checksum":"386b6ec8c52714e00c16f65f69c8dbace2eff0f899613a43f6cbb467796235c1","payload":{"createdAt":-978307180,"identifier":"00000000-0000-0000-0000-0000000000A1","items":[],"restoredItemIdentifiers":{},"rulesVersion":0,"targetCalendarIdentifier":"legacy-calendar","targetCalendarTitle":"Legacy list","targetSourceIdentifier":"legacy-source"}}
    """.utf8
)

private let legacyPruneBackupUnknownPayloadFieldFixture = Data(
    """
    {"checksum":"386b6ec8c52714e00c16f65f69c8dbace2eff0f899613a43f6cbb467796235c1","payload":{"createdAt":-978307180,"identifier":"00000000-0000-0000-0000-0000000000A1","items":[],"restoredItemIdentifiers":{},"rulesVersion":0,"targetCalendarIdentifier":"legacy-calendar","targetCalendarTitle":"Legacy list","targetSourceIdentifier":"legacy-source","unknownPayloadField":"must-not-be-ignored"}}
    """.utf8
)

private func currentAccountHomeURL() throws -> URL {
    guard
        let account = getpwuid(getuid()),
        let homePath = String(
            validatingUTF8: account.pointee.pw_dir
        )
    else {
        throw TestFailure(description: "current account home is unavailable")
    }
    return URL(fileURLWithPath: homePath, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
}

private func expectedOperationLockAnchorURL() throws -> URL {
    let home = try currentAccountHomeURL()
    let candidates = [
        home.appendingPathComponent("Library/Caches", isDirectory: true),
        home.appendingPathComponent("Library", isDirectory: true),
        home
    ]
    for candidate in candidates {
        let resolved = candidate.standardizedFileURL
            .resolvingSymlinksInPath()
        var status = stat()
        guard lstat(resolved.path, &status) == 0 else {
            continue
        }
        if status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_mode & 0o077 == 0
        {
            return resolved
        }
    }
    throw TestFailure(
        description: "no deterministic private account anchor is available"
    )
}

private func taskForgeEntries(at url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path)
        .filter { $0.localizedCaseInsensitiveContains("taskforge") }
        .sorted()
}

private let tests: [TestCase] = [
    ("TaskForge v6 MessagePack store decodes task records", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        try require(snapshot.version == 6, "unexpected task store version")
        try require(snapshot.vaultPath == "/vault", "unexpected vault path")
        try require(snapshot.tasks.count == 4, "unexpected decoded task count")
        try require(snapshot.tasks[0].title == "示例任务", "unexpected first task title")
        try require(snapshot.tasks[0].sourceType == "markdownInline", "unexpected source type")
    }),
    ("today selection matches TaskForge calendar open tasks", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let today = TaskForgeDay(year: 2026, month: 7, day: 26)
        let tasks = snapshot.openTasksScheduled(on: today)

        try require(tasks.map(\.identifier) == ["task-1", "task-2"], "unexpected today tasks")
        try require(tasks[0].scheduled?.time == nil, "untimed task should be all-day")
        try require(tasks[1].scheduled?.time?.hour == 22, "unexpected scheduled hour")
        try require(tasks[1].scheduled?.time?.minute == 45, "unexpected scheduled minute")
    }),
    ("TaskForge task marker is stable and hides raw identifiers", {
        let first = TaskSyncMarker.make(vaultPath: "/vault", taskIdentifier: "task/raw")
        let same = TaskSyncMarker.make(vaultPath: "/vault", taskIdentifier: "task/raw")
        let other = TaskSyncMarker.make(vaultPath: "/vault", taskIdentifier: "task/other")

        try require(first == same, "task marker should be stable")
        try require(first != other, "different tasks need different markers")
        try require(first.hasPrefix("TaskForge-Task-ID: "), "task marker prefix missing")
        try require(!first.contains("task/raw"), "task marker should encode raw ID")
    }),
    ("TaskForge scheduled time maps to reminder due components", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let calendar = shanghaiCalendar
        let untimed = try requireValue(snapshot.tasks[0].scheduled, "missing untimed schedule")
        let timed = try requireValue(snapshot.tasks[1].scheduled, "missing timed schedule")
        let untimedComponents = TaskReminderTiming.dueDateComponents(
            for: untimed,
            calendar: calendar
        )
        let timedComponents = TaskReminderTiming.dueDateComponents(
            for: timed,
            calendar: calendar
        )

        try require(untimedComponents.day == 26, "unexpected untimed day")
        try require(untimedComponents.hour == nil, "untimed task should have no hour")
        try require(timedComponents.hour == 22, "unexpected timed hour")
        try require(timedComponents.minute == 45, "unexpected timed minute")
    }),
    ("reminder due comparison ignores EventKit calendar metadata", {
        let scheduled = TaskForgeScheduledDate(
            day: TaskForgeDay(year: 2026, month: 7, day: 27),
            time: TaskForgeTime(hour: 11, minute: 30)
        )
        let desired = TaskReminderTiming.dueDateComponents(
            for: scheduled,
            calendar: shanghaiCalendar
        )
        var stored = DateComponents()
        stored.year = 2026
        stored.month = 7
        stored.day = 27
        stored.hour = 11
        stored.minute = 30

        try require(
            ReminderDueDatePolicy.isEquivalent(stored, desired),
            "EventKit metadata differences must not trigger a write"
        )
        stored.minute = 31
        try require(
            !ReminderDueDatePolicy.isEquivalent(stored, desired),
            "a real minute change must trigger a write"
        )
    }),
    ("task marker decodes to its vault and task identifier", {
        let marker = TaskSyncMarker.make(
            vaultPath: "/vault/中文",
            taskIdentifier: "task-42"
        )
        let decoded = try requireValue(
            TaskSyncMarker.decode(marker),
            "marker should decode"
        )

        try require(decoded.vaultPath == "/vault/中文", "unexpected decoded vault")
        try require(decoded.taskIdentifier == "task-42", "unexpected decoded task ID")
    }),
    ("source identity survives TaskForge identifier and title changes", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let original = snapshot.tasks[0]
        let changed = TaskForgeTask(
            identifier: "task-reindexed",
            title: "已改名的示例任务",
            status: original.status,
            priority: original.priority,
            scheduled: original.scheduled,
            filePath: original.filePath,
            sourceType: original.sourceType,
            originalLine: "- [ ] 已改名的示例任务",
            lineNumber: original.lineNumber,
            onCompletion: original.onCompletion,
            recurrence: original.recurrence
        )

        try require(
            TaskSourceIdentity(task: original) == TaskSourceIdentity(task: changed),
            "same inline source coordinate must keep a stable identity"
        )
    }),
    ("reminder matching reuses the same reminder after TaskForge reindexing", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let original = snapshot.tasks[0]
        let changed = TaskForgeTask(
            identifier: "task-reindexed",
            title: "已改名的示例任务",
            status: original.status,
            priority: original.priority,
            scheduled: original.scheduled,
            filePath: original.filePath,
            sourceType: original.sourceType,
            originalLine: "- [ ] 已改名的示例任务",
            lineNumber: original.lineNumber,
            onCompletion: original.onCompletion,
            recurrence: original.recurrence
        )
        let sourceIdentity = try requireValue(
            TaskSourceIdentity(task: original),
            "source identity should exist"
        )
        let records = [
            TaskReminderMatchRecord(
                key: 0,
                taskIdentifier: original.identifier,
                sourceIdentity: sourceIdentity
            )
        ]

        try require(
            TaskReminderMatchPolicy.select(
                task: changed,
                records: records,
                claimedKeys: []
            ) == .source(0),
            "changed TaskForge ID should reuse the reminder at the same source"
        )
    }),
    ("reminder matching refuses ambiguous source duplicates", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let task = snapshot.tasks[0]
        let sourceIdentity = try requireValue(
            TaskSourceIdentity(task: task),
            "source identity should exist"
        )
        let records = [
            TaskReminderMatchRecord(
                key: 0,
                taskIdentifier: "old-a",
                sourceIdentity: sourceIdentity
            ),
            TaskReminderMatchRecord(
                key: 1,
                taskIdentifier: "old-b",
                sourceIdentity: sourceIdentity
            )
        ]

        try require(
            TaskReminderMatchPolicy.select(
                task: task,
                records: records,
                claimedKeys: []
            ) == .ambiguous,
            "ambiguous reminders must not create another duplicate"
        )
    }),
    ("reminder matching ignores completed history from another occurrence", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let task = snapshot.tasks[0]
        let sourceIdentity = try requireValue(
            TaskSourceIdentity(task: task),
            "source identity should exist"
        )
        let records = [
            TaskReminderMatchRecord(
                key: 0,
                taskIdentifier: "historical-task",
                sourceIdentity: sourceIdentity,
                reminderIsCompleted: true,
                scheduledDay: TaskForgeDay(year: 2026, month: 7, day: 25)
            )
        ]

        try require(
            TaskReminderMatchPolicy.select(
                task: task,
                records: records,
                claimedKeys: []
            ) == .none,
            "a completed historical occurrence must not capture today's task"
        )
    }),
    ("reminder matching retains a completed reminder for the same occurrence", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let task = snapshot.tasks[0]
        let sourceIdentity = try requireValue(
            TaskSourceIdentity(task: task),
            "source identity should exist"
        )
        let records = [
            TaskReminderMatchRecord(
                key: 0,
                taskIdentifier: "reindexed-task",
                sourceIdentity: sourceIdentity,
                reminderIsCompleted: true,
                scheduledDay: task.scheduled?.day
            )
        ]

        try require(
            TaskReminderMatchPolicy.select(
                task: task,
                records: records,
                claimedKeys: []
            ) == .source(0),
            "same-day completion should stay attached after reindexing"
        )
    }),
    ("reminder audit counts duplicate marker and source groups", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let firstIdentity = try requireValue(
            TaskSourceIdentity(task: snapshot.tasks[0]),
            "first source identity should exist"
        )
        let secondIdentity = try requireValue(
            TaskSourceIdentity(task: snapshot.tasks[1]),
            "second source identity should exist"
        )
        let report = TaskReminderAuditPolicy.analyze([
            TaskReminderAuditRecord(
                taskIdentifier: "task-a",
                sourceIdentity: firstIdentity
            ),
            TaskReminderAuditRecord(
                taskIdentifier: "task-a",
                sourceIdentity: firstIdentity
            ),
            TaskReminderAuditRecord(
                taskIdentifier: "task-b",
                sourceIdentity: secondIdentity
            ),
            TaskReminderAuditRecord(
                taskIdentifier: "task-c",
                sourceIdentity: nil
            )
        ])

        try require(report.managedReminderCount == 4, "unexpected audit total")
        try require(
            report.duplicateTaskIdentifierGroups == 1,
            "duplicate marker group should be reported"
        )
        try require(
            report.duplicateActiveSourceIdentityGroups == 1,
            "duplicate active source group should be reported"
        )
        try require(
            report.missingSourceIdentityCount == 1,
            "missing source reference should be reported"
        )
        try require(!report.isDuplicateFree, "duplicate audit must fail")
    }),
    ("reminder audit separates completed historical source reuse", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let sourceIdentity = try requireValue(
            TaskSourceIdentity(task: snapshot.tasks[0]),
            "source identity should exist"
        )
        let report = TaskReminderAuditPolicy.analyze([
            TaskReminderAuditRecord(
                taskIdentifier: "history-a",
                sourceIdentity: sourceIdentity,
                isCompleted: true,
                scheduledDay: TaskForgeDay(year: 2026, month: 7, day: 25)
            ),
            TaskReminderAuditRecord(
                taskIdentifier: "history-b",
                sourceIdentity: sourceIdentity,
                isCompleted: true,
                scheduledDay: TaskForgeDay(year: 2026, month: 7, day: 26)
            )
        ])

        try require(
            report.duplicateActiveSourceIdentityGroups == 0,
            "completed history must not count as an active duplicate"
        )
        try require(
            report.duplicateCompletedOccurrenceGroups == 0,
            "different scheduled days are different historical occurrences"
        )
        try require(
            report.historicalSourceReuseGroups == 1,
            "historical source reuse should remain visible"
        )
        try require(report.isDuplicateFree, "historical reuse should pass audit")
    }),
    ("deduplication plan preserves current exact reminder and archives extras", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let sourceIdentity = try requireValue(
            TaskSourceIdentity(task: snapshot.tasks[0]),
            "source identity should exist"
        )
        let plan = TaskReminderDeduplicationPolicy.plan(
            records: [
                TaskReminderDeduplicationRecord(
                    key: 0,
                    taskIdentifier: "stale-a",
                    sourceIdentity: sourceIdentity,
                    creationTimestamp: 10
                ),
                TaskReminderDeduplicationRecord(
                    key: 1,
                    taskIdentifier: "task-1",
                    sourceIdentity: sourceIdentity,
                    creationTimestamp: 20
                ),
                TaskReminderDeduplicationRecord(
                    key: 2,
                    taskIdentifier: "stale-b",
                    sourceIdentity: sourceIdentity,
                    creationTimestamp: 5
                )
            ],
            currentTaskIdentifiers: ["task-1"]
        )

        try require(plan.duplicateGroups == 1, "unexpected duplicate group count")
        try require(plan.preservedKeys == [1], "current exact reminder must win")
        try require(plan.archiveKeys == [0, 2], "stale reminders should be archived")
    }),
    ("deduplication plan falls back to the oldest reminder", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let sourceIdentity = try requireValue(
            TaskSourceIdentity(task: snapshot.tasks[0]),
            "source identity should exist"
        )
        let plan = TaskReminderDeduplicationPolicy.plan(
            records: [
                TaskReminderDeduplicationRecord(
                    key: 4,
                    taskIdentifier: "stale-newer",
                    sourceIdentity: sourceIdentity,
                    creationTimestamp: 20
                ),
                TaskReminderDeduplicationRecord(
                    key: 3,
                    taskIdentifier: "stale-older",
                    sourceIdentity: sourceIdentity,
                    creationTimestamp: 10
                )
            ],
            currentTaskIdentifiers: []
        )

        try require(plan.preservedKeys == [3], "oldest reminder should be preserved")
        try require(plan.archiveKeys == [4], "newer duplicate should be archived")
    }),
    ("TaskNotes source identity ignores frontmatter line movement", {
        let first = TaskForgeTask(
            identifier: "note-a",
            title: "任务笔记",
            status: "todo",
            priority: nil,
            scheduled: nil,
            filePath: "/vault/TaskNotes/Tasks/note.md",
            sourceType: "taskNotes",
            originalLine: "tasknotes:{}",
            lineNumber: 1
        )
        let moved = TaskForgeTask(
            identifier: "note-b",
            title: "任务笔记（改名）",
            status: "todo",
            priority: nil,
            scheduled: nil,
            filePath: "/vault/TaskNotes/Tasks/note.md",
            sourceType: "taskNotes",
            originalLine: "tasknotes:{}",
            lineNumber: 8
        )

        try require(
            TaskSourceIdentity(task: first) == TaskSourceIdentity(task: moved),
            "TaskNotes should be identified by its file, not a frontmatter line"
        )
    }),
    ("inline completion checks the exact source task and adds completion date", {
        let task = TaskForgeTask(
            identifier: "task-inline",
            title: "示例任务",
            status: "todo",
            priority: nil,
            scheduled: TaskForgeScheduledDate(
                day: TaskForgeDay(year: 2026, month: 7, day: 26),
                time: nil
            ),
            filePath: "/vault/journal/2026-07-26.md",
            sourceType: "markdownInline",
            originalLine: "\t- [ ] 示例任务",
            lineNumber: 2,
            onCompletion: "keep",
            recurrence: nil
        )
        let source = "heading\n\t- [ ] 示例任务\nnext\n"
        let edit = try TaskCompletionEditor.complete(
            task: task,
            contents: source,
            on: TaskForgeDay(year: 2026, month: 7, day: 26)
        )

        try require(edit.lineNumber == 2, "unexpected edited line")
        try require(
            edit.updatedContents == "heading\n\t- [x] 示例任务 ✅ 2026-07-26\nnext\n",
            "unexpected inline completion edit"
        )
    }),
    ("TaskNotes completion updates status and completedDate", {
        let task = TaskForgeTask(
            identifier: "task-note",
            title: "任务笔记",
            status: "todo",
            priority: nil,
            scheduled: nil,
            filePath: "/vault/TaskNotes/Tasks/任务笔记.md",
            sourceType: "taskNotes",
            originalLine: "tasknotes:{}",
            lineNumber: 1,
            onCompletion: "keep",
            recurrence: nil
        )
        let source = """
        ---
        status: open
        priority: medium
        completedDate: 2026-07-20
        ---
        body
        """
        let edit = try TaskCompletionEditor.complete(
            task: task,
            contents: source,
            on: TaskForgeDay(year: 2026, month: 7, day: 26)
        )

        try require(edit.updatedContents.contains("status: done"), "status not updated")
        try require(
            edit.updatedContents.contains("completedDate: 2026-07-26"),
            "completion date not updated"
        )
        try require(
            !edit.updatedContents.contains("completedDate: 2026-07-20"),
            "old completion date remains"
        )
    }),
    ("completion refuses recurring tasks", {
        let task = TaskForgeTask(
            identifier: "recurring",
            title: "每天任务",
            status: "todo",
            priority: nil,
            scheduled: nil,
            filePath: "/vault/daily.md",
            sourceType: "markdownInline",
            originalLine: "- [ ] 每天任务",
            lineNumber: 1,
            onCompletion: "keep",
            recurrence: "every day"
        )
        do {
            _ = try TaskCompletionEditor.complete(
                task: task,
                contents: "- [ ] 每天任务\n",
                on: TaskForgeDay(year: 2026, month: 7, day: 26)
            )
            throw TestFailure(description: "recurring task should be refused")
        } catch let error as TaskCompletionEditorError {
            try require(error == .recurringTaskUnsupported, "unexpected refusal reason")
        }
    }),
    ("completion refuses stale or ambiguous inline source", {
        let task = TaskForgeTask(
            identifier: "stale",
            title: "同名任务",
            status: "todo",
            priority: nil,
            scheduled: nil,
            filePath: "/vault/tasks.md",
            sourceType: "markdownInline",
            originalLine: "- [ ] 同名任务",
            lineNumber: 2,
            onCompletion: "keep",
            recurrence: nil
        )
        do {
            _ = try TaskCompletionEditor.complete(
                task: task,
                contents: "- [ ] 同名任务\nchanged\n- [ ] 同名任务\n",
                on: TaskForgeDay(year: 2026, month: 7, day: 26)
            )
            throw TestFailure(description: "ambiguous source should be refused")
        } catch let error as TaskCompletionEditorError {
            try require(error == .sourceLineNotUnique, "unexpected stale-source reason")
            try require(
                error.isSafeUnattendedSkip,
                "stale source refusal should be a non-failing unattended skip"
            )
        }
    }),
    ("forward completion policy never reopens an Apple-completed reminder", {
        try require(
            ReminderCompletionPolicy.desiredCompletion(
                taskIsCompleted: false,
                reminderIsCompleted: true
            ),
            "Apple-completed reminder must stay completed"
        )
        try require(
            ReminderCompletionPolicy.desiredCompletion(
                taskIsCompleted: true,
                reminderIsCompleted: false
            ),
            "TaskForge-completed task must complete reminder"
        )
    }),
    ("readback accepts a completed inline task disappearing from refreshed cache", {
        let initial = try TaskForgeTaskStore.decode(taskStoreFixture())
        let original = initial.tasks[0]
        let refreshed = TaskForgeSnapshot(
            version: initial.version,
            vaultPath: initial.vaultPath,
            tasks: initial.tasks.filter { $0.identifier != original.identifier }
        )

        try require(
            TaskCompletionReadback.confirmsCompletion(
                of: original,
                in: refreshed.tasks
            ),
            "a removed inline task should confirm completion"
        )
        try require(
            !TaskCompletionReadback.confirmsCompletion(
                of: original,
                in: initial.tasks
            ),
            "an unchanged open task must not confirm completion"
        )
    }),
    ("reminder source reference round-trips after TaskForge cache eviction", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let original = snapshot.tasks[0]
        let reference = TaskSourceReference(task: original)
        let notes = "来源：TaskForge\n\(reference.encodedLine)"
        let decoded = try requireValue(
            TaskSourceReference.decode(from: notes),
            "source reference should decode"
        )

        try require(decoded == reference, "source reference changed during round-trip")
        let resolved = try requireValue(
            TaskSourceReference.resolveTask(
                markerTaskIdentifier: original.identifier,
                snapshotTasks: [],
                reminderNotes: notes
            ),
            "evicted task should resolve from reminder metadata"
        )
        try require(resolved == original, "resolved historical task differs from source")
    }),
    ("completed source inspector skips an already completed historical task", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        let task = snapshot.tasks[0]
        let source = (
            Array(repeating: "filler", count: 11)
                + ["- [x] 示例任务 ✅ 2026-07-26"]
        ).joined(separator: "\n")

        try require(
            TaskCompletionSourceInspector.isCompleted(
                task: task,
                contents: source
            ),
            "completed historical source should be recognized"
        )
    }),
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
    }),
    ("source presence fails closed for missing or unknown source metadata", {
        let cases = [
            TaskForgeTask(
                identifier: "missing-line",
                title: "保留任务",
                status: "todo",
                priority: nil,
                scheduled: nil,
                filePath: "/vault/note.md",
                sourceType: "markdownInline",
                originalLine: nil,
                lineNumber: 1
            ),
            TaskForgeTask(
                identifier: "missing-type",
                title: "保留任务",
                status: "todo",
                priority: nil,
                scheduled: nil,
                filePath: "/vault/note.md",
                sourceType: nil,
                originalLine: "- [ ] 保留任务",
                lineNumber: 1
            ),
            TaskForgeTask(
                identifier: "unknown-type",
                title: "保留任务",
                status: "todo",
                priority: nil,
                scheduled: nil,
                filePath: "/vault/note.md",
                sourceType: "unsupported",
                originalLine: "- [ ] 保留任务",
                lineNumber: 1
            )
        ]
        for task in cases {
            try require(
                TaskSourcePresenceInspector.inspect(
                    task: task,
                    contents: "- [ ] 保留任务\n"
                ) == .indeterminate,
                "\(task.identifier) must fail closed"
            )
        }
    }),
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
    }),
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
    ("prune state clamps custom confirmation intervals to sixty seconds", {
        let now = Date(timeIntervalSince1970: 2_500)
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
            now: now
        )
        for confirmationInterval: TimeInterval in [0, 59] {
            let early = ReminderPruneStateMachine.plan(
                observations: [observation],
                prior: first.nextLedger,
                targetCalendarIdentifier: "calendar-target",
                now: now.addingTimeInterval(59),
                confirmationInterval: confirmationInterval
            )
            try require(
                early.readyIdentifiers.isEmpty,
                "\(confirmationInterval) seconds must not bypass confirmation"
            )
        }
        let ready = ReminderPruneStateMachine.plan(
            observations: [observation],
            prior: first.nextLedger,
            targetCalendarIdentifier: "calendar-target",
            now: now.addingTimeInterval(60),
            confirmationInterval: 0
        )
        try require(
            ready.readyIdentifiers == ["external"],
            "clamped interval should allow readiness at sixty seconds"
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
    }),
    ("legacy prune backup verifies old checksum before migration", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let url = try store.saveBackup(pruneBackupFixture())
        try legacyPruneBackupEnvelopeFixture.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let migrated = try store.loadBackup(at: url)
        try require(
            migrated.backupSchemaVersion
                == ReminderPruneRestorePolicy.currentBackupSchemaVersion,
            "legacy backup did not migrate to schema 1"
        )
        try require(
            migrated.rulesVersion == 0
                && migrated.targetCalendarTitle == "Legacy list",
            "legacy payload fields changed during migration"
        )

        let tampered = String(
            data: legacyPruneBackupEnvelopeFixture,
            encoding: .utf8
        )!.replacingOccurrences(
            of: "Legacy list",
            with: "Tampered list"
        )
        try Data(tampered.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        do {
            _ = try store.loadBackup(at: url)
            throw TestFailure(
                description: "tampered legacy backup was accepted"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .checksumMismatch,
                "unexpected legacy checksum error"
            )
        }
    }),
    ("legacy prune backup rejects an unknown payload field", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let url = try store.saveBackup(pruneBackupFixture())
        try legacyPruneBackupUnknownPayloadFieldFixture.write(
            to: url,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )

        do {
            _ = try store.loadBackup(at: url)
            throw TestFailure(
                description: "unknown legacy payload field was accepted"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .checksumMismatch,
                "unexpected unknown legacy field error"
            )
        }
    }),
    ("restore policy separates backup schema from candidate rules", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        var legacyRulesBackup = pruneBackupFixture()
        legacyRulesBackup.rulesVersion = 0
        let url = try store.saveBackup(legacyRulesBackup)
        let loaded = try store.loadBackup(at: url)
        try require(
            ReminderPruneRestorePolicy.supportsBackupSchema(
                loaded.backupSchemaVersion
            ),
            "supported schema must remain restorable"
        )
        try require(
            !ReminderPruneRestorePolicy.supportsBackupSchema(
                loaded.backupSchemaVersion + 1
            ),
            "unknown backup schema must be rejected"
        )
        try require(
            loaded.rulesVersion == 0,
            "candidate rules version must remain audit data"
        )
        let now = Date(timeIntervalSince1970: 100)
        let entry = ReminderPruneRestorePolicy.graceLedgerEntry(
            fingerprint: "restored",
            calendarIdentifier: "calendar",
            now: now,
            restoreGraceInterval: 1
        )
        try require(
            entry.rulesVersion == ReminderPruneStateMachine.rulesVersion,
            "restored grace must use current candidate rules"
        )
        try require(
            entry.graceUntil == now.addingTimeInterval(86_400),
            "restored grace must remain at least 24 hours"
        )
    }),
    ("prune operation flock does not change the filesystem tree", {
        let defaultAnchor =
            try ReminderPruneOperationFileLock.defaultAnchorURL()
        let expectedDefaultAnchor = try expectedOperationLockAnchorURL()
        try require(
            defaultAnchor == expectedDefaultAnchor,
            "operation lock anchor must be deterministic from account home"
        )
        var defaultBeforeStatus = stat()
        try require(
            lstat(defaultAnchor.path, &defaultBeforeStatus) == 0,
            "default operation lock anchor is unavailable"
        )
        try require(
            defaultBeforeStatus.st_uid == getuid()
                && defaultBeforeStatus.st_mode & S_IFMT == S_IFDIR
                && defaultBeforeStatus.st_mode & 0o077 == 0,
            "default operation lock anchor must be a private owned directory"
        )
        let defaultTaskForgeEntriesBefore =
            try taskForgeEntries(at: defaultAnchor)
        let defaultShared = try ReminderPruneOperationFileLock(
            exclusive: false
        )
        defaultShared.unlock()
        let defaultExclusive = try ReminderPruneOperationFileLock(
            exclusive: true
        )
        defaultExclusive.unlock()
        var defaultAfterStatus = stat()
        try require(
            lstat(defaultAnchor.path, &defaultAfterStatus) == 0
                && defaultAfterStatus.st_dev == defaultBeforeStatus.st_dev
                && defaultAfterStatus.st_ino == defaultBeforeStatus.st_ino
                && defaultAfterStatus.st_uid == defaultBeforeStatus.st_uid
                && defaultAfterStatus.st_mode & 0o777
                    == defaultBeforeStatus.st_mode & 0o777,
            "default flock must retain its private anchor inode"
        )
        try require(
            try taskForgeEntries(at: defaultAnchor)
                == defaultTaskForgeEntriesBefore,
            "default flock must not create a TaskForge path"
        )
        do {
            _ = try ReminderPruneOperationFileLock(
                exclusive: false,
                anchorURL: URL(
                    fileURLWithPath: "/tmp",
                    isDirectory: true
                )
            )
            throw TestFailure(
                description: "system temp anchor should be rejected"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .permissions,
                "unexpected system temp anchor error"
            )
        }

        let anchor = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: anchor) }
        try FileManager.default.createDirectory(
            at: anchor,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let before = try FileManager.default.contentsOfDirectory(
            atPath: anchor.path
        ).sorted()
        let shared = try ReminderPruneOperationFileLock(
            exclusive: false,
            anchorURL: anchor
        )
        shared.unlock()
        let exclusive = try ReminderPruneOperationFileLock(
            exclusive: true,
            anchorURL: anchor
        )
        exclusive.unlock()
        let after = try FileManager.default.contentsOfDirectory(
            atPath: anchor.path
        ).sorted()
        try require(before == after, "flock must not create a lock path")
    }),
    ("prune operation flock rejects a non-private owned anchor", {
        let anchor = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: anchor) }
        try FileManager.default.createDirectory(
            at: anchor,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o750]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o750],
            ofItemAtPath: anchor.path
        )

        do {
            _ = try ReminderPruneOperationFileLock(
                exclusive: false,
                anchorURL: anchor
            )
            throw TestFailure(
                description: "non-private operation anchor was accepted"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .permissions,
                "unexpected non-private anchor error"
            )
        }
    }),
    ("prune read-only ledger load never creates its root", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        try require(
            try store.loadLedgerReadOnly() == ReminderPruneLedger(),
            "missing read-only ledger should be empty"
        )
        try require(
            !FileManager.default.fileExists(atPath: root.path),
            "read-only ledger load must not create its root"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try require(
            try store.loadLedgerReadOnly() == ReminderPruneLedger(),
            "missing read-only ledger should remain empty"
        )
        try require(
            !FileManager.default.fileExists(atPath: store.ledgerURL.path),
            "read-only ledger load must not create the ledger"
        )
    }),
    ("prune backup persists deletion and idempotent restore readback", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        var batch = pruneBackupFixture()
        var notDeleted = batch.items[0]
        notDeleted.originalItemIdentifier = "not-deleted"
        batch.items.append(notDeleted)
        let url = try store.saveBackup(batch)
        try store.recordActuallyDeletedIdentifiers(["item"], at: url)
        let firstAttempt = try store.beginRestoreAttempt(at: url)
        let secondAttempt = try store.beginRestoreAttempt(at: url)
        try require(
            firstAttempt.restoreAttemptIdentifier
                == secondAttempt.restoreAttemptIdentifier,
            "restore attempt must be stable across retries"
        )
        try store.recordRestoreReadback(
            ["item": "restored-item"],
            at: url
        )
        let loaded = try store.loadBackup(at: url)
        try require(
            loaded.actuallyDeletedIdentifiers == ["item"],
            "actual deletion result did not persist"
        )
        try require(
            loaded.actuallyDeletedItems?.map(\.originalItemIdentifier)
                == ["item"],
            "restore selection must exclude attempted but retained items"
        )
        try require(
            loaded.restoredItemIdentifiers == ["item": "restored-item"],
            "restore readback did not persist"
        )
        do {
            try store.recordActuallyDeletedIdentifiers([], at: url)
            throw TestFailure(
                description: "deletion result overwrite should fail"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .invalidBackup,
                "unexpected deletion overwrite error"
            )
        }
        do {
            try store.recordRestoreReadback(
                ["item": "different-restored-item"],
                at: url
            )
            throw TestFailure(
                description: "restore readback overwrite should fail"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .invalidBackup,
                "unexpected restore overwrite error"
            )
        }
    }),
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

        let rootPermissions = try requireValue(
            FileManager.default.attributesOfItem(
                atPath: root.path
            )[.posixPermissions] as? NSNumber,
            "root permissions missing"
        )
        try require(rootPermissions.intValue & 0o777 == 0o700, "root must be 0700")

        let batch = pruneBackupFixture()
        let url = try store.saveBackup(batch)
        let loadedBatch = try store.loadBackup(at: url)
        try require(loadedBatch == batch, "backup verification failed")
        try require(
            loadedBatch.targetSourceIdentifier == "source",
            "backup source identifier round-trip failed"
        )
        try require(
            loadedBatch.backupSchemaVersion
                == ReminderPruneRestorePolicy.currentBackupSchemaVersion,
            "backup schema version round-trip failed"
        )
        try require(
            loadedBatch.rulesVersion
                == ReminderPruneStateMachine.rulesVersion,
            "backup rules version round-trip failed"
        )
        try require(
            loadedBatch.items.first?.taskPresence == .absent,
            "backup task presence round-trip failed"
        )
    }),
    ("prune local store rejects a modified backup", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let url = try store.saveBackup(pruneBackupFixture())
        let object = try requireValue(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any],
            "backup envelope should be JSON"
        )
        var modified = object
        var payload = try requireValue(
            object["payload"] as? [String: Any],
            "backup payload should be an object"
        )
        payload["targetCalendarTitle"] = "tampered"
        modified["payload"] = payload
        try JSONSerialization.data(
            withJSONObject: modified,
            options: [.sortedKeys]
        ).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        do {
            _ = try store.loadBackup(at: url)
            throw TestFailure(description: "tampered backup was accepted")
        } catch let error as ReminderPruneStoreError {
            try require(error == .checksumMismatch, "unexpected store error")
        }
    }),
    ("prune local store refuses insecure overwrite before replacing the ledger", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let original = ReminderPruneLedger(entries: [:])
        let replacement = ReminderPruneLedger(entries: [
            "item": ReminderPruneLedgerEntry(
                firstSeen: Date(timeIntervalSince1970: 100),
                fingerprint: "replacement",
                calendarIdentifier: "calendar",
                rulesVersion: 1,
                graceUntil: nil
            )
        ])
        try store.saveLedger(original)
        let originalData = try Data(contentsOf: store.ledgerURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: store.ledgerURL.path
        )

        do {
            try store.saveLedger(replacement)
            throw TestFailure(description: "insecure ledger was overwritten")
        } catch let error as ReminderPruneStoreError {
            try require(error == .permissions, "unexpected overwrite error")
        }
        try require(
            try Data(contentsOf: store.ledgerURL) == originalData,
            "insecure ledger contents changed before rejection"
        )
        let permissions = try requireValue(
            FileManager.default.attributesOfItem(
                atPath: store.ledgerURL.path
            )[.posixPermissions] as? NSNumber,
            "ledger permissions missing"
        )
        try require(
            permissions.intValue & 0o777 == 0o644,
            "insecure ledger permissions changed before rejection"
        )
    }),
    ("prune local store fails closed for corrupt ledger and backup inventory", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        try store.saveLedger(ReminderPruneLedger())
        try Data("not ledger json".utf8).write(to: store.ledgerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: store.ledgerURL.path
        )
        do {
            _ = try store.loadLedger()
            throw TestFailure(description: "corrupt ledger returned an empty ledger")
        } catch let error as ReminderPruneStoreError {
            try require(error == .invalidLedger, "unexpected corrupt ledger error")
        }

        let backupURL = try store.saveBackup(pruneBackupFixture())
        try Data("not backup json".utf8).write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
        do {
            _ = try store.latestUnrestoredBackup()
            throw TestFailure(description: "corrupt backup was ignored")
        } catch let error as ReminderPruneStoreError {
            try require(error == .checksumMismatch, "unexpected corrupt backup error")
        }
    }),
    ("prune local store preserves restored backups and private runtime permissions", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let backupURL = try store.saveBackup(pruneBackupFixture())
        let restoredAt = Date(timeIntervalSince1970: 99)
        try store.recordActuallyDeletedIdentifiers(["item"], at: backupURL)
        _ = try store.beginRestoreAttempt(at: backupURL)
        try store.recordRestoreReadback(
            ["item": "restored-item"],
            at: backupURL
        )
        try store.markRestored(at: backupURL, date: restoredAt)
        try require(
            try store.loadBackup(at: backupURL).restoredAt == restoredAt,
            "restored backup must still verify"
        )
        try require(
            try store.latestUnrestoredBackup() == nil,
            "restored backup must not remain latest unrestored"
        )

        let salt = try store.loadOrCreateHashSalt()
        try require(salt.count == 32, "salt must be 32 bytes")
        try require(salt == store.loadOrCreateHashSalt(), "salt should be reused")
        for (url, expected) in [
            (root, 0o700),
            (backupURL.deletingLastPathComponent(), 0o700),
            (backupURL, 0o600),
            (root.appendingPathComponent("PruneHashSalt"), 0o600)
        ] {
            let permissions = try requireValue(
                FileManager.default.attributesOfItem(
                    atPath: url.path
                )[.posixPermissions] as? NSNumber,
                "permissions missing for \(url.lastPathComponent)"
            )
            try require(
                permissions.intValue & 0o777 == expected,
                "unexpected permissions for \(url.lastPathComponent)"
            )
        }
    }),
    ("prune local stores create one shared hash salt across instances", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = (0..<32).map { _ in
            ReminderPruneLocalStore(rootURL: root)
        }
        let queue = DispatchQueue(label: "prune-salt", attributes: .concurrent)
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var salts: [Data] = []
        var failures: [String] = []

        for index in stores.indices {
            group.enter()
            queue.async {
                start.wait()
                do {
                    let salt = try stores[index].loadOrCreateHashSalt()
                    lock.lock()
                    salts.append(salt)
                    lock.unlock()
                } catch {
                    lock.lock()
                    failures.append(String(describing: error))
                    lock.unlock()
                }
                group.leave()
            }
        }
        for _ in 0..<32 {
            start.signal()
        }
        group.wait()

        try require(
            failures.isEmpty,
            "concurrent salt creation failed: \(failures)"
        )
        try require(salts.count == 32, "missing concurrent salt result")
        try require(
            salts.dropFirst().allSatisfy { $0 == salts[0] },
            "concurrent callers received different salts"
        )
        try require(
            try ReminderPruneLocalStore(rootURL: root).loadOrCreateHashSalt()
                == salts[0],
            "persisted salt differs from concurrent callers"
        )
    })
]

@main
private struct TestRunner {
    static func main() {
        var failures = 0
        for test in tests {
            do {
                try test.body()
                print("PASS  \(test.name)")
            } catch {
                failures += 1
                print("FAIL  \(test.name): \(error)")
            }
        }
        print("\n\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 {
            exit(1)
        }
    }
}
