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

public enum ReminderPrunerError: Error, LocalizedError {
    case noReminderSource
    case backupVerificationFailed
    case restoredReminderReadbackFailed

    public var errorDescription: String? {
        switch self {
        case .noReminderSource:
            return "找不到可以创建提醒事项列表的账户。"
        case .backupVerificationFailed:
            return "清理备份写入后的回读校验失败。"
        case .restoredReminderReadbackFailed:
            return "恢复提交后未能回读全部新提醒，备份仍未消费。"
        }
    }
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
        guard let targetCalendar = targetCalendar() else {
            return ReminderPruneCounts()
        }
        let reminders = await fetchReminders(in: targetCalendar)
        let observations = reminders.compactMap {
            observation(
                for: $0,
                targetCalendar: targetCalendar,
                snapshot: snapshot
            )
        }
        let prior = try localStore.loadLedger()
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
        guard let targetCalendar = targetCalendar() else {
            return ReminderPruneCounts()
        }
        let initialReminders = await fetchReminders(in: targetCalendar)
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
        var confirmed: [EKReminder] = []
        for identifier in initialPlan.readyIdentifiers {
            let current = await fetchReminders(in: targetCalendar).first {
                $0.calendarItemIdentifier == identifier
            }
            guard
                let current,
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
                confirmed.append(current)
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
            items: confirmed.map(ReminderBackupAdapter.capture),
            restoredAt: nil
        )
        let backupURL = try localStore.saveBackup(backup)
        guard try localStore.loadBackup(at: backupURL) == backup else {
            throw ReminderPrunerError.backupVerificationFailed
        }

        let confirmedIdentifiers = Set(
            confirmed.map(\.calendarItemIdentifier)
        )
        for reminder in confirmed {
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
        let targetCalendarIdentifier = targetCalendar.calendarIdentifier
        eventStore.reset()

        var ledger = initialPlan.nextLedger
        guard
            let refreshedCalendar = eventStore.calendar(
                withIdentifier: targetCalendarIdentifier
            )
        else {
            counts.failed = confirmedIdentifiers.count
            log(summary(prefix: "清理推进", counts: counts))
            return counts
        }
        let remaining = Set(
            await fetchReminders(in: refreshedCalendar).map(
                \.calendarItemIdentifier
            )
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
        guard let (backupURL, backup) = try localStore.latestUnrestoredBackup()
        else {
            return ReminderPruneCounts()
        }
        let calendar = try targetCalendar()
            ?? createTargetCalendar(
                title: backup.targetCalendarTitle,
                preferredSource: eventStore.calendar(
                    withIdentifier: backup.targetCalendarIdentifier
                )?.source
            )
        var created: [EKReminder] = []
        do {
            for item in backup.items {
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = calendar
                ReminderBackupAdapter.restore(item, into: reminder)
                try eventStore.save(reminder, commit: false)
                created.append(reminder)
            }
            try eventStore.commit()
        } catch {
            eventStore.reset()
            throw error
        }

        let createdIdentifiers = Set(
            created.map(\.calendarItemIdentifier)
        )
        let restoredCalendarIdentifier = calendar.calendarIdentifier
        eventStore.reset()
        guard
            let refreshedCalendar = eventStore.calendar(
                withIdentifier: restoredCalendarIdentifier
            )
        else {
            throw ReminderPrunerError.restoredReminderReadbackFailed
        }
        let refreshed = await fetchReminders(in: refreshedCalendar)
        let restored = refreshed.filter {
            createdIdentifiers.contains($0.calendarItemIdentifier)
        }
        guard restored.count == backup.items.count else {
            throw ReminderPrunerError.restoredReminderReadbackFailed
        }

        var ledger = try localStore.loadLedger()
        let graceUntil = now.addingTimeInterval(
            max(configuration.restoreGraceInterval, 86_400)
        )
        for reminder in restored {
            let presence = restoredSourcePresence(notes: reminder.notes)
            let identifier = reminder.calendarItemIdentifier
            ledger.entries[identifier] = ReminderPruneLedgerEntry(
                firstSeen: now,
                fingerprint: fingerprint(
                    reminder: reminder,
                    targetCalendarIdentifier:
                        refreshedCalendar.calendarIdentifier,
                    presence: presence
                ),
                calendarIdentifier: refreshedCalendar.calendarIdentifier,
                rulesVersion: ReminderPruneStateMachine.rulesVersion,
                graceUntil: graceUntil
            )
        }
        try localStore.saveLedger(ledger)
        try localStore.markRestored(at: backupURL, date: now)

        var counts = ReminderPruneCounts()
        counts.scanned = refreshed.count
        counts.restored = restored.count
        log(summary(prefix: "清理恢复", counts: counts))
        return counts
    }

    private let eventStore: EKEventStore
    private let configuration: ReminderPruneConfiguration
    private let localStore: ReminderPruneLocalStore
    private let log: @Sendable (String) -> Void
    private let logError: @Sendable (String) -> Void

    private func targetCalendar() -> EKCalendar? {
        eventStore.calendars(for: .reminder).first {
            $0.title == configuration.listName
        }
    }

    private func createTargetCalendar(
        title: String,
        preferredSource: EKSource?
    ) throws -> EKCalendar {
        guard
            let source = preferredSource
                ?? eventStore.defaultCalendarForNewReminders()?.source
                ?? eventStore.calendars(for: .reminder).first?.source
        else {
            throw ReminderPrunerError.noReminderSource
        }
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = title
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func fetchReminders(in calendar: EKCalendar) async -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: [calendar])
        return await withCheckedContinuation { continuation in
            _ = eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
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
        guard
            let reference = TaskSourceReference.decode(from: notes),
            let path = reference.task.filePath
        else {
            return .indeterminate
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

    private func restoredSourcePresence(
        notes: String?
    ) -> TaskForgeReminderPresence {
        guard
            let marker = TaskSyncMarker.extract(from: notes),
            let decoded = TaskSyncMarker.decode(marker)
        else {
            return .indeterminate
        }
        return sourcePresence(
            notes: notes,
            snapshot: TaskForgeSnapshot(
                version: 6,
                vaultPath: decoded.vaultPath,
                tasks: []
            )
        )
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
