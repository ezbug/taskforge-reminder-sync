import Foundation

public struct TaskForgeDay: Codable, Equatable, Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(containing date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0
        )
    }
}

public struct TaskForgeTime: Codable, Equatable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

public struct TaskForgeScheduledDate: Codable, Equatable, Sendable {
    public let day: TaskForgeDay
    public let time: TaskForgeTime?

    public init(day: TaskForgeDay, time: TaskForgeTime?) {
        self.day = day
        self.time = time
    }
}

public struct TaskForgeTask: Codable, Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let status: String
    public let priority: String?
    public let scheduled: TaskForgeScheduledDate?
    public let filePath: String?
    public let sourceType: String?
    public let originalLine: String?
    public let lineNumber: Int?
    public let onCompletion: String?
    public let recurrence: String?

    public init(
        identifier: String,
        title: String,
        status: String,
        priority: String?,
        scheduled: TaskForgeScheduledDate?,
        filePath: String?,
        sourceType: String?,
        originalLine: String?,
        lineNumber: Int?,
        onCompletion: String? = nil,
        recurrence: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.status = status
        self.priority = priority
        self.scheduled = scheduled
        self.filePath = filePath
        self.sourceType = sourceType
        self.originalLine = originalLine
        self.lineNumber = lineNumber
        self.onCompletion = onCompletion
        self.recurrence = recurrence
    }

    public var isCompleted: Bool {
        status == "done" || status == "cancelled"
    }
}

public struct TaskForgeSnapshot: Equatable, Sendable {
    public let version: Int
    public let vaultPath: String
    public let tasks: [TaskForgeTask]

    public init(version: Int, vaultPath: String, tasks: [TaskForgeTask]) {
        self.version = version
        self.vaultPath = vaultPath
        self.tasks = tasks
    }

    public func openTasksScheduled(on day: TaskForgeDay) -> [TaskForgeTask] {
        tasks.filter { task in
            !task.isCompleted && task.scheduled?.day == day
        }
    }
}

public enum TaskForgeTaskStoreError: Error, LocalizedError {
    case truncated
    case malformed(String)
    case unsupportedType(UInt8)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .truncated:
            return "TaskForge 任务库数据不完整，可能正在写入；请稍后重试。"
        case let .malformed(reason):
            return "TaskForge 任务库格式无效：\(reason)"
        case let .unsupportedType(byte):
            return String(format: "TaskForge 任务库包含不支持的 MessagePack 类型 0x%02X。", byte)
        case let .unsupportedVersion(version):
            return "暂不支持 TaskForge tasks.v\(version) 任务库。"
        }
    }
}

public enum TaskForgeTaskStore {
    public static let defaultPath =
        "\(NSHomeDirectory())/Library/Containers/com.azhard.taskforge/Data/Library/Application Support/com.azhard.taskforge/tasks.v6.bin"

    public static func load(at path: String = defaultPath) throws -> TaskForgeSnapshot {
        try decode(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func decode(_ data: Data) throws -> TaskForgeSnapshot {
        var decoder = MessagePackDecoder(data: data)
        let root = try decoder.decodeValue()
        guard
            let values = root.arrayValue,
            values.count >= 5,
            let version = values[0].intValue,
            let vaultPath = values[3].stringValue,
            let records = values[4].arrayValue
        else {
            throw TaskForgeTaskStoreError.malformed("缺少版本、Vault 路径或任务数组")
        }
        guard version == 6 else {
            throw TaskForgeTaskStoreError.unsupportedVersion(version)
        }

        let tasks = records.compactMap(decodeTaskRecord)
        return TaskForgeSnapshot(version: version, vaultPath: vaultPath, tasks: tasks)
    }

    private static func decodeTaskRecord(_ value: MessagePackValue) -> TaskForgeTask? {
        guard
            let fields = value.arrayValue,
            fields.count >= 33,
            let identifier = fields[0].stringValue,
            let title = fields[1].stringValue
        else {
            return nil
        }

        let status = fields[3].arrayValue?.first?.stringValue
            ?? fields[3].stringValue
            ?? "todo"
        return TaskForgeTask(
            identifier: identifier,
            title: title,
            status: status,
            priority: fields[4].stringValue,
            scheduled: decodeScheduledDate(fields[12]),
            filePath: fields[18].stringValue,
            sourceType: fields[20].stringValue,
            originalLine: fields[31].stringValue,
            lineNumber: fields[32].intValue,
            onCompletion: fields[25].stringValue,
            recurrence: fields[30].stringValue
        )
    }

    private static func decodeScheduledDate(
        _ value: MessagePackValue
    ) -> TaskForgeScheduledDate? {
        guard
            let fields = value.arrayValue,
            fields.count >= 2,
            let date = fields[0].arrayValue,
            date.count >= 3,
            let year = date[0].intValue,
            let month = date[1].intValue,
            let day = date[2].intValue
        else {
            return nil
        }

        var time: TaskForgeTime?
        if
            let values = fields[1].arrayValue,
            values.count >= 2,
            let hour = values[0].intValue,
            let minute = values[1].intValue
        {
            time = TaskForgeTime(hour: hour, minute: minute)
        }
        return TaskForgeScheduledDate(
            day: TaskForgeDay(year: year, month: month, day: day),
            time: time
        )
    }
}

public enum TaskSyncMarker {
    public static let prefix = "TaskForge-Task-ID: "

    public struct Decoded: Equatable, Sendable {
        public let vaultPath: String
        public let taskIdentifier: String

        public init(vaultPath: String, taskIdentifier: String) {
            self.vaultPath = vaultPath
            self.taskIdentifier = taskIdentifier
        }
    }

    public static func make(vaultPath: String, taskIdentifier: String) -> String {
        let encoded = Data("\(vaultPath)|\(taskIdentifier)".utf8).base64EncodedString()
        return prefix + encoded
    }

    public static func extract(from notes: String?) -> String? {
        guard let notes else {
            return nil
        }
        return notes
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
    }

    public static func decode(_ marker: String) -> Decoded? {
        guard marker.hasPrefix(prefix) else {
            return nil
        }
        let encoded = String(marker.dropFirst(prefix.count))
        guard
            let data = Data(base64Encoded: encoded),
            let rawValue = String(data: data, encoding: .utf8),
            let separator = rawValue.lastIndex(of: "|")
        else {
            return nil
        }
        let vaultPath = String(rawValue[..<separator])
        let taskIdentifier = String(rawValue[rawValue.index(after: separator)...])
        guard !vaultPath.isEmpty, !taskIdentifier.isEmpty else {
            return nil
        }
        return Decoded(vaultPath: vaultPath, taskIdentifier: taskIdentifier)
    }
}

public enum TaskReminderTiming {
    public static func dueDateComponents(
        for scheduled: TaskForgeScheduledDate,
        calendar: Calendar
    ) -> DateComponents {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = scheduled.day.year
        components.month = scheduled.day.month
        components.day = scheduled.day.day
        if let time = scheduled.time {
            components.hour = time.hour
            components.minute = time.minute
        }
        return components
    }
}

public enum ReminderDueDatePolicy {
    public static func isEquivalent(
        _ actual: DateComponents?,
        _ desired: DateComponents?
    ) -> Bool {
        guard let actual, let desired else {
            return actual == nil && desired == nil
        }
        return actual.year == desired.year
            && actual.month == desired.month
            && actual.day == desired.day
            && actual.hour == desired.hour
            && actual.minute == desired.minute
    }
}

public enum ReminderCompletionPolicy {
    public static func desiredCompletion(
        taskIsCompleted: Bool,
        reminderIsCompleted: Bool
    ) -> Bool {
        taskIsCompleted || reminderIsCompleted
    }
}

public enum TaskCompletionReadback {
    public static func confirmsCompletion(
        of originalTask: TaskForgeTask,
        in refreshedTasks: [TaskForgeTask]
    ) -> Bool {
        let currentTask = refreshedTasks.first {
            $0.identifier == originalTask.identifier
        } ?? refreshedTasks.first {
            $0.title == originalTask.title
                && $0.filePath == originalTask.filePath
        }
        return currentTask?.isCompleted ?? true
    }
}

public struct TaskSourceReference: Codable, Equatable, Sendable {
    public static let linePrefix = "TaskForge-Source-Ref: "

    public let task: TaskForgeTask

    public init(task: TaskForgeTask) {
        self.task = task
    }

    public var encodedLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return Self.linePrefix
        }
        return Self.linePrefix + data.base64EncodedString()
    }

    public static func decode(from notes: String?) -> TaskSourceReference? {
        guard
            let encoded = notes?
                .components(separatedBy: "\n")
                .first(where: { $0.hasPrefix(linePrefix) })?
                .dropFirst(linePrefix.count),
            let data = Data(base64Encoded: String(encoded))
        else {
            return nil
        }
        return try? JSONDecoder().decode(TaskSourceReference.self, from: data)
    }

    public static func resolveTask(
        markerTaskIdentifier: String,
        snapshotTasks: [TaskForgeTask],
        reminderNotes: String?
    ) -> TaskForgeTask? {
        if
            let current = snapshotTasks.first(where: {
                $0.identifier == markerTaskIdentifier
            })
        {
            return current
        }
        guard
            let reference = decode(from: reminderNotes),
            reference.task.identifier == markerTaskIdentifier
        else {
            return nil
        }
        return reference.task
    }
}

public struct TaskSourceIdentity: Hashable, Sendable {
    public let sourceType: String
    public let filePath: String
    public let lineNumber: Int?

    public init?(task: TaskForgeTask) {
        guard
            let rawSourceType = task.sourceType?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            let rawFilePath = task.filePath?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !rawSourceType.isEmpty,
            !rawFilePath.isEmpty
        else {
            return nil
        }

        let normalizedSourceType = rawSourceType.lowercased()
        let stableLineNumber: Int?
        switch normalizedSourceType {
        case "markdowninline":
            guard let lineNumber = task.lineNumber, lineNumber > 0 else {
                return nil
            }
            stableLineNumber = lineNumber
        case "tasknotes":
            stableLineNumber = nil
        default:
            return nil
        }

        sourceType = normalizedSourceType
        filePath = URL(fileURLWithPath: rawFilePath).standardizedFileURL.path
        lineNumber = stableLineNumber
    }
}

public struct TaskReminderMatchRecord: Equatable, Sendable {
    public let key: Int
    public let taskIdentifier: String?
    public let sourceIdentity: TaskSourceIdentity?
    public let reminderIsCompleted: Bool
    public let scheduledDay: TaskForgeDay?

    public init(
        key: Int,
        taskIdentifier: String?,
        sourceIdentity: TaskSourceIdentity?,
        reminderIsCompleted: Bool = false,
        scheduledDay: TaskForgeDay? = nil
    ) {
        self.key = key
        self.taskIdentifier = taskIdentifier
        self.sourceIdentity = sourceIdentity
        self.reminderIsCompleted = reminderIsCompleted
        self.scheduledDay = scheduledDay
    }
}

public enum TaskReminderMatchResult: Equatable, Sendable {
    case exact(Int)
    case source(Int)
    case none
    case ambiguous
}

public enum TaskReminderMatchPolicy {
    public static func select(
        task: TaskForgeTask,
        records: [TaskReminderMatchRecord],
        claimedKeys: Set<Int>
    ) -> TaskReminderMatchResult {
        let available = records.filter { !claimedKeys.contains($0.key) }
        let exact = available.filter {
            $0.taskIdentifier == task.identifier
        }
        if exact.count == 1, let key = exact.first?.key {
            return .exact(key)
        }
        if exact.count > 1 {
            return .ambiguous
        }

        guard let sourceIdentity = TaskSourceIdentity(task: task) else {
            return .none
        }
        let activeSameSource = available.filter {
            $0.sourceIdentity == sourceIdentity && !$0.reminderIsCompleted
        }
        if
            activeSameSource.count == 1,
            let key = activeSameSource.first?.key
        {
            return .source(key)
        }
        if activeSameSource.count > 1 {
            return .ambiguous
        }

        guard let scheduledDay = task.scheduled?.day else {
            return .none
        }
        let completedSameOccurrence = available.filter {
            $0.sourceIdentity == sourceIdentity
                && $0.reminderIsCompleted
                && $0.scheduledDay == scheduledDay
        }
        if
            completedSameOccurrence.count == 1,
            let key = completedSameOccurrence.first?.key
        {
            return .source(key)
        }
        if completedSameOccurrence.count > 1 {
            return .ambiguous
        }
        return .none
    }
}

public struct TaskReminderAuditRecord: Equatable, Sendable {
    public let taskIdentifier: String
    public let sourceIdentity: TaskSourceIdentity?
    public let isCompleted: Bool
    public let scheduledDay: TaskForgeDay?

    public init(
        taskIdentifier: String,
        sourceIdentity: TaskSourceIdentity?,
        isCompleted: Bool = false,
        scheduledDay: TaskForgeDay? = nil
    ) {
        self.taskIdentifier = taskIdentifier
        self.sourceIdentity = sourceIdentity
        self.isCompleted = isCompleted
        self.scheduledDay = scheduledDay
    }
}

public struct TaskReminderAuditReport: Equatable, Sendable {
    public let managedReminderCount: Int
    public let duplicateTaskIdentifierGroups: Int
    public let duplicateActiveSourceIdentityGroups: Int
    public let duplicateCompletedOccurrenceGroups: Int
    public let historicalSourceReuseGroups: Int
    public let missingSourceIdentityCount: Int

    public init(
        managedReminderCount: Int,
        duplicateTaskIdentifierGroups: Int,
        duplicateActiveSourceIdentityGroups: Int,
        duplicateCompletedOccurrenceGroups: Int,
        historicalSourceReuseGroups: Int,
        missingSourceIdentityCount: Int
    ) {
        self.managedReminderCount = managedReminderCount
        self.duplicateTaskIdentifierGroups = duplicateTaskIdentifierGroups
        self.duplicateActiveSourceIdentityGroups =
            duplicateActiveSourceIdentityGroups
        self.duplicateCompletedOccurrenceGroups =
            duplicateCompletedOccurrenceGroups
        self.historicalSourceReuseGroups = historicalSourceReuseGroups
        self.missingSourceIdentityCount = missingSourceIdentityCount
    }

    public var isDuplicateFree: Bool {
        duplicateTaskIdentifierGroups == 0
            && duplicateActiveSourceIdentityGroups == 0
            && duplicateCompletedOccurrenceGroups == 0
    }
}

public enum TaskReminderAuditPolicy {
    private struct CompletedOccurrence: Hashable {
        let sourceIdentity: TaskSourceIdentity
        let scheduledDay: TaskForgeDay?
    }

    public static func analyze(
        _ records: [TaskReminderAuditRecord]
    ) -> TaskReminderAuditReport {
        var taskIdentifierCounts: [String: Int] = [:]
        var activeSourceIdentityCounts: [TaskSourceIdentity: Int] = [:]
        var completedOccurrenceCounts: [CompletedOccurrence: Int] = [:]
        var recordsBySourceIdentity: [
            TaskSourceIdentity: [TaskReminderAuditRecord]
        ] = [:]
        var missingSourceIdentityCount = 0

        for record in records {
            taskIdentifierCounts[record.taskIdentifier, default: 0] += 1
            if let sourceIdentity = record.sourceIdentity {
                recordsBySourceIdentity[sourceIdentity, default: []].append(
                    record
                )
                if record.isCompleted {
                    let occurrence = CompletedOccurrence(
                        sourceIdentity: sourceIdentity,
                        scheduledDay: record.scheduledDay
                    )
                    completedOccurrenceCounts[occurrence, default: 0] += 1
                } else {
                    activeSourceIdentityCounts[sourceIdentity, default: 0] += 1
                }
            } else {
                missingSourceIdentityCount += 1
            }
        }

        return TaskReminderAuditReport(
            managedReminderCount: records.count,
            duplicateTaskIdentifierGroups: taskIdentifierCounts.values.filter {
                $0 > 1
            }.count,
            duplicateActiveSourceIdentityGroups:
                activeSourceIdentityCounts.values.filter {
                    $0 > 1
                }.count,
            duplicateCompletedOccurrenceGroups:
                completedOccurrenceCounts.values.filter {
                    $0 > 1
                }.count,
            historicalSourceReuseGroups: recordsBySourceIdentity.values.filter {
                let scheduledDays = Set($0.compactMap(\.scheduledDay))
                return scheduledDays.count > 1
            }.count,
            missingSourceIdentityCount: missingSourceIdentityCount
        )
    }
}

public struct TaskReminderDeduplicationRecord: Equatable, Sendable {
    public let key: Int
    public let taskIdentifier: String
    public let sourceIdentity: TaskSourceIdentity?
    public let creationTimestamp: TimeInterval

    public init(
        key: Int,
        taskIdentifier: String,
        sourceIdentity: TaskSourceIdentity?,
        creationTimestamp: TimeInterval
    ) {
        self.key = key
        self.taskIdentifier = taskIdentifier
        self.sourceIdentity = sourceIdentity
        self.creationTimestamp = creationTimestamp
    }
}

public struct TaskReminderDeduplicationPlan: Equatable, Sendable {
    public let duplicateGroups: Int
    public let preservedKeys: [Int]
    public let archiveKeys: [Int]

    public init(
        duplicateGroups: Int,
        preservedKeys: [Int],
        archiveKeys: [Int]
    ) {
        self.duplicateGroups = duplicateGroups
        self.preservedKeys = preservedKeys
        self.archiveKeys = archiveKeys
    }
}

public enum TaskReminderDeduplicationPolicy {
    public static func plan(
        records: [TaskReminderDeduplicationRecord],
        currentTaskIdentifiers: Set<String>
    ) -> TaskReminderDeduplicationPlan {
        var visited = Set<Int>()
        var components: [[TaskReminderDeduplicationRecord]] = []

        for startIndex in records.indices where !visited.contains(startIndex) {
            var stack = [startIndex]
            var componentIndices: [Int] = []
            visited.insert(startIndex)
            while let currentIndex = stack.popLast() {
                componentIndices.append(currentIndex)
                for candidateIndex in records.indices
                    where !visited.contains(candidateIndex)
                {
                    if linked(records[currentIndex], records[candidateIndex]) {
                        visited.insert(candidateIndex)
                        stack.append(candidateIndex)
                    }
                }
            }
            if componentIndices.count > 1 {
                components.append(componentIndices.map { records[$0] })
            }
        }

        var preservedKeys: [Int] = []
        var archiveKeys: [Int] = []
        for component in components {
            let ranked = component.sorted { first, second in
                let firstIsCurrent = currentTaskIdentifiers.contains(
                    first.taskIdentifier
                )
                let secondIsCurrent = currentTaskIdentifiers.contains(
                    second.taskIdentifier
                )
                if firstIsCurrent != secondIsCurrent {
                    return firstIsCurrent
                }
                if first.creationTimestamp != second.creationTimestamp {
                    return first.creationTimestamp < second.creationTimestamp
                }
                return first.key < second.key
            }
            guard let preserved = ranked.first else {
                continue
            }
            preservedKeys.append(preserved.key)
            archiveKeys.append(contentsOf: ranked.dropFirst().map(\.key))
        }

        return TaskReminderDeduplicationPlan(
            duplicateGroups: components.count,
            preservedKeys: preservedKeys.sorted(),
            archiveKeys: archiveKeys.sorted()
        )
    }

    private static func linked(
        _ first: TaskReminderDeduplicationRecord,
        _ second: TaskReminderDeduplicationRecord
    ) -> Bool {
        if first.taskIdentifier == second.taskIdentifier {
            return true
        }
        guard
            let firstSource = first.sourceIdentity,
            let secondSource = second.sourceIdentity
        else {
            return false
        }
        return firstSource == secondSource
    }
}

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

public enum TaskCompletionSourceInspector {
    public static func isCompleted(
        task: TaskForgeTask,
        contents: String
    ) -> Bool {
        switch task.sourceType?.lowercased() {
        case "markdowninline":
            guard let lineNumber = task.lineNumber else {
                return false
            }
            let lines = contents.components(separatedBy: "\n")
            let index = lineNumber - 1
            guard lines.indices.contains(index) else {
                return false
            }
            return lines[index].range(
                of: #"\[[xX]\]"#,
                options: .regularExpression
            ) != nil
        case "tasknotes":
            let lines = contents.components(separatedBy: "\n")
            guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
                return false
            }
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    break
                }
                let normalized = line
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if normalized == "status: done" || normalized == "status: cancelled" {
                    return true
                }
            }
            return false
        default:
            return false
        }
    }
}

public struct TaskCompletionEdit: Equatable, Sendable {
    public let updatedContents: String
    public let lineNumber: Int
    public let originalLine: String
    public let updatedLine: String

    public init(
        updatedContents: String,
        lineNumber: Int,
        originalLine: String,
        updatedLine: String
    ) {
        self.updatedContents = updatedContents
        self.lineNumber = lineNumber
        self.originalLine = originalLine
        self.updatedLine = updatedLine
    }
}

public enum TaskCompletionEditorError: Error, LocalizedError, Equatable {
    case alreadyCompleted
    case recurringTaskUnsupported
    case onCompletionUnsupported
    case sourceTypeUnsupported
    case missingSourceMetadata
    case sourceLineNotUnique
    case uncheckedCheckboxNotFound
    case invalidTaskNotesFrontmatter
    case taskNotesStatusNotFound

    public var isSafeUnattendedSkip: Bool {
        true
    }

    public var errorDescription: String? {
        switch self {
        case .alreadyCompleted:
            return "TaskForge 任务已经完成。"
        case .recurringTaskUnsupported:
            return "为避免破坏下一次实例，暂不反向完成重复任务。"
        case .onCompletionUnsupported:
            return "暂不反向处理完成后会移动、归档或删除的任务。"
        case .sourceTypeUnsupported:
            return "暂不支持该 TaskForge 任务来源类型。"
        case .missingSourceMetadata:
            return "TaskForge 任务缺少源文件或原始行信息。"
        case .sourceLineNotUnique:
            return "源任务行已移动、改变或存在多个同名候选，已拒绝写入。"
        case .uncheckedCheckboxNotFound:
            return "源任务行中找不到未完成复选框。"
        case .invalidTaskNotesFrontmatter:
            return "TaskNotes 文件缺少有效的 YAML frontmatter。"
        case .taskNotesStatusNotFound:
            return "TaskNotes frontmatter 中找不到 status 字段。"
        }
    }
}

public enum TaskCompletionEditor {
    public static func complete(
        task: TaskForgeTask,
        contents: String,
        on day: TaskForgeDay
    ) throws -> TaskCompletionEdit {
        guard !task.isCompleted else {
            throw TaskCompletionEditorError.alreadyCompleted
        }
        if let recurrence = task.recurrence, !recurrence.isEmpty {
            throw TaskCompletionEditorError.recurringTaskUnsupported
        }
        if
            let onCompletion = task.onCompletion,
            !onCompletion.isEmpty,
            onCompletion != "keep"
        {
            throw TaskCompletionEditorError.onCompletionUnsupported
        }

        switch task.sourceType {
        case "markdownInline":
            return try completeInlineTask(task: task, contents: contents, on: day)
        case "taskNotes":
            return try completeTaskNotes(contents: contents, on: day)
        default:
            throw TaskCompletionEditorError.sourceTypeUnsupported
        }
    }

    private static func completeInlineTask(
        task: TaskForgeTask,
        contents: String,
        on day: TaskForgeDay
    ) throws -> TaskCompletionEdit {
        guard let originalLine = task.originalLine else {
            throw TaskCompletionEditorError.missingSourceMetadata
        }
        var lines = contents.components(separatedBy: "\n")
        let expectedIndex = task.lineNumber.map { $0 - 1 }
        let lineIndex: Int
        if
            let expectedIndex,
            lines.indices.contains(expectedIndex),
            lines[expectedIndex] == originalLine
        {
            lineIndex = expectedIndex
        } else {
            let candidates = lines.indices.filter { lines[$0] == originalLine }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw TaskCompletionEditorError.sourceLineNotUnique
            }
            lineIndex = candidate
        }

        let regex = try NSRegularExpression(
            pattern: #"^(\s*(?:[-*+]|\d+\.)\s+)\[ \]"#
        )
        let range = NSRange(lines[lineIndex].startIndex..., in: lines[lineIndex])
        guard regex.firstMatch(in: lines[lineIndex], range: range) != nil else {
            throw TaskCompletionEditorError.uncheckedCheckboxNotFound
        }
        var updatedLine = regex.stringByReplacingMatches(
            in: lines[lineIndex],
            range: range,
            withTemplate: "$1[x]"
        )
        let date = format(day)
        if !updatedLine.contains("✅ \(date)") {
            updatedLine += " ✅ \(date)"
        }
        lines[lineIndex] = updatedLine
        return TaskCompletionEdit(
            updatedContents: lines.joined(separator: "\n"),
            lineNumber: lineIndex + 1,
            originalLine: originalLine,
            updatedLine: updatedLine
        )
    }

    private static func completeTaskNotes(
        contents: String,
        on day: TaskForgeDay
    ) throws -> TaskCompletionEdit {
        var lines = contents.components(separatedBy: "\n")
        guard
            lines.first == "---",
            let closingIndex = lines.dropFirst().firstIndex(of: "---")
        else {
            throw TaskCompletionEditorError.invalidTaskNotesFrontmatter
        }

        let frontmatter = 1..<closingIndex
        guard
            let statusIndex = frontmatter.first(where: {
                lines[$0].hasPrefix("status:")
            })
        else {
            throw TaskCompletionEditorError.taskNotesStatusNotFound
        }
        let originalStatus = lines[statusIndex]
        lines[statusIndex] = "status: done"

        let completedDate = "completedDate: \(format(day))"
        if
            let completedIndex = frontmatter.first(where: {
                lines[$0].hasPrefix("completedDate:")
            })
        {
            lines[completedIndex] = completedDate
        } else {
            lines.insert(completedDate, at: statusIndex + 1)
        }

        return TaskCompletionEdit(
            updatedContents: lines.joined(separator: "\n"),
            lineNumber: statusIndex + 1,
            originalLine: originalStatus,
            updatedLine: "status: done"
        )
    }

    private static func format(_ day: TaskForgeDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }
}

private indirect enum MessagePackValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([(MessagePackValue, MessagePackValue)])

    var intValue: Int? {
        guard case let .int(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [MessagePackValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }
}

private struct MessagePackDecoder {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func decodeValue() throws -> MessagePackValue {
        let prefix = try readByte()

        if prefix <= 0x7F {
            return .int(Int(prefix))
        }
        if prefix >= 0xE0 {
            return .int(Int(Int8(bitPattern: prefix)))
        }
        if (0x80...0x8F).contains(prefix) {
            return try decodeMap(count: Int(prefix & 0x0F))
        }
        if (0x90...0x9F).contains(prefix) {
            return try decodeArray(count: Int(prefix & 0x0F))
        }
        if (0xA0...0xBF).contains(prefix) {
            return try decodeString(length: Int(prefix & 0x1F))
        }

        switch prefix {
        case 0xC0:
            return .null
        case 0xC2:
            return .bool(false)
        case 0xC3:
            return .bool(true)
        case 0xC4:
            return .binary(try readData(count: Int(try readUnsigned(byteCount: 1))))
        case 0xC5:
            return .binary(try readData(count: Int(try readUnsigned(byteCount: 2))))
        case 0xC6:
            return .binary(try readData(count: try checkedInt(readUnsigned(byteCount: 4))))
        case 0xCA:
            let bits = UInt32(try readUnsigned(byteCount: 4))
            return .double(Double(Float(bitPattern: bits)))
        case 0xCB:
            return .double(Double(bitPattern: try readUnsigned(byteCount: 8)))
        case 0xCC:
            return .int(Int(try readUnsigned(byteCount: 1)))
        case 0xCD:
            return .int(Int(try readUnsigned(byteCount: 2)))
        case 0xCE:
            return .int(try checkedInt(readUnsigned(byteCount: 4)))
        case 0xCF:
            return .int(try checkedInt(readUnsigned(byteCount: 8)))
        case 0xD0:
            return .int(Int(Int8(bitPattern: try readByte())))
        case 0xD1:
            return .int(Int(Int16(bitPattern: UInt16(try readUnsigned(byteCount: 2)))))
        case 0xD2:
            return .int(Int(Int32(bitPattern: UInt32(try readUnsigned(byteCount: 4)))))
        case 0xD3:
            return .int(try checkedSignedInt(try readUnsigned(byteCount: 8)))
        case 0xD9:
            return try decodeString(length: Int(try readUnsigned(byteCount: 1)))
        case 0xDA:
            return try decodeString(length: Int(try readUnsigned(byteCount: 2)))
        case 0xDB:
            return try decodeString(length: try checkedInt(readUnsigned(byteCount: 4)))
        case 0xDC:
            return try decodeArray(count: Int(try readUnsigned(byteCount: 2)))
        case 0xDD:
            return try decodeArray(count: try checkedInt(readUnsigned(byteCount: 4)))
        case 0xDE:
            return try decodeMap(count: Int(try readUnsigned(byteCount: 2)))
        case 0xDF:
            return try decodeMap(count: try checkedInt(readUnsigned(byteCount: 4)))
        case 0xD4:
            return try decodeExtension(length: 1)
        case 0xD5:
            return try decodeExtension(length: 2)
        case 0xD6:
            return try decodeExtension(length: 4)
        case 0xD7:
            return try decodeExtension(length: 8)
        case 0xD8:
            return try decodeExtension(length: 16)
        case 0xC7:
            return try decodeExtension(length: Int(try readUnsigned(byteCount: 1)))
        case 0xC8:
            return try decodeExtension(length: Int(try readUnsigned(byteCount: 2)))
        case 0xC9:
            return try decodeExtension(length: try checkedInt(readUnsigned(byteCount: 4)))
        default:
            throw TaskForgeTaskStoreError.unsupportedType(prefix)
        }
    }

    private mutating func decodeString(length: Int) throws -> MessagePackValue {
        let value = try readData(count: length)
        guard let string = String(data: value, encoding: .utf8) else {
            throw TaskForgeTaskStoreError.malformed("字符串不是 UTF-8")
        }
        return .string(string)
    }

    private mutating func decodeArray(count: Int) throws -> MessagePackValue {
        var values: [MessagePackValue] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try decodeValue())
        }
        return .array(values)
    }

    private mutating func decodeMap(count: Int) throws -> MessagePackValue {
        var values: [(MessagePackValue, MessagePackValue)] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append((try decodeValue(), try decodeValue()))
        }
        return .map(values)
    }

    private mutating func decodeExtension(length: Int) throws -> MessagePackValue {
        _ = try readByte()
        return .binary(try readData(count: length))
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw TaskForgeTaskStoreError.truncated
        }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw TaskForgeTaskStoreError.truncated
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    private mutating func readUnsigned(byteCount: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<byteCount {
            value = (value << 8) | UInt64(try readByte())
        }
        return value
    }

    private func checkedInt(
        _ value: @autoclosure () throws -> UInt64
    ) throws -> Int {
        let result = try value()
        guard result <= UInt64(Int.max) else {
            throw TaskForgeTaskStoreError.malformed("整数超出范围")
        }
        return Int(result)
    }

    private func checkedSignedInt(_ bits: UInt64) throws -> Int {
        let signed = Int64(bitPattern: bits)
        guard
            signed >= Int64(Int.min),
            signed <= Int64(Int.max)
        else {
            throw TaskForgeTaskStoreError.malformed("有符号整数超出范围")
        }
        return Int(signed)
    }
}
