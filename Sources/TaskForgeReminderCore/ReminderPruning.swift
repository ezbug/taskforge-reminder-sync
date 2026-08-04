import Foundation

public enum TaskForgeReminderPresence: String, Codable, Equatable, Sendable {
    case currentSnapshot
    case sourceConfirmed
    case absent
    case indeterminate
}

public struct ReminderPruneObservation: Equatable, Sendable {
    public let itemIdentifier: String
    public let calendarIdentifier: String
    public let isCompleted: Bool
    public let priority: Int
    public let title: String
    public let fingerprint: String
    public let taskPresence: TaskForgeReminderPresence

    public init(
        itemIdentifier: String,
        calendarIdentifier: String,
        isCompleted: Bool,
        priority: Int,
        title: String,
        fingerprint: String,
        taskPresence: TaskForgeReminderPresence
    ) {
        self.itemIdentifier = itemIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.isCompleted = isCompleted
        self.priority = priority
        self.title = title
        self.fingerprint = fingerprint
        self.taskPresence = taskPresence
    }

    public func withTaskPresence(
        _ value: TaskForgeReminderPresence
    ) -> ReminderPruneObservation {
        ReminderPruneObservation(
            itemIdentifier: itemIdentifier,
            calendarIdentifier: calendarIdentifier,
            isCompleted: isCompleted,
            priority: priority,
            title: title,
            fingerprint: fingerprint,
            taskPresence: value
        )
    }
}

public enum ReminderPruneCandidatePolicy {
    public static let importantPrefixes = [
        "!", "！", "❗", "‼️", "⭐", "📌"
    ]

    public static func isCandidate(
        _ observation: ReminderPruneObservation,
        targetCalendarIdentifier: String
    ) -> Bool {
        guard observation.calendarIdentifier == targetCalendarIdentifier else {
            return false
        }
        guard !observation.isCompleted, observation.priority == 0 else {
            return false
        }
        let title = observation.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !importantPrefixes.contains(where: title.hasPrefix) else {
            return false
        }
        return observation.taskPresence == .absent
    }
}

public struct ReminderPruneLedgerEntry: Codable, Equatable, Sendable {
    public var firstSeen: Date
    public var fingerprint: String
    public var calendarIdentifier: String
    public var rulesVersion: Int
    public var graceUntil: Date?

    public init(
        firstSeen: Date,
        fingerprint: String,
        calendarIdentifier: String,
        rulesVersion: Int,
        graceUntil: Date?
    ) {
        self.firstSeen = firstSeen
        self.fingerprint = fingerprint
        self.calendarIdentifier = calendarIdentifier
        self.rulesVersion = rulesVersion
        self.graceUntil = graceUntil
    }
}

public struct ReminderPruneLedger: Codable, Equatable, Sendable {
    public var entries: [String: ReminderPruneLedgerEntry]

    public init(entries: [String: ReminderPruneLedgerEntry] = [:]) {
        self.entries = entries
    }
}

public struct ReminderPrunePlan: Equatable, Sendable {
    public let firstSeenIdentifiers: [String]
    public let waitingIdentifiers: [String]
    public let readyIdentifiers: [String]
    public let revokedIdentifiers: [String]
    public let nextLedger: ReminderPruneLedger
}

public enum ReminderPruneStateMachine {
    public static let rulesVersion = 1

    public static func plan(
        observations: [ReminderPruneObservation],
        prior: ReminderPruneLedger,
        targetCalendarIdentifier: String,
        now: Date,
        confirmationInterval: TimeInterval = 60
    ) -> ReminderPrunePlan {
        let effectiveConfirmationInterval = max(confirmationInterval, 60)
        var next = ReminderPruneLedger()
        var firstSeen: [String] = []
        var waiting: [String] = []
        var ready: [String] = []
        let candidates = observations.filter {
            ReminderPruneCandidatePolicy.isCandidate(
                $0,
                targetCalendarIdentifier: targetCalendarIdentifier
            )
        }

        for observation in candidates {
            let old = prior.entries[observation.itemIdentifier]
            let isSame = old?.fingerprint == observation.fingerprint
                && old?.calendarIdentifier == observation.calendarIdentifier
                && old?.rulesVersion == rulesVersion
            if !isSame {
                next.entries[observation.itemIdentifier] = ReminderPruneLedgerEntry(
                    firstSeen: now,
                    fingerprint: observation.fingerprint,
                    calendarIdentifier: observation.calendarIdentifier,
                    rulesVersion: rulesVersion,
                    graceUntil: nil
                )
                firstSeen.append(observation.itemIdentifier)
            } else if let old, let graceUntil = old.graceUntil {
                if now < graceUntil {
                    next.entries[observation.itemIdentifier] = old
                    waiting.append(observation.itemIdentifier)
                } else {
                    next.entries[observation.itemIdentifier] = ReminderPruneLedgerEntry(
                        firstSeen: now,
                        fingerprint: observation.fingerprint,
                        calendarIdentifier: observation.calendarIdentifier,
                        rulesVersion: rulesVersion,
                        graceUntil: nil
                    )
                    firstSeen.append(observation.itemIdentifier)
                }
            } else if let old,
                now.timeIntervalSince(old.firstSeen) >= effectiveConfirmationInterval {
                next.entries[observation.itemIdentifier] = old
                ready.append(observation.itemIdentifier)
            } else if let old {
                next.entries[observation.itemIdentifier] = old
                waiting.append(observation.itemIdentifier)
            }
        }

        let active = Set(candidates.map(\.itemIdentifier))
        let revoked = prior.entries.keys.filter { !active.contains($0) }.sorted()
        return ReminderPrunePlan(
            firstSeenIdentifiers: firstSeen.sorted(),
            waitingIdentifiers: waiting.sorted(),
            readyIdentifiers: ready.sorted(),
            revokedIdentifiers: revoked,
            nextLedger: next
        )
    }
}

public enum ReminderPruneRestorePolicy {
    public static let currentBackupSchemaVersion = 1

    public static func supportsBackupSchema(_ version: Int) -> Bool {
        version == currentBackupSchemaVersion
    }

    public static func graceLedgerEntry(
        fingerprint: String,
        calendarIdentifier: String,
        now: Date,
        restoreGraceInterval: TimeInterval = 86_400
    ) -> ReminderPruneLedgerEntry {
        ReminderPruneLedgerEntry(
            firstSeen: now,
            fingerprint: fingerprint,
            calendarIdentifier: calendarIdentifier,
            rulesVersion: ReminderPruneStateMachine.rulesVersion,
            graceUntil: now.addingTimeInterval(
                max(restoreGraceInterval, 86_400)
            )
        )
    }
}
