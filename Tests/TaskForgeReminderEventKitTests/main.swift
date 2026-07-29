import Darwin
import Dispatch
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

private final class AsyncResultGate<Value>: @unchecked Sendable {
    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
}

private struct FixtureLabels {
    let plain: String
    let priority: String
    let important: [String]
    let completed: String
    let current: String
    let historical: String
    let other: String
}

private struct RestoreExpectation {
    let title: String
    let notes: String
    let url: URL
    let dueDateComponents: DateComponents
    let startDateComponents: DateComponents
    let alarmOffset: TimeInterval
    let recurrenceInterval: Int
    let recurrenceCount: Int
}

private let operationTimeout: TimeInterval = 30

private func checked(
    _ count: inout Int,
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    try require(condition(), message)
    count += 1
}

private func requestReminderAccess(
    eventStore: EKEventStore
) async throws {
    let granted: Bool = try await withCheckedThrowingContinuation {
        continuation in
        let gate = AsyncResultGate<Bool>(continuation)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + operationTimeout
        ) {
            gate.resolve(
                .failure(
                    IntegrationFailure(
                        description: "reminder access request timed out"
                    )
                )
            )
        }

        let completion: @Sendable (Bool, Error?) -> Void = {
            granted, error in
            if error != nil {
                gate.resolve(
                    .failure(
                        IntegrationFailure(
                            description: "reminder access request failed"
                        )
                    )
                )
            } else {
                gate.resolve(.success(granted))
            }
        }
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders(completion: completion)
        } else {
            eventStore.requestAccess(to: .reminder, completion: completion)
        }
    }
    guard granted else {
        throw IntegrationFailure(description: "reminder access was denied")
    }
}

private func fetchReminders(
    eventStore: EKEventStore,
    calendars: [EKCalendar]
) async throws -> [EKReminder] {
    guard !calendars.isEmpty else {
        throw IntegrationFailure(
            description: "isolated reminder fetch requires a temporary calendar"
        )
    }
    let predicate = eventStore.predicateForReminders(in: calendars)
    return try await withCheckedThrowingContinuation { continuation in
        let gate = AsyncResultGate<[EKReminder]>(continuation)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + operationTimeout
        ) {
            gate.resolve(
                .failure(
                    IntegrationFailure(
                        description: "isolated reminder fetch timed out"
                    )
                )
            )
        }
        _ = eventStore.fetchReminders(matching: predicate) { reminders in
            guard let reminders else {
                gate.resolve(
                    .failure(
                        IntegrationFailure(
                            description: "isolated reminder fetch failed"
                        )
                    )
                )
                return
            }
            gate.resolve(.success(reminders))
        }
    }
}

private func exactTemporaryCalendars(
    eventStore: EKEventStore,
    names: Set<String>
) -> [EKCalendar] {
    eventStore.calendars(for: .reminder).filter {
        names.contains($0.title)
    }
}

private func exactTemporaryCalendar(
    eventStore: EKEventStore,
    name: String
) throws -> EKCalendar {
    let matches = exactTemporaryCalendars(
        eventStore: eventStore,
        names: [name]
    )
    guard matches.count == 1, let calendar = matches.first else {
        throw IntegrationFailure(
            description: "temporary calendar lookup was not unique"
        )
    }
    return calendar
}

private func createTemporaryCalendars(
    eventStore: EKEventStore,
    targetName: String,
    otherName: String
) throws {
    let exactNames: Set<String> = [targetName, otherName]
    guard exactTemporaryCalendars(
        eventStore: eventStore,
        names: exactNames
    ).isEmpty else {
        throw IntegrationFailure(
            description: "temporary calendar UUID collision"
        )
    }
    let reminderSources = eventStore.sources.filter {
        $0.sourceType == .local || $0.sourceType == .calDAV
    }
    guard let source = reminderSources.first else {
        throw IntegrationFailure(
            description: "no writable reminder source is available"
        )
    }

    let target = EKCalendar(for: .reminder, eventStore: eventStore)
    target.title = targetName
    target.source = source
    try eventStore.saveCalendar(target, commit: false)

    let other = EKCalendar(for: .reminder, eventStore: eventStore)
    other.title = otherName
    other.source = source
    try eventStore.saveCalendar(other, commit: false)

    try eventStore.commit()
    eventStore.reset()
    guard exactTemporaryCalendars(
        eventStore: eventStore,
        names: exactNames
    ).count == exactNames.count else {
        throw IntegrationFailure(
            description: "temporary calendars were not persisted"
        )
    }
}

private func cleanupTemporaryCalendars(
    eventStore: EKEventStore,
    names: Set<String>
) -> IntegrationFailure? {
    for _ in 0..<3 {
        eventStore.reset()
        let matches = exactTemporaryCalendars(
            eventStore: eventStore,
            names: names
        )
        if matches.isEmpty {
            return nil
        }
        for calendar in matches {
            try? eventStore.removeCalendar(calendar, commit: true)
        }
    }
    eventStore.reset()
    guard exactTemporaryCalendars(
        eventStore: eventStore,
        names: names
    ).isEmpty else {
        return IntegrationFailure(
            description: "temporary calendar cleanup failed"
        )
    }
    return nil
}

private func createPrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
}

private func stageReminder(
    eventStore: EKEventStore,
    calendar: EKCalendar,
    title: String,
    notes: String? = nil,
    priority: Int = 0,
    isCompleted: Bool = false,
    configure: ((EKReminder) -> Void)? = nil
) throws {
    let reminder = EKReminder(eventStore: eventStore)
    reminder.calendar = calendar
    reminder.title = title
    reminder.notes = notes
    reminder.priority = priority
    reminder.isCompleted = isCompleted
    configure?(reminder)
    try eventStore.save(reminder, commit: false)
}

private func stageFixtures(
    eventStore: EKEventStore,
    targetCalendar: EKCalendar,
    otherCalendar: EKCalendar,
    labels: FixtureLabels,
    restore: RestoreExpectation,
    currentMarker: String,
    historicalReference: String
) throws {
    try stageReminder(
        eventStore: eventStore,
        calendar: targetCalendar,
        title: labels.plain,
        notes: restore.notes
    ) { reminder in
        reminder.url = restore.url
        reminder.dueDateComponents = restore.dueDateComponents
        reminder.startDateComponents = restore.startDateComponents
        reminder.addAlarm(
            EKAlarm(relativeOffset: restore.alarmOffset)
        )
        reminder.addRecurrenceRule(
            EKRecurrenceRule(
                recurrenceWith: .daily,
                interval: restore.recurrenceInterval,
                end: EKRecurrenceEnd(
                    occurrenceCount: restore.recurrenceCount
                )
            )
        )
    }
    try stageReminder(
        eventStore: eventStore,
        calendar: targetCalendar,
        title: labels.priority,
        priority: 1
    )
    for title in labels.important {
        try stageReminder(
            eventStore: eventStore,
            calendar: targetCalendar,
            title: title
        )
    }
    try stageReminder(
        eventStore: eventStore,
        calendar: targetCalendar,
        title: labels.completed,
        isCompleted: true
    )
    try stageReminder(
        eventStore: eventStore,
        calendar: targetCalendar,
        title: labels.current,
        notes: currentMarker
    )
    try stageReminder(
        eventStore: eventStore,
        calendar: targetCalendar,
        title: labels.historical,
        notes: historicalReference
    )
    try stageReminder(
        eventStore: eventStore,
        calendar: otherCalendar,
        title: labels.other
    )
    try eventStore.commit()
    eventStore.reset()
}

private func onlyReminder(
    _ reminders: [EKReminder],
    title: String
) throws -> EKReminder {
    let matches = reminders.filter { $0.title == title }
    guard matches.count == 1, let reminder = matches.first else {
        throw IntegrationFailure(
            description: "fixture reminder lookup was not unique"
        )
    }
    return reminder
}

private func sameDateComponents(
    _ lhs: DateComponents?,
    _ rhs: DateComponents?
) -> Bool {
    guard let lhs, let rhs else {
        return lhs == nil && rhs == nil
    }
    return lhs.year == rhs.year
        && lhs.month == rhs.month
        && lhs.day == rhs.day
        && lhs.hour == rhs.hour
        && lhs.minute == rhs.minute
}

private func latestBackupURL(localRoot: URL) throws -> URL {
    let backupDirectory = localRoot.appendingPathComponent(
        "PruneBackups",
        isDirectory: true
    )
    let backups = try FileManager.default.contentsOfDirectory(
        at: backupDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
    guard backups.count == 1, let backup = backups.first else {
        throw IntegrationFailure(
            description: "exactly one prune backup was expected"
        )
    }
    return backup
}

private func privateFilePermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(
        atPath: url.path
    )
    if let permissions = attributes[.posixPermissions] as? NSNumber {
        return permissions.intValue & 0o777
    }
    if let permissions = attributes[.posixPermissions] as? Int {
        return permissions & 0o777
    }
    throw IntegrationFailure(
        description: "backup permissions were unavailable"
    )
}

@MainActor
private func runIntegrationTests() async throws -> Int {
    let eventStore = EKEventStore()
    let targetName = "TaskForgeReminderSync Test \(UUID().uuidString)"
    let otherName = "TaskForgeReminderSync Other \(UUID().uuidString)"
    let exactNames: Set<String> = [targetName, otherName]
    let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "TaskForgeReminderEventKitTests-\(UUID().uuidString)",
            isDirectory: true
        )
    let vaultURL = testRoot.appendingPathComponent(
        "Vault",
        isDirectory: true
    )
    let localRoot = testRoot.appendingPathComponent(
        "PruneState",
        isDirectory: true
    )

    var bodyError: Error?
    var cleanupError: Error?
    var passCount = 0

    do {
        defer {
            let calendarError = cleanupTemporaryCalendars(
                eventStore: eventStore,
                names: exactNames
            )
            var directoryError: IntegrationFailure?
            if FileManager.default.fileExists(atPath: testRoot.path) {
                do {
                    try FileManager.default.removeItem(at: testRoot)
                } catch {
                    directoryError = IntegrationFailure(
                        description: "temporary test directory cleanup failed"
                    )
                }
            }
            cleanupError = calendarError ?? directoryError
        }

        do {
            try await requestReminderAccess(eventStore: eventStore)
            try createPrivateDirectory(testRoot)
            try createPrivateDirectory(vaultURL)
            try createTemporaryCalendars(
                eventStore: eventStore,
                targetName: targetName,
                otherName: otherName
            )
            print("TEMP  \(targetName)")
            print("TEMP  \(otherName)")

            let labelToken = UUID().uuidString
            let labels = FixtureLabels(
                plain: "plain-\(labelToken)",
                priority: "priority-\(labelToken)",
                important: ["!", "！", "❗", "‼️", "⭐", "📌"].map {
                    "  \($0) protected-\(labelToken)"
                },
                completed: "completed-\(labelToken)",
                current: "current-\(labelToken)",
                historical: "historical-\(labelToken)",
                other: "other-\(labelToken)"
            )

            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
            let dueDate = DateComponents(
                calendar: gregorian,
                timeZone: gregorian.timeZone,
                year: 2030,
                month: 7,
                day: 30,
                hour: 10,
                minute: 45
            )
            let startDate = DateComponents(
                calendar: gregorian,
                timeZone: gregorian.timeZone,
                year: 2030,
                month: 7,
                day: 30,
                hour: 9,
                minute: 30
            )
            let restore = RestoreExpectation(
                title: labels.plain,
                notes: "integration fixture notes",
                url: URL(
                    string:
                        "taskforge-eventkit-test://restore/\(UUID().uuidString)"
                )!,
                dueDateComponents: dueDate,
                startDateComponents: startDate,
                alarmOffset: -1_800,
                recurrenceInterval: 2,
                recurrenceCount: 4
            )

            let sourceURL = vaultURL.appendingPathComponent("history.md")
            try "- [ ] 历史任务\n".write(
                to: sourceURL,
                atomically: true,
                encoding: .utf8
            )
            let historicalTask = TaskForgeTask(
                identifier: "historical-\(UUID().uuidString)",
                title: "历史任务",
                status: "todo",
                priority: nil,
                scheduled: nil,
                filePath: sourceURL.path,
                sourceType: "markdownInline",
                originalLine: "- [ ] 历史任务",
                lineNumber: 1
            )
            let currentTask = TaskForgeTask(
                identifier: "current-\(UUID().uuidString)",
                title: "当前任务",
                status: "todo",
                priority: nil,
                scheduled: nil,
                filePath: nil,
                sourceType: nil,
                originalLine: nil,
                lineNumber: nil
            )
            let snapshot = TaskForgeSnapshot(
                version: 6,
                vaultPath: vaultURL.path,
                tasks: [currentTask]
            )
            let currentMarker = TaskSyncMarker.make(
                vaultPath: snapshot.vaultPath,
                taskIdentifier: currentTask.identifier
            )
            let historicalReference = TaskSourceReference(
                task: historicalTask
            ).encodedLine

            let targetCalendar = try exactTemporaryCalendar(
                eventStore: eventStore,
                name: targetName
            )
            let otherCalendar = try exactTemporaryCalendar(
                eventStore: eventStore,
                name: otherName
            )
            try stageFixtures(
                eventStore: eventStore,
                targetCalendar: targetCalendar,
                otherCalendar: otherCalendar,
                labels: labels,
                restore: restore,
                currentMarker: currentMarker,
                historicalReference: historicalReference
            )

            let initialTarget = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        name: targetName
                    )
                ]
            )
            let initialOther = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        name: otherName
                    )
                ]
            )
            try checked(
                &passCount,
                initialTarget.count == 11,
                "target fixture count was incorrect"
            )
            try checked(
                &passCount,
                initialOther.count == 1,
                "other-list fixture count was incorrect"
            )

            let plainIdentifier = try onlyReminder(
                initialTarget,
                title: labels.plain
            ).calendarItemIdentifier
            let priorityIdentifier = try onlyReminder(
                initialTarget,
                title: labels.priority
            ).calendarItemIdentifier
            let importantIdentifiers = try labels.important.map {
                try onlyReminder(initialTarget, title: $0)
                    .calendarItemIdentifier
            }
            let completedIdentifier = try onlyReminder(
                initialTarget,
                title: labels.completed
            ).calendarItemIdentifier
            let currentIdentifier = try onlyReminder(
                initialTarget,
                title: labels.current
            ).calendarItemIdentifier
            let historicalIdentifier = try onlyReminder(
                initialTarget,
                title: labels.historical
            ).calendarItemIdentifier
            let otherIdentifier = try onlyReminder(
                initialOther,
                title: labels.other
            ).calendarItemIdentifier

            let pruner = ReminderPruner(
                eventStore: eventStore,
                configuration: ReminderPruneConfiguration(
                    listName: targetName,
                    localRoot: localRoot,
                    confirmationInterval: 60,
                    restoreGraceInterval: 86_400
                ),
                log: { _ in },
                logError: { _ in }
            )
            let firstNow = Date(timeIntervalSince1970: 10_000)
            let secondNow = Date(timeIntervalSince1970: 10_061)
            let first = try await pruner.advance(
                snapshot: snapshot,
                now: firstNow
            )
            try checked(
                &passCount,
                first.deleted == 0,
                "first scan deleted immediately"
            )
            try checked(
                &passCount,
                first.firstSeen == 1,
                "first scan did not register exactly one candidate"
            )

            let afterFirst = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        name: targetName
                    )
                ]
            )
            try checked(
                &passCount,
                afterFirst.contains {
                    $0.calendarItemIdentifier == plainIdentifier
                },
                "first scan removed the plain external fixture"
            )

            let second = try await pruner.advance(
                snapshot: snapshot,
                now: secondNow
            )
            try checked(
                &passCount,
                second.deleted == 1,
                "second scan did not delete exactly one reminder"
            )

            let afterSecond = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        name: targetName
                    )
                ]
            )
            let afterSecondIdentifiers = Set(
                afterSecond.map(\.calendarItemIdentifier)
            )
            try checked(
                &passCount,
                !afterSecondIdentifiers.contains(plainIdentifier),
                "plain external fixture survived the second scan"
            )
            try checked(
                &passCount,
                afterSecondIdentifiers.contains(priorityIdentifier),
                "priority fixture was not protected"
            )
            for identifier in importantIdentifiers {
                try checked(
                    &passCount,
                    afterSecondIdentifiers.contains(identifier),
                    "important-prefix fixture was not protected"
                )
            }
            try checked(
                &passCount,
                afterSecondIdentifiers.contains(completedIdentifier),
                "completed fixture was not protected"
            )
            try checked(
                &passCount,
                afterSecondIdentifiers.contains(currentIdentifier),
                "current snapshot fixture was not protected"
            )
            try checked(
                &passCount,
                afterSecondIdentifiers.contains(historicalIdentifier),
                "historical source fixture was not protected"
            )

            let afterSecondOther = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        name: otherName
                    )
                ]
            )
            try checked(
                &passCount,
                afterSecondOther.contains {
                    $0.calendarItemIdentifier == otherIdentifier
                },
                "other-list fixture was touched"
            )

            let backupURL = try latestBackupURL(localRoot: localRoot)
            let backupPermissions = try privateFilePermissions(
                at: backupURL
            )
            try checked(
                &passCount,
                backupPermissions == 0o600,
                "prune backup permissions were not 0600"
            )

            let restoreNow = Date(timeIntervalSince1970: 10_062)
            let restoredCounts = try await pruner.restoreLast(now: restoreNow)
            try checked(
                &passCount,
                restoredCounts.restored == 1,
                "restore did not recreate exactly one reminder"
            )

            let afterRestore = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        name: targetName
                    )
                ]
            )
            let restored = try onlyReminder(
                afterRestore,
                title: restore.title
            )
            try checked(
                &passCount,
                restored.title == restore.title,
                "restored title did not match"
            )
            try checked(
                &passCount,
                restored.notes == restore.notes,
                "restored notes did not match"
            )
            try checked(
                &passCount,
                restored.url == restore.url,
                "restored URL did not match"
            )
            try checked(
                &passCount,
                restored.priority == 0,
                "restored priority did not match"
            )
            try checked(
                &passCount,
                !restored.isCompleted,
                "restored completion state did not match"
            )
            try checked(
                &passCount,
                sameDateComponents(
                    restored.dueDateComponents,
                    restore.dueDateComponents
                ),
                "restored due date did not match"
            )
            try checked(
                &passCount,
                sameDateComponents(
                    restored.startDateComponents,
                    restore.startDateComponents
                ),
                "restored start date did not match"
            )
            let restoredAlarms = restored.alarms ?? []
            try checked(
                &passCount,
                restoredAlarms.count == 1,
                "restored alarm count did not match"
            )
            try checked(
                &passCount,
                restoredAlarms.first?.absoluteDate == nil
                    && abs(
                        (restoredAlarms.first?.relativeOffset ?? 0)
                            - restore.alarmOffset
                    ) < 0.001,
                "restored alarm fields did not match"
            )
            let restoredRules = restored.recurrenceRules ?? []
            try checked(
                &passCount,
                restoredRules.count == 1,
                "restored recurrence count did not match"
            )
            try checked(
                &passCount,
                restoredRules.first?.frequency == .daily
                    && restoredRules.first?.interval
                        == restore.recurrenceInterval
                    && restoredRules.first?.recurrenceEnd?.occurrenceCount
                        == restore.recurrenceCount,
                "restored recurrence fields did not match"
            )

            let withinGrace = try await pruner.advance(
                snapshot: snapshot,
                now: restoreNow.addingTimeInterval(61)
            )
            try checked(
                &passCount,
                withinGrace.deleted == 0 && withinGrace.waiting == 1,
                "24-hour restore grace did not block deletion"
            )

            let afterGraceFirst = try await pruner.advance(
                snapshot: snapshot,
                now: restoreNow.addingTimeInterval(86_401)
            )
            try checked(
                &passCount,
                afterGraceFirst.deleted == 0
                    && afterGraceFirst.firstSeen == 1,
                "post-grace first scan did not re-register the candidate"
            )

            let afterGraceSecond = try await pruner.advance(
                snapshot: snapshot,
                now: restoreNow.addingTimeInterval(86_462)
            )
            try checked(
                &passCount,
                afterGraceSecond.deleted == 1,
                "post-grace second scan did not delete the candidate"
            )

            let finalOther = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        name: otherName
                    )
                ]
            )
            try checked(
                &passCount,
                finalOther.contains {
                    $0.calendarItemIdentifier == otherIdentifier
                },
                "other-list fixture was touched after restore"
            )
        } catch {
            bodyError = error
        }
    }

    if let cleanupError {
        throw cleanupError
    }
    if let bodyError {
        throw bodyError
    }
    return passCount
}

do {
    let passCount = try await runIntegrationTests()
    print("PASS  \(passCount) isolated EventKit checks")
    print("EventKit integration tests passed")
} catch {
    fputs("FAIL  EventKit integration tests: \(error)\n", stderr)
    exit(1)
}
