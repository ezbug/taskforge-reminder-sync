import CoreLocation
import EventKit
import Foundation
import TaskForgeReminderCore

enum ReminderBackupAdapter {
    static func capture(_ reminder: EKReminder) -> ReminderPruneBackupItem {
        ReminderPruneBackupItem(
            originalItemIdentifier: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            url: reminder.url,
            priority: reminder.priority,
            dueDateComponents: reminder.dueDateComponents,
            startDateComponents: reminder.startDateComponents,
            alarms: (reminder.alarms ?? []).map(captureAlarm),
            recurrenceRules: (reminder.recurrenceRules ?? []).map(
                captureRecurrence
            )
        )
    }

    static func restore(
        _ backup: ReminderPruneBackupItem,
        into reminder: EKReminder
    ) {
        reminder.title = backup.title
        reminder.notes = backup.notes
        reminder.url = backup.url
        reminder.priority = backup.priority
        reminder.dueDateComponents = backup.dueDateComponents
        reminder.startDateComponents = backup.startDateComponents

        (reminder.alarms ?? []).forEach(reminder.removeAlarm)
        (reminder.recurrenceRules ?? []).forEach(
            reminder.removeRecurrenceRule
        )

        for backupAlarm in backup.alarms {
            let alarm: EKAlarm
            if let absoluteDate = backupAlarm.absoluteDate {
                alarm = EKAlarm(absoluteDate: absoluteDate)
            } else {
                alarm = EKAlarm(
                    relativeOffset: backupAlarm.relativeOffset ?? 0
                )
            }
            if let backupLocation = backupAlarm.structuredLocation {
                let location = EKStructuredLocation(
                    title: backupLocation.title
                )
                if
                    let latitude = backupLocation.latitude,
                    let longitude = backupLocation.longitude
                {
                    location.geoLocation = CLLocation(
                        latitude: latitude,
                        longitude: longitude
                    )
                }
                location.radius = backupLocation.radius
                alarm.structuredLocation = location
            }
            if let proximity = alarmProximity(
                rawValue: backupAlarm.proximityRawValue
            ) {
                alarm.proximity = proximity
            }
            reminder.addAlarm(alarm)
        }

        for backupRule in backup.recurrenceRules {
            guard
                let frequency = recurrenceFrequency(
                    rawValue: backupRule.frequencyRawValue
                ),
                backupRule.interval > 0,
                validRecurrenceValues(backupRule),
                let daysOfWeek = recurrenceDays(
                    from: backupRule.daysOfWeek
                )
            else {
                continue
            }
            let rule = EKRecurrenceRule(
                recurrenceWith: frequency,
                interval: backupRule.interval,
                daysOfTheWeek: daysOfWeek.nilIfEmpty,
                daysOfTheMonth: backupRule.daysOfMonth.numbers.nilIfEmpty,
                monthsOfTheYear: backupRule.monthsOfYear.numbers.nilIfEmpty,
                weeksOfTheYear: backupRule.weeksOfYear.numbers.nilIfEmpty,
                daysOfTheYear: backupRule.daysOfYear.numbers.nilIfEmpty,
                setPositions: backupRule.setPositions.numbers.nilIfEmpty,
                end: recurrenceEnd(
                    date: backupRule.endDate,
                    count: backupRule.occurrenceCount
                )
            )
            reminder.addRecurrenceRule(rule)
        }
    }

    private static func captureAlarm(_ alarm: EKAlarm) -> ReminderAlarmBackup {
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

    private static func captureRecurrence(
        _ rule: EKRecurrenceRule
    ) -> ReminderRecurrenceBackup {
        let end = rule.recurrenceEnd
        return ReminderRecurrenceBackup(
            frequencyRawValue: rule.frequency.rawValue,
            interval: rule.interval,
            daysOfWeek: (rule.daysOfTheWeek ?? []).map {
                ReminderWeekdayBackup(
                    dayOfTheWeekRawValue: $0.dayOfTheWeek.rawValue,
                    weekNumber: $0.weekNumber
                )
            },
            daysOfMonth: (rule.daysOfTheMonth ?? []).map(\.intValue),
            monthsOfYear: (rule.monthsOfTheYear ?? []).map(\.intValue),
            weeksOfYear: (rule.weeksOfTheYear ?? []).map(\.intValue),
            daysOfYear: (rule.daysOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue),
            endDate: end?.endDate,
            occurrenceCount: end.flatMap {
                $0.occurrenceCount > 0 ? Int($0.occurrenceCount) : nil
            }
        )
    }

    private static func recurrenceFrequency(
        rawValue: Int
    ) -> EKRecurrenceFrequency? {
        switch rawValue {
        case EKRecurrenceFrequency.daily.rawValue:
            return .daily
        case EKRecurrenceFrequency.weekly.rawValue:
            return .weekly
        case EKRecurrenceFrequency.monthly.rawValue:
            return .monthly
        case EKRecurrenceFrequency.yearly.rawValue:
            return .yearly
        default:
            return nil
        }
    }

    private static func recurrenceDays(
        from backups: [ReminderWeekdayBackup]
    ) -> [EKRecurrenceDayOfWeek]? {
        var result: [EKRecurrenceDayOfWeek] = []
        for backup in backups {
            guard
                let weekday = weekday(rawValue: backup.dayOfTheWeekRawValue),
                (-53...53).contains(backup.weekNumber)
            else {
                return nil
            }
            result.append(
                EKRecurrenceDayOfWeek(
                    dayOfTheWeek: weekday,
                    weekNumber: backup.weekNumber
                )
            )
        }
        return result
    }

    private static func validRecurrenceValues(
        _ backup: ReminderRecurrenceBackup
    ) -> Bool {
        backup.daysOfMonth.allSatisfy {
            $0 != 0 && (-31...31).contains($0)
        }
            && backup.monthsOfYear.allSatisfy { (1...12).contains($0) }
            && backup.weeksOfYear.allSatisfy {
                $0 != 0 && (-53...53).contains($0)
            }
            && backup.daysOfYear.allSatisfy {
                $0 != 0 && (-366...366).contains($0)
            }
            && backup.setPositions.allSatisfy {
                $0 != 0 && (-366...366).contains($0)
            }
    }

    private static func weekday(rawValue: Int) -> EKWeekday? {
        switch rawValue {
        case EKWeekday.sunday.rawValue:
            return .sunday
        case EKWeekday.monday.rawValue:
            return .monday
        case EKWeekday.tuesday.rawValue:
            return .tuesday
        case EKWeekday.wednesday.rawValue:
            return .wednesday
        case EKWeekday.thursday.rawValue:
            return .thursday
        case EKWeekday.friday.rawValue:
            return .friday
        case EKWeekday.saturday.rawValue:
            return .saturday
        default:
            return nil
        }
    }

    private static func alarmProximity(
        rawValue: Int?
    ) -> EKAlarmProximity? {
        switch rawValue {
        case EKAlarmProximity.none.rawValue:
            return EKAlarmProximity.none
        case EKAlarmProximity.enter.rawValue:
            return .enter
        case EKAlarmProximity.leave.rawValue:
            return .leave
        default:
            return nil
        }
    }

    private static func recurrenceEnd(
        date: Date?,
        count: Int?
    ) -> EKRecurrenceEnd? {
        if let date {
            return EKRecurrenceEnd(end: date)
        }
        if let count, count > 0 {
            return EKRecurrenceEnd(occurrenceCount: count)
        }
        return nil
    }
}

private extension Array {
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}

private extension Array where Element == Int {
    var numbers: [NSNumber] {
        map(NSNumber.init(value:))
    }
}
