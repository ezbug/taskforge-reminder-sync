import CoreLocation
import CryptoKit
import Dispatch
import Darwin
import EventKit
import Foundation
import TaskForgeReminderCore
@testable import TaskForgeReminderEventKit

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

private final class AsyncTestResultBox<Value>: @unchecked Sendable {
    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private let lock = NSLock()
    private var result: Result<Value, Error>?
}

private final class LockedCounter: @unchecked Sendable {
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private let lock = NSLock()
    private var count = 0
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func read() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    private let lock = NSLock()
    private var values: [Value] = []
}

private final class ScheduledCallbackBox: @unchecked Sendable {
    func store(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func call() throws {
        lock.lock()
        let callback = self.callback
        lock.unlock()
        try require(
            callback != nil,
            "scheduled callback was not registered"
        )
        callback?()
    }

    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
}

private func waitForAsync<Value>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let resultBox = AsyncTestResultBox<Value>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            resultBox.store(.success(try await operation()))
        } catch {
            resultBox.store(.failure(error))
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 5) == .success else {
        throw TestFailure(description: "async unit test timed out")
    }
    return try requireValue(
        resultBox.take(),
        "async unit test produced no result"
    ).get()
}

private func addReadOnlyExtendedACL(to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "everyone allow read", url.path]
    let standardError = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        throw TestFailure(
            description: "could not create ACL fixture: \(message)"
        )
    }
}

private func permissions(at url: URL) throws -> Int {
    let value = try requireValue(
        FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber,
        "permissions missing for \(url.lastPathComponent)"
    )
    return value.intValue & 0o777
}

private struct LegacySourceBackupFixture {
    let backupsRoot: URL
    let directories: [URL]
    let files: [URL]
}

private struct RuntimeTreeEvidence: Equatable {
    var directoryCount = 0
    var fileCount = 0
    var fileHashes: [String: String] = [:]
}

private func makeLegacySourceBackupFixture(
    root: URL,
    rootPermissions: Int
) throws -> LegacySourceBackupFixture {
    let backups = root.appendingPathComponent("Backups", isDirectory: true)
    let batchA = backups.appendingPathComponent("batch-a", isDirectory: true)
    let nested = batchA.appendingPathComponent("nested", isDirectory: true)
    let batchB = backups.appendingPathComponent("batch-b", isDirectory: true)
    let batchC = backups.appendingPathComponent("batch-c", isDirectory: true)
    let directories = [root, backups, batchA, nested, batchB, batchC]
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: batchB,
        withIntermediateDirectories: false
    )
    try FileManager.default.createDirectory(
        at: batchC,
        withIntermediateDirectories: false
    )
    for directory in directories {
        try FileManager.default.setAttributes(
            [
                .posixPermissions:
                    directory == root ? rootPermissions : 0o755
            ],
            ofItemAtPath: directory.path
        )
    }

    let files = [
        backups.appendingPathComponent("manifest.bak"),
        batchA.appendingPathComponent("one.bak"),
        nested.appendingPathComponent("two.bak"),
        batchB.appendingPathComponent("three.bak"),
        batchC.appendingPathComponent("four.bak")
    ]
    for (index, file) in files.enumerated() {
        try Data("legacy-\(index)".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path
        )
    }
    return LegacySourceBackupFixture(
        backupsRoot: backups,
        directories: directories,
        files: files
    )
}

private func runtimeTreeEvidence(at root: URL) throws
    -> RuntimeTreeEvidence
{
    var evidence = RuntimeTreeEvidence()

    func visit(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw TestFailure(
                description: "could not inspect \(url.lastPathComponent)"
            )
        }
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            evidence.directoryCount += 1
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
            for child in children.sorted(by: { $0.path < $1.path }) {
                try visit(child)
            }
        case S_IFREG:
            evidence.fileCount += 1
            let relative = String(
                url.path.dropFirst(root.path.count)
            )
            evidence.fileHashes[relative] = SHA256.hash(
                data: try Data(contentsOf: url)
            ).map { String(format: "%02x", $0) }.joined()
        default:
            throw TestFailure(
                description: "unexpected node in evidence tree"
            )
        }
    }

    try visit(root)
    return evidence
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

private func taskStoreFixture(
    extraRecord: FixtureValue? = nil,
    trailingRecord: FixtureValue? = nil
) -> Data {
    let root = encodeFixture(
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
                ),
                // A live v6 store can retain scalar `1` tombstones.
                .int(1)
            ] + (extraRecord.map { [$0] } ?? []))
        ])
    )
    guard let trailingRecord else { return root }
    return root + encodeFixture(trailingRecord)
}

private func pruneBackupFixture(
    identifier: UUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!,
    createdAt: Date = Date(timeIntervalSince1970: 20),
    actuallyDeletedIdentifiers: [String]? = nil
) -> ReminderPruneBackupBatch {
    ReminderPruneBackupBatch(
        identifier: identifier,
        createdAt: createdAt,
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
        actuallyDeletedIdentifiers: actuallyDeletedIdentifiers,
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

private func kanbanTask(
    identifier: String,
    status: String,
    line: String,
    fileName: String = "Today.md",
    tags: [String] = []
) -> TaskForgeTask {
    TaskForgeTask(
        identifier: identifier,
        title: identifier,
        status: status,
        priority: "medium",
        scheduled: nil,
        filePath: "/vault/\(fileName)",
        sourceType: "markdownInline",
        originalLine: line,
        lineNumber: 1,
        tags: tags,
        fileName: fileName
    )
}

private let tests: [TestCase] = [
    ("custom Kanban filters preserve group and condition logic", {
        let statusCondition = try TaskForgeFilterCondition(
            type: "status",
            operator: "not_equals",
            value: "TaskStatus.done"
        )
        let fileCondition = try TaskForgeFilterCondition(
            type: "file_name",
            operator: "contains",
            value: "Today"
        )
        let tagCondition = try TaskForgeFilterCondition(
            type: "tag",
            operator: "contains",
            value: "keep"
        )
        let list = try TaskForgeCustomList(
            id: "list",
            name: "Today",
            filterGroups: [
                try TaskForgeFilterGroup(
                    conditions: [statusCondition, fileCondition],
                    matchMode: "all"
                ),
                try TaskForgeFilterGroup(
                    conditions: [tagCondition],
                    matchMode: "all"
                )
            ],
            filterGroupsMatchMode: "any",
            kanbanMode: true
        )
        let tasks = [
            kanbanTask(
                identifier: "first",
                status: "todo",
                line: "- [ ] first"
            ),
            kanbanTask(
                identifier: "second",
                status: "done",
                line: "- [x] second"
            ),
            kanbanTask(
                identifier: "third",
                status: "todo",
                line: "- [ ] third",
                fileName: "Other.md",
                tags: ["keep"]
            )
        ]
        let selected = try TaskForgeFilterEvaluator.select(
            tasks: tasks,
            list: list,
            calendar: Calendar(identifier: .gregorian)
        )
        try require(
            selected.map(\.identifier) == ["first", "third"],
            "custom list group logic selected the wrong tasks"
        )
    }),
    ("custom Kanban rejects unknown fields and operators", {
        let unknownField = Data(
            """
            {"id":"list","name":"Today","filterGroups":[{"conditions":[{"type":"unknown","operator":"equals"}],"matchMode":"all"}],"filterGroupsMatchMode":"all","kanbanMode":true}
            """.utf8
        )
        do {
            _ = try TaskForgeListConfigurationStore.decode(jsonData: unknownField)
            throw TestFailure(description: "unknown field was accepted")
        } catch let error as TaskForgeFilterConfigurationError {
            try require(
                error == .unsupportedField("unknown"),
                "unexpected unknown field error"
            )
        }

        let unknownOperator = Data(
            """
            {"id":"list","name":"Today","filterGroups":[{"conditions":[{"type":"status","operator":"guess"}],"matchMode":"all"}],"filterGroupsMatchMode":"all","kanbanMode":true}
            """.utf8
        )
        do {
            _ = try TaskForgeListConfigurationStore.decode(jsonData: unknownOperator)
            throw TestFailure(description: "unknown operator was accepted")
        } catch let error as TaskForgeFilterConfigurationError {
            try require(
                error == .unsupportedOperator("guess"),
                "unexpected unknown operator error"
            )
        }
    }),
    ("TaskForge status symbol learning rejects conflicts", {
        let tasks = [
            kanbanTask(
                identifier: "one",
                status: "todo",
                line: "- [ ] one"
            ),
            kanbanTask(
                identifier: "two",
                status: "todo",
                line: "- [>] two"
            )
        ]
        do {
            _ = try TaskForgeStatusSymbolLearner.learn(tasks: tasks)
            throw TestFailure(description: "conflicting symbols were learned")
        } catch let error as TaskForgeStatusSymbolError {
            try require(
                error == .conflict("todo"),
                "unexpected symbol conflict error"
            )
        }
    }),
    ("TaskForge status editor changes only the checkbox symbol", {
        let task = kanbanTask(
            identifier: "one",
            status: "todo",
            line: "- [ ] one"
        )
        let edit = try TaskForgeStatusSourceEditor.update(
            task: task,
            contents: "- [ ] one\n",
            targetStatus: "inProgress",
            symbols: ["inProgress": "[/]"]
        )
        try require(
            edit.updatedContents == "- [/ ] one\n"
                || edit.updatedContents == "- [/] one\n",
            "status editor changed the source unexpectedly"
        )
        try require(
            !edit.updatedContents.contains("✅"),
            "status editor added an artificial completion date"
        )
    }),
    ("TaskForge status symbol learning migrates planned aliases", {
        let task = kanbanTask(
            identifier: "planned-task",
            status: "planned",
            line: "- [>] planned-task"
        )
        let learned = try TaskForgeStatusSymbolLearner.learn(
            tasks: [task],
            existing: ["planned": "[>]"]
        )
        try require(
            learned["scheduled"] == "[>]" && learned["planned"] == nil,
            "planned symbol alias was not migrated to scheduled"
        )
    }),
    ("TaskForge status aliases cover every Kanban state", {
        let aliases = [
            "todo", "scheduled", "planned", "ready", "inProgress", "on-hold",
            "deferred", "blocked", "someday", "done", "cancelled"
        ]
        let expected = Set(TaskForgeKanbanStatus.allCases.map(\.rawValue))
        try require(
            Set(aliases.map(TaskForgeKanbanStatus.canonical)) == expected,
            "status aliases do not cover the locked status matrix"
        )
    }),
    ("Kanban private state is read-only until an explicit save", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskForgeSyncPrivateStore(rootURL: root)
        try require(
            try store.loadConfigurationReadOnly() == nil,
            "read-only private load should not create a root"
        )
        try require(
            !FileManager.default.fileExists(atPath: root.path),
            "read-only private load created a root"
        )
        try store.saveConfiguration(
            TaskForgeSyncPrivateConfiguration(taskForgeListID: "list")
        )
        try store.saveIndex(TaskForgeSyncIndex(listID: "list"))
        let rootMode = try requireValue(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber,
            "private root mode missing"
        )
        let configMode = try requireValue(
            FileManager.default.attributesOfItem(
                atPath: store.configurationURL.path
            )[.posixPermissions] as? NSNumber,
            "private config mode missing"
        )
        try require(rootMode.intValue & 0o777 == 0o700, "private root is not 0700")
        try require(configMode.intValue & 0o777 == 0o600, "private config is not 0600")
        try require(
            try store.loadConfigurationReadOnly()?.taskForgeListID == "list",
            "private config did not round-trip"
        )
    }),
    ("reminder fetch timeout cancels a registered request exactly once", {
        let cancellations = LockedValues<Int>()
        do {
            let _: Int = try waitForAsync {
                try await ReminderFetchWaiter.wait(
                    timeout: 0.05,
                    scheduleTimeout: { _, timeout in
                        DispatchQueue.global().asyncAfter(
                            deadline: .now() + 0.05
                        ) {
                            timeout()
                            timeout()
                        }
                    },
                    cancel: { identifier in
                        cancellations.append(identifier)
                    },
                    start: { completion in
                        _ = completion
                        return 11
                    }
                )
            }
            throw TestFailure(
                description: "fetch timeout unexpectedly succeeded"
            )
        } catch ReminderPrunerError.reminderFetchFailed {
            // Expected anonymous timeout.
        }
        try require(
            cancellations.read() == [11],
            "timeout must cancel the registered request identifier once"
        )
    }),
    ("reminder fetch success ignores a late timeout without cancelling", {
        let scheduledTimeout = ScheduledCallbackBox()
        let cancellations = LockedCounter()
        let value: Int = try waitForAsync {
            try await ReminderFetchWaiter.wait(
                scheduleTimeout: { _, timeout in
                    scheduledTimeout.store(timeout)
                },
                cancel: { _ in
                    cancellations.increment()
                },
                start: { completion in
                    completion(.success(7))
                    return 12
                }
            )
        }
        try scheduledTimeout.call()
        try scheduledTimeout.call()
        try require(value == 7, "fetch success returned an unexpected value")
        try require(
            cancellations.read() == 0,
            "a late timeout must not cancel a successful request"
        )
    }),
    ("reminder fetch timeout before handle registration cancels once", {
        let cancellations = LockedValues<Int>()
        do {
            let _: Int = try waitForAsync {
                try await ReminderFetchWaiter.wait(
                    timeout: 0,
                    scheduleTimeout: { _, timeout in
                        timeout()
                        timeout()
                    },
                    cancel: { identifier in
                        cancellations.append(identifier)
                    },
                    start: { completion in
                        completion(.success(9))
                        return 13
                    }
                )
            }
            throw TestFailure(
                description: "pre-registration timeout unexpectedly succeeded"
            )
        } catch ReminderPrunerError.reminderFetchFailed {
            // Expected; the callback arrives after timeout has already won.
        }
        try require(
            cancellations.read() == [13],
            "a late request identifier must be cancelled exactly once"
        )
    }),
    ("reminder backup adapter round-trips every expressible field", {
        let eventStore = EKEventStore()
        let original = EKReminder(eventStore: eventStore)
        original.title = "adapter fixture"
        original.notes = "adapter notes"
        original.url = URL(string: "taskforge-adapter-test://fixture")
        original.priority = 5

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        original.dueDateComponents = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            era: 1,
            year: 2031,
            month: 8,
            day: 9,
            hour: 10,
            minute: 11,
            second: 12
        )
        original.startDateComponents = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            era: 1,
            year: 2031,
            month: 8,
            day: 9,
            hour: 9,
            minute: 10,
            second: 11
        )

        let absoluteAlarm = EKAlarm(
            absoluteDate: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let location = EKStructuredLocation(title: "adapter location")
        location.geoLocation = CLLocation(
            latitude: 31.2304,
            longitude: 121.4737
        )
        location.radius = 125
        absoluteAlarm.structuredLocation = location
        absoluteAlarm.proximity = .enter
        original.addAlarm(absoluteAlarm)
        original.addAlarm(EKAlarm(relativeOffset: -1_800))

        let recurrence = EKRecurrenceRule(
            recurrenceWith: .yearly,
            interval: 2,
            daysOfTheWeek: [
                EKRecurrenceDayOfWeek(
                    dayOfTheWeek: .monday,
                    weekNumber: 2
                )
            ],
            daysOfTheMonth: [1, -1].map(NSNumber.init(value:)),
            monthsOfTheYear: [1, 12].map(NSNumber.init(value:)),
            weeksOfTheYear: [1, -1].map(NSNumber.init(value:)),
            daysOfTheYear: [100, -1].map(NSNumber.init(value:)),
            setPositions: [1, -1].map(NSNumber.init(value:)),
            end: EKRecurrenceEnd(occurrenceCount: 7)
        )
        original.addRecurrenceRule(recurrence)

        let captured = ReminderBackupAdapter.capture(
            original,
            taskPresence: .sourceConfirmed
        )
        let restored = EKReminder(eventStore: eventStore)
        ReminderBackupAdapter.restore(captured, into: restored)
        let roundTrip = ReminderBackupAdapter.capture(
            restored,
            taskPresence: .sourceConfirmed
        )

        try require(
            roundTrip.title == captured.title
                && roundTrip.notes == captured.notes
                && roundTrip.url == captured.url
                && roundTrip.priority == captured.priority,
            "adapter changed scalar reminder fields"
        )
        try require(
            roundTrip.dueDateComponents == captured.dueDateComponents
                && roundTrip.startDateComponents
                    == captured.startDateComponents,
            "adapter changed date component fields"
        )
        try require(
            roundTrip.alarms.count == captured.alarms.count,
            "adapter changed alarm count"
        )
        let capturedAbsolute = try requireValue(
            captured.alarms.first { $0.absoluteDate != nil },
            "absolute alarm fixture was not captured"
        )
        let roundTripAbsolute = try requireValue(
            roundTrip.alarms.first { $0.absoluteDate != nil },
            "absolute alarm was not restored"
        )
        try require(
            roundTripAbsolute.absoluteDate
                == capturedAbsolute.absoluteDate,
            "adapter changed absolute alarm date"
        )
        try require(
            roundTripAbsolute.structuredLocation
                == capturedAbsolute.structuredLocation,
            "adapter changed structured alarm location"
        )
        try require(
            roundTripAbsolute.proximityRawValue
                == capturedAbsolute.proximityRawValue,
            "adapter changed alarm proximity"
        )
        let capturedRelative = try requireValue(
            captured.alarms.first { $0.absoluteDate == nil },
            "relative alarm fixture was not captured"
        )
        let roundTripRelative = try requireValue(
            roundTrip.alarms.first { $0.absoluteDate == nil },
            "relative alarm was not restored"
        )
        try require(
            roundTripRelative == capturedRelative,
            "adapter changed relative alarm fields"
        )
        try require(
            roundTrip.recurrenceRules == captured.recurrenceRules,
            "adapter changed recurrence fields"
        )
        try require(
            roundTrip.taskPresence == .sourceConfirmed
                && captured.priority == 5
                && captured.alarms.count == 2
                && captured.alarms.contains {
                    $0.absoluteDate != nil
                        && $0.structuredLocation != nil
                        && $0.proximityRawValue
                            == EKAlarmProximity.enter.rawValue
                }
                && captured.recurrenceRules.first?.daysOfMonth
                    == [1, -1]
                && captured.recurrenceRules.first?.monthsOfYear
                    == [1, 12]
                && captured.recurrenceRules.first?.weeksOfYear
                    == [1, -1]
                && captured.recurrenceRules.first?.daysOfYear
                    == [100, -1]
                && captured.recurrenceRules.first?.setPositions
                    == [1, -1],
            "adapter fixture did not cover extended fields"
        )
    }),
    ("reminder backup adapter round-trips recurrence end date", {
        let eventStore = EKEventStore()
        let original = EKReminder(eventStore: eventStore)
        original.title = "adapter end-date fixture"
        original.addRecurrenceRule(
            EKRecurrenceRule(
                recurrenceWith: .daily,
                interval: 3,
                end: EKRecurrenceEnd(
                    end: Date(timeIntervalSince1970: 2_100_000_000)
                )
            )
        )

        let captured = ReminderBackupAdapter.capture(
            original,
            taskPresence: .absent
        )
        let stableEndDate = try requireValue(
            original.recurrenceRules?.first?.recurrenceEnd?.endDate,
            "EventKit did not expose the recurrence end date"
        )
        let capturedRule = try requireValue(
            captured.recurrenceRules.first,
            "end-date recurrence fixture was not captured"
        )
        try require(
            capturedRule.endDate == stableEndDate,
            "adapter did not preserve EventKit's stable recurrence end date"
        )
        let restored = EKReminder(eventStore: eventStore)
        ReminderBackupAdapter.restore(captured, into: restored)
        let restoredEndDate = try requireValue(
            restored.recurrenceRules?.first?.recurrenceEnd?.endDate,
            "adapter did not restore the recurrence end date"
        )
        let roundTrip = ReminderBackupAdapter.capture(
            restored,
            taskPresence: .absent
        )
        let roundTripRule = try requireValue(
            roundTrip.recurrenceRules.first,
            "end-date recurrence was not restored"
        )

        try require(
            restoredEndDate == stableEndDate
                && roundTripRule.endDate == stableEndDate,
            "adapter changed EventKit's stable recurrence end date"
        )
        try require(
            capturedRule.occurrenceCount == nil
                && roundTripRule.occurrenceCount == nil,
            "date-bounded recurrence must not become count-bounded"
        )
    }),
    ("prune target calendar selection fails closed on ambiguity", {
        let missing: Int? = try ReminderPruner.uniqueTargetCalendarMatch([])
        try require(missing == nil, "zero matching calendars should be absent")
        let unique = try ReminderPruner.uniqueTargetCalendarMatch([7])
        try require(unique == 7, "one matching calendar should be selected")

        do {
            let _: Int? = try ReminderPruner.uniqueTargetCalendarMatch([7, 8])
            throw TestFailure(
                description: "multiple matching calendars must fail closed"
            )
        } catch ReminderPrunerError.ambiguousTargetCalendar {
            // Expected anonymous fail-closed error.
        }
    }),
    ("TaskForge v6 MessagePack store decodes task records", {
        let snapshot = try TaskForgeTaskStore.decode(taskStoreFixture())
        try require(snapshot.version == 6, "unexpected task store version")
        try require(snapshot.vaultPath == "/vault", "unexpected vault path")
        try require(snapshot.tasks.count == 4, "unexpected decoded task count")
        try require(snapshot.tasks[0].title == "示例任务", "unexpected first task title")
        try require(snapshot.tasks[0].sourceType == "markdownInline", "unexpected source type")
    }),
    ("TaskForge v6 store rejects unknown scalar records", {
        do {
            _ = try TaskForgeTaskStore.decode(
                taskStoreFixture(extraRecord: .int(2))
            )
            throw TestFailure(description: "unknown scalar record was accepted")
        } catch TaskForgeTaskStoreError.malformed {
            // Expected fail-closed behavior.
        }
    }),
    ("TaskForge v6 store includes a complete trailing task record", {
        let trailing = taskRecord(
            id: "trailing-task",
            title: "追加任务",
            status: "todo",
            scheduled: .null
        )
        let snapshot = try TaskForgeTaskStore.decode(
            taskStoreFixture(trailingRecord: trailing)
        )
        try require(
            snapshot.tasks.contains { $0.identifier == "trailing-task" },
            "complete trailing task record was dropped"
        )
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
    ("source presence rejects non-positive and overflowing line numbers", {
        for lineNumber in [Int.min, 0, -1] {
            let task = TaskForgeTask(
                identifier: "invalid-line-\(lineNumber)",
                title: "保留任务",
                status: "todo",
                priority: nil,
                scheduled: nil,
                filePath: "/vault/note.md",
                sourceType: "markdownInline",
                originalLine: "- [ ] 保留任务",
                lineNumber: lineNumber
            )
            try require(
                TaskSourcePresenceInspector.inspect(
                    task: task,
                    contents: "- [ ] 保留任务\n"
                ) == .indeterminate,
                "\(lineNumber) must fail closed without index arithmetic"
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
    ("prune state restarts when the calendar identifier changes", {
        let now = Date(timeIntervalSince1970: 2_250)
        let prior = ReminderPruneLedger(entries: [
            "external": ReminderPruneLedgerEntry(
                firstSeen: now.addingTimeInterval(-120),
                fingerprint: "stable",
                calendarIdentifier: "calendar-before",
                rulesVersion: ReminderPruneStateMachine.rulesVersion,
                graceUntil: nil
            )
        ])
        let moved = ReminderPruneObservation(
            itemIdentifier: "external",
            calendarIdentifier: "calendar-after",
            isCompleted: false,
            priority: 0,
            title: "普通提醒",
            fingerprint: "stable",
            taskPresence: .absent
        )
        let plan = ReminderPruneStateMachine.plan(
            observations: [moved],
            prior: prior,
            targetCalendarIdentifier: "calendar-after",
            now: now
        )

        try require(
            plan.firstSeenIdentifiers == ["external"],
            "calendar move must start a fresh confirmation window"
        )
        try require(
            plan.readyIdentifiers.isEmpty,
            "calendar move must not reuse the old ready state"
        )
        try require(
            plan.nextLedger.entries["external"]?.calendarIdentifier
                == "calendar-after",
            "fresh state must record the current calendar"
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
    ("prune dry-run rejects an exposed root without changing it", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.path
        )

        do {
            _ = try ReminderPruneLocalStore(rootURL: root)
                .loadLedgerReadOnly()
            throw TestFailure(
                description: "read-only load accepted an unmigrated root"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .permissions,
                "unexpected read-only exposed-root error"
            )
        }
        try require(
            try permissions(at: root) == 0o755,
            "dry-run changed the root permissions"
        )
    }),
    ("prune mutating load safely migrates an exposed root", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.path
        )

        try require(
            try ReminderPruneLocalStore(rootURL: root).loadLedger()
                == ReminderPruneLedger(),
            "normal load should preserve an absent ledger"
        )
        try require(
            try permissions(at: root) == 0o700,
            "normal load did not migrate the root to 0700"
        )
        try require(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Backups").path
            ),
            "prune initialization created an unused source backup tree"
        )
    }),
    ("unresolved selection chooses the newest unresolved outcome", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        _ = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000201"
                )!,
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        let newerUnresolved = pruneBackupFixture(
            identifier: UUID(
                uuidString: "00000000-0000-0000-0000-000000000202"
            )!,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        _ = try store.saveBackup(newerUnresolved)
        _ = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000203"
                )!,
                createdAt: Date(timeIntervalSince1970: 30),
                actuallyDeletedIdentifiers: ["item"]
            )
        )
        _ = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000204"
                )!,
                createdAt: Date(timeIntervalSince1970: 40),
                actuallyDeletedIdentifiers: []
            )
        )
        let restoredURL = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000205"
                )!,
                createdAt: Date(timeIntervalSince1970: 50),
                actuallyDeletedIdentifiers: ["item"]
            )
        )
        _ = try store.beginRestoreAttempt(at: restoredURL)
        try store.recordRestoreReadback(
            ["item": "restored-item"],
            at: restoredURL
        )
        try store.markRestored(
            at: restoredURL,
            date: Date(timeIntervalSince1970: 60)
        )

        let selected = try requireValue(
            try store.latestUnresolvedDeletionBackup(),
            "unresolved deletion backup should be selected"
        )
        try require(
            selected.1.identifier == newerUnresolved.identifier,
            "selection did not choose the newest unresolved outcome"
        )
    }),
    ("unresolved selection ignores empty resolved and restorable outcomes", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        _ = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000211"
                )!,
                createdAt: Date(timeIntervalSince1970: 10),
                actuallyDeletedIdentifiers: []
            )
        )
        _ = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000212"
                )!,
                createdAt: Date(timeIntervalSince1970: 20),
                actuallyDeletedIdentifiers: ["item"]
            )
        )

        try require(
            try store.latestUnresolvedDeletionBackup() == nil,
            "resolved outcomes must not be selected as unresolved"
        )
    }),
    ("unresolved outcome settles into a preserved restorable backup", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let batch = pruneBackupFixture(
            identifier: UUID(
                uuidString: "00000000-0000-0000-0000-000000000221"
            )!,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let url = try store.saveBackup(batch)
        let unresolved = try requireValue(
            try store.latestUnresolvedDeletionBackup(),
            "unresolved deletion outcome should be discoverable"
        )
        try require(
            unresolved.1.identifier == batch.identifier,
            "unresolved selection returned another backup"
        )

        try store.recordActuallyDeletedIdentifiers(["item"], at: url)

        try require(
            try store.latestUnresolvedDeletionBackup() == nil,
            "settled outcome remained unresolved"
        )
        let restorable = try requireValue(
            try store.latestRestorableBackup(),
            "settled non-empty deletion should become restorable"
        )
        try require(
            restorable.1.identifier == batch.identifier,
            "settlement replaced or lost the original backup"
        )
        try require(
            FileManager.default.fileExists(atPath: url.path),
            "settlement must preserve the backup file"
        )
    }),
    ("restore selection skips a newer unresolved backup", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let older = pruneBackupFixture(
            identifier: UUID(
                uuidString: "00000000-0000-0000-0000-000000000101"
            )!,
            createdAt: Date(timeIntervalSince1970: 10),
            actuallyDeletedIdentifiers: ["item"]
        )
        _ = try store.saveBackup(older)
        _ = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000102"
                )!,
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )

        let selected = try requireValue(
            try store.latestRestorableBackup(),
            "older real deletion backup should remain restorable"
        )
        try require(
            selected.1.identifier == older.identifier,
            "newer unresolved backup blocked the real deletion backup"
        )
    }),
    ("restore selection skips a newer empty deletion result", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let older = pruneBackupFixture(
            identifier: UUID(
                uuidString: "00000000-0000-0000-0000-000000000111"
            )!,
            createdAt: Date(timeIntervalSince1970: 10),
            actuallyDeletedIdentifiers: ["item"]
        )
        _ = try store.saveBackup(older)
        _ = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000112"
                )!,
                createdAt: Date(timeIntervalSince1970: 20),
                actuallyDeletedIdentifiers: []
            )
        )

        let selected = try requireValue(
            try store.latestRestorableBackup(),
            "older real deletion backup should remain restorable"
        )
        try require(
            selected.1.identifier == older.identifier,
            "newer empty deletion result blocked the real deletion backup"
        )
    }),
    ("unresolved and empty backups are not restorable or markable", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let unresolvedURL = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000121"
                )!,
                createdAt: Date(timeIntervalSince1970: 10)
            )
        )
        let emptyURL = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000122"
                )!,
                createdAt: Date(timeIntervalSince1970: 20),
                actuallyDeletedIdentifiers: []
            )
        )

        try require(
            try store.latestRestorableBackup() == nil,
            "unresolved or empty deletion results are not restorable"
        )
        for url in [unresolvedURL, emptyURL] {
            do {
                try store.markRestored(
                    at: url,
                    date: Date(timeIntervalSince1970: 30)
                )
                throw TestFailure(
                    description: "non-restorable backup was marked restored"
                )
            } catch let error as ReminderPruneStoreError {
                try require(
                    error == .invalidBackup,
                    "unexpected non-restorable mark error"
                )
            }
            try require(
                try store.loadBackup(at: url).restoredAt == nil,
                "failed mark must not modify the backup"
            )
        }
    }),
    ("restore selection chooses the newest real deletion backup", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        _ = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000131"
                )!,
                createdAt: Date(timeIntervalSince1970: 10),
                actuallyDeletedIdentifiers: ["item"]
            )
        )
        let newer = pruneBackupFixture(
            identifier: UUID(
                uuidString: "00000000-0000-0000-0000-000000000132"
            )!,
            createdAt: Date(timeIntervalSince1970: 20),
            actuallyDeletedIdentifiers: ["item"]
        )
        _ = try store.saveBackup(newer)

        let selected = try requireValue(
            try store.latestRestorableBackup(),
            "real deletion backup should be restorable"
        )
        try require(
            selected.1.identifier == newer.identifier,
            "selection did not choose the newest real deletion backup"
        )
    }),
    ("restore selection skips a restored real deletion backup", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let older = pruneBackupFixture(
            identifier: UUID(
                uuidString: "00000000-0000-0000-0000-000000000141"
            )!,
            createdAt: Date(timeIntervalSince1970: 10),
            actuallyDeletedIdentifiers: ["item"]
        )
        _ = try store.saveBackup(older)
        let newerURL = try store.saveBackup(
            pruneBackupFixture(
                identifier: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000142"
                )!,
                createdAt: Date(timeIntervalSince1970: 20),
                actuallyDeletedIdentifiers: ["item"]
            )
        )
        _ = try store.beginRestoreAttempt(at: newerURL)
        try store.recordRestoreReadback(
            ["item": "restored-item"],
            at: newerURL
        )
        try store.markRestored(
            at: newerURL,
            date: Date(timeIntervalSince1970: 30)
        )

        let selected = try requireValue(
            try store.latestRestorableBackup(),
            "older unrestored deletion backup should remain available"
        )
        try require(
            selected.1.identifier == older.identifier,
            "restored deletion backup was selected again"
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
    ("restored backup rejects every further state mutation", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReminderPruneLocalStore(rootURL: root)
        let url = try store.saveBackup(
            pruneBackupFixture(
                actuallyDeletedIdentifiers: ["item"]
            )
        )
        _ = try store.beginRestoreAttempt(at: url)
        try store.recordRestoreReadback(
            ["item": "restored-item"],
            at: url
        )
        let restoredAt = Date(timeIntervalSince1970: 30)
        try store.markRestored(at: url, date: restoredAt)

        do {
            try store.recordActuallyDeletedIdentifiers(["item"], at: url)
            throw TestFailure(
                description: "restored deletion outcome was accepted"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .invalidBackup,
                "unexpected restored outcome mutation error"
            )
        }
        do {
            _ = try store.beginRestoreAttempt(at: url)
            throw TestFailure(
                description: "restored backup began another attempt"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .invalidBackup,
                "unexpected restored begin mutation error"
            )
        }
        do {
            try store.recordRestoreReadback(
                ["item": "restored-item"],
                at: url
            )
            throw TestFailure(
                description: "restored backup accepted another readback"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .invalidBackup,
                "unexpected restored readback mutation error"
            )
        }
        do {
            try store.markRestored(
                at: url,
                date: Date(timeIntervalSince1970: 40)
            )
            throw TestFailure(
                description: "restored backup was marked twice"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .invalidBackup,
                "unexpected repeated restored mutation error"
            )
        }
        try require(
            try store.loadBackup(at: url).restoredAt == restoredAt,
            "rejected mutations changed the restored backup"
        )
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
    ("runtime backup migration preserves content and normalizes permissions", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let backups = root.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        let legacyBatch = backups.appendingPathComponent(
            "legacy-batch",
            isDirectory: true
        )
        let sentinel = legacyBatch.appendingPathComponent("sentinel.bak")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: legacyBatch,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        for directory in [root, backups, legacyBatch] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
        }
        let sentinelData = Data("legacy sentinel".utf8)
        try sentinelData.write(to: sentinel)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: sentinel.path
        )

        let backupStore = TaskSourceBackupStore(backupsRootURL: backups)
        let freshData = Data("fresh backup".utf8)
        let fresh = try backupStore.save(
            freshData,
            fileName: "fresh.bak",
            batchName: "fresh-batch"
        )
        let ledger = try ReminderPruneLocalStore(rootURL: root).loadLedger()

        try require(
            ledger == ReminderPruneLedger(),
            "prune store could not load after source backup initialization"
        )
        try require(
            try Data(contentsOf: sentinel) == sentinelData,
            "legacy backup content changed during migration"
        )
        try require(
            try Data(contentsOf: fresh) == freshData,
            "new source backup content changed"
        )
        for directory in [
            root,
            backups,
            legacyBatch,
            fresh.deletingLastPathComponent()
        ] {
            try require(
                try permissions(at: directory) == 0o700,
                "\(directory.lastPathComponent) must be 0700"
            )
        }
        for file in [sentinel, fresh] {
            try require(
                try permissions(at: file) == 0o600,
                "\(file.lastPathComponent) must be 0600"
            )
        }
    }),
    ("prune store migrates an existing backup tree under a private root", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeLegacySourceBackupFixture(
            root: root,
            rootPermissions: 0o700
        )
        let before = try runtimeTreeEvidence(at: root)
        try require(
            before.directoryCount == 6 && before.fileCount == 5,
            "legacy fixture does not match production tree shape"
        )

        try require(
            try ReminderPruneLocalStore(rootURL: root).loadLedger()
                == ReminderPruneLedger(),
            "normal prune load should preserve an absent ledger"
        )
        let after = try runtimeTreeEvidence(at: root)

        try require(
            after == before,
            "prune initialization changed backup count or content hashes"
        )
        for directory in fixture.directories {
            try require(
                try permissions(at: directory) == 0o700,
                "\(directory.lastPathComponent) was not migrated to 0700"
            )
        }
        for file in fixture.files {
            try require(
                try permissions(at: file) == 0o600,
                "\(file.lastPathComponent) was not migrated to 0600"
            )
        }
    }),
    ("prune store migrates an exposed root and its complete backup tree", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeLegacySourceBackupFixture(
            root: root,
            rootPermissions: 0o755
        )
        let before = try runtimeTreeEvidence(at: fixture.backupsRoot)
        let store = ReminderPruneLocalStore(rootURL: root)

        try store.saveLedger(ReminderPruneLedger())
        try require(
            try store.loadLedger() == ReminderPruneLedger(),
            "normal prune save did not preserve the ledger"
        )
        let after = try runtimeTreeEvidence(at: fixture.backupsRoot)

        try require(
            after == before,
            "full migration changed backup count or content hashes"
        )
        for directory in fixture.directories {
            try require(
                try permissions(at: directory) == 0o700,
                "\(directory.lastPathComponent) was not private"
            )
        }
        for file in fixture.files {
            try require(
                try permissions(at: file) == 0o600,
                "\(file.lastPathComponent) was not private"
            )
        }
        try require(
            try permissions(at: store.ledgerURL) == 0o600,
            "prune save did not create a private ledger"
        )
    }),
    ("prune store fails closed for an unsafe existing backup tree", {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let writableRoot = container.appendingPathComponent(
            "writable",
            isDirectory: true
        )
        let writableFixture = try makeLegacySourceBackupFixture(
            root: writableRoot,
            rootPermissions: 0o700
        )
        let writableBefore = try runtimeTreeEvidence(at: writableRoot)
        let writableFile = writableFixture.files[0]
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o660],
            ofItemAtPath: writableFile.path
        )

        do {
            _ = try ReminderPruneLocalStore(rootURL: writableRoot)
                .loadLedger()
            throw TestFailure(
                description: "group-writable backup tree was accepted"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .permissions,
                "unexpected writable-tree error"
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: writableFile.path
        )
        try require(
            try runtimeTreeEvidence(at: writableRoot) == writableBefore,
            "failed migration changed writable-tree content"
        )
        try require(
            try permissions(at: writableFixture.backupsRoot) == 0o755,
            "failed migration partially changed directory modes"
        )

        let symlinkRoot = container.appendingPathComponent(
            "symlink",
            isDirectory: true
        )
        let symlinkFixture = try makeLegacySourceBackupFixture(
            root: symlinkRoot,
            rootPermissions: 0o700
        )
        let external = container.appendingPathComponent("external.bak")
        let linked = symlinkFixture.backupsRoot
            .appendingPathComponent("linked.bak")
        try Data("external".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: external
        )

        do {
            _ = try ReminderPruneLocalStore(rootURL: symlinkRoot).loadLedger()
            throw TestFailure(
                description: "symlinked backup tree was accepted"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .permissions,
                "unexpected symlink-tree error"
            )
        }
        try require(
            try Data(contentsOf: external) == Data("external".utf8),
            "failed migration changed the symlink target"
        )
        try require(
            try permissions(at: symlinkFixture.backupsRoot) == 0o755,
            "symlink rejection partially changed directory modes"
        )
    }),
    ("prune dry-run leaves an exposed backup tree unchanged", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeLegacySourceBackupFixture(
            root: root,
            rootPermissions: 0o700
        )
        let before = try runtimeTreeEvidence(at: root)

        try require(
            try ReminderPruneLocalStore(rootURL: root).loadLedgerReadOnly()
                == ReminderPruneLedger(),
            "dry-run should ignore an unrelated source backup tree"
        )

        try require(
            try runtimeTreeEvidence(at: root) == before,
            "dry-run changed backup count or content hashes"
        )
        try require(
            try permissions(at: fixture.backupsRoot) == 0o755,
            "dry-run changed source backup directory permissions"
        )
        try require(
            try permissions(at: fixture.files[0]) == 0o644,
            "dry-run changed source backup file permissions"
        )
    }),
    ("runtime migration policy rejects a different owner", {
        let metadata = PrivateRuntimeNodeSecurity(
            ownerUID: 502,
            permissions: 0o755,
            kind: .directory,
            hasExtendedACL: false
        )
        try require(
            !PrivateRuntimeDirectoryPolicy.canMigrate(
                metadata,
                currentUserUID: 501,
                expectedKind: .directory
            ),
            "a different owner must fail closed"
        )
    }),
    ("runtime root migration rejects symlinks and writable modes", {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = container.appendingPathComponent(
            "target",
            isDirectory: true
        )
        let symlink = container.appendingPathComponent(
            "runtime-link",
            isDirectory: true
        )
        let writable = container.appendingPathComponent(
            "runtime-writable",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: target
        )
        try FileManager.default.createDirectory(
            at: writable,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o770]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770],
            ofItemAtPath: writable.path
        )

        for root in [symlink, writable] {
            do {
                _ = try ReminderPruneLocalStore(rootURL: root).loadLedger()
                throw TestFailure(
                    description: "\(root.lastPathComponent) was migrated"
                )
            } catch let error as ReminderPruneStoreError {
                try require(
                    error == .permissions,
                    "unexpected unsafe-root error"
                )
            }
        }
        try require(
            try permissions(at: target) == 0o755,
            "symlink target permissions changed"
        )
        try require(
            try permissions(at: writable) == 0o770,
            "writable root permissions changed"
        )
    }),
    ("runtime backup migration rejects a symlink entry", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let backups = root.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        let target = root.appendingPathComponent("outside.bak")
        let linked = backups.appendingPathComponent("linked.bak")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: backups,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: target
        )

        do {
            _ = try TaskSourceBackupStore(backupsRootURL: backups).save(
                Data("new".utf8),
                fileName: "new.bak",
                batchName: "new-batch"
            )
            throw TestFailure(
                description: "symlinked legacy backup entry was accepted"
            )
        } catch let error as PrivateRuntimeDirectoryError {
            try require(
                error == .unsafeNode,
                "unexpected backup-tree symlink error"
            )
        }
        try require(
            try Data(contentsOf: target) == Data("outside".utf8),
            "symlink target content changed"
        )
    }),
    ("runtime root migration rejects an extended ACL", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.path
        )
        try addReadOnlyExtendedACL(to: root)

        do {
            _ = try ReminderPruneLocalStore(rootURL: root).loadLedger()
            throw TestFailure(
                description: "extended ACL runtime root was accepted"
            )
        } catch let error as ReminderPruneStoreError {
            try require(
                error == .permissions,
                "unexpected ACL-root error"
            )
        }
        try require(
            try permissions(at: root) == 0o755,
            "ACL rejection changed root permissions"
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
            _ = try store.latestRestorableBackup()
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
            try store.latestRestorableBackup() == nil,
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
