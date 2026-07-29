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
