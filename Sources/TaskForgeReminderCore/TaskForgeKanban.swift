import Foundation

public enum TaskForgeKanbanStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case scheduled
    case ready
    case inProgress
    case onHold
    case deferred
    case blocked
    case someday
    case done
    case cancelled

    public static func canonical(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("TaskStatus.") {
            normalized = String(normalized.dropFirst("TaskStatus.".count))
        }
        normalized = normalized.replacingOccurrences(of: "-", with: "_")
        switch normalized.lowercased() {
        case "todo", "open":
            return Self.todo.rawValue
        case "scheduled":
            return Self.scheduled.rawValue
        case "ready":
            return Self.ready.rawValue
        case "inprogress", "in_progress":
            return Self.inProgress.rawValue
        case "onhold", "on_hold", "hold":
            return Self.onHold.rawValue
        case "deferred", "postponed":
            return Self.deferred.rawValue
        case "blocked":
            return Self.blocked.rawValue
        case "someday", "someday_maybe":
            return Self.someday.rawValue
        case "done", "completed", "complete":
            return Self.done.rawValue
        case "cancelled", "canceled":
            return Self.cancelled.rawValue
        default:
            return normalized
        }
    }

    public static func fromTask(_ task: TaskForgeTask) -> Self? {
        Self(rawValue: canonical(task.status))
    }

    public var isTerminal: Bool {
        self == .done || self == .cancelled
    }
}

public enum TaskForgeFilterConfigurationError: Error, LocalizedError, Equatable {
    case missingList(String)
    case malformedJSON
    case unsupportedField(String)
    case unsupportedOperator(String)
    case invalidMatchMode(String)
    case invalidCondition(String)
    case invalidPrivateState

    public var errorDescription: String? {
        switch self {
        case let .missingList(id):
            _ = id
            return "找不到 TaskForge 自定义列表配置，已停止同步。"
        case .malformedJSON:
            return "TaskForge 自定义列表配置不是有效 JSON。"
        case let .unsupportedField(field):
            return "TaskForge 自定义列表包含未知过滤字段：\(field)"
        case let .unsupportedOperator(value):
            return "TaskForge 自定义列表包含未知过滤操作符：\(value)"
        case let .invalidMatchMode(value):
            return "TaskForge 自定义列表包含无效组逻辑：\(value)"
        case let .invalidCondition(value):
            return "TaskForge 自定义列表过滤条件无效：\(value)"
        case .invalidPrivateState:
            return "TaskForge 同步私有状态损坏，已拒绝写入。"
        }
    }
}

public enum TaskForgeFilterField: String, CaseIterable, Sendable {
    case dueDate = "due_date"
    case scheduledDate = "scheduled_date"
    case startDate = "start_date"
    case completionDate = "completion_date"
    case cancelledDate = "cancelled_date"
    case status
    case priority
    case tag
    case context
    case project
    case filePath = "file_path"
    case fileName = "file_name"
    case taskSourceType = "task_source_type"
    case title
    case isBlocked = "is_blocked"
}

public enum TaskForgeFilterOperator: String, CaseIterable, Sendable {
    case equals
    case notEquals = "not_equals"
    case contains
    case notContains = "not_contains"
    case isNull = "is_null"
    case isNotNull = "is_not_null"
    case today
    case beforeToday = "before_today"
    case afterToday = "after_today"
    case inNextDays = "in_next_days"
    case inLastDays = "in_last_days"
    case onOrBefore = "on_or_before"
    case onOrAfter = "on_or_after"
    case anyOf = "any_of"
    case notAnyOf = "not_any_of"
}

public struct TaskForgeFilterCondition: Codable, Equatable, Sendable {
    public let type: String
    public let `operator`: String
    public let value: String?
    public let days: Int?
    public let propertyName: String?
    public let useInCalendarView: Bool
    public let useInDistributionView: Bool

    public init(
        type: String,
        operator: String,
        value: String? = nil,
        days: Int? = nil,
        propertyName: String? = nil,
        useInCalendarView: Bool = true,
        useInDistributionView: Bool = true
    ) throws {
        guard TaskForgeFilterField(rawValue: type) != nil else {
            throw TaskForgeFilterConfigurationError.unsupportedField(type)
        }
        guard TaskForgeFilterOperator(rawValue: `operator`) != nil else {
            throw TaskForgeFilterConfigurationError.unsupportedOperator(`operator`)
        }
        self.type = type
        self.operator = `operator`
        self.value = value
        self.days = days
        self.propertyName = propertyName
        self.useInCalendarView = useInCalendarView
        self.useInDistributionView = useInDistributionView
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case `operator`
        case value
        case days
        case propertyName
        case useInCalendarView
        case useInDistributionView
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let op = try container.decode(String.self, forKey: .operator)
        try self.init(
            type: type,
            operator: op,
            value: try container.decodeIfPresent(String.self, forKey: .value),
            days: try container.decodeIfPresent(Int.self, forKey: .days),
            propertyName: try container.decodeIfPresent(
                String.self,
                forKey: .propertyName
            ),
            useInCalendarView: try container.decodeIfPresent(
                Bool.self,
                forKey: .useInCalendarView
            ) ?? true,
            useInDistributionView: try container.decodeIfPresent(
                Bool.self,
                forKey: .useInDistributionView
            ) ?? true
        )
    }
}

public struct TaskForgeFilterGroup: Codable, Equatable, Sendable {
    public let conditions: [TaskForgeFilterCondition]
    public let matchMode: String

    public init(
        conditions: [TaskForgeFilterCondition],
        matchMode: String
    ) throws {
        guard matchMode == "all" || matchMode == "any" else {
            throw TaskForgeFilterConfigurationError.invalidMatchMode(matchMode)
        }
        guard !conditions.isEmpty else {
            throw TaskForgeFilterConfigurationError.invalidCondition("empty group")
        }
        self.conditions = conditions
        self.matchMode = matchMode
    }

    private enum CodingKeys: String, CodingKey {
        case conditions
        case matchMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            conditions: container.decode([TaskForgeFilterCondition].self, forKey: .conditions),
            matchMode: container.decode(String.self, forKey: .matchMode)
        )
    }
}

public struct TaskForgeCustomList: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let filterGroups: [TaskForgeFilterGroup]
    public let filterGroupsMatchMode: String
    public let kanbanMode: Bool

    public init(
        id: String,
        name: String,
        filterGroups: [TaskForgeFilterGroup],
        filterGroupsMatchMode: String,
        kanbanMode: Bool
    ) throws {
        guard !id.isEmpty, !name.isEmpty else {
            throw TaskForgeFilterConfigurationError.invalidCondition("list identity")
        }
        guard filterGroupsMatchMode == "all" || filterGroupsMatchMode == "any" else {
            throw TaskForgeFilterConfigurationError.invalidMatchMode(
                filterGroupsMatchMode
            )
        }
        guard !filterGroups.isEmpty else {
            throw TaskForgeFilterConfigurationError.invalidCondition("empty list")
        }
        self.id = id
        self.name = name
        self.filterGroups = filterGroups
        self.filterGroupsMatchMode = filterGroupsMatchMode
        self.kanbanMode = kanbanMode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case filterGroups
        case filterGroupsMatchMode
        case kanbanMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            filterGroups: container.decode(
                [TaskForgeFilterGroup].self,
                forKey: .filterGroups
            ),
            filterGroupsMatchMode: container.decode(
                String.self,
                forKey: .filterGroupsMatchMode
            ),
            kanbanMode: container.decodeIfPresent(Bool.self, forKey: .kanbanMode)
                ?? false
        )
    }
}

public enum TaskForgeListConfigurationStore {
    public static let defaultPreferencesPath =
        "\(NSHomeDirectory())/Library/Containers/com.azhard.taskforge/Data/Library/Preferences/com.azhard.taskforge.plist"

    public static func load(
        listID: String,
        preferencesPath: String = defaultPreferencesPath
    ) throws -> TaskForgeCustomList {
        let url = URL(fileURLWithPath: preferencesPath)
        guard
            let data = try? Data(contentsOf: url),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let plist = propertyList as? [String: Any],
            let rawJSON = plist["flutter.ctl_\(listID)"] as? String
        else {
            throw TaskForgeFilterConfigurationError.missingList(listID)
        }
        guard let jsonData = rawJSON.data(using: .utf8) else {
            throw TaskForgeFilterConfigurationError.malformedJSON
        }
        do {
            return try JSONDecoder().decode(TaskForgeCustomList.self, from: jsonData)
        } catch let error as TaskForgeFilterConfigurationError {
            throw error
        } catch {
            throw TaskForgeFilterConfigurationError.malformedJSON
        }
    }

    public static func decode(jsonData: Data) throws -> TaskForgeCustomList {
        do {
            return try JSONDecoder().decode(TaskForgeCustomList.self, from: jsonData)
        } catch let error as TaskForgeFilterConfigurationError {
            throw error
        } catch {
            throw TaskForgeFilterConfigurationError.malformedJSON
        }
    }
}

public enum TaskForgeFilterEvaluator {
    public static func select(
        tasks: [TaskForgeTask],
        list: TaskForgeCustomList,
        calendar: Calendar,
        now: Date = Date()
    ) throws -> [TaskForgeTask] {
        try tasks.filter { task in
            try evaluate(task: task, list: list, calendar: calendar, now: now)
        }
    }

    public static func evaluate(
        task: TaskForgeTask,
        list: TaskForgeCustomList,
        calendar: Calendar,
        now: Date = Date()
    ) throws -> Bool {
        let groupResults = try list.filterGroups.map { group in
            let conditionResults = try group.conditions.map {
                try evaluate(
                    condition: $0,
                    task: task,
                    calendar: calendar,
                    now: now
                )
            }
            return group.matchMode == "all"
                ? conditionResults.allSatisfy { $0 }
                : conditionResults.contains { $0 }
        }
        return list.filterGroupsMatchMode == "all"
            ? groupResults.allSatisfy { $0 }
            : groupResults.contains { $0 }
    }

    private static func evaluate(
        condition: TaskForgeFilterCondition,
        task: TaskForgeTask,
        calendar: Calendar,
        now: Date
    ) throws -> Bool {
        guard let field = TaskForgeFilterField(rawValue: condition.type) else {
            throw TaskForgeFilterConfigurationError.unsupportedField(condition.type)
        }
        guard let op = TaskForgeFilterOperator(rawValue: condition.operator) else {
            throw TaskForgeFilterConfigurationError.unsupportedOperator(
                condition.operator
            )
        }
        switch field {
        case .dueDate, .scheduledDate, .startDate, .completionDate, .cancelledDate:
            let day: TaskForgeDay?
            switch field {
            case .dueDate: day = task.due?.day
            case .scheduledDate: day = task.scheduled?.day
            case .startDate: day = task.start?.day
            case .completionDate: day = task.completionDay
            case .cancelledDate: day = task.cancelledDay
            default: day = nil
            }
            return evaluateDate(
                day: day,
                operator: op,
                value: condition.value,
                days: condition.days,
                calendar: calendar,
                now: now
            )
        case .isBlocked:
            return evaluateScalar(
                task.isBlocked ? "true" : "false",
                isPresent: true,
                operator: op,
                value: condition.value
            )
        case .status:
            return evaluateScalar(
                TaskForgeKanbanStatus.canonical(task.status),
                isPresent: true,
                operator: op,
                value: condition.value.map(TaskForgeKanbanStatus.canonical)
            )
        case .priority:
            return evaluateScalar(
                canonicalEnum(task.priority),
                isPresent: task.priority != nil,
                operator: op,
                value: condition.value.map(canonicalEnum)
            )
        case .tag:
            return evaluateCollection(
                task.tags,
                operator: op,
                value: condition.value
            )
        case .context:
            return evaluateCollection(
                task.contexts,
                operator: op,
                value: condition.value
            )
        case .project:
            return evaluateCollection(
                task.projects,
                operator: op,
                value: condition.value
            )
        case .filePath:
            return evaluateScalar(
                task.filePath ?? "",
                isPresent: task.filePath != nil,
                operator: op,
                value: condition.value
            )
        case .fileName:
            return evaluateScalar(
                task.fileName ?? task.filePath.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? "",
                isPresent: task.fileName != nil || task.filePath != nil,
                operator: op,
                value: condition.value
            )
        case .taskSourceType:
            return evaluateScalar(
                canonicalEnum(task.sourceType),
                isPresent: task.sourceType != nil,
                operator: op,
                value: condition.value.map(canonicalEnum)
            )
        case .title:
            return evaluateScalar(
                task.title,
                isPresent: !task.title.isEmpty,
                operator: op,
                value: condition.value
            )
        }
    }

    private static func evaluateScalar(
        _ actual: String,
        isPresent: Bool,
        operator op: TaskForgeFilterOperator,
        value: String?
    ) -> Bool {
        let expected = value ?? ""
        switch op {
        case .equals:
            return isPresent && actual.caseInsensitiveCompare(expected) == .orderedSame
        case .notEquals:
            return !isPresent || actual.caseInsensitiveCompare(expected) != .orderedSame
        case .contains:
            return isPresent && actual.range(of: expected, options: .caseInsensitive) != nil
        case .notContains:
            return !isPresent || actual.range(of: expected, options: .caseInsensitive) == nil
        case .isNull:
            return !isPresent
        case .isNotNull:
            return isPresent
        case .anyOf:
            return valueList(value).contains {
                actual.caseInsensitiveCompare($0) == .orderedSame
            }
        case .notAnyOf:
            return !valueList(value).contains {
                actual.caseInsensitiveCompare($0) == .orderedSame
            }
        default:
            return false
        }
    }

    private static func evaluateCollection(
        _ actual: [String],
        operator op: TaskForgeFilterOperator,
        value: String?
    ) -> Bool {
        let expected = value ?? ""
        let matches: (String) -> Bool = {
            $0.range(of: expected, options: .caseInsensitive) != nil
        }
        switch op {
        case .equals, .contains:
            return actual.contains(where: matches)
        case .notEquals, .notContains:
            return !actual.contains(where: matches)
        case .isNull:
            return actual.isEmpty
        case .isNotNull:
            return !actual.isEmpty
        case .anyOf:
            return valueList(value).contains { candidate in
                actual.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }
        case .notAnyOf:
            return !valueList(value).contains { candidate in
                actual.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }
        default:
            return false
        }
    }

    private static func evaluateDate(
        day: TaskForgeDay?,
        operator op: TaskForgeFilterOperator,
        value: String?,
        days: Int?,
        calendar: Calendar,
        now: Date
    ) -> Bool {
        guard let day else {
            return op == .isNull || op == .notEquals
        }
        if op == .isNotNull { return true }
        if op == .isNull { return false }
        let today = TaskForgeDay(containing: now, calendar: calendar)
        let target = parseDay(value) ?? today
        guard let dayDate = date(day, calendar: calendar),
            let targetDate = date(target, calendar: calendar),
            let todayDate = date(today, calendar: calendar)
        else { return false }
        switch op {
        case .equals, .today:
            return dayDate == targetDate
        case .notEquals:
            return dayDate != targetDate
        case .beforeToday:
            return dayDate < todayDate
        case .afterToday:
            return dayDate > todayDate
        case .inNextDays:
            let upper = calendar.date(byAdding: .day, value: max(days ?? 0, 0), to: todayDate) ?? todayDate
            return dayDate >= todayDate && dayDate <= upper
        case .inLastDays:
            let lower = calendar.date(byAdding: .day, value: -max(days ?? 0, 0), to: todayDate) ?? todayDate
            return dayDate >= lower && dayDate <= todayDate
        case .onOrBefore:
            return dayDate <= targetDate
        case .onOrAfter:
            return dayDate >= targetDate
        case .anyOf:
            return valueList(value).contains { parseDay($0) == day }
        case .notAnyOf:
            return !valueList(value).contains { parseDay($0) == day }
        default:
            return false
        }
    }

    private static func canonicalEnum(_ value: String?) -> String {
        guard let value else { return "" }
        if let dot = value.lastIndex(of: ".") {
            return String(value[value.index(after: dot)...]).lowercased()
        }
        return value.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func valueList(_ value: String?) -> [String] {
        value?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? []
    }

    private static func parseDay(_ value: String?) -> TaskForgeDay? {
        guard let value else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }
        return TaskForgeDay(year: year, month: month, day: day)
    }

    private static func date(_ day: TaskForgeDay, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: day.year,
            month: day.month,
            day: day.day
        ))
    }
}

public enum TaskForgeStatusSymbolError: Error, LocalizedError, Equatable {
    case conflict(String)
    case unknownStatus(String)
    case sourceLineNotUnique
    case sourceLineMismatch
    case unsupportedSourceType
    case statusFieldNotFound

    public var errorDescription: String? {
        switch self {
        case let .conflict(status):
            return "TaskForge 状态符号存在冲突：\(status)"
        case let .unknownStatus(status):
            return "尚未学习 TaskForge 状态的写回符号：\(status)"
        case .sourceLineNotUnique:
            return "TaskForge 源任务行不唯一，已拒绝写回。"
        case .sourceLineMismatch:
            return "TaskForge 源任务原始内容已变化，已拒绝写回。"
        case .unsupportedSourceType:
            return "暂不支持该 TaskForge 源类型的状态写回。"
        case .statusFieldNotFound:
            return "TaskNotes frontmatter 中找不到 status 字段。"
        }
    }
}

public enum TaskForgeStatusSymbolLearner {
    public static let supportedSymbols = Set(["[ ]", "[>]", "[/]", "[x]"])

    public static func learn(
        tasks: [TaskForgeTask],
        existing: [String: String] = [:]
    ) throws -> [String: String] {
        var result = existing
        for task in tasks {
            guard task.sourceType?.lowercased() == "markdowninline",
                let line = task.originalLine,
                let symbol = symbol(in: line),
                supportedSymbols.contains(symbol)
            else { continue }
            let status = TaskForgeKanbanStatus.canonical(task.status)
            if let previous = result[status], previous != symbol {
                throw TaskForgeStatusSymbolError.conflict(status)
            }
            if let otherStatus = result.first(where: {
                $0.value == symbol && $0.key != status
            })?.key {
                throw TaskForgeStatusSymbolError.conflict(otherStatus)
            }
            result[status] = symbol
        }
        return result
    }

    public static func symbol(in line: String) -> String? {
        guard let range = line.range(of: #"\[[^\]]\]"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range])
    }
}

public struct TaskForgeStatusEdit: Equatable, Sendable {
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

public enum TaskForgeStatusSourceEditor {
    public static func update(
        task: TaskForgeTask,
        contents: String,
        targetStatus: String,
        symbols: [String: String]
    ) throws -> TaskForgeStatusEdit {
        let canonicalStatus = TaskForgeKanbanStatus.canonical(targetStatus)
        switch task.sourceType?.lowercased() {
        case "markdowninline":
            guard let expectedLine = task.originalLine else {
                throw TaskForgeStatusSymbolError.sourceLineMismatch
            }
            var lines = contents.components(separatedBy: "\n")
            let expectedIndex = task.lineNumber.map { $0 - 1 }
            let lineIndex: Int
            if let expectedIndex,
                lines.indices.contains(expectedIndex),
                lines[expectedIndex] == expectedLine
            {
                lineIndex = expectedIndex
            } else {
                let matches = lines.indices.filter { lines[$0] == expectedLine }
                guard matches.count == 1, let match = matches.first else {
                    throw matches.isEmpty
                        ? TaskForgeStatusSymbolError.sourceLineMismatch
                        : TaskForgeStatusSymbolError.sourceLineNotUnique
                }
                lineIndex = match
            }
            guard let symbol = symbols[canonicalStatus], supported(symbol) else {
                throw TaskForgeStatusSymbolError.unknownStatus(canonicalStatus)
            }
            let pattern = #"^(\s*(?:[-*+]|\d+\.)\s+)\[[^\]]\]"#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(lines[lineIndex].startIndex..., in: lines[lineIndex])
            guard regex.firstMatch(in: lines[lineIndex], range: range) != nil else {
                throw TaskForgeStatusSymbolError.sourceLineMismatch
            }
            let updatedLine = regex.stringByReplacingMatches(
                in: lines[lineIndex],
                range: range,
                withTemplate: "$1\(symbol)"
            )
            lines[lineIndex] = updatedLine
            return TaskForgeStatusEdit(
                updatedContents: lines.joined(separator: "\n"),
                lineNumber: lineIndex + 1,
                originalLine: expectedLine,
                updatedLine: updatedLine
            )
        case "tasknotes":
            var lines = contents.components(separatedBy: "\n")
            guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
                let closing = lines.dropFirst().firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces) == "---"
                })
            else {
                throw TaskForgeStatusSymbolError.statusFieldNotFound
            }
            guard let statusIndex = (1..<closing).first(where: {
                lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("status:")
            }) else {
                throw TaskForgeStatusSymbolError.statusFieldNotFound
            }
            let targetValue: String
            switch canonicalStatus {
            case "todo": targetValue = "open"
            case "inProgress": targetValue = "in-progress"
            default: targetValue = canonicalStatus
            }
            let originalLine = lines[statusIndex]
            let indentation = String(originalLine.prefix {
                $0 == " " || $0 == "\t"
            })
            let updatedLine = indentation + "status: " + targetValue
            lines[statusIndex] = updatedLine
            return TaskForgeStatusEdit(
                updatedContents: lines.joined(separator: "\n"),
                lineNumber: statusIndex + 1,
                originalLine: originalLine,
                updatedLine: updatedLine
            )
        default:
            throw TaskForgeStatusSymbolError.unsupportedSourceType
        }
    }

    private static func supported(_ symbol: String) -> Bool {
        TaskForgeStatusSymbolLearner.supportedSymbols.contains(symbol)
    }
}

public struct TaskForgeSyncIndexEntry: Codable, Equatable, Sendable {
    public var reminderIdentifier: String
    public var calendarIdentifier: String
    public var status: String
    public var sourceHash: String?
    public var sourceReference: TaskForgeTask?
    public var lastSyncAt: Date

    public init(
        reminderIdentifier: String,
        calendarIdentifier: String,
        status: String,
        sourceHash: String?,
        sourceReference: TaskForgeTask? = nil,
        lastSyncAt: Date
    ) {
        self.reminderIdentifier = reminderIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.status = status
        self.sourceHash = sourceHash
        self.sourceReference = sourceReference
        self.lastSyncAt = lastSyncAt
    }
}

public struct TaskForgeSyncIndex: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var listID: String
    public var entries: [String: TaskForgeSyncIndexEntry]

    public init(
        schemaVersion: Int = 1,
        listID: String,
        entries: [String: TaskForgeSyncIndexEntry] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.listID = listID
        self.entries = entries
    }
}

public struct TaskForgeSyncPrivateConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var taskForgeListID: String?
    public var listPrefix: String
    public var learnedSymbols: [String: String]

    public init(
        schemaVersion: Int = 1,
        taskForgeListID: String? = nil,
        listPrefix: String = "TaskForge",
        learnedSymbols: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.taskForgeListID = taskForgeListID
        self.listPrefix = listPrefix
        self.learnedSymbols = learnedSymbols
    }
}

public final class TaskForgeSyncPrivateStore: @unchecked Sendable {
    public static let defaultRoot = URL(
        fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/TaskForgeReminderSync",
        isDirectory: true
    )

    public let rootURL: URL

    public init(rootURL: URL = defaultRoot) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var configurationURL: URL {
        rootURL.appendingPathComponent("KanbanSyncConfig.json")
    }

    public var indexURL: URL {
        rootURL.appendingPathComponent("KanbanSyncIndex.json")
    }

    public func loadConfigurationReadOnly() throws -> TaskForgeSyncPrivateConfiguration? {
        guard try PrivateRuntimeDirectory.validatePrivateRootReadOnly(at: rootURL) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return nil
        }
        try PrivateRuntimeDirectory.validatePrivateFile(at: configurationURL)
        let configuration = try decode(
            TaskForgeSyncPrivateConfiguration.self,
            at: configurationURL
        )
        guard configuration.schemaVersion == 1,
            !configuration.listPrefix.isEmpty,
            !configuration.listPrefix.contains("\n"),
            !configuration.listPrefix.contains("\r"),
            configuration.learnedSymbols.allSatisfy({ key, value in
                !key.isEmpty
                    && TaskForgeStatusSymbolLearner.supportedSymbols.contains(value)
            })
        else {
            throw TaskForgeFilterConfigurationError.invalidPrivateState
        }
        return configuration
    }

    public func loadIndexReadOnly() throws -> TaskForgeSyncIndex? {
        guard try PrivateRuntimeDirectory.validatePrivateRootReadOnly(at: rootURL) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return nil
        }
        try PrivateRuntimeDirectory.validatePrivateFile(at: indexURL)
        let index = try decode(TaskForgeSyncIndex.self, at: indexURL)
        guard index.schemaVersion == 1, !index.listID.isEmpty,
            index.entries.allSatisfy({ key, entry in
                !key.isEmpty && !entry.reminderIdentifier.isEmpty
                    && !entry.calendarIdentifier.isEmpty
                    && !entry.status.isEmpty
            })
        else {
            throw TaskForgeFilterConfigurationError.invalidPrivateState
        }
        return index
    }

    public func saveConfiguration(
        _ configuration: TaskForgeSyncPrivateConfiguration
    ) throws {
        try save(configuration, to: configurationURL)
    }

    public func saveIndex(_ index: TaskForgeSyncIndex) throws {
        try save(index, to: indexURL)
    }

    private func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try PrivateRuntimeDirectory.prepareRoot(at: rootURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let temporary = rootURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try PrivateRuntimeDirectory.writePrivateFile(data, to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            try PrivateRuntimeDirectory.validatePrivateFile(at: url)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try PrivateRuntimeDirectory.validatePrivateFile(at: url)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw TaskForgeFilterConfigurationError.invalidPrivateState
        }
    }
}
