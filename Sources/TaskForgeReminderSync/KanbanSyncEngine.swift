import CoreGraphics
import CryptoKit
import Darwin
import EventKit
import Foundation
import TaskForgeReminderCore
import TaskForgeReminderEventKit

private struct KanbanFetchHandle: @unchecked Sendable {
    let rawValue: Any
}

private final class KanbanFetchResolution: @unchecked Sendable {
    init(
        _ continuation: CheckedContinuation<[EKReminder], Error>,
        cancel: @escaping @Sendable (KanbanFetchHandle) -> Void
    ) {
        self.continuation = continuation
        self.cancel = cancel
    }

    func resolve(_ result: Result<[EKReminder], Error>) {
        lock.lock()
        guard !settled, let continuation else {
            lock.unlock()
            return
        }
        settled = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func register(_ handle: KanbanFetchHandle) {
        lock.lock()
        self.handle = handle
        let shouldCancel = timedOut && !cancelIssued
        if shouldCancel { cancelIssued = true }
        lock.unlock()
        if shouldCancel { cancel(handle) }
    }

    func timeout() {
        lock.lock()
        guard !settled, let continuation else {
            lock.unlock()
            return
        }
        settled = true
        timedOut = true
        self.continuation = nil
        let handleToCancel: KanbanFetchHandle?
        if let handle, !cancelIssued {
            cancelIssued = true
            handleToCancel = handle
        } else {
            handleToCancel = nil
        }
        lock.unlock()
        if let handleToCancel { cancel(handleToCancel) }
        continuation.resume(throwing: SyncError.reminderFetchFailed)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<[EKReminder], Error>?
    private var handle: KanbanFetchHandle?
    private var settled = false
    private var timedOut = false
    private var cancelIssued = false
    private let cancel: @Sendable (KanbanFetchHandle) -> Void
}

struct KanbanSyncConfiguration {
    var taskStorePath: String
    var taskForgeListID: String?
    var listPrefix: String?
    var taskIdentifier: String?
    var backupRoot: String
    var preferencesPath: String
    var privateRoot: URL

    init(
        taskStorePath: String,
        taskForgeListID: String?,
        listPrefix: String? = nil,
        taskIdentifier: String?,
        backupRoot: String,
        preferencesPath: String = TaskForgeListConfigurationStore.defaultPreferencesPath,
        privateRoot: URL = TaskForgeSyncPrivateStore.defaultRoot
    ) {
        self.taskStorePath = taskStorePath
        self.taskForgeListID = taskForgeListID
        self.listPrefix = listPrefix
        self.taskIdentifier = taskIdentifier
        self.backupRoot = backupRoot
        self.preferencesPath = preferencesPath
        self.privateRoot = privateRoot
    }
}

struct KanbanPreview {
    var listName: String
    var totalMembers: Int
    var statusCounts: [String: Int]
    var taskForgeListIDWasConfigured: Bool
}

struct KanbanSyncCounts {
    var created = 0
    var updated = 0
    var moved = 0
    var completed = 0
    var reverseCandidates = 0
    var reverseWritten = 0
    var reverseSkipped = 0
    var conflicts = 0
    var failed = 0
}

@MainActor
final class KanbanSyncEngine {
    private let configuration: KanbanSyncConfiguration
    private let store: EKEventStore
    private let privateStore: TaskForgeSyncPrivateStore
    private var calendar: Calendar
    private var reminderObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var isReconciling = false
    private var needsAnotherPass = false
    private var resolvedListPrefix = "TaskForge"

    init(configuration: KanbanSyncConfiguration, calendar: Calendar) {
        self.configuration = configuration
        self.calendar = calendar
        self.store = EKEventStore()
        self.privateStore = TaskForgeSyncPrivateStore(
            rootURL: configuration.privateRoot
        )
    }

    deinit {
        if let reminderObserver {
            NotificationCenter.default.removeObserver(reminderObserver)
        }
        debounceTask?.cancel()
    }

    func requestReminderAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *), status == .fullAccess {
            return
        }
        if #unavailable(macOS 14.0), status == .authorized {
            return
        }
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        guard granted else {
            throw SyncError.accessDenied
        }
    }

    func preview() throws -> KanbanPreview {
        let snapshot = try loadSnapshotWithRetry()
        let (list, _) = try loadList(readOnly: true)
        let privateConfiguration = try privateStore.loadConfigurationReadOnly()
        let configured = privateConfiguration?.taskForgeListID != nil
        let tasks = try TaskForgeFilterEvaluator.select(
            tasks: snapshot.tasks,
            list: list,
            calendar: calendar
        )
        var counts: [String: Int] = [:]
        for task in tasks {
            let status = TaskForgeKanbanStatus.canonical(task.status)
            counts[status, default: 0] += 1
        }
        return KanbanPreview(
            listName: list.name,
            totalMembers: tasks.count,
            statusCounts: counts,
            taskForgeListIDWasConfigured: configured
        )
    }

    func sync() async throws -> KanbanSyncCounts {
        try await requestReminderAccess()
        return try await reconcileOnce(reason: "手动同步")
    }

    func reverse(dryRun: Bool) async throws -> KanbanSyncCounts {
        try await requestReminderAccess()
        let snapshot = try loadSnapshotWithRetry()
        let (list, listID) = try loadList(readOnly: dryRun)
        let members = try TaskForgeFilterEvaluator.select(
            tasks: snapshot.tasks,
            list: list,
            calendar: calendar
        )
        let symbols = try learnedSymbols(
            snapshot: snapshot,
            listID: listID,
            persist: !dryRun
        )
        return try await reverse(
            snapshot: snapshot,
            members: members,
            listID: listID,
            symbols: symbols,
            dryRun: dryRun
        )
    }

    func deduplicate(dryRun: Bool) async throws -> DeduplicationCounts {
        try await requestReminderAccess()
        let snapshot = try loadSnapshotWithRetry()
        let (_, listID) = try loadList(readOnly: dryRun)
        let index = try privateStore.loadIndexReadOnly()
        let reminders = try await fetchReminders(in: nil)
        let records = reminders.enumerated().compactMap {
            key, reminder -> TaskReminderDeduplicationRecord? in
            guard isManaged(reminder, snapshot: snapshot, listID: listID),
                !reminder.isCompleted,
                let marker = TaskSyncMarker.extract(from: reminder.notes),
                let decoded = TaskSyncMarker.decode(marker),
                decoded.vaultPath == snapshot.vaultPath
            else { return nil }
            let sourceReference = index?.entries[decoded.taskIdentifier]?.sourceReference
                ?? TaskSourceReference.decode(from: reminder.notes)?.task
                ?? snapshot.tasks.first(where: {
                    $0.identifier == decoded.taskIdentifier
                })
            return TaskReminderDeduplicationRecord(
                key: key,
                taskIdentifier: decoded.taskIdentifier,
                sourceIdentity: sourceReference.flatMap(TaskSourceIdentity.init),
                creationTimestamp: reminder.creationDate?.timeIntervalSince1970
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
        guard !dryRun, !plan.archiveKeys.isEmpty else { return counts }
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.calendars(for: .reminder).first?.source
        else { throw SyncError.noReminderSource }
        let archiveTitle = "TaskForge 今日 · 去重归档"
        let matching = store.calendars(for: .reminder).filter {
            $0.title == archiveTitle
        }
        guard matching.count <= 1 else { throw SyncError.noReminderSource }
        let archive: EKCalendar
        if let existing = matching.first {
            archive = existing
        } else {
            archive = EKCalendar(for: .reminder, eventStore: store)
            archive.title = archiveTitle
            archive.source = source
            try store.saveCalendar(archive, commit: true)
        }
        for key in plan.archiveKeys {
            let reminder = reminders[key]
            reminder.isCompleted = true
            reminder.calendar = archive
            reminder.notes = (reminder.notes ?? "")
                + "\nTaskForge-Dedup-Archived: 1"
            try store.save(reminder, commit: false)
        }
        try store.commit()
        return counts
    }

    func prune(dryRun: Bool) async throws -> ReminderPruneCounts {
        try await requestReminderAccess()
        let (_, listID) = try loadList(readOnly: dryRun)
        let snapshot = try loadSnapshotWithRetry()
        return try await prune(
            snapshot: snapshot,
            listID: listID,
            dryRun: dryRun
        )
    }

    private func prune(
        snapshot: TaskForgeSnapshot,
        listID: String,
        dryRun: Bool
    ) async throws -> ReminderPruneCounts {
        let baseCalendar = try stateCalendar(
            status: .todo,
            create: !dryRun
        )
        guard let baseCalendar else {
            return ReminderPruneCounts()
        }
        let pruner = ReminderPruner(
            eventStore: store,
            configuration: ReminderPruneConfiguration(
                listName: baseCalendar.title,
                localRoot: privateStore.rootURL,
                confirmationInterval: 60,
                restoreGraceInterval: 86_400,
                managedIndex: try privateStore.loadIndexReadOnly()
            ),
            log: { _ in },
            logError: { _ in }
        )
        _ = listID
        return dryRun
            ? try await pruner.dryRun(snapshot: snapshot)
            : try await pruner.advance(snapshot: snapshot)
    }

    func watch() async throws {
        try await requestReminderAccess()
        _ = try loadList(readOnly: true)
        var lastTaskStoreModification = modificationDate(
            at: configuration.taskStorePath
        )
        var lastPreferencesModification = modificationDate(
            at: configuration.preferencesPath
        )
        var lastFullReconciliation = Date.distantPast
        var lastScheduleKey = ""

        reminderObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.reconcile(reason: "Apple 提醒事项变化")
                }
            }
        }

        await reconcile(reason: "启动")
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let currentTaskStoreModification = modificationDate(
                at: configuration.taskStorePath
            )
            let currentPreferencesModification = modificationDate(
                at: configuration.preferencesPath
            )
            if currentTaskStoreModification != lastTaskStoreModification
                || currentPreferencesModification != lastPreferencesModification
            {
                lastTaskStoreModification = currentTaskStoreModification
                lastPreferencesModification = currentPreferencesModification
                await reconcile(reason: "TaskForge 任务库或列表规则变化")
            }

            let now = Date()
            if now.timeIntervalSince(lastFullReconciliation) >= 60 {
                lastFullReconciliation = now
                await reconcile(reason: "60 秒漏事件兜底")
            }
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: now
            )
            if let hour = components.hour,
                components.minute == 0,
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
                    await reconcile(reason: "\(hour):00 全量校准")
                }
            }
        }
    }

    private func reconcile(reason: String) async {
        if isReconciling {
            needsAnotherPass = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }
        repeat {
            needsAnotherPass = false
            do {
                _ = try await reconcileOnce(reason: reason)
            } catch {
                fputs("TaskForge 同步失败：\(error.localizedDescription)\n", stderr)
            }
        } while needsAnotherPass
    }

    private func reconcileOnce(reason: String) async throws -> KanbanSyncCounts {
        let snapshot = try loadSnapshotWithRetry()
        let (list, listID) = try loadList(readOnly: false)
        let members = try TaskForgeFilterEvaluator.select(
            tasks: snapshot.tasks,
            list: list,
            calendar: calendar
        )
        let symbols = try learnedSymbols(
            snapshot: snapshot,
            listID: listID,
            persist: true
        )
        var counts = try await reverse(
            snapshot: snapshot,
            members: members,
            listID: listID,
            symbols: symbols,
            dryRun: false
        )
        let refreshedSnapshot = (try? loadSnapshotWithRetry()) ?? snapshot
        let refreshedMembers = (try? TaskForgeFilterEvaluator.select(
            tasks: refreshedSnapshot.tasks,
            list: list,
            calendar: calendar
        )) ?? members
        let forwardCounts = try await forward(
            snapshot: refreshedSnapshot,
            members: refreshedMembers,
            listID: listID,
            dryRun: false
        )
        counts.created += forwardCounts.created
        counts.updated += forwardCounts.updated
        counts.moved += forwardCounts.moved
        counts.completed += forwardCounts.completed
        counts.conflicts += forwardCounts.conflicts
        counts.failed += forwardCounts.failed
        _ = try await prune(
            snapshot: refreshedSnapshot,
            listID: listID,
            dryRun: false
        )
        _ = reason
        return counts
    }

    private func loadList(readOnly: Bool) throws -> (TaskForgeCustomList, String) {
        let existing = try privateStore.loadConfigurationReadOnly()
        if let configured = existing?.taskForgeListID,
            let requested = configuration.taskForgeListID,
            configured != requested
        {
            throw TaskForgeFilterConfigurationError.invalidPrivateState
        }
        let listID = configuration.taskForgeListID ?? existing?.taskForgeListID
        guard let listID,
            !listID.isEmpty,
            listID == listID.trimmingCharacters(in: .whitespacesAndNewlines),
            !listID.contains("\n"),
            !listID.contains("\r")
        else {
            throw TaskForgeFilterConfigurationError.missingList("未配置")
        }
        resolvedListPrefix = configuration.listPrefix
            ?? existing?.listPrefix
            ?? "TaskForge"
        guard !resolvedListPrefix.isEmpty,
            !resolvedListPrefix.contains("\n"),
            !resolvedListPrefix.contains("\r"),
            resolvedListPrefix.count <= 80
        else {
            throw TaskForgeFilterConfigurationError.invalidCondition(
                "列表前缀"
            )
        }
        let list = try TaskForgeListConfigurationStore.load(
            listID: listID,
            preferencesPath: configuration.preferencesPath
        )
        guard list.kanbanMode else {
            throw TaskForgeFilterConfigurationError.invalidCondition("目标列表不是 Kanban")
        }
        if !readOnly {
            var state = existing ?? TaskForgeSyncPrivateConfiguration()
            state.taskForgeListID = listID
            state.listPrefix = resolvedListPrefix
            try privateStore.saveConfiguration(state)
        }
        return (list, listID)
    }

    private func learnedSymbols(
        snapshot: TaskForgeSnapshot,
        listID: String,
        persist: Bool
    ) throws -> [String: String] {
        let existing = try privateStore.loadConfigurationReadOnly()
        let learned = try TaskForgeStatusSymbolLearner.learn(
            tasks: snapshot.tasks,
            existing: existing?.learnedSymbols ?? [:]
        )
        guard persist else { return learned }
        var state = existing ?? TaskForgeSyncPrivateConfiguration()
        state.taskForgeListID = listID
        state.listPrefix = resolvedListPrefix
        state.learnedSymbols = learned
        try privateStore.saveConfiguration(state)
        return learned
    }

    private func forward(
        snapshot: TaskForgeSnapshot,
        members: [TaskForgeTask],
        listID: String,
        dryRun: Bool
    ) async throws -> KanbanSyncCounts {
        let calendars = try stateCalendars(
            statusKeys: Set(members.map {
                TaskForgeKanbanStatus.canonical($0.status)
            }),
            create: !dryRun
        )
        let reminders = try await fetchReminders(in: nil)
        let managed = reminders.filter {
            isManaged($0, snapshot: snapshot, listID: listID)
        }
        var counts = KanbanSyncCounts()
        var claimed = Set<String>()
        var index = try privateStore.loadIndexReadOnly()
            ?? TaskForgeSyncIndex(listID: listID)
        var seenTaskIDs = Set<String>()
        for task in members {
            if let taskIdentifier = configuration.taskIdentifier,
                taskIdentifier != task.identifier
            {
                continue
            }
            guard seenTaskIDs.insert(task.identifier).inserted else {
                counts.conflicts += 1
                continue
            }
            let statusKey = TaskForgeKanbanStatus.canonical(task.status)
            let candidates = managed.filter { reminder in
                TaskSyncMarker.decode(
                    TaskSyncMarker.extract(from: reminder.notes) ?? ""
                )?.taskIdentifier == task.identifier
            }
            guard candidates.count <= 1 else {
                counts.conflicts += 1
                continue
            }
            let reminder: EKReminder
            let isNew: Bool
            if let current = candidates.first {
                reminder = current
                isNew = false
                claimed.insert(current.calendarItemIdentifier)
            } else if let entry = index.entries[task.identifier],
                let current = managed.first(where: {
                    $0.calendarItemIdentifier == entry.reminderIdentifier
                }),
                !claimed.contains(current.calendarItemIdentifier)
            {
                reminder = current
                isNew = false
                claimed.insert(current.calendarItemIdentifier)
            } else {
                reminder = EKReminder(eventStore: store)
                isNew = true
            }
            if (statusKey == TaskForgeKanbanStatus.done.rawValue
                || statusKey == TaskForgeKanbanStatus.cancelled.rawValue)
                && isNew
            {
                continue
            }
            let desiredCalendar: EKCalendar?
            if statusKey == TaskForgeKanbanStatus.done.rawValue
                || statusKey == TaskForgeKanbanStatus.cancelled.rawValue
            {
                desiredCalendar = nil
            } else {
                desiredCalendar = calendars[statusKey]
            }
            if let desiredCalendar, reminder.calendar?.calendarIdentifier
                != desiredCalendar.calendarIdentifier
            {
                if !dryRun {
                    reminder.calendar = desiredCalendar
                }
                counts.moved += 1
            }
            if isNew, let desiredCalendar, !dryRun {
                reminder.calendar = desiredCalendar
            }
            let changed = apply(
                task: task,
                vaultPath: snapshot.vaultPath,
                to: reminder
            )
            if !dryRun && (isNew || changed) {
                try store.save(reminder, commit: false)
                if isNew { counts.created += 1 } else { counts.updated += 1 }
                if statusKey == TaskForgeKanbanStatus.done.rawValue
                    || statusKey == TaskForgeKanbanStatus.cancelled.rawValue
                {
                    counts.completed += 1
                }
            }
            index.entries[task.identifier] = TaskForgeSyncIndexEntry(
                reminderIdentifier: reminder.calendarItemIdentifier,
                calendarIdentifier: desiredCalendar?.calendarIdentifier
                    ?? reminder.calendar?.calendarIdentifier ?? "completed",
                status: statusKey,
                sourceHash: index.entries[task.identifier]?.sourceHash,
                sourceReference: task,
                lastSyncAt: Date()
            )
        }
        let baseCalendar = try stateCalendar(
            status: .todo,
            create: !dryRun
        )
        for reminder in managed where !claimed.contains(
            reminder.calendarItemIdentifier
        ) {
            guard let marker = TaskSyncMarker.extract(from: reminder.notes),
                let decoded = TaskSyncMarker.decode(marker),
                decoded.vaultPath == snapshot.vaultPath,
                configuration.taskIdentifier == nil
                    || configuration.taskIdentifier == decoded.taskIdentifier,
                let task = snapshot.tasks.first(where: {
                    $0.identifier == decoded.taskIdentifier
                })
            else { continue }
            let status = TaskForgeKanbanStatus.canonical(task.status)
            var unclaimedChanged = false
            if status == TaskForgeKanbanStatus.done.rawValue
                || status == TaskForgeKanbanStatus.cancelled.rawValue
            {
                unclaimedChanged = apply(
                    task: task,
                    vaultPath: snapshot.vaultPath,
                    to: reminder
                )
                if !reminder.isCompleted {
                    reminder.isCompleted = true
                    unclaimedChanged = true
                }
            }
            if let baseCalendar,
                reminder.calendar?.calendarIdentifier != baseCalendar.calendarIdentifier
            {
                if !dryRun {
                    reminder.calendar = baseCalendar
                    try store.save(reminder, commit: false)
                    unclaimedChanged = false
                }
                counts.moved += 1
            }
            if !dryRun && unclaimedChanged {
                try store.save(reminder, commit: false)
            }
            if !dryRun {
                index.entries[task.identifier] = TaskForgeSyncIndexEntry(
                    reminderIdentifier: reminder.calendarItemIdentifier,
                    calendarIdentifier: reminder.calendar?.calendarIdentifier
                        ?? "unknown",
                    status: status,
                    sourceHash: index.entries[task.identifier]?.sourceHash,
                    sourceReference: task,
                    lastSyncAt: Date()
                )
            }
        }
        if !dryRun {
            try store.commit()
            index.listID = listID
            try privateStore.saveIndex(index)
        }
        return counts
    }

    private func reverse(
        snapshot: TaskForgeSnapshot,
        members: [TaskForgeTask],
        listID: String,
        symbols: [String: String],
        dryRun: Bool
    ) async throws -> KanbanSyncCounts {
        let reminders = try await fetchReminders(in: nil)
        let memberIDs = Set(members.map(\.identifier))
        var counts = KanbanSyncCounts()
        var index = try privateStore.loadIndexReadOnly()
            ?? TaskForgeSyncIndex(listID: listID)
        let stateCalendarNames = try stateCalendarNameMap()
        for reminder in reminders where isManaged(
            reminder,
            snapshot: snapshot,
            listID: listID
        ) {
            guard let decoded = TaskSyncMarker.decode(
                TaskSyncMarker.extract(from: reminder.notes) ?? ""
            ) else { continue }
            guard let task = snapshot.tasks.first(where: {
                $0.identifier == decoded.taskIdentifier
            }) else { continue }
            if configuration.taskIdentifier != nil,
                configuration.taskIdentifier != task.identifier
            {
                continue
            }
            let currentStatus = TaskForgeKanbanStatus.canonical(task.status)
            let calendarStatus: String?
            if let title = reminder.calendar?.title {
                calendarStatus = stateCalendarNames[title]
            } else {
                calendarStatus = nil
            }
            var targetStatus = calendarStatus ?? currentStatus
            let lastStatus = index.entries[task.identifier]?.status
            let taskStatusChanged = lastStatus.map {
                $0 != currentStatus
            } ?? false
            let appleStatusChanged: Bool
            if let calendarStatus {
                appleStatusChanged = lastStatus.map {
                    calendarStatus != $0
                } ?? (calendarStatus != currentStatus)
            } else {
                appleStatusChanged = false
            }
            var sourceHash: String?
            if !reminder.isCompleted,
                memberIDs.contains(task.identifier),
                calendarStatus == nil
            {
                if !dryRun {
                    try moveBack(reminder: reminder, status: currentStatus)
                    index.entries[task.identifier] = TaskForgeSyncIndexEntry(
                        reminderIdentifier: reminder.calendarItemIdentifier,
                        calendarIdentifier: reminder.calendar?.calendarIdentifier
                            ?? "unknown",
                        status: currentStatus,
                        sourceHash: index.entries[task.identifier]?.sourceHash,
                        sourceReference: task,
                        lastSyncAt: Date()
                    )
                }
                continue
            }
            if reminder.isCompleted && !task.isCompleted {
                counts.reverseCandidates += 1
                if dryRun {
                    continue
                }
                do {
                    sourceHash = try writeSourceStatus(
                        task: task,
                        snapshot: snapshot,
                        targetStatus: TaskForgeKanbanStatus.done.rawValue,
                        symbols: symbols
                    )
                    try await verifyTaskForgeStatus(
                        task: task,
                        targetStatus: TaskForgeKanbanStatus.done.rawValue
                    )
                    counts.reverseWritten += 1
                    targetStatus = TaskForgeKanbanStatus.done.rawValue
                } catch {
                    counts.reverseSkipped += 1
                    try moveBack(
                        reminder: reminder,
                        status: currentStatus
                    )
                    index.entries[task.identifier] = TaskForgeSyncIndexEntry(
                        reminderIdentifier: reminder.calendarItemIdentifier,
                        calendarIdentifier: reminder.calendar?.calendarIdentifier
                            ?? "unknown",
                        status: currentStatus,
                        sourceHash: index.entries[task.identifier]?.sourceHash,
                        sourceReference: task,
                        lastSyncAt: Date()
                    )
                    continue
                }
            } else if !reminder.isCompleted,
                !task.isCompleted,
                appleStatusChanged,
                !taskStatusChanged,
                memberIDs.contains(task.identifier)
            {
                counts.reverseCandidates += 1
                if dryRun {
                    continue
                }
                do {
                    sourceHash = try writeSourceStatus(
                        task: task,
                        snapshot: snapshot,
                        targetStatus: targetStatus,
                        symbols: symbols
                    )
                    try await verifyTaskForgeStatus(
                        task: task,
                        targetStatus: targetStatus
                    )
                    counts.reverseWritten += 1
                } catch {
                    counts.reverseSkipped += 1
                    try moveBack(
                        reminder: reminder,
                        status: currentStatus
                    )
                    index.entries[task.identifier] = TaskForgeSyncIndexEntry(
                        reminderIdentifier: reminder.calendarItemIdentifier,
                        calendarIdentifier: reminder.calendar?.calendarIdentifier
                            ?? "unknown",
                        status: currentStatus,
                        sourceHash: index.entries[task.identifier]?.sourceHash,
                        sourceReference: task,
                        lastSyncAt: Date()
                    )
                    continue
                }
            }
            if !dryRun {
                index.entries[task.identifier] = TaskForgeSyncIndexEntry(
                    reminderIdentifier: reminder.calendarItemIdentifier,
                    calendarIdentifier: reminder.calendar?.calendarIdentifier ?? "completed",
                    status: targetStatus,
                    sourceHash: sourceHash,
                    sourceReference: task,
                    lastSyncAt: Date()
                )
            }
        }
        if !dryRun {
            index.listID = listID
            try privateStore.saveIndex(index)
        }
        return counts
    }

    private func apply(
        task: TaskForgeTask,
        vaultPath: String,
        to reminder: EKReminder
    ) -> Bool {
        let status = TaskForgeKanbanStatus.canonical(task.status)
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let desiredTitle = status == TaskForgeKanbanStatus.cancelled.rawValue
            ? "已取消 · \(title.isEmpty ? "（无标题 TaskForge 任务）" : title)"
            : (title.isEmpty ? "（无标题 TaskForge 任务）" : title)
        let desiredNotes = [
            TaskSyncMarker.make(
                vaultPath: vaultPath,
                taskIdentifier: task.identifier
            ),
            "来源：TaskForge"
        ].joined(separator: "\n")
        let desiredDueDate = task.scheduled.map {
            TaskReminderTiming.dueDateComponents(for: $0, calendar: calendar)
        }
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
        if reminder.priority != applePriority(task.priority) {
            reminder.priority = applePriority(task.priority)
            changed = true
        }
        if reminder.notes != desiredNotes {
            reminder.notes = desiredNotes
            changed = true
        }
        let shouldBeCompleted = task.isCompleted || reminder.isCompleted
        if reminder.isCompleted != shouldBeCompleted {
            reminder.isCompleted = shouldBeCompleted
            changed = true
        }
        if reminder.url != nil {
            reminder.url = nil
            changed = true
        }
        return changed
    }

    private func writeSourceStatus(
        task: TaskForgeTask,
        snapshot: TaskForgeSnapshot,
        targetStatus: String,
        symbols: [String: String]
    ) throws -> String {
        guard let sourcePath = task.filePath else {
            throw TaskForgeStatusSymbolError.sourceLineMismatch
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let vaultURL = URL(fileURLWithPath: snapshot.vaultPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = vaultURL.path.hasSuffix("/")
            ? vaultURL.path
            : vaultURL.path + "/"
        guard sourceURL.path.hasPrefix(prefix) else {
            throw SyncError.sourceOutsideVault(sourceURL.path)
        }
        let originalData = try Data(contentsOf: sourceURL)
        guard let contents = String(data: originalData, encoding: .utf8) else {
            throw SyncError.sourceEncodingInvalid(sourceURL.path)
        }
        let edit = try TaskForgeStatusSourceEditor.update(
            task: task,
            contents: contents,
            targetStatus: targetStatus,
            symbols: symbols
        )
        guard let updatedData = edit.updatedContents.data(using: .utf8) else {
            throw SyncError.sourceEncodingInvalid(sourceURL.path)
        }
        guard updatedData != originalData else {
            return sha256(originalData)
        }
        let safeIdentifier = task.identifier.map { character in
            character.isLetter || character.isNumber
                || character == "-" || character == "_"
                ? character
                : "_"
        }
        _ = try TaskSourceBackupStore(
            backupsRootURL: URL(
                fileURLWithPath: configuration.backupRoot,
                isDirectory: true
            )
        ).save(
            originalData,
            fileName: "\(String(safeIdentifier))-\(sourceURL.lastPathComponent).bak"
        )
        try updatedData.write(to: sourceURL, options: [.atomic])
        guard try Data(contentsOf: sourceURL) == updatedData else {
            throw SyncError.writeVerificationFailed(sourceURL.path)
        }
        return sha256(updatedData)
    }

    private func verifyTaskForgeStatus(
        task: TaskForgeTask,
        targetStatus: String,
        timeout: TimeInterval = 15
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let refreshed = try? loadSnapshotWithRetry(),
                let current = refreshed.tasks.first(where: {
                    $0.identifier == task.identifier
                })
            {
                if TaskForgeKanbanStatus.canonical(current.status)
                    == TaskForgeKanbanStatus.canonical(targetStatus)
                {
                    return
                }
            } else if targetStatus == TaskForgeKanbanStatus.done.rawValue,
                let sourcePath = task.filePath,
                let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)),
                let contents = String(data: data, encoding: .utf8),
                TaskCompletionSourceInspector.isCompleted(
                    task: task,
                    contents: contents
                )
            {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SyncError.taskForgeVerificationTimedOut("受管任务")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func moveBack(reminder: EKReminder, status: String) throws {
        guard let calendar = try stateCalendar(rawStatus: status, create: true)
        else { return }
        reminder.isCompleted = false
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
    }

    private func stateCalendars(
        statuses: [TaskForgeKanbanStatus],
        create: Bool
    ) throws -> [String: EKCalendar] {
        var result: [String: EKCalendar] = [:]
        for status in Set(statuses) where !status.isTerminal {
            if let calendar = try stateCalendar(status: status, create: create) {
                result[status.rawValue] = calendar
            }
        }
        return result
    }

    private func stateCalendars(
        statusKeys: Set<String>,
        create: Bool
    ) throws -> [String: EKCalendar] {
        var result: [String: EKCalendar] = [:]
        for statusKey in statusKeys
            where statusKey != TaskForgeKanbanStatus.done.rawValue
                && statusKey != TaskForgeKanbanStatus.cancelled.rawValue
        {
            if let calendar = try stateCalendar(
                rawStatus: statusKey,
                create: create
            ) {
                result[statusKey] = calendar
            }
        }
        return result
    }

    private func stateCalendarNameMap() throws -> [String: String] {
        var result: [String: String] = [:]
        for status in TaskForgeKanbanStatus.allCases where !status.isTerminal {
            result[stateTitle(status)] = status.rawValue
        }
        return result
    }

    private func stateCalendar(
        status: TaskForgeKanbanStatus?,
        create: Bool
    ) throws -> EKCalendar? {
        guard let status, !status.isTerminal else { return nil }
        return try stateCalendar(rawStatus: status.rawValue, create: create)
    }

    private func stateCalendar(
        rawStatus: String,
        create: Bool
    ) throws -> EKCalendar? {
        let canonicalStatus = TaskForgeKanbanStatus.canonical(rawStatus)
        guard canonicalStatus != TaskForgeKanbanStatus.done.rawValue,
            canonicalStatus != TaskForgeKanbanStatus.cancelled.rawValue
        else { return nil }
        let status = TaskForgeKanbanStatus(rawValue: canonicalStatus)
        let title = stateTitle(rawStatus: canonicalStatus)
        let matching = store.calendars(for: .reminder).filter {
            $0.title == title
        }
        guard matching.count <= 1 else {
            throw SyncError.noReminderSource
        }
        if let existing = matching.first {
            try setColor(existing, status: status, save: true)
            return existing
        }
        guard create else { return nil }
        if canonicalStatus == TaskForgeKanbanStatus.todo.rawValue,
            let legacy = store.calendars(for: .reminder).first(where: {
                $0.title == "TaskForge 今日"
            })
        {
            legacy.title = title
            try setColor(legacy, status: status, save: true)
            return legacy
        }
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.calendars(for: .reminder).first?.source
        else {
            throw SyncError.noReminderSource
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title
        calendar.source = source
        try setColor(calendar, status: status, save: false)
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func setColor(
        _ calendar: EKCalendar,
        status: TaskForgeKanbanStatus?,
        save: Bool
    ) throws {
        let color: (CGFloat, CGFloat, CGFloat)
        switch status {
        case nil: color = (0.56, 0.56, 0.58)
        case .todo: color = (0.20, 0.47, 0.96)
        case .scheduled: color = (0.69, 0.32, 0.86)
        case .ready: color = (0.20, 0.78, 0.35)
        case .inProgress: color = (0.00, 0.78, 0.75)
        case .onHold: color = (1.00, 0.58, 0.00)
        case .deferred: color = (0.56, 0.56, 0.58)
        case .blocked: color = (1.00, 0.23, 0.19)
        case .someday: color = (0.35, 0.34, 0.84)
        case .done, .cancelled: return
        }
        calendar.cgColor = CGColor(
            srgbRed: color.0,
            green: color.1,
            blue: color.2,
            alpha: 1
        )
        if save {
            try store.saveCalendar(calendar, commit: true)
        }
    }

    private func stateTitle(_ status: TaskForgeKanbanStatus) -> String {
        stateTitle(rawStatus: status.rawValue)
    }

    private func stateTitle(rawStatus: String) -> String {
        let status = TaskForgeKanbanStatus(rawValue: rawStatus)
        let name: String
        switch status {
        case .todo: name = "待办"
        case .scheduled: name = "已计划"
        case .ready: name = "就绪"
        case .inProgress: name = "进行中"
        case .onHold: name = "暂停"
        case .deferred: name = "已推迟"
        case .blocked: name = "已阻塞"
        case .someday: name = "将来某天"
        case .done: name = "完成"
        case .cancelled: name = "取消"
        case nil: name = rawStatus
        }
        return "\(resolvedListPrefix) · \(name)"
    }

    private func isManaged(
        _ reminder: EKReminder,
        snapshot: TaskForgeSnapshot,
        listID: String
    ) -> Bool {
        guard !(reminder.notes ?? "").contains("TaskForge-Dedup-Archived: 1")
        else { return false }
        if let marker = TaskSyncMarker.extract(from: reminder.notes),
            let decoded = TaskSyncMarker.decode(marker),
            decoded.vaultPath == snapshot.vaultPath
        {
            return true
        }
        guard let index = try? privateStore.loadIndexReadOnly(),
            index.listID == listID
        else { return false }
        return index.entries.values.contains {
            $0.reminderIdentifier == reminder.calendarItemIdentifier
        }
    }

    private func fetchReminders(in calendars: [EKCalendar]?) async throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: calendars)
        return try await withCheckedThrowingContinuation { continuation in
            let resolution = KanbanFetchResolution(
                continuation,
                cancel: { [store] handle in
                    Task { @MainActor in
                        store.cancelFetchRequest(handle.rawValue)
                    }
                }
            )
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + 30
            ) {
                resolution.timeout()
            }
            let request = store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    resolution.resolve(.failure(SyncError.reminderFetchFailed))
                    return
                }
                resolution.resolve(.success(reminders))
            }
            resolution.register(KanbanFetchHandle(rawValue: request))
        }
    }

    private func loadSnapshotWithRetry() throws -> TaskForgeSnapshot {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try TaskForgeTaskStore.load(at: configuration.taskStorePath)
            } catch {
                lastError = error
                if attempt < 3 { usleep(200_000) }
            }
        }
        throw lastError ?? TaskForgeTaskStoreError.truncated
    }

    private func applePriority(_ value: String?) -> Int {
        switch value?.lowercased() {
        case "highest", "high", "taskpriority.highest", "taskpriority.high":
            return 1
        case "medium", "taskpriority.medium":
            return 5
        case "low", "lowest", "taskpriority.low", "taskpriority.lowest":
            return 9
        default:
            return 0
        }
    }

    private func modificationDate(at path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date
    }
}
