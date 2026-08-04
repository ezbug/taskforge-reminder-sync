import CryptoKit
import Darwin
import Dispatch
import EventKit
import Foundation
import TaskForgeReminderCore

public struct ReminderPruneConfiguration: Sendable {
    public var listName: String
    public var localRoot: URL
    public var confirmationInterval: TimeInterval
    public var restoreGraceInterval: TimeInterval
    public var managedIndex: TaskForgeSyncIndex?

    public init(
        listName: String,
        localRoot: URL,
        confirmationInterval: TimeInterval = 60,
        restoreGraceInterval: TimeInterval = 86_400,
        managedIndex: TaskForgeSyncIndex? = nil
    ) {
        self.listName = listName
        self.localRoot = localRoot
        self.confirmationInterval = confirmationInterval
        self.restoreGraceInterval = restoreGraceInterval
        self.managedIndex = managedIndex
    }
}

@MainActor
private final class ReminderPrunerOperationGate {
    static let shared = ReminderPrunerOperationGate()

    private var held: Set<String> = []
    private var waiters: [
        String: [CheckedContinuation<Void, Never>]
    ] = [:]

    func acquire(_ key: String) async {
        if held.insert(key).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        if var pending = waiters[key], !pending.isEmpty {
            let next = pending.removeFirst()
            if pending.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = pending
            }
            next.resume()
        } else {
            held.remove(key)
        }
    }
}

public struct ReminderPruneCounts: Equatable, Sendable {
    public init() {}

    public var scanned = 0
    public var firstSeen = 0
    public var waiting = 0
    public var ready = 0
    public var deleted = 0
    public var restored = 0
    public var protected = 0
    public var failed = 0
}

public enum ReminderPrunerError: Error, LocalizedError {
    case backupReminderSourceUnavailable
    case backupVerificationFailed
    case backupSchemaVersionUnsupported
    case deletionOutcomeUnresolved
    case ambiguousTargetCalendar
    case operationLockFailed
    case reminderFetchFailed
    case restoreReadbackAmbiguous
    case restoredReminderReadbackFailed

    public var errorDescription: String? {
        switch self {
        case .backupReminderSourceUnavailable:
            return "找不到备份指定的提醒事项账户，备份仍未消费。"
        case .backupVerificationFailed:
            return "清理备份写入后的回读校验失败。"
        case .backupSchemaVersionUnsupported:
            return "备份格式版本不兼容，备份仍未消费。"
        case .deletionOutcomeUnresolved:
            return "备份尚未记录可核实的实际删除结果，已拒绝恢复。"
        case .ambiguousTargetCalendar:
            return "原账户中存在多个同名提醒列表，已拒绝选择。"
        case .operationLockFailed:
            return "无法取得提醒清理操作锁。"
        case .reminderFetchFailed:
            return "提醒事项读取失败，已按失败关闭。"
        case .restoreReadbackAmbiguous:
            return "恢复尝试的提醒回读不唯一，备份仍未消费。"
        case .restoredReminderReadbackFailed:
            return "恢复提交后未能回读全部新提醒，备份仍未消费。"
        }
    }
}

private final class ReminderFetchResolution<
    Value,
    Handle: Sendable
>: @unchecked Sendable {
    init(
        _ continuation: CheckedContinuation<Value, Error>,
        cancel: @escaping @Sendable (Handle) -> Void
    ) {
        self.continuation = continuation
        self.cancel = cancel
    }

    func resolve(_ result: Result<Value, Error>) {
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

    func timeout() {
        lock.lock()
        guard !settled, let continuation else {
            lock.unlock()
            return
        }
        settled = true
        timeoutWon = true
        self.continuation = nil
        let handleToCancel = cancellationHandleLocked()
        lock.unlock()

        if let handleToCancel {
            cancel(handleToCancel)
        }
        continuation.resume(
            throwing: ReminderPrunerError.reminderFetchFailed
        )
    }

    func register(_ handle: Handle) {
        lock.lock()
        self.handle = handle
        let handleToCancel = cancellationHandleLocked()
        lock.unlock()

        if let handleToCancel {
            cancel(handleToCancel)
        }
    }

    private func cancellationHandleLocked() -> Handle? {
        guard timeoutWon, !cancelIssued, let handle else {
            return nil
        }
        cancelIssued = true
        return handle
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var handle: Handle?
    private var settled = false
    private var timeoutWon = false
    private var cancelIssued = false
    private let cancel: @Sendable (Handle) -> Void
}

enum ReminderFetchWaiter {
    typealias TimeoutScheduler = @Sendable (
        TimeInterval,
        @escaping @Sendable () -> Void
    ) -> Void

    static func wait<Value, Handle: Sendable>(
        timeout: TimeInterval = 30,
        scheduleTimeout: @escaping TimeoutScheduler = {
            interval, timeout in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + max(interval, 0),
                execute: timeout
            )
        },
        cancel: @escaping @Sendable (Handle) -> Void,
        start: (
            @escaping @Sendable (Result<Value, Error>) -> Void
        ) -> Handle
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let resolution = ReminderFetchResolution<Value, Handle>(
                continuation,
                cancel: cancel
            )
            scheduleTimeout(timeout) {
                resolution.timeout()
            }
            let handle = start { result in
                resolution.resolve(result)
            }
            resolution.register(handle)
        }
    }
}

private final class ReminderFetchRequestIdentifier: @unchecked Sendable {
    init(_ rawValue: Any) {
        self.rawValue = rawValue
    }

    let rawValue: Any
}

@MainActor
private final class ReminderFetchCanceller {
    init(eventStore: EKEventStore) {
        self.eventStore = eventStore
    }

    func cancel(_ identifier: ReminderFetchRequestIdentifier) {
        eventStore.cancelFetchRequest(identifier.rawValue)
    }

    private let eventStore: EKEventStore
}

@MainActor
public final class ReminderPruner {
    public init(
        eventStore: EKEventStore,
        configuration: ReminderPruneConfiguration,
        log: @escaping @Sendable (String) -> Void,
        logError: @escaping @Sendable (String) -> Void
    ) {
        self.eventStore = eventStore
        self.configuration = configuration
        self.localStore = ReminderPruneLocalStore(
            rootURL: configuration.localRoot
        )
        self.log = log
        self.logError = logError
    }

    public func dryRun(
        snapshot: TaskForgeSnapshot,
        now: Date = Date()
    ) async throws -> ReminderPruneCounts {
        await ReminderPrunerOperationGate.shared.acquire(operationKey)
        defer {
            ReminderPrunerOperationGate.shared.release(operationKey)
        }
        let operationLock = try operationFileLock(exclusive: false)
        defer { operationLock.unlock() }

        guard let targetCalendar = try targetCalendar() else {
            return ReminderPruneCounts()
        }
        let reminders = try await fetchReminders(in: targetCalendar)
        let observations = reminders.compactMap {
            observation(
                for: $0,
                targetCalendar: targetCalendar,
                snapshot: snapshot
            )
        }
        let prior = try localStore.loadLedgerReadOnly()
        let plan = ReminderPruneStateMachine.plan(
            observations: observations,
            prior: prior,
            targetCalendarIdentifier: targetCalendar.calendarIdentifier,
            now: now,
            confirmationInterval: configuration.confirmationInterval
        )
        let counts = counts(
            scanned: reminders.count,
            observations: observations,
            targetCalendarIdentifier: targetCalendar.calendarIdentifier,
            plan: plan
        )
        log(summary(prefix: "清理预演", counts: counts))
        return counts
    }

    public func advance(
        snapshot: TaskForgeSnapshot,
        now: Date = Date()
    ) async throws -> ReminderPruneCounts {
        await ReminderPrunerOperationGate.shared.acquire(operationKey)
        defer {
            ReminderPrunerOperationGate.shared.release(operationKey)
        }
        let operationLock = try operationFileLock(exclusive: true)
        defer { operationLock.unlock() }

        guard let targetCalendar = try targetCalendar() else {
            return ReminderPruneCounts()
        }
        let initialReminders = try await fetchReminders(in: targetCalendar)
        try reconcileUnresolvedBackup(
            targetCalendar: targetCalendar,
            reminders: initialReminders
        )
        let observations = initialReminders.compactMap {
            observation(
                for: $0,
                targetCalendar: targetCalendar,
                snapshot: snapshot
            )
        }
        let prior = try localStore.loadLedger()
        let initialPlan = ReminderPruneStateMachine.plan(
            observations: observations,
            prior: prior,
            targetCalendarIdentifier: targetCalendar.calendarIdentifier,
            now: now,
            confirmationInterval: configuration.confirmationInterval
        )
        try localStore.saveLedger(initialPlan.nextLedger)

        var counts = counts(
            scanned: initialReminders.count,
            observations: observations,
            targetCalendarIdentifier: targetCalendar.calendarIdentifier,
            plan: initialPlan
        )
        let freshReminders = try await fetchReminders(in: targetCalendar)
        var freshByIdentifier: [String: EKReminder] = [:]
        for reminder in freshReminders {
            freshByIdentifier[reminder.calendarItemIdentifier] = reminder
        }
        var confirmed: [
            (reminder: EKReminder, observation: ReminderPruneObservation)
        ] = []
        for identifier in initialPlan.readyIdentifiers {
            guard
                let current = freshByIdentifier[identifier],
                let currentObservation = observation(
                    for: current,
                    targetCalendar: targetCalendar,
                    snapshot: snapshot
                )
            else {
                continue
            }
            let recheck = ReminderPruneStateMachine.plan(
                observations: [currentObservation],
                prior: initialPlan.nextLedger,
                targetCalendarIdentifier: targetCalendar.calendarIdentifier,
                now: now,
                confirmationInterval: configuration.confirmationInterval
            )
            if recheck.readyIdentifiers == [identifier] {
                confirmed.append((current, currentObservation))
            }
        }
        counts.ready = confirmed.count
        counts.protected += initialPlan.readyIdentifiers.count - confirmed.count
        guard !confirmed.isEmpty else {
            log(summary(prefix: "清理推进", counts: counts))
            return counts
        }

        let backup = ReminderPruneBackupBatch(
            identifier: UUID(),
            createdAt: now,
            targetCalendarIdentifier: targetCalendar.calendarIdentifier,
            targetCalendarTitle: targetCalendar.title,
            targetSourceIdentifier:
                targetCalendar.source.sourceIdentifier,
            backupSchemaVersion:
                ReminderPruneRestorePolicy.currentBackupSchemaVersion,
            rulesVersion: ReminderPruneStateMachine.rulesVersion,
            items: confirmed.map {
                ReminderBackupAdapter.capture(
                    $0.reminder,
                    taskPresence: $0.observation.taskPresence
                )
            },
            actuallyDeletedIdentifiers: nil,
            restoreAttemptIdentifier: nil,
            restoredItemIdentifiers: [:],
            restoredAt: nil
        )
        let backupURL = try localStore.saveBackup(backup)
        guard try localStore.loadBackup(at: backupURL) == backup else {
            throw ReminderPrunerError.backupVerificationFailed
        }

        let confirmedIdentifiers = Set(
            confirmed.map(\.reminder.calendarItemIdentifier)
        )
        let targetCalendarIdentifier = targetCalendar.calendarIdentifier
        let targetSourceIdentifier = targetCalendar.source.sourceIdentifier
        for candidate in confirmed {
            let reminder = candidate.reminder
            do {
                try eventStore.remove(reminder, commit: false)
            } catch {
                let identifier = loggedIdentifier(
                    reminder.calendarItemIdentifier
                )
                logError(
                    "清理暂存失败 [\(identifier)]。"
                )
            }
        }

        do {
            try eventStore.commit()
        } catch {
            logError("清理提交失败，将按回读实际状态结算。")
        }
        eventStore.reset()

        var ledger = initialPlan.nextLedger
        guard
            let refreshedCalendar = eventStore.calendar(
                withIdentifier: targetCalendarIdentifier
            ),
            refreshedCalendar.source.sourceIdentifier == targetSourceIdentifier
        else {
            throw ReminderPrunerError.reminderFetchFailed
        }
        let remaining = Set(
            try await fetchReminders(in: refreshedCalendar).map(
                \.calendarItemIdentifier
            )
        )
        let actuallyDeleted = confirmedIdentifiers.subtracting(remaining)
        try localStore.recordActuallyDeletedIdentifiers(
            actuallyDeleted.sorted(),
            at: backupURL
        )
        for identifier in confirmedIdentifiers {
            if remaining.contains(identifier) {
                counts.failed += 1
            } else {
                ledger.entries.removeValue(forKey: identifier)
                counts.deleted += 1
            }
        }
        try localStore.saveLedger(ledger)
        log(summary(prefix: "清理推进", counts: counts))
        return counts
    }

    public func restoreLast(
        now: Date = Date()
    ) async throws -> ReminderPruneCounts {
        await ReminderPrunerOperationGate.shared.acquire(operationKey)
        defer {
            ReminderPrunerOperationGate.shared.release(operationKey)
        }
        let operationLock = try operationFileLock(exclusive: true)
        defer { operationLock.unlock() }

        guard let (backupURL, originalBackup) =
            try localStore.latestRestorableBackup()
        else {
            return ReminderPruneCounts()
        }
        guard
            ReminderPruneRestorePolicy.supportsBackupSchema(
                originalBackup.backupSchemaVersion
            )
        else {
            throw ReminderPrunerError.backupSchemaVersionUnsupported
        }
        guard
            let items = originalBackup.actuallyDeletedItems,
            !items.isEmpty
        else {
            throw ReminderPrunerError.deletionOutcomeUnresolved
        }

        let backup = try localStore.beginRestoreAttempt(at: backupURL)
        guard let attemptIdentifier = backup.restoreAttemptIdentifier else {
            throw ReminderPrunerError.deletionOutcomeUnresolved
        }
        var calendar = try restoreTargetCalendar(for: backup)
        var reminders = try await fetchReminders(in: calendar)
        var restoredIdentifiers = backup.restoredItemIdentifiers

        if restoredIdentifiers.isEmpty {
            var stagedCreation = false
            for item in items {
                let marker = restoreMarker(
                    backupIdentifier: backup.identifier,
                    attemptIdentifier: attemptIdentifier,
                    originalItemIdentifier: item.originalItemIdentifier
                )
                let matches = reminders.filter {
                    containsRestoreMarker($0.notes, marker: marker)
                }
                guard matches.count <= 1 else {
                    throw ReminderPrunerError.restoreReadbackAmbiguous
                }
                guard matches.isEmpty else {
                    continue
                }
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = calendar
                ReminderBackupAdapter.restore(item, into: reminder)
                reminder.notes = addingRestoreMarker(
                    to: item.notes,
                    marker: marker
                )
                try eventStore.save(reminder, commit: false)
                stagedCreation = true
            }
            if stagedCreation {
                let calendarIdentifier = calendar.calendarIdentifier
                let sourceIdentifier = calendar.source.sourceIdentifier
                do {
                    try eventStore.commit()
                } catch {
                    eventStore.reset()
                    throw error
                }
                eventStore.reset()
                calendar = try exactRestoreCalendar(
                    identifier: calendarIdentifier,
                    sourceIdentifier: sourceIdentifier
                )
            }
            reminders = try await fetchReminders(in: calendar)
            for item in items {
                let marker = restoreMarker(
                    backupIdentifier: backup.identifier,
                    attemptIdentifier: attemptIdentifier,
                    originalItemIdentifier: item.originalItemIdentifier
                )
                let matches = reminders.filter {
                    containsRestoreMarker($0.notes, marker: marker)
                }
                guard matches.count == 1, let match = matches.first else {
                    throw matches.isEmpty
                        ? ReminderPrunerError.restoredReminderReadbackFailed
                        : ReminderPrunerError.restoreReadbackAmbiguous
                }
                restoredIdentifiers[item.originalItemIdentifier] =
                    match.calendarItemIdentifier
            }
            try localStore.recordRestoreReadback(
                restoredIdentifiers,
                at: backupURL
            )
        }

        let restoredPairs = try restoreReadbackPairs(
            items: items,
            identifiers: restoredIdentifiers,
            reminders: reminders
        )
        do {
            for pair in restoredPairs {
                ReminderBackupAdapter.restore(pair.item, into: pair.reminder)
                try eventStore.save(pair.reminder, commit: false)
            }
            try eventStore.commit()
        } catch {
            eventStore.reset()
            throw error
        }

        let restoredCalendarIdentifier = calendar.calendarIdentifier
        let restoredSourceIdentifier = calendar.source.sourceIdentifier
        eventStore.reset()
        let refreshedCalendar = try exactRestoreCalendar(
            identifier: restoredCalendarIdentifier,
            sourceIdentifier: restoredSourceIdentifier
        )
        let refreshed = try await fetchReminders(in: refreshedCalendar)
        let finalPairs = try restoreReadbackPairs(
            items: items,
            identifiers: restoredIdentifiers,
            reminders: refreshed
        )
        var ledger = try localStore.loadLedger()
        for pair in finalPairs {
            let reminder = pair.reminder
            let identifier = reminder.calendarItemIdentifier
            ledger.entries[identifier] =
                ReminderPruneRestorePolicy.graceLedgerEntry(
                fingerprint: fingerprint(
                    reminder: reminder,
                    targetCalendarIdentifier:
                        refreshedCalendar.calendarIdentifier,
                    presence: pair.item.taskPresence
                ),
                calendarIdentifier: refreshedCalendar.calendarIdentifier,
                now: now,
                restoreGraceInterval: configuration.restoreGraceInterval
            )
        }
        try localStore.saveLedger(ledger)
        try localStore.markRestored(at: backupURL, date: now)

        var counts = ReminderPruneCounts()
        counts.scanned = refreshed.count
        counts.restored = finalPairs.count
        log(summary(prefix: "清理恢复", counts: counts))
        return counts
    }

    private let eventStore: EKEventStore
    private let configuration: ReminderPruneConfiguration
    private let localStore: ReminderPruneLocalStore
    private let log: @Sendable (String) -> Void
    private let logError: @Sendable (String) -> Void

    private var operationKey: String {
        configuration.localRoot.standardizedFileURL
            .resolvingSymlinksInPath().path
    }

    private func operationFileLock(
        exclusive: Bool
    ) throws -> ReminderPruneOperationFileLock {
        do {
            return try ReminderPruneOperationFileLock(
                exclusive: exclusive
            )
        } catch {
            throw ReminderPrunerError.operationLockFailed
        }
    }

    nonisolated static func uniqueTargetCalendarMatch<Element>(
        _ matches: [Element]
    ) throws -> Element? {
        switch matches.count {
        case 0:
            return nil
        case 1:
            return matches[0]
        default:
            throw ReminderPrunerError.ambiguousTargetCalendar
        }
    }

    private func targetCalendar() throws -> EKCalendar? {
        let matches = eventStore.calendars(for: .reminder).filter {
            $0.title == configuration.listName
        }
        return try Self.uniqueTargetCalendarMatch(matches)
    }

    private func reconcileUnresolvedBackup(
        targetCalendar: EKCalendar,
        reminders: [EKReminder]
    ) throws {
        guard
            let (url, backup) =
                try localStore.latestUnresolvedDeletionBackup()
        else {
            return
        }
        guard
            backup.targetCalendarIdentifier
                == targetCalendar.calendarIdentifier,
            backup.targetSourceIdentifier
                == targetCalendar.source.sourceIdentifier
        else {
            throw ReminderPrunerError.deletionOutcomeUnresolved
        }
        let remaining = Set(
            reminders.map(\.calendarItemIdentifier)
        )
        let attempted = Set(
            backup.items.map(\.originalItemIdentifier)
        )
        try localStore.recordActuallyDeletedIdentifiers(
            attempted.subtracting(remaining).sorted(),
            at: url
        )
    }

    private func restoreTargetCalendar(
        for backup: ReminderPruneBackupBatch
    ) throws -> EKCalendar {
        let calendars = eventStore.calendars(for: .reminder)
        if let exact = calendars.first(where: {
            $0.calendarIdentifier == backup.targetCalendarIdentifier
                && $0.source.sourceIdentifier
                    == backup.targetSourceIdentifier
        }) {
            return exact
        }
        let named = calendars.filter {
            $0.title == backup.targetCalendarTitle
                && $0.source.sourceIdentifier
                    == backup.targetSourceIdentifier
        }
        guard named.count <= 1 else {
            throw ReminderPrunerError.ambiguousTargetCalendar
        }
        if let existing = named.first {
            return existing
        }
        guard let source = eventStore.sources.first(where: {
            $0.sourceIdentifier == backup.targetSourceIdentifier
        }) else {
            throw ReminderPrunerError.backupReminderSourceUnavailable
        }
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = backup.targetCalendarTitle
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func exactRestoreCalendar(
        identifier: String,
        sourceIdentifier: String
    ) throws -> EKCalendar {
        guard let calendar = eventStore.calendars(for: .reminder).first(where: {
            $0.calendarIdentifier == identifier
                && $0.source.sourceIdentifier == sourceIdentifier
        }) else {
            throw ReminderPrunerError.restoredReminderReadbackFailed
        }
        return calendar
    }

    private func fetchReminders(
        in calendar: EKCalendar
    ) async throws -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: [calendar])
        let canceller = ReminderFetchCanceller(eventStore: eventStore)
        return try await ReminderFetchWaiter.wait(
            timeout: 30,
            cancel: { identifier in
                Task { @MainActor in
                    canceller.cancel(identifier)
                }
            },
            start: { completion in
                let identifier = eventStore.fetchReminders(
                    matching: predicate
                ) { reminders in
                    guard let reminders else {
                        completion(
                            .failure(
                                ReminderPrunerError.reminderFetchFailed
                            )
                        )
                        return
                    }
                    completion(.success(reminders))
                }
                return ReminderFetchRequestIdentifier(identifier)
            }
        )
    }

    private func restoreReadbackPairs(
        items: [ReminderPruneBackupItem],
        identifiers: [String: String],
        reminders: [EKReminder]
    ) throws -> [
        (item: ReminderPruneBackupItem, reminder: EKReminder)
    ] {
        guard
            Set(identifiers.keys)
                == Set(items.map(\.originalItemIdentifier))
        else {
            throw ReminderPrunerError.restoredReminderReadbackFailed
        }
        var remindersByIdentifier: [String: EKReminder] = [:]
        for reminder in reminders {
            let identifier = reminder.calendarItemIdentifier
            guard remindersByIdentifier[identifier] == nil else {
                throw ReminderPrunerError.restoreReadbackAmbiguous
            }
            remindersByIdentifier[identifier] = reminder
        }
        return try items.map { item in
            guard
                let restoredIdentifier =
                    identifiers[item.originalItemIdentifier],
                let reminder =
                    remindersByIdentifier[restoredIdentifier]
            else {
                throw ReminderPrunerError.restoredReminderReadbackFailed
            }
            return (item, reminder)
        }
    }

    private func restoreMarker(
        backupIdentifier: UUID,
        attemptIdentifier: UUID,
        originalItemIdentifier: String
    ) -> String {
        let itemHash = SHA256.hash(
            data: Data(originalItemIdentifier.utf8)
        ).map { String(format: "%02x", $0) }.joined()
        return "TaskForge-Prune-Restore-ID: "
            + "\(backupIdentifier.uuidString):"
            + "\(attemptIdentifier.uuidString):\(itemHash)"
    }

    private func containsRestoreMarker(
        _ notes: String?,
        marker: String
    ) -> Bool {
        notes?.components(separatedBy: "\n").contains(marker) == true
    }

    private func addingRestoreMarker(
        to notes: String?,
        marker: String
    ) -> String {
        guard let notes, !notes.isEmpty else {
            return marker
        }
        return notes + "\n" + marker
    }

    private func observation(
        for reminder: EKReminder,
        targetCalendar: EKCalendar,
        snapshot: TaskForgeSnapshot
    ) -> ReminderPruneObservation? {
        let identifier = reminder.calendarItemIdentifier
        guard !identifier.isEmpty else {
            return nil
        }
        let presence = sourcePresence(
            notes: reminder.notes,
            snapshot: snapshot
        )
        return ReminderPruneObservation(
            itemIdentifier: identifier,
            calendarIdentifier: targetCalendar.calendarIdentifier,
            isCompleted: reminder.isCompleted,
            priority: reminder.priority,
            title: reminder.title ?? "",
            fingerprint: fingerprint(
                reminder: reminder,
                targetCalendarIdentifier: targetCalendar.calendarIdentifier,
                presence: presence
            ),
            taskPresence: presence
        )
    }

    private func sourcePresence(
        notes: String?,
        snapshot: TaskForgeSnapshot
    ) -> TaskForgeReminderPresence {
        if
            let marker = TaskSyncMarker.extract(from: notes),
            snapshot.tasks.contains(where: {
                marker == TaskSyncMarker.make(
                    vaultPath: snapshot.vaultPath,
                    taskIdentifier: $0.identifier
                )
            })
        {
            return .currentSnapshot
        }
        let markerTaskIdentifier = TaskSyncMarker.extract(from: notes)
            .flatMap(TaskSyncMarker.decode)?.taskIdentifier
        let reference = TaskSourceReference.decode(from: notes)
            ?? markerTaskIdentifier.flatMap {
                configuration.managedIndex?.entries[$0]?.sourceReference
                    .map(TaskSourceReference.init(task:))
            }
        guard let reference, let path = reference.task.filePath
        else {
            return .absent
        }

        let vaultURL = URL(
            fileURLWithPath: snapshot.vaultPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let sourceURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isDescendant(sourceURL, of: vaultURL) else {
            return .indeterminate
        }

        do {
            _ = try FileManager.default.attributesOfItem(
                atPath: sourceURL.path
            )
        } catch {
            return isNoSuchFileError(error) ? .absent : .indeterminate
        }
        guard
            let data = try? Data(contentsOf: sourceURL),
            let contents = String(data: data, encoding: .utf8)
        else {
            return .indeterminate
        }
        switch TaskSourcePresenceInspector.inspect(
            task: reference.task,
            contents: contents
        ) {
        case .present:
            return .sourceConfirmed
        case .absent:
            return .absent
        case .indeterminate:
            return .indeterminate
        }
    }

    private func fingerprint(
        reminder: EKReminder,
        targetCalendarIdentifier: String,
        presence: TaskForgeReminderPresence
    ) -> String {
        let fields: [String] = [
            targetCalendarIdentifier,
            reminder.calendarItemIdentifier,
            reminder.isCompleted ? "1" : "0",
            String(reminder.priority),
            reminder.title ?? "",
            reminder.notes ?? "",
            presence.rawValue
        ]
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) {
                data.append(contentsOf: $0)
            }
            data.append(bytes)
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func counts(
        scanned: Int,
        observations: [ReminderPruneObservation],
        targetCalendarIdentifier: String,
        plan: ReminderPrunePlan
    ) -> ReminderPruneCounts {
        var counts = ReminderPruneCounts()
        counts.scanned = scanned
        counts.firstSeen = plan.firstSeenIdentifiers.count
        counts.waiting = plan.waitingIdentifiers.count
        counts.ready = plan.readyIdentifiers.count
        let candidates = observations.filter {
            ReminderPruneCandidatePolicy.isCandidate(
                $0,
                targetCalendarIdentifier: targetCalendarIdentifier
            )
        }.count
        counts.protected = max(scanned - candidates, 0)
        return counts
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count))
                == parentComponents
    }

    private func isNoSuchFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError
                || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT)
    }

    private func loggedIdentifier(_ identifier: String) -> String {
        guard var data = try? localStore.loadOrCreateHashSalt() else {
            return "hash-unavailable"
        }
        data.append(Data(identifier.utf8))
        return SHA256.hash(data: data)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func summary(
        prefix: String,
        counts: ReminderPruneCounts
    ) -> String {
        "\(prefix)：扫描 \(counts.scanned)，首次 \(counts.firstSeen)，"
            + "等待 \(counts.waiting)，就绪 \(counts.ready)，"
            + "删除 \(counts.deleted)，恢复 \(counts.restored)，"
            + "保护 \(counts.protected)，失败 \(counts.failed)"
    }
}
