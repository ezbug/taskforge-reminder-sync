import CryptoKit
import Darwin
import EventKit
import Foundation
import TaskForgeReminderCore
import TaskForgeReminderEventKit

struct SyncConfiguration {
    var listName: String
    var taskStorePath: String
    var requestedDay: TaskForgeDay?
    var taskIdentifier: String?
    var backupRoot: String
}

enum SyncError: Error, LocalizedError {
    case unknownArgument(String)
    case missingArgumentValue(String)
    case invalidDate(String)
    case accessDenied
    case noReminderSource
    case reverseCandidateNotFound(String)
    case missingSourceFile(String)
    case sourceOutsideVault(String)
    case sourceEncodingInvalid(String)
    case backupFailed(String)
    case writeVerificationFailed(String)
    case taskForgeVerificationTimedOut(String)

    var errorDescription: String? {
        switch self {
        case let .unknownArgument(value):
            return "未知参数：\(value)"
        case let .missingArgumentValue(value):
            return "参数 \(value) 缺少取值。"
        case let .invalidDate(value):
            return "日期必须是有效的 YYYY-MM-DD：\(value)"
        case .accessDenied:
            return "没有获得提醒事项完整访问权限。请到“系统设置 → 隐私与安全性 → 提醒事项”中允许。"
        case .noReminderSource:
            return "找不到可以创建提醒事项列表的账户。"
        case let .reverseCandidateNotFound(identifier):
            return "找不到 Apple 已完成、TaskForge 未完成的目标任务：\(identifier)"
        case let .missingSourceFile(path):
            return "TaskForge 源文件不存在：\(path)"
        case let .sourceOutsideVault(path):
            return "为避免越界写入，已拒绝 Vault 之外的源文件：\(path)"
        case let .sourceEncodingInvalid(path):
            return "TaskForge 源文件不是有效的 UTF-8：\(path)"
        case let .backupFailed(path):
            return "创建源文件备份失败：\(path)"
        case let .writeVerificationFailed(path):
            return "写入后内容校验失败：\(path)"
        case let .taskForgeVerificationTimedOut(title):
            return "源文件已写入，但等待 TaskForge 确认完成超时：\(title)"
        }
    }
}

struct ForwardCounts {
    var created = 0
    var updated = 0
    var relinked = 0
    var unchanged = 0
    var conflicts = 0
}

struct ReverseCounts {
    var candidates = 0
    var written = 0
    var skipped = 0
    var failed = 0
}

struct DeduplicationCounts {
    var duplicateGroups = 0
    var preserved = 0
    var archived = 0
}

struct TaskSourceWriteReceipt {
    let sourcePath: String
    let backupPath: String
    let beforeHash: String
    let afterHash: String
    let lineNumber: Int
    let updatedLine: String
}

enum TaskSourceWriter {
    static let defaultBackupRoot =
        "\(NSHomeDirectory())/Library/Application Support/TaskForgeReminderSync/Backups"

    static func complete(
        task: TaskForgeTask,
        vaultPath: String,
        completionDay: TaskForgeDay,
        backupRoot: String
    ) throws -> TaskSourceWriteReceipt {
        guard let sourcePath = task.filePath else {
            throw TaskCompletionEditorError.missingSourceMetadata
        }
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let vaultURL = URL(fileURLWithPath: vaultPath).standardizedFileURL
        let vaultPrefix = vaultURL.path.hasSuffix("/") ? vaultURL.path : vaultURL.path + "/"
        guard sourceURL.path.hasPrefix(vaultPrefix) else {
            throw SyncError.sourceOutsideVault(sourceURL.path)
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SyncError.missingSourceFile(sourceURL.path)
        }

        let originalData = try Data(contentsOf: sourceURL)
        guard let contents = String(data: originalData, encoding: .utf8) else {
            throw SyncError.sourceEncodingInvalid(sourceURL.path)
        }
        let edit = try TaskCompletionEditor.complete(
            task: task,
            contents: contents,
            on: completionDay
        )
        guard let updatedData = edit.updatedContents.data(using: .utf8) else {
            throw SyncError.sourceEncodingInvalid(sourceURL.path)
        }

        let backupDirectory = try makeBackupDirectory(root: backupRoot)
        let safeName = sourceURL.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let backupURL = backupDirectory.appendingPathComponent(
            "\(task.identifier)-\(safeName).bak"
        )
        do {
            try originalData.write(to: backupURL, options: [.atomic])
        } catch {
            throw SyncError.backupFailed(backupURL.path)
        }

        try updatedData.write(to: sourceURL, options: [.atomic])
        let verified = try Data(contentsOf: sourceURL)
        guard verified == updatedData else {
            throw SyncError.writeVerificationFailed(sourceURL.path)
        }

        return TaskSourceWriteReceipt(
            sourcePath: sourceURL.path,
            backupPath: backupURL.path,
            beforeHash: sha256(originalData),
            afterHash: sha256(updatedData),
            lineNumber: edit.lineNumber,
            updatedLine: edit.updatedLine
        )
    }

    private static func makeBackupDirectory(root: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class SyncEngine {
    private let configuration: SyncConfiguration
    private var calendar: Calendar
    private let store: EKEventStore
    private let pruner: ReminderPruner
    private var reminderObserver: NSObjectProtocol?
    private var reminderDebounceTask: Task<Void, Never>?
    private var isReconciling = false
    private var needsAnotherPass = false

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
            log: { message in
                print("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
            },
            logError: { message in
                fputs(
                    "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n",
                    stderr
                )
            }
        )
    }

    deinit {
        if let reminderObserver {
            NotificationCenter.default.removeObserver(reminderObserver)
        }
        reminderDebounceTask?.cancel()
    }

    func requestReminderAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        log("提醒事项权限状态：\(status.rawValue)")
        if #available(macOS 14.0, *), status == .fullAccess {
            log("提醒事项权限：完整访问")
            return
        }
        if #unavailable(macOS 14.0), status == .authorized {
            log("提醒事项权限：已授权")
            return
        }

        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestFullAccessToReminders { granted, error in
                    Self.resume(continuation, granted: granted, error: error)
                }
            }
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, error in
                    Self.resume(continuation, granted: granted, error: error)
                }
            }
        }
        guard granted else {
            throw SyncError.accessDenied
        }
        log("提醒事项权限请求：已批准")
    }

    func auditReminderMappings() async throws -> TaskReminderAuditReport {
        let snapshot = try loadSnapshotWithRetry()
        guard
            let reminderCalendar = store.calendars(for: .reminder)
                .first(where: { $0.title == configuration.listName })
        else {
            return TaskReminderAuditPolicy.analyze([])
        }
        let reminders = await fetchReminders(in: reminderCalendar)
        let records = reminders.compactMap {
            reminder -> TaskReminderAuditRecord? in
            guard
                let marker = TaskSyncMarker.extract(from: reminder.notes),
                let decoded = TaskSyncMarker.decode(marker),
                decoded.vaultPath == snapshot.vaultPath
            else {
                return nil
            }
            let sourceReference = TaskSourceReference.decode(
                from: reminder.notes
            )
            let sourceIdentity = sourceReference.flatMap {
                TaskSourceIdentity(task: $0.task)
            }
            return TaskReminderAuditRecord(
                taskIdentifier: decoded.taskIdentifier,
                sourceIdentity: sourceIdentity,
                isCompleted: reminder.isCompleted,
                scheduledDay: sourceReference?.task.scheduled?.day
            )
        }
        return TaskReminderAuditPolicy.analyze(records)
    }

    func deduplicateActiveReminders(
        dryRun: Bool
    ) async throws -> DeduplicationCounts {
        let snapshot = try loadSnapshotWithRetry()
        guard
            let reminderCalendar = store.calendars(for: .reminder)
                .first(where: { $0.title == configuration.listName })
        else {
            return DeduplicationCounts()
        }
        let reminders = await fetchReminders(in: reminderCalendar)
        let records = reminders.enumerated().compactMap {
            index, reminder -> TaskReminderDeduplicationRecord? in
            guard
                !reminder.isCompleted,
                let marker = TaskSyncMarker.extract(from: reminder.notes),
                let decoded = TaskSyncMarker.decode(marker),
                decoded.vaultPath == snapshot.vaultPath
            else {
                return nil
            }
            let sourceIdentity = TaskSourceReference.decode(
                from: reminder.notes
            ).flatMap {
                TaskSourceIdentity(task: $0.task)
            }
            return TaskReminderDeduplicationRecord(
                key: index,
                taskIdentifier: decoded.taskIdentifier,
                sourceIdentity: sourceIdentity,
                creationTimestamp: reminder.creationDate?
                    .timeIntervalSince1970
                    ?? .greatestFiniteMagnitude
            )
        }
        let plan = TaskReminderDeduplicationPolicy.plan(
            records: records,
            currentTaskIdentifiers: Set(snapshot.tasks.map(\.identifier))
        )
        let counts = DeduplicationCounts(
            duplicateGroups: plan.duplicateGroups,
            preserved: plan.preservedKeys.count,
            archived: plan.archiveKeys.count
        )
        guard !dryRun, !plan.archiveKeys.isEmpty else {
            return counts
        }

        let archiveCalendar = try findOrCreateArchiveCalendar(
            source: reminderCalendar.source
        )
        for key in plan.archiveKeys {
            reminders[key].calendar = archiveCalendar
            try store.save(reminders[key], commit: false)
        }
        try store.commit()
        log(
            "去重归档：重复组 \(counts.duplicateGroups)，"
                + "保留 \(counts.preserved)，归档 \(counts.archived)"
        )
        return counts
    }

    func reverse(
        dryRun: Bool,
        taskIdentifier: String?,
        requireCandidate: Bool
    ) async throws -> ReverseCounts {
        let snapshot = try loadSnapshotWithRetry()
        guard
            let reminderCalendar = store.calendars(for: .reminder)
                .first(where: { $0.title == configuration.listName })
        else {
            if requireCandidate {
                throw SyncError.reverseCandidateNotFound(taskIdentifier ?? "全部")
            }
            return ReverseCounts()
        }
        let reminders = await fetchReminders(in: reminderCalendar)
        var counts = ReverseCounts()
        for reminder in reminders where reminder.isCompleted {
            guard
                let marker = TaskSyncMarker.extract(from: reminder.notes),
                let decoded = TaskSyncMarker.decode(marker),
                decoded.vaultPath == snapshot.vaultPath
            else {
                continue
            }
            if let taskIdentifier, decoded.taskIdentifier != taskIdentifier {
                continue
            }
            guard
                let task = TaskSourceReference.resolveTask(
                    markerTaskIdentifier: decoded.taskIdentifier,
                    snapshotTasks: snapshot.tasks,
                    reminderNotes: reminder.notes
                )
            else {
                counts.skipped += 1
                continue
            }
            guard !task.isCompleted else {
                counts.skipped += 1
                continue
            }

            counts.candidates += 1
            let completionDate = reminder.completionDate ?? Date()
            let completionDay = TaskForgeDay(containing: completionDate, calendar: calendar)
            do {
                guard let sourcePath = task.filePath else {
                    throw TaskCompletionEditorError.missingSourceMetadata
                }
                let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
                guard let source = String(data: sourceData, encoding: .utf8) else {
                    throw SyncError.sourceEncodingInvalid(sourcePath)
                }
                if TaskCompletionSourceInspector.isCompleted(
                    task: task,
                    contents: source
                ) {
                    counts.skipped += 1
                    continue
                }
                let edit = try TaskCompletionEditor.complete(
                    task: task,
                    contents: source,
                    on: completionDay
                )
                if dryRun {
                    log("反向预览：\(task.title)")
                    log("  文件：\(sourcePath):\(edit.lineNumber)")
                    log("  原行：\(edit.originalLine)")
                    log("  新行：\(edit.updatedLine)")
                    continue
                }

                let taskStoreModificationBefore = modificationDate(
                    at: configuration.taskStorePath
                )
                let receipt = try TaskSourceWriter.complete(
                    task: task,
                    vaultPath: snapshot.vaultPath,
                    completionDay: completionDay,
                    backupRoot: configuration.backupRoot
                )
                counts.written += 1
                log("反向写入：\(task.title)")
                log("  文件：\(receipt.sourcePath):\(receipt.lineNumber)")
                log("  备份：\(receipt.backupPath)")
                log("  SHA-256：\(receipt.beforeHash) -> \(receipt.afterHash)")
                try await verifyTaskForgeCompletion(
                    originalTask: task,
                    receipt: receipt,
                    taskStoreModificationBefore: taskStoreModificationBefore,
                    timeoutSeconds: 15
                )
                log("  TaskForge 回读：done")
            } catch let error as TaskCompletionEditorError
                where error.isSafeUnattendedSkip
            {
                counts.skipped += 1
                if requireCandidate {
                    throw error
                }
            } catch {
                counts.failed += 1
                logError("反向跳过 \(task.title)：\(error.localizedDescription)")
                if requireCandidate {
                    throw error
                }
            }
        }

        if requireCandidate, counts.candidates == 0 {
            throw SyncError.reverseCandidateNotFound(taskIdentifier ?? "全部")
        }
        return counts
    }

    func forward() async throws -> ForwardCounts {
        let snapshot = try loadSnapshotWithRetry()
        let requestedDay = configuration.requestedDay
            ?? TaskForgeDay(containing: Date(), calendar: calendar)
        let todayTasks = snapshot.openTasksScheduled(on: requestedDay)
        let reminderCalendar = try findOrCreateReminderCalendar()
        let existing = await fetchReminders(in: reminderCalendar)
        let matchRecords = existing.enumerated().compactMap {
            index, reminder -> TaskReminderMatchRecord? in
            guard
                let marker = TaskSyncMarker.extract(from: reminder.notes),
                let decoded = TaskSyncMarker.decode(marker),
                decoded.vaultPath == snapshot.vaultPath
            else {
                return nil
            }
            let sourceReference = TaskSourceReference.decode(
                from: reminder.notes
            )
            let sourceIdentity = sourceReference.flatMap {
                TaskSourceIdentity(task: $0.task)
            }
            return TaskReminderMatchRecord(
                key: index,
                taskIdentifier: decoded.taskIdentifier,
                sourceIdentity: sourceIdentity,
                reminderIsCompleted: reminder.isCompleted,
                scheduledDay: sourceReference?.task.scheduled?.day
            )
        }
        let todayIdentifiers = Set(todayTasks.map(\.identifier))

        var counts = ForwardCounts()
        var claimedReminderKeys = Set<Int>()
        var processedTaskIdentifiers = Set<String>()
        var processedSourceIdentities = Set<TaskSourceIdentity>()
        for task in snapshot.tasks {
            let marker = TaskSyncMarker.make(
                vaultPath: snapshot.vaultPath,
                taskIdentifier: task.identifier
            )
            let match = TaskReminderMatchPolicy.select(
                task: task,
                records: matchRecords,
                claimedKeys: claimedReminderKeys
            )
            let matchedKey: Int?
            let wasRelinked: Bool
            switch match {
            case let .exact(key):
                matchedKey = key
                wasRelinked = false
            case let .source(key):
                matchedKey = key
                wasRelinked = true
            case .none:
                matchedKey = nil
                wasRelinked = false
            case .ambiguous:
                counts.conflicts += 1
                logError(
                    "正向去重冲突 \(task.title)：存在多个同一 TaskForge ID 或源位置的提醒事项，"
                        + "已拒绝新建。"
                )
                continue
            }

            guard todayIdentifiers.contains(task.identifier) || matchedKey != nil else {
                continue
            }
            let sourceIdentity = TaskSourceIdentity(task: task)
            guard processedTaskIdentifiers.insert(task.identifier).inserted else {
                counts.conflicts += 1
                logError("正向去重冲突 \(task.title)：任务库中存在重复 TaskForge ID，已拒绝新建。")
                continue
            }
            if
                let sourceIdentity,
                !processedSourceIdentities.insert(sourceIdentity).inserted
            {
                counts.conflicts += 1
                logError("正向去重冲突 \(task.title)：任务库中存在重复源位置，已拒绝新建。")
                continue
            }

            let existingReminder = matchedKey.map { existing[$0] }
            let reminder = existingReminder ?? EKReminder(eventStore: store)
            let isNew = matchedKey == nil
            if isNew {
                reminder.calendar = reminderCalendar
            } else if let matchedKey {
                claimedReminderKeys.insert(matchedKey)
            }
            let changed = apply(task: task, marker: marker, to: reminder)
            if changed || isNew {
                try store.save(reminder, commit: false)
                if isNew {
                    counts.created += 1
                } else {
                    counts.updated += 1
                    if wasRelinked {
                        counts.relinked += 1
                    }
                }
            } else {
                counts.unchanged += 1
            }
        }

        if counts.created > 0 || counts.updated > 0 {
            try store.commit()
        }
        log(
            "正向同步：新建 \(counts.created)，更新 \(counts.updated)，"
                + "重新关联 \(counts.relinked)，无需变化 \(counts.unchanged)，"
                + "冲突 \(counts.conflicts)"
        )
        return counts
    }

    func prune(dryRun: Bool) async throws -> ReminderPruneCounts {
        let snapshot = try loadSnapshotWithRetry()
        return dryRun
            ? try await pruner.dryRun(snapshot: snapshot)
            : try await pruner.advance(snapshot: snapshot)
    }

    func restoreLastPrune() async throws -> ReminderPruneCounts {
        try await pruner.restoreLast()
    }

    func reconcile(reason: String) async {
        if isReconciling {
            needsAnotherPass = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        repeat {
            needsAnotherPass = false
            do {
                log("开始双向同步：\(reason)")
                let reverseCounts = try await reverse(
                    dryRun: false,
                    taskIdentifier: nil,
                    requireCandidate: false
                )
                log(
                    "反向同步：候选 \(reverseCounts.candidates)，写入 \(reverseCounts.written)，"
                        + "跳过 \(reverseCounts.skipped)，失败 \(reverseCounts.failed)"
                )
                _ = try await forward()
                let pruneCounts = try await prune(dryRun: false)
                log(
                    "清理同步：首次 \(pruneCounts.firstSeen)，"
                        + "等待 \(pruneCounts.waiting)，删除 \(pruneCounts.deleted)，"
                        + "失败 \(pruneCounts.failed)"
                )
            } catch {
                logError("双向同步失败：\(error.localizedDescription)")
            }
        } while needsAnotherPass
    }

    func watch() async throws {
        try await requestReminderAccess()
        var lastTaskStoreModification = modificationDate(
            at: configuration.taskStorePath
        )
        var lastReminderPoll = Date.distantPast
        var lastScheduleKey = ""

        reminderObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.reminderDebounceTask?.cancel()
                self.reminderDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.reconcile(reason: "Apple 提醒事项变化")
                }
            }
        }

        log("近实时监听已启动")
        await reconcile(reason: "启动")
        lastReminderPoll = Date()

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let currentModification = modificationDate(at: configuration.taskStorePath)
            if currentModification != lastTaskStoreModification {
                lastTaskStoreModification = currentModification
                await reconcile(reason: "TaskForge 任务库变化")
            }

            let now = Date()
            if now.timeIntervalSince(lastReminderPoll) >= 60 {
                lastReminderPoll = now
                await reconcile(reason: "每分钟漏失兜底")
            }

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: now
            )
            if
                let hour = components.hour,
                let minute = components.minute,
                minute == 0,
                [7, 11, 15].contains(hour)
            {
                let key = String(
                    format: "%04d-%02d-%02d-%02d",
                    components.year ?? 0,
                    components.month ?? 0,
                    components.day ?? 0,
                    hour
                )
                if key != lastScheduleKey {
                    lastScheduleKey = key
                    await reconcile(reason: "\(hour):00 定时兜底")
                }
            }
        }
    }

    private func apply(
        task: TaskForgeTask,
        marker: String,
        to reminder: EKReminder
    ) -> Bool {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let desiredTitle = title.isEmpty ? "（无标题 TaskForge 任务）" : title
        let desiredDueDate = task.scheduled.map {
            TaskReminderTiming.dueDateComponents(for: $0, calendar: calendar)
        }
        let desiredNotes = taskNotes(task: task, marker: marker)
        let desiredCompletion = ReminderCompletionPolicy.desiredCompletion(
            taskIsCompleted: task.isCompleted,
            reminderIsCompleted: reminder.isCompleted
        )

        var changed = false
        if reminder.title != desiredTitle {
            reminder.title = desiredTitle
            changed = true
        }
        if !ReminderDueDatePolicy.isEquivalent(
            reminder.dueDateComponents,
            desiredDueDate
        ) {
            reminder.dueDateComponents = desiredDueDate
            changed = true
        }
        if reminder.notes != desiredNotes {
            reminder.notes = desiredNotes
            changed = true
        }
        if reminder.url != nil {
            reminder.url = nil
            changed = true
        }
        if reminder.isCompleted != desiredCompletion {
            reminder.isCompleted = desiredCompletion
            changed = true
        }
        return changed
    }

    private func taskNotes(task: TaskForgeTask, marker: String) -> String {
        var lines = [
            marker,
            TaskSourceReference(task: task).encodedLine,
            "来源：TaskForge",
            "状态：\(task.status)"
        ]
        if let sourceType = task.sourceType, !sourceType.isEmpty {
            lines.append("来源类型：\(sourceType)")
        }
        if let filePath = task.filePath, !filePath.isEmpty {
            lines.append("文件：\(filePath)")
        }
        if let lineNumber = task.lineNumber {
            lines.append("行号：\(lineNumber)")
        }
        return lines.joined(separator: "\n")
    }

    private func findOrCreateReminderCalendar() throws -> EKCalendar {
        if
            let existing = store.calendars(for: .reminder)
                .first(where: { $0.title == configuration.listName })
        {
            return existing
        }
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.calendars(for: .reminder).first?.source
        else {
            throw SyncError.noReminderSource
        }
        let reminderCalendar = EKCalendar(for: .reminder, eventStore: store)
        reminderCalendar.title = configuration.listName
        reminderCalendar.source = source
        try store.saveCalendar(reminderCalendar, commit: true)
        return reminderCalendar
    }

    private func findOrCreateArchiveCalendar(
        source: EKSource
    ) throws -> EKCalendar {
        let archiveName = "\(configuration.listName) · 去重归档"
        if
            let existing = store.calendars(for: .reminder)
                .first(where: { $0.title == archiveName })
        {
            return existing
        }
        let archiveCalendar = EKCalendar(for: .reminder, eventStore: store)
        archiveCalendar.title = archiveName
        archiveCalendar.source = source
        try store.saveCalendar(archiveCalendar, commit: true)
        return archiveCalendar
    }

    private func fetchReminders(in reminderCalendar: EKCalendar) async -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [reminderCalendar])
        return await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func loadSnapshotWithRetry() throws -> TaskForgeSnapshot {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try TaskForgeTaskStore.load(at: configuration.taskStorePath)
            } catch {
                lastError = error
                if attempt < 3 {
                    usleep(200_000)
                }
            }
        }
        throw lastError ?? TaskForgeTaskStoreError.truncated
    }

    private func verifyTaskForgeCompletion(
        originalTask: TaskForgeTask,
        receipt: TaskSourceWriteReceipt,
        taskStoreModificationBefore: Date?,
        timeoutSeconds: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let taskStoreWasRefreshed =
                modificationDate(at: configuration.taskStorePath)
                    != taskStoreModificationBefore
            if
                taskStoreWasRefreshed,
                sourceStillContainsCompletedLine(receipt),
                let snapshot = try? loadSnapshotWithRetry(),
                TaskCompletionReadback.confirmsCompletion(
                    of: originalTask,
                    in: snapshot.tasks
                )
            {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SyncError.taskForgeVerificationTimedOut(originalTask.title)
    }

    private func sourceStillContainsCompletedLine(
        _ receipt: TaskSourceWriteReceipt
    ) -> Bool {
        guard
            let data = try? Data(
                contentsOf: URL(fileURLWithPath: receipt.sourcePath)
            ),
            let contents = String(data: data, encoding: .utf8)
        else {
            return false
        }
        let lines = contents.components(separatedBy: "\n")
        let index = receipt.lineNumber - 1
        return lines.indices.contains(index)
            && lines[index] == receipt.updatedLine
    }

    private func modificationDate(at path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }

    nonisolated private static func resume(
        _ continuation: CheckedContinuation<Bool, Error>,
        granted: Bool,
        error: Error?
    ) {
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: granted)
        }
    }

    private func log(_ message: String) {
        print("[\(timestamp())] \(message)")
    }

    private func logError(_ message: String) {
        fputs("[\(timestamp())] \(message)\n", stderr)
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
