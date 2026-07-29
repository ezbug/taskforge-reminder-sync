import CryptoKit
import Darwin
import Foundation

public struct ReminderLocationBackup: Codable, Equatable, Sendable {
    public var title: String
    public var latitude: Double?
    public var longitude: Double?
    public var radius: Double

    public init(
        title: String,
        latitude: Double?,
        longitude: Double?,
        radius: Double
    ) {
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }
}

public struct ReminderWeekdayBackup: Codable, Equatable, Sendable {
    public var dayOfTheWeekRawValue: Int
    public var weekNumber: Int

    public init(dayOfTheWeekRawValue: Int, weekNumber: Int) {
        self.dayOfTheWeekRawValue = dayOfTheWeekRawValue
        self.weekNumber = weekNumber
    }
}

public struct ReminderAlarmBackup: Codable, Equatable, Sendable {
    public var absoluteDate: Date?
    public var relativeOffset: TimeInterval?
    public var structuredLocation: ReminderLocationBackup?
    public var proximityRawValue: Int?

    public init(
        absoluteDate: Date?,
        relativeOffset: TimeInterval?,
        structuredLocation: ReminderLocationBackup?,
        proximityRawValue: Int?
    ) {
        self.absoluteDate = absoluteDate
        self.relativeOffset = relativeOffset
        self.structuredLocation = structuredLocation
        self.proximityRawValue = proximityRawValue
    }
}

public struct ReminderRecurrenceBackup: Codable, Equatable, Sendable {
    public var frequencyRawValue: Int
    public var interval: Int
    public var daysOfWeek: [ReminderWeekdayBackup]
    public var daysOfMonth: [Int]
    public var monthsOfYear: [Int]
    public var weeksOfYear: [Int]
    public var daysOfYear: [Int]
    public var setPositions: [Int]
    public var endDate: Date?
    public var occurrenceCount: Int?

    public init(
        frequencyRawValue: Int,
        interval: Int,
        daysOfWeek: [ReminderWeekdayBackup],
        daysOfMonth: [Int],
        monthsOfYear: [Int],
        weeksOfYear: [Int],
        daysOfYear: [Int],
        setPositions: [Int],
        endDate: Date?,
        occurrenceCount: Int?
    ) {
        self.frequencyRawValue = frequencyRawValue
        self.interval = interval
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.weeksOfYear = weeksOfYear
        self.daysOfYear = daysOfYear
        self.setPositions = setPositions
        self.endDate = endDate
        self.occurrenceCount = occurrenceCount
    }
}

public struct ReminderPruneBackupItem: Codable, Equatable, Sendable {
    public var originalItemIdentifier: String
    public var title: String
    public var notes: String?
    public var url: URL?
    public var priority: Int
    public var dueDateComponents: DateComponents?
    public var startDateComponents: DateComponents?
    public var alarms: [ReminderAlarmBackup]
    public var recurrenceRules: [ReminderRecurrenceBackup]
    public var taskPresence: TaskForgeReminderPresence

    public init(
        originalItemIdentifier: String,
        title: String,
        notes: String?,
        url: URL?,
        priority: Int,
        dueDateComponents: DateComponents?,
        startDateComponents: DateComponents?,
        alarms: [ReminderAlarmBackup],
        recurrenceRules: [ReminderRecurrenceBackup],
        taskPresence: TaskForgeReminderPresence
    ) {
        self.originalItemIdentifier = originalItemIdentifier
        self.title = title
        self.notes = notes
        self.url = url
        self.priority = priority
        self.dueDateComponents = dueDateComponents
        self.startDateComponents = startDateComponents
        self.alarms = alarms
        self.recurrenceRules = recurrenceRules
        self.taskPresence = taskPresence
    }
}

public struct ReminderPruneBackupBatch: Codable, Equatable, Sendable {
    public var identifier: UUID
    public var createdAt: Date
    public var targetCalendarIdentifier: String
    public var targetCalendarTitle: String
    public var targetSourceIdentifier: String
    public var backupSchemaVersion: Int
    public var rulesVersion: Int
    public var items: [ReminderPruneBackupItem]
    public var actuallyDeletedIdentifiers: [String]?
    public var restoreAttemptIdentifier: UUID?
    public var restoredItemIdentifiers: [String: String]
    public var restoredAt: Date?

    public var actuallyDeletedItems: [ReminderPruneBackupItem]? {
        guard let identifiers = actuallyDeletedIdentifiers else {
            return nil
        }
        let deleted = Set(identifiers)
        let result = items.filter {
            deleted.contains($0.originalItemIdentifier)
        }
        return result.count == deleted.count ? result : nil
    }

    public init(
        identifier: UUID,
        createdAt: Date,
        targetCalendarIdentifier: String,
        targetCalendarTitle: String,
        targetSourceIdentifier: String,
        backupSchemaVersion: Int,
        rulesVersion: Int,
        items: [ReminderPruneBackupItem],
        actuallyDeletedIdentifiers: [String]?,
        restoreAttemptIdentifier: UUID?,
        restoredItemIdentifiers: [String: String],
        restoredAt: Date?
    ) {
        self.identifier = identifier
        self.createdAt = createdAt
        self.targetCalendarIdentifier = targetCalendarIdentifier
        self.targetCalendarTitle = targetCalendarTitle
        self.targetSourceIdentifier = targetSourceIdentifier
        self.backupSchemaVersion = backupSchemaVersion
        self.rulesVersion = rulesVersion
        self.items = items
        self.actuallyDeletedIdentifiers = actuallyDeletedIdentifiers
        self.restoreAttemptIdentifier = restoreAttemptIdentifier
        self.restoredItemIdentifiers = restoredItemIdentifiers
        self.restoredAt = restoredAt
    }
}

public enum ReminderPruneStoreError: Error, Equatable {
    case invalidLedger
    case invalidBackup
    case checksumMismatch
    case permissions
    case noUnrestoredBackup
}

public final class ReminderPruneLocalStore: @unchecked Sendable {
    public static let defaultRoot = URL(
        fileURLWithPath:
            "\(NSHomeDirectory())/Library/Application Support/"
                + "TaskForgeReminderSync",
        isDirectory: true
    )

    public let rootURL: URL

    public var ledgerURL: URL {
        rootURL.appendingPathComponent("PruneCandidates.json")
    }

    public init(rootURL: URL = defaultRoot) {
        self.rootURL = rootURL
    }

    public func loadLedger() throws -> ReminderPruneLedger {
        try ensureDirectory(rootURL)
        guard try itemExists(at: ledgerURL) else {
            return ReminderPruneLedger()
        }

        try ensurePrivateFile(ledgerURL)
        let data = try readData(at: ledgerURL, error: .invalidLedger)
        do {
            return try decoder.decode(ReminderPruneLedger.self, from: data)
        } catch {
            throw ReminderPruneStoreError.invalidLedger
        }
    }

    public func loadLedgerReadOnly() throws -> ReminderPruneLedger {
        guard try attributesIfItemExists(at: rootURL) != nil else {
            return ReminderPruneLedger()
        }
        try ensurePermissions(of: rootURL, expected: 0o700)
        guard try itemExists(at: ledgerURL) else {
            return ReminderPruneLedger()
        }
        try ensurePrivateFile(ledgerURL)
        let data = try readData(at: ledgerURL, error: .invalidLedger)
        do {
            return try decoder.decode(ReminderPruneLedger.self, from: data)
        } catch {
            throw ReminderPruneStoreError.invalidLedger
        }
    }

    public func saveLedger(_ ledger: ReminderPruneLedger) throws {
        try ensureDirectory(rootURL)
        let data: Data
        do {
            data = try encoder.encode(ledger)
        } catch {
            throw ReminderPruneStoreError.invalidLedger
        }
        try writeAtomically(data, to: ledgerURL)
    }

    public func saveBackup(_ batch: ReminderPruneBackupBatch) throws -> URL {
        let url = try backupURL(for: batch.identifier)
        try saveBackup(batch, to: url)
        return url
    }

    public func loadBackup(at url: URL) throws -> ReminderPruneBackupBatch {
        try ensureDirectory(rootURL)
        let backups = try backupsURL()
        guard url.standardizedFileURL.deletingLastPathComponent() == backups else {
            throw ReminderPruneStoreError.invalidBackup
        }

        let data = try readData(at: url, error: .invalidBackup)
        let hasSchemaVersion: Bool
        do {
            guard
                let root = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let payload = root["payload"] as? [String: Any]
            else {
                throw ReminderPruneStoreError.checksumMismatch
            }
            hasSchemaVersion = payload["backupSchemaVersion"] != nil
        } catch let error as ReminderPruneStoreError {
            throw error
        } catch {
            throw ReminderPruneStoreError.checksumMismatch
        }

        let batch: ReminderPruneBackupBatch
        if hasSchemaVersion {
            let envelope: BackupEnvelope
            do {
                envelope = try decoder.decode(BackupEnvelope.self, from: data)
            } catch {
                throw ReminderPruneStoreError.checksumMismatch
            }
            let payload: Data
            do {
                payload = try encoder.encode(envelope.payload)
            } catch {
                throw ReminderPruneStoreError.invalidBackup
            }
            guard envelope.checksum == checksum(for: payload) else {
                throw ReminderPruneStoreError.checksumMismatch
            }
            batch = envelope.payload
        } else {
            let legacy: LegacyBackupEnvelopeV1
            do {
                legacy = try decoder.decode(
                    LegacyBackupEnvelopeV1.self,
                    from: data
                )
            } catch {
                throw ReminderPruneStoreError.checksumMismatch
            }
            let legacyPayload: Data
            do {
                legacyPayload = try encoder.encode(legacy.payload)
            } catch {
                throw ReminderPruneStoreError.invalidBackup
            }
            guard legacy.checksum == checksum(for: legacyPayload) else {
                throw ReminderPruneStoreError.checksumMismatch
            }
            batch = legacy.payload.migrated()
        }
        guard isValidBackup(batch) else {
            throw ReminderPruneStoreError.invalidBackup
        }
        try ensurePrivateFile(url)
        return batch
    }

    public func latestUnrestoredBackup() throws -> (URL, ReminderPruneBackupBatch)? {
        try ensureDirectory(rootURL)
        let backups = try backupsURL()
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: backups,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        } catch {
            throw ReminderPruneStoreError.permissions
        }

        let batches = try urls.map { url in
            (url, try loadBackup(at: url))
        }
        return batches
            .filter { $0.1.restoredAt == nil }
            .sorted {
                if $0.1.createdAt == $1.1.createdAt {
                    return $0.0.lastPathComponent > $1.0.lastPathComponent
                }
                return $0.1.createdAt > $1.1.createdAt
            }
            .first
    }

    public func markRestored(at url: URL, date: Date) throws {
        var batch = try loadBackup(at: url)
        guard batch.actuallyDeletedIdentifiers != nil else {
            throw ReminderPruneStoreError.invalidBackup
        }
        batch.restoredAt = date
        try saveBackup(batch, to: url)
    }

    public func recordActuallyDeletedIdentifiers(
        _ identifiers: [String],
        at url: URL
    ) throws {
        var batch = try loadBackup(at: url)
        let original = Set(batch.items.map(\.originalItemIdentifier))
        let deleted = Set(identifiers)
        guard deleted.isSubset(of: original) else {
            throw ReminderPruneStoreError.invalidBackup
        }
        if let existing = batch.actuallyDeletedIdentifiers {
            guard Set(existing) == deleted else {
                throw ReminderPruneStoreError.invalidBackup
            }
            return
        }
        batch.actuallyDeletedIdentifiers = deleted.sorted()
        try saveBackup(batch, to: url)
    }

    public func beginRestoreAttempt(
        at url: URL
    ) throws -> ReminderPruneBackupBatch {
        var batch = try loadBackup(at: url)
        guard batch.actuallyDeletedIdentifiers != nil else {
            throw ReminderPruneStoreError.invalidBackup
        }
        if batch.restoreAttemptIdentifier == nil {
            batch.restoreAttemptIdentifier = UUID()
            try saveBackup(batch, to: url)
        }
        return batch
    }

    public func recordRestoreReadback(
        _ identifiers: [String: String],
        at url: URL
    ) throws {
        var batch = try loadBackup(at: url)
        guard
            batch.restoreAttemptIdentifier != nil,
            let deleted = batch.actuallyDeletedIdentifiers,
            Set(identifiers.keys) == Set(deleted),
            identifiers.values.allSatisfy({ !$0.isEmpty }),
            Set(identifiers.values).count == identifiers.count
        else {
            throw ReminderPruneStoreError.invalidBackup
        }
        if !batch.restoredItemIdentifiers.isEmpty {
            guard batch.restoredItemIdentifiers == identifiers else {
                throw ReminderPruneStoreError.invalidBackup
            }
            return
        }
        batch.restoredItemIdentifiers = identifiers
        try saveBackup(batch, to: url)
    }

    public func loadOrCreateHashSalt() throws -> Data {
        Self.saltSetupLock.lock()
        defer { Self.saltSetupLock.unlock() }

        try ensureDirectory(rootURL)
        let saltURL = rootURL.appendingPathComponent("PruneHashSalt")
        let lockURL = rootURL.appendingPathComponent("PruneHashSalt.lock")
        let lockDescriptor = try openSaltLock(at: lockURL)
        defer { _ = close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw ReminderPruneStoreError.permissions
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        try ensurePrivateFile(lockURL)
        if try itemExists(at: saltURL) {
            try ensurePrivateFile(saltURL)
            let salt = try readData(at: saltURL, error: .invalidBackup)
            guard salt.count == 32 else {
                throw ReminderPruneStoreError.invalidBackup
            }
            return salt
        }

        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try writeAtomically(salt, to: saltURL)
        return salt
    }

    private let fileManager = FileManager.default
    private static let saltSetupLock = NSLock()

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        JSONDecoder()
    }

    private func backupsURL() throws -> URL {
        let url = rootURL.appendingPathComponent("PruneBackups", isDirectory: true)
        try ensureDirectory(url)
        return url.standardizedFileURL
    }

    private func backupURL(for identifier: UUID) throws -> URL {
        try backupsURL().appendingPathComponent("\(identifier.uuidString).json")
    }

    private func saveBackup(
        _ batch: ReminderPruneBackupBatch,
        to url: URL
    ) throws {
        let backups = try backupsURL()
        guard url.standardizedFileURL.deletingLastPathComponent() == backups else {
            throw ReminderPruneStoreError.invalidBackup
        }

        guard isValidBackup(batch) else {
            throw ReminderPruneStoreError.invalidBackup
        }
        let payload: Data
        let data: Data
        do {
            payload = try encoder.encode(batch)
            data = try encoder.encode(
                BackupEnvelope(
                    checksum: checksum(for: payload),
                    payload: batch
                )
            )
        } catch {
            throw ReminderPruneStoreError.invalidBackup
        }
        try writeAtomically(data, to: url)
    }

    private func isValidBackup(_ batch: ReminderPruneBackupBatch) -> Bool {
        let originalIdentifiers = batch.items.map(\.originalItemIdentifier)
        let original = Set(originalIdentifiers)
        guard
            !batch.targetCalendarIdentifier.isEmpty,
            !batch.targetSourceIdentifier.isEmpty,
            batch.backupSchemaVersion > 0,
            batch.rulesVersion >= 0,
            original.count == originalIdentifiers.count,
            originalIdentifiers.allSatisfy({ !$0.isEmpty })
        else {
            return false
        }
        if let deleted = batch.actuallyDeletedIdentifiers {
            guard
                Set(deleted).count == deleted.count,
                Set(deleted).isSubset(of: original)
            else {
                return false
            }
        } else if batch.restoreAttemptIdentifier != nil
            || !batch.restoredItemIdentifiers.isEmpty
            || batch.restoredAt != nil
        {
            return false
        }
        if !batch.restoredItemIdentifiers.isEmpty {
            guard
                batch.restoreAttemptIdentifier != nil,
                let deleted = batch.actuallyDeletedIdentifiers,
                Set(batch.restoredItemIdentifiers.keys) == Set(deleted),
                batch.restoredItemIdentifiers.values.allSatisfy({
                    !$0.isEmpty
                }),
                Set(batch.restoredItemIdentifiers.values).count
                    == batch.restoredItemIdentifiers.count
            else {
                return false
            }
        }
        return batch.restoredAt == nil
            || batch.actuallyDeletedIdentifiers?.isEmpty == true
            || !batch.restoredItemIdentifiers.isEmpty
    }

    private func ensureDirectory(_ url: URL) throws {
        if let attributes = try attributesIfItemExists(at: url) {
            guard
                attributes[.type] as? String
                    == FileAttributeType.typeDirectory.rawValue
            else {
                throw ReminderPruneStoreError.permissions
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                guard try attributesIfItemExists(at: url) != nil else {
                    throw ReminderPruneStoreError.permissions
                }
            }
        }
        try ensurePermissions(of: url, expected: 0o700)
    }

    private func ensurePrivateFile(_ url: URL) throws {
        try ensurePermissions(of: url, expected: 0o600)
    }

    private func ensurePermissions(of url: URL, expected: Int) throws {
        guard let attributes = try attributesIfItemExists(at: url) else {
            throw ReminderPruneStoreError.permissions
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            ?? (attributes[.posixPermissions] as? Int)
        guard let permissions, permissions & 0o777 == expected else {
            throw ReminderPruneStoreError.permissions
        }
        try ensureOwnedByCurrentUser(url)
        try ensureNoExtendedACL(url)
    }

    private func ensureOwnedByCurrentUser(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_uid == getuid() else {
            throw ReminderPruneStoreError.permissions
        }
    }

    private func ensureNoExtendedACL(_ url: URL) throws {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw ReminderPruneStoreError.permissions
            }
            return
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw ReminderPruneStoreError.permissions
    }

    private func openSaltLock(at url: URL) throws -> Int32 {
        let descriptor = open(
            url.path,
            O_RDWR | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        if descriptor >= 0 {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                _ = close(descriptor)
                throw ReminderPruneStoreError.permissions
            }
            return descriptor
        }
        guard errno == EEXIST else {
            throw ReminderPruneStoreError.permissions
        }

        let existingDescriptor = open(url.path, O_RDWR)
        guard existingDescriptor >= 0 else {
            throw ReminderPruneStoreError.permissions
        }
        return existingDescriptor
    }

    private func itemExists(at url: URL) throws -> Bool {
        try attributesIfItemExists(at: url) != nil
    }

    private func attributesIfItemExists(
        at url: URL
    ) throws -> [FileAttributeKey: Any]? {
        do {
            return try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            guard isNoSuchFileError(error) else {
                throw ReminderPruneStoreError.permissions
            }
            return nil
        }
    }

    private func isNoSuchFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError
                || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT)
    }

    private func readData(
        at url: URL,
        error storeError: ReminderPruneStoreError
    ) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw storeError
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(parent)
        let temporaryURL = parent.appendingPathComponent(
            ".\(UUID().uuidString).tmp"
        )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw ReminderPruneStoreError.permissions
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            try ensurePrivateFile(temporaryURL)

            if try itemExists(at: url) {
                try ensurePrivateFile(url)
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            try ensurePrivateFile(url)
        } catch let error as ReminderPruneStoreError {
            throw error
        } catch {
            throw ReminderPruneStoreError.permissions
        }
    }

    private func checksum(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public final class ReminderPruneOperationFileLock: @unchecked Sendable {
    public static func defaultAnchorURL() throws -> URL {
        let fileManager = FileManager.default
        let home = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
        var candidates = [fileManager.temporaryDirectory]
        if let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first {
            candidates.append(caches)
        }
        candidates.append(
            home.appendingPathComponent(
                "Library/Caches",
                isDirectory: true
            )
        )
        candidates.append(
            home.appendingPathComponent("Library", isDirectory: true)
        )
        candidates.append(home)
        for candidate in candidates {
            if let validated = validatedAnchor(candidate) {
                return validated
            }
        }
        throw ReminderPruneStoreError.permissions
    }

    public init(
        exclusive: Bool,
        anchorURL: URL? = nil
    ) throws {
        let anchor: URL
        if let anchorURL {
            guard let validated = Self.validatedAnchor(anchorURL) else {
                throw ReminderPruneStoreError.permissions
            }
            anchor = validated
        } else {
            anchor = try Self.defaultAnchorURL()
        }
        let opened = open(
            anchor.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard opened >= 0 else {
            throw ReminderPruneStoreError.permissions
        }
        var status = stat()
        guard
            fstat(opened, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFDIR
        else {
            _ = close(opened)
            throw ReminderPruneStoreError.permissions
        }
        let operation = exclusive ? LOCK_EX : LOCK_SH
        var result: Int32
        repeat {
            result = flock(opened, operation)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            _ = close(opened)
            throw ReminderPruneStoreError.permissions
        }
        descriptor = opened
    }

    deinit {
        unlock()
    }

    public func unlock() {
        guard let descriptor else {
            return
        }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        self.descriptor = nil
    }

    private var descriptor: Int32?

    private static func validatedAnchor(_ url: URL) -> URL? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path != "/tmp", resolved.path != "/private/tmp" else {
            return nil
        }
        var status = stat()
        guard
            lstat(resolved.path, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFDIR
        else {
            return nil
        }
        return resolved
    }
}

private struct BackupEnvelope: Codable {
    let checksum: String
    let payload: ReminderPruneBackupBatch
}

private struct LegacyBackupEnvelopeV1: Codable {
    let checksum: String
    let payload: LegacyReminderPruneBackupBatchV1
}

private struct LegacyReminderPruneBackupBatchV1: Codable {
    let identifier: UUID
    let createdAt: Date
    let targetCalendarIdentifier: String
    let targetCalendarTitle: String
    let targetSourceIdentifier: String
    let rulesVersion: Int
    let items: [ReminderPruneBackupItem]
    let actuallyDeletedIdentifiers: [String]?
    let restoreAttemptIdentifier: UUID?
    let restoredItemIdentifiers: [String: String]
    let restoredAt: Date?

    func migrated() -> ReminderPruneBackupBatch {
        ReminderPruneBackupBatch(
            identifier: identifier,
            createdAt: createdAt,
            targetCalendarIdentifier: targetCalendarIdentifier,
            targetCalendarTitle: targetCalendarTitle,
            targetSourceIdentifier: targetSourceIdentifier,
            backupSchemaVersion:
                ReminderPruneRestorePolicy.currentBackupSchemaVersion,
            rulesVersion: rulesVersion,
            items: items,
            actuallyDeletedIdentifiers: actuallyDeletedIdentifiers,
            restoreAttemptIdentifier: restoreAttemptIdentifier,
            restoredItemIdentifiers: restoredItemIdentifiers,
            restoredAt: restoredAt
        )
    }
}
