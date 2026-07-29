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

private struct TemporaryCalendarIdentifiers {
    var target: String?
    var other: String?

    var all: [String] {
        [target, other].compactMap { $0 }
    }
}

private struct DateComponentsBaseline: Equatable {
    init(_ components: DateComponents) {
        calendarIdentifier = components.calendar?.identifier
        timeZoneIdentifier = components.timeZone?.identifier
        timeZoneSecondsFromGMT =
            components.timeZone?.secondsFromGMT()
        era = components.era
        year = components.year
        month = components.month
        day = components.day
        hour = components.hour
        minute = components.minute
        second = components.second
        nanosecond = components.nanosecond
        weekday = components.weekday
        weekdayOrdinal = components.weekdayOrdinal
        quarter = components.quarter
        weekOfMonth = components.weekOfMonth
        weekOfYear = components.weekOfYear
        yearForWeekOfYear = components.yearForWeekOfYear
        isLeapMonth = components.isLeapMonth
    }

    let calendarIdentifier: Calendar.Identifier?
    let timeZoneIdentifier: String?
    let timeZoneSecondsFromGMT: Int?
    let era: Int?
    let year: Int?
    let month: Int?
    let day: Int?
    let hour: Int?
    let minute: Int?
    let second: Int?
    let nanosecond: Int?
    let weekday: Int?
    let weekdayOrdinal: Int?
    let quarter: Int?
    let weekOfMonth: Int?
    let weekOfYear: Int?
    let yearForWeekOfYear: Int?
    let isLeapMonth: Bool?
}

private struct ReminderFieldBaseline: Equatable {
    init(_ reminder: EKReminder) {
        title = reminder.title
        notes = reminder.notes
        url = reminder.url
        priority = reminder.priority
        isCompleted = reminder.isCompleted
        dueDateComponents = reminder.dueDateComponents.map(
            DateComponentsBaseline.init
        )
        startDateComponents = reminder.startDateComponents.map(
            DateComponentsBaseline.init
        )
        alarms = (reminder.alarms ?? []).map { alarm in
            let location = alarm.structuredLocation.map {
                ReminderLocationBackup(
                    title: $0.title ?? "",
                    latitude: $0.geoLocation?.coordinate.latitude,
                    longitude: $0.geoLocation?.coordinate.longitude,
                    radius: $0.radius
                )
            }
            return ReminderAlarmBackup(
                absoluteDate: alarm.absoluteDate,
                relativeOffset: alarm.absoluteDate == nil
                    ? alarm.relativeOffset
                    : nil,
                structuredLocation: location,
                proximityRawValue: alarm.proximity.rawValue
            )
        }
        recurrenceRules = (reminder.recurrenceRules ?? []).map { rule in
            let end = rule.recurrenceEnd
            return ReminderRecurrenceBackup(
                frequencyRawValue: rule.frequency.rawValue,
                interval: rule.interval,
                daysOfWeek: (rule.daysOfTheWeek ?? []).map {
                    ReminderWeekdayBackup(
                        dayOfTheWeekRawValue:
                            $0.dayOfTheWeek.rawValue,
                        weekNumber: $0.weekNumber
                    )
                },
                daysOfMonth:
                    (rule.daysOfTheMonth ?? []).map(\.intValue),
                monthsOfYear:
                    (rule.monthsOfTheYear ?? []).map(\.intValue),
                weeksOfYear:
                    (rule.weeksOfTheYear ?? []).map(\.intValue),
                daysOfYear:
                    (rule.daysOfTheYear ?? []).map(\.intValue),
                setPositions:
                    (rule.setPositions ?? []).map(\.intValue),
                endDate: end?.endDate,
                occurrenceCount: end.flatMap {
                    $0.occurrenceCount > 0
                        ? Int($0.occurrenceCount)
                        : nil
                }
            )
        }
    }

    let title: String?
    let notes: String?
    let url: URL?
    let priority: Int
    let isCompleted: Bool
    let dueDateComponents: DateComponentsBaseline?
    let startDateComponents: DateComponentsBaseline?
    let alarms: [ReminderAlarmBackup]
    let recurrenceRules: [ReminderRecurrenceBackup]
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

private func exactTemporaryCalendar(
    eventStore: EKEventStore,
    identifier: String,
    expectedName: String
) throws -> EKCalendar {
    guard
        let calendar = eventStore.calendar(withIdentifier: identifier),
        calendar.title == expectedName
    else {
        throw IntegrationFailure(
            description: "temporary calendar lookup failed"
        )
    }
    return calendar
}

private func createTemporaryCalendars(
    eventStore: EKEventStore,
    targetName: String,
    otherName: String,
    identifiers: inout TemporaryCalendarIdentifiers
) throws {
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
    try eventStore.saveCalendar(target, commit: true)
    guard !target.calendarIdentifier.isEmpty else {
        try? eventStore.removeCalendar(target, commit: true)
        throw IntegrationFailure(
            description: "target calendar identifier was unavailable"
        )
    }
    let targetIdentifier = target.calendarIdentifier
    identifiers.target = targetIdentifier

    let other = EKCalendar(for: .reminder, eventStore: eventStore)
    other.title = otherName
    other.source = source
    try eventStore.saveCalendar(other, commit: true)
    guard !other.calendarIdentifier.isEmpty else {
        try? eventStore.removeCalendar(other, commit: true)
        throw IntegrationFailure(
            description: "other calendar identifier was unavailable"
        )
    }
    let otherIdentifier = other.calendarIdentifier
    identifiers.other = otherIdentifier

    eventStore.reset()
    _ = try exactTemporaryCalendar(
        eventStore: eventStore,
        identifier: targetIdentifier,
        expectedName: targetName
    )
    _ = try exactTemporaryCalendar(
        eventStore: eventStore,
        identifier: otherIdentifier,
        expectedName: otherName
    )
}

private func cleanupTemporaryCalendars(
    eventStore: EKEventStore,
    identifiers: [String]
) -> IntegrationFailure? {
    for identifier in identifiers {
        for _ in 0..<3 {
            eventStore.reset()
            guard
                let calendar = eventStore.calendar(
                    withIdentifier: identifier
                )
            else {
                break
            }
            try? eventStore.removeCalendar(calendar, commit: true)
        }
    }
    eventStore.reset()
    guard identifiers.allSatisfy({
        eventStore.calendar(withIdentifier: $0) == nil
    }) else {
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
    var calendarIdentifiers = TemporaryCalendarIdentifiers()

    do {
        defer {
            let calendarError = cleanupTemporaryCalendars(
                eventStore: eventStore,
                identifiers: calendarIdentifiers.all
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
                otherName: otherName,
                identifiers: &calendarIdentifiers
            )
            guard
                let targetCalendarIdentifier =
                    calendarIdentifiers.target,
                let otherCalendarIdentifier =
                    calendarIdentifiers.other
            else {
                throw IntegrationFailure(
                    description: "temporary calendar identifiers missing"
                )
            }
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
                identifier: targetCalendarIdentifier,
                expectedName: targetName
            )
            let otherCalendar = try exactTemporaryCalendar(
                eventStore: eventStore,
                identifier: otherCalendarIdentifier,
                expectedName: otherName
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
                        identifier: targetCalendarIdentifier,
                        expectedName: targetName
                    )
                ]
            )
            let initialOther = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        identifier: otherCalendarIdentifier,
                        expectedName: otherName
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

            let initialTargetIdentifiers = Set(
                initialTarget.map(\.calendarItemIdentifier)
            )
            let initialOtherIdentifiers = Set(
                initialOther.map(\.calendarItemIdentifier)
            )
            let plainReminder = try onlyReminder(
                initialTarget,
                title: labels.plain
            )
            let plainIdentifier =
                plainReminder.calendarItemIdentifier
            let plainFieldBaseline = ReminderFieldBaseline(
                plainReminder
            )
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
                        identifier: targetCalendarIdentifier,
                        expectedName: targetName
                    )
                ]
            )
            let afterFirstOther = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        identifier: otherCalendarIdentifier,
                        expectedName: otherName
                    )
                ]
            )
            try checked(
                &passCount,
                Set(afterFirst.map(\.calendarItemIdentifier))
                    == initialTargetIdentifiers,
                "first scan changed the target identifier set"
            )
            try checked(
                &passCount,
                Set(afterFirstOther.map(\.calendarItemIdentifier))
                    == initialOtherIdentifiers,
                "first scan changed the other-list identifier set"
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
                        identifier: targetCalendarIdentifier,
                        expectedName: targetName
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
                        identifier: otherCalendarIdentifier,
                        expectedName: otherName
                    )
                ]
            )
            try checked(
                &passCount,
                Set(afterSecondOther.map(\.calendarItemIdentifier))
                    == initialOtherIdentifiers,
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
                        identifier: targetCalendarIdentifier,
                        expectedName: targetName
                    )
                ]
            )
            let restored = try onlyReminder(
                afterRestore,
                title: restore.title
            )
            let restoredIdentifier =
                restored.calendarItemIdentifier
            try checked(
                &passCount,
                ReminderFieldBaseline(restored)
                    == plainFieldBaseline,
                "restored fields differ from the saved EventKit baseline"
            )

            let withinGrace = try await pruner.advance(
                snapshot: snapshot,
                now: restoreNow.addingTimeInterval(86_399)
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

            let finalTarget = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        identifier: targetCalendarIdentifier,
                        expectedName: targetName
                    )
                ]
            )
            let finalOther = try await fetchReminders(
                eventStore: eventStore,
                calendars: [
                    try exactTemporaryCalendar(
                        eventStore: eventStore,
                        identifier: otherCalendarIdentifier,
                        expectedName: otherName
                    )
                ]
            )
            try checked(
                &passCount,
                !Set(finalTarget.map(\.calendarItemIdentifier))
                    .contains(restoredIdentifier)
                    && !finalTarget.contains {
                        $0.title == labels.plain
                    },
                "post-grace second scan retained the restored fixture"
            )
            try checked(
                &passCount,
                Set(finalTarget.map(\.calendarItemIdentifier))
                    == afterSecondIdentifiers,
                "post-grace scans changed a protected fixture"
            )
            try checked(
                &passCount,
                Set(finalOther.map(\.calendarItemIdentifier))
                    == initialOtherIdentifiers,
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
} catch let failure as IntegrationFailure {
    fputs(
        "FAIL  EventKit integration tests: \(failure.description)\n",
        stderr
    )
    exit(1)
} catch {
    fputs(
        "FAIL  EventKit integration tests: unexpected-stage-failure\n",
        stderr
    )
    exit(1)
}
