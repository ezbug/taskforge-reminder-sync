import Darwin
import Foundation
import TaskForgeReminderCore

private enum RunMode {
    case checkConfig
    case dryRun
    case audit
    case deduplicateDryRun
    case deduplicate
    case sync
    case reverseDryRun
    case reverseOnce
    case pruneDryRun
    case pruneOnce
    case restoreLastPrune
    case watch
    case help
}

private enum CommandParsingError: Error, LocalizedError {
    case conflictingRunModes

    var errorDescription: String? {
        "不能同时指定多个运行模式。"
    }
}

private struct Options {
    var mode: RunMode = .dryRun
    var listName = "TaskForge 今日"
    var taskStorePath = TaskForgeTaskStore.defaultPath
    var requestedDay: TaskForgeDay?
    var taskIdentifier: String?
    var backupRoot = TaskSourceWriter.defaultBackupRoot

    static func parse(_ arguments: [String], calendar: Calendar) throws -> Options {
        var options = Options()
        var selectedMode: RunMode?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--check-config":
                try select(.checkConfig, into: &selectedMode)
            case "--dry-run":
                try select(.dryRun, into: &selectedMode)
            case "--audit":
                try select(.audit, into: &selectedMode)
            case "--deduplicate-dry-run":
                try select(.deduplicateDryRun, into: &selectedMode)
            case "--deduplicate":
                try select(.deduplicate, into: &selectedMode)
            case "--sync":
                try select(.sync, into: &selectedMode)
            case "--reverse-dry-run":
                try select(.reverseDryRun, into: &selectedMode)
            case "--reverse-once":
                try select(.reverseOnce, into: &selectedMode)
            case "--prune-dry-run":
                try select(.pruneDryRun, into: &selectedMode)
            case "--prune-once":
                try select(.pruneOnce, into: &selectedMode)
            case "--restore-last-prune":
                try select(.restoreLastPrune, into: &selectedMode)
            case "--watch":
                try select(.watch, into: &selectedMode)
            case "--help", "-h":
                try select(.help, into: &selectedMode)
            case "--list-name":
                index += 1
                options.listName = try value(after: argument, at: index, in: arguments)
            case "--task-store":
                index += 1
                options.taskStorePath = NSString(
                    string: try value(after: argument, at: index, in: arguments)
                ).expandingTildeInPath
            case "--date":
                index += 1
                options.requestedDay = try parseDay(
                    try value(after: argument, at: index, in: arguments),
                    calendar: calendar
                )
            case "--task-id":
                index += 1
                options.taskIdentifier = try value(
                    after: argument,
                    at: index,
                    in: arguments
                )
            case "--backup-root":
                index += 1
                options.backupRoot = NSString(
                    string: try value(after: argument, at: index, in: arguments)
                ).expandingTildeInPath
            default:
                throw SyncError.unknownArgument(argument)
            }
            index += 1
        }
        options.mode = selectedMode ?? .dryRun
        return options
    }

    private static func select(
        _ mode: RunMode,
        into selectedMode: inout RunMode?
    ) throws {
        guard selectedMode == nil else {
            throw CommandParsingError.conflictingRunModes
        }
        selectedMode = mode
    }

    private static func value(
        after argument: String,
        at index: Int,
        in arguments: [String]
    ) throws -> String {
        guard index < arguments.count else {
            throw SyncError.missingArgumentValue(argument)
        }
        return arguments[index]
    }

    private static func parseDay(
        _ value: String,
        calendar: Calendar
    ) throws -> TaskForgeDay {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard
            pieces.count == 3,
            pieces[0].count == 4,
            pieces[1].count == 2,
            pieces[2].count == 2,
            let year = Int(pieces[0]),
            let month = Int(pieces[1]),
            let day = Int(pieces[2])
        else {
            throw SyncError.invalidDate(value)
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard
            let date = calendar.date(from: components),
            calendar.component(.year, from: date) == year,
            calendar.component(.month, from: date) == month,
            calendar.component(.day, from: date) == day
        else {
            throw SyncError.invalidDate(value)
        }
        return TaskForgeDay(year: year, month: month, day: day)
    }
}

@main
private struct TaskForgeReminderSyncCommand {
    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            let options = try Options.parse(
                Array(CommandLine.arguments.dropFirst()),
                calendar: calendar
            )

            #if DEBUG
            if
                ProcessInfo.processInfo.environment[
                    "TASKFORGE_REMINDER_SYNC_TEST_PARSE_ONLY"
                ] == "1"
            {
                print("参数解析完成")
                return
            }
            #endif

            switch options.mode {
            case .help:
                printHelp()
            case .checkConfig:
                try checkConfig(options: options, calendar: calendar)
            case .dryRun:
                try printPreview(options: options, calendar: calendar)
            case .audit, .deduplicateDryRun, .deduplicate,
                 .sync, .reverseDryRun, .reverseOnce, .pruneDryRun,
                 .pruneOnce, .restoreLastPrune, .watch:
                try await run(options: options, calendar: calendar)
            }
        } catch {
            fputs("错误：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func checkConfig(options: Options, calendar: Calendar) throws {
        let snapshot = try loadSnapshotWithRetry(at: options.taskStorePath)
        let requestedDay = options.requestedDay
            ?? TaskForgeDay(containing: Date(), calendar: calendar)
        let todayTasks = snapshot.openTasksScheduled(on: requestedDay)
        let taskForgeExists = FileManager.default.fileExists(
            atPath: "/Applications/TaskForge.app"
        )

        print("TaskForge：\(taskForgeExists ? "已安装" : "未在 /Applications 找到")")
        print("任务库：\(options.taskStorePath)")
        print("任务库版本：v\(snapshot.version)")
        print("Vault：\(snapshot.vaultPath)")
        print("缓存任务总数：\(snapshot.tasks.count)")
        print("\(format(requestedDay)) 未完成任务：\(todayTasks.count)")
        print("提醒事项目标列表：\(options.listName)")
        print("备份目录：\(options.backupRoot)")
        print("配置检查不会请求提醒事项权限，也不会写入任何内容。")
    }

    @MainActor
    private static func run(options: Options, calendar: Calendar) async throws {
        let configuration = SyncConfiguration(
            listName: options.listName,
            taskStorePath: options.taskStorePath,
            requestedDay: options.requestedDay,
            taskIdentifier: options.taskIdentifier,
            backupRoot: options.backupRoot
        )
        let engine = SyncEngine(configuration: configuration, calendar: calendar)
        try await engine.requestReminderAccess()

        switch options.mode {
        case .audit:
            let report = try await engine.auditReminderMappings()
            printAudit(report)
        case .deduplicateDryRun:
            let counts = try await engine.deduplicateActiveReminders(
                dryRun: true
            )
            print(
                "去重预演：重复组 \(counts.duplicateGroups)，"
                    + "保留 \(counts.preserved)，将归档 \(counts.archived)。"
            )
            print("预演模式：没有修改提醒事项。")
        case .deduplicate:
            let counts = try await engine.deduplicateActiveReminders(
                dryRun: false
            )
            let forward = try await engine.forward()
            let report = try await engine.auditReminderMappings()
            print(
                "去重完成：重复组 \(counts.duplicateGroups)，"
                    + "保留 \(counts.preserved)，归档 \(counts.archived)。"
            )
            print("归档列表：\(options.listName) · 去重归档")
            print(
                "重新关联：\(forward.relinked)，更新 \(forward.updated)，"
                    + "新建 \(forward.created)。"
            )
            printAudit(report)
        case .sync:
            let reverse = try await engine.reverse(
                dryRun: false,
                taskIdentifier: options.taskIdentifier,
                requireCandidate: options.taskIdentifier != nil
            )
            let forward = try await engine.forward()
            let prune = try await engine.prune(dryRun: false)
            print(
                "双向同步完成：反向写入 \(reverse.written)，"
                    + "正向新建 \(forward.created)，更新 \(forward.updated)，"
                    + "重新关联 \(forward.relinked)，无需变化 \(forward.unchanged)，"
                    + "冲突 \(forward.conflicts)；"
                    + "清理首次 \(prune.firstSeen)，等待 \(prune.waiting)，"
                    + "删除 \(prune.deleted)，失败 \(prune.failed)。"
            )
        case .reverseDryRun:
            let counts = try await engine.reverse(
                dryRun: true,
                taskIdentifier: options.taskIdentifier,
                requireCandidate: options.taskIdentifier != nil
            )
            print("反向预览完成：候选 \(counts.candidates)，没有写入文件。")
        case .reverseOnce:
            let counts = try await engine.reverse(
                dryRun: false,
                taskIdentifier: options.taskIdentifier,
                requireCandidate: true
            )
            print("反向同步完成：写入 \(counts.written)，失败 \(counts.failed)。")
        case .pruneDryRun:
            let counts = try await engine.prune(dryRun: true)
            print(
                "清理预演：扫描 \(counts.scanned)，首次候选 \(counts.firstSeen)，"
                    + "已满足二次确认 \(counts.ready)。"
            )
            print("预演模式：没有写候选账本，没有删除提醒。")
        case .pruneOnce:
            let counts = try await engine.prune(dryRun: false)
            print(
                "清理推进：扫描 \(counts.scanned)，首次 \(counts.firstSeen)，"
                    + "等待 \(counts.waiting)，删除 \(counts.deleted)，"
                    + "失败 \(counts.failed)。"
            )
        case .restoreLastPrune:
            let counts = try await engine.restoreLastPrune()
            print(
                "清理恢复：恢复 \(counts.restored)，失败 \(counts.failed)。"
            )
        case .watch:
            try await engine.watch()
        case .checkConfig, .dryRun, .help:
            break
        }
    }

    private static func printPreview(options: Options, calendar: Calendar) throws {
        let snapshot = try loadSnapshotWithRetry(at: options.taskStorePath)
        let requestedDay = options.requestedDay
            ?? TaskForgeDay(containing: Date(), calendar: calendar)
        let tasks = snapshot.openTasksScheduled(on: requestedDay)

        print("日期：\(format(requestedDay))")
        print("TaskForge 任务库：\(options.taskStorePath)")
        print("今日未完成任务：\(tasks.count) 个")
        for task in tasks {
            let time: String
            if let scheduledTime = task.scheduled?.time {
                time = String(
                    format: "%02d:%02d",
                    scheduledTime.hour,
                    scheduledTime.minute
                )
            } else {
                time = "全天"
            }
            print("- [\(time)] \(task.title)")
        }
        print("\n预览模式：没有读取或写入提醒事项。")
    }

    private static func loadSnapshotWithRetry(at path: String) throws -> TaskForgeSnapshot {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try TaskForgeTaskStore.load(at: path)
            } catch {
                lastError = error
                if attempt < 3 {
                    usleep(200_000)
                }
            }
        }
        throw lastError ?? TaskForgeTaskStoreError.truncated
    }

    private static func format(_ day: TaskForgeDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    private static func printHelp() {
        print(
            """
            TaskForge 今日任务 ↔ Apple 提醒事项

            用法：
              TaskForgeReminderSync --check-config [--date YYYY-MM-DD]
              TaskForgeReminderSync --dry-run [--date YYYY-MM-DD]
              TaskForgeReminderSync --audit
              TaskForgeReminderSync --deduplicate-dry-run
              TaskForgeReminderSync --deduplicate
              TaskForgeReminderSync --sync [--task-id ID]
              TaskForgeReminderSync --reverse-dry-run [--task-id ID]
              TaskForgeReminderSync --reverse-once --task-id ID
              TaskForgeReminderSync --prune-dry-run
              TaskForgeReminderSync --prune-once
              TaskForgeReminderSync --restore-last-prune
              TaskForgeReminderSync --watch

            选项：
              --list-name NAME      目标提醒事项列表（默认：TaskForge 今日）
              --task-store PATH     TaskForge tasks.v6.bin 路径
              --date DATE           指定要同步的本地日期
              --task-id ID          只处理一个 TaskForge 任务
              --backup-root PATH    反向写入前的备份目录
              --dry-run             只列出今日任务，不请求权限（默认）
              --audit               只读审计受管提醒中的重复 ID 与源位置
              --deduplicate-dry-run  预演将保留和归档的重复提醒数量
              --deduplicate          将冗余活跃提醒移到可恢复的归档列表
              --reverse-dry-run     预览 Apple 完成状态的反向写入
              --reverse-once        执行一次反向写入并等待 TaskForge 回读
              --prune-dry-run       只读预演提醒清理，不写候选账本
              --prune-once          推进一轮双扫描确认和清理
              --restore-last-prune  恢复最近一批已删除提醒
              --sync                反向写入后再正向同步一次
              --watch               常驻近实时双向同步
            """
        )
    }

    private static func printAudit(_ report: TaskReminderAuditReport) {
        print("受管提醒事项：\(report.managedReminderCount)")
        print("重复 TaskForge ID 组：\(report.duplicateTaskIdentifierGroups)")
        print(
            "重复活跃源位置组："
                + "\(report.duplicateActiveSourceIdentityGroups)"
        )
        print(
            "重复历史任务实例组："
                + "\(report.duplicateCompletedOccurrenceGroups)"
        )
        print("历史源位置复用组：\(report.historicalSourceReuseGroups)")
        print("缺少可审计源身份：\(report.missingSourceIdentityCount)")
        print("去重状态：\(report.isDuplicateFree ? "通过" : "发现冲突")")
    }
}
