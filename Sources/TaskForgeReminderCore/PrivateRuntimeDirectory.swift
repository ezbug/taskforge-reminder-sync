import Darwin
import Foundation

public enum PrivateRuntimeNodeKind: Equatable, Sendable {
    case directory
    case regularFile
    case other
}

public struct PrivateRuntimeNodeSecurity: Equatable, Sendable {
    public var ownerUID: UInt32
    public var permissions: Int
    public var kind: PrivateRuntimeNodeKind
    public var hasExtendedACL: Bool

    public init(
        ownerUID: UInt32,
        permissions: Int,
        kind: PrivateRuntimeNodeKind,
        hasExtendedACL: Bool
    ) {
        self.ownerUID = ownerUID
        self.permissions = permissions
        self.kind = kind
        self.hasExtendedACL = hasExtendedACL
    }
}

public enum PrivateRuntimeDirectoryPolicy {
    public static func canMigrate(
        _ security: PrivateRuntimeNodeSecurity,
        currentUserUID: UInt32,
        expectedKind: PrivateRuntimeNodeKind
    ) -> Bool {
        security.ownerUID == currentUserUID
            && security.kind == expectedKind
            && security.kind != .other
            && !security.hasExtendedACL
            && (0...0o777).contains(security.permissions)
            && security.permissions & 0o022 == 0
    }
}

public enum PrivateRuntimeDirectoryError: Error, Equatable {
    case unsafeNode
}

public enum PrivateRuntimeDirectory {
    public static func prepareRoot(at url: URL) throws {
        if let snapshot = try snapshotIfPresent(at: url) {
            try validateMigratable(
                snapshot,
                expectedKind: .directory
            )
            try migrate(snapshot, to: 0o700)
            return
        }

        try createDirectoryIncludingParents(at: url)
        try validatePrivateDirectory(at: url)
    }

    public static func prepareRootAndKnownTree(
        rootURL: URL,
        treeURL: URL
    ) throws {
        try prepareRootAndKnownTree(
            rootURL: rootURL,
            treeURL: treeURL,
            createTreeIfMissing: true
        )
    }

    public static func prepareRootAndExistingKnownTree(
        rootURL: URL,
        treeURL: URL
    ) throws {
        try prepareRootAndKnownTree(
            rootURL: rootURL,
            treeURL: treeURL,
            createTreeIfMissing: false
        )
    }

    private static func prepareRootAndKnownTree(
        rootURL: URL,
        treeURL: URL,
        createTreeIfMissing: Bool
    ) throws {
        let root = rootURL.standardizedFileURL
        let tree = treeURL.standardizedFileURL
        guard tree.deletingLastPathComponent() == root else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }

        guard let rootSnapshot = try snapshotIfPresent(at: root) else {
            try createDirectoryIncludingParents(at: root)
            if createTreeIfMissing {
                try createPrivateDirectory(at: tree)
            }
            return
        }
        try validateMigratable(rootSnapshot, expectedKind: .directory)

        let treeSnapshots: [NodeSnapshot]
        if let treeSnapshot = try snapshotIfPresent(at: tree) {
            treeSnapshots = try collectKnownTree(
                at: tree,
                rootSnapshot: treeSnapshot
            )
            for snapshot in treeSnapshots {
                try validateMigratable(
                    snapshot,
                    expectedKind: snapshot.security.kind
                )
            }
        } else {
            treeSnapshots = []
        }

        // Validate the complete known tree before changing any existing mode.
        try migrate(rootSnapshot, to: 0o700)
        if treeSnapshots.isEmpty && createTreeIfMissing {
            try createPrivateDirectory(at: tree)
        } else {
            for snapshot in treeSnapshots.sorted(by: migrationOrder) {
                let permissions = snapshot.security.kind == .directory
                    ? 0o700
                    : 0o600
                try migrate(snapshot, to: permissions)
            }
        }
    }

    public static func validatePrivateRootReadOnly(
        at url: URL
    ) throws -> Bool {
        guard let snapshot = try snapshotIfPresent(at: url) else {
            return false
        }
        try validatePrivate(
            snapshot,
            expectedKind: .directory,
            permissions: 0o700
        )
        return true
    }

    public static func validatePrivateDirectory(at url: URL) throws {
        guard let snapshot = try snapshotIfPresent(at: url) else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        try validatePrivate(
            snapshot,
            expectedKind: .directory,
            permissions: 0o700
        )
    }

    public static func validatePrivateFile(at url: URL) throws {
        guard let snapshot = try snapshotIfPresent(at: url) else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        try validatePrivate(
            snapshot,
            expectedKind: .regularFile,
            permissions: 0o600
        )
    }

    public static func createPrivateDirectory(at url: URL) throws {
        let result = mkdir(url.path, mode_t(0o700))
        if result != 0 {
            guard errno == EEXIST else {
                throw PrivateRuntimeDirectoryError.unsafeNode
            }
        }
        try validatePrivateDirectory(at: url)
    }

    public static func writePrivateFile(
        _ data: Data,
        to url: URL
    ) throws {
        try validatePrivateDirectory(
            at: url.deletingLastPathComponent()
        )
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }

        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove {
                _ = unlink(url.path)
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw PrivateRuntimeDirectoryError.unsafeNode
                }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 && errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw PrivateRuntimeDirectoryError.unsafeNode
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }

        var status = stat()
        guard
            fstat(descriptor, &status) == 0,
            metadata(for: status, hasExtendedACL: false)
                == PrivateRuntimeNodeSecurity(
                    ownerUID: getuid(),
                    permissions: 0o600,
                    kind: .regularFile,
                    hasExtendedACL: false
                ),
            try !hasExtendedACL(at: url)
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        try verifyPathStillMatches(
            url,
            device: status.st_dev,
            inode: status.st_ino,
            expectedKind: .regularFile,
            permissions: 0o600
        )
        shouldRemove = false
    }

    private struct NodeSnapshot {
        let url: URL
        let security: PrivateRuntimeNodeSecurity
        let device: dev_t
        let inode: ino_t
    }

    private static func createDirectoryIncludingParents(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            guard try snapshotIfPresent(at: url) != nil else {
                throw PrivateRuntimeDirectoryError.unsafeNode
            }
        }
        guard let snapshot = try snapshotIfPresent(at: url) else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        try validateMigratable(snapshot, expectedKind: .directory)
        try migrate(snapshot, to: 0o700)
    }

    private static func collectKnownTree(
        at url: URL,
        rootSnapshot: NodeSnapshot
    ) throws -> [NodeSnapshot] {
        guard rootSnapshot.security.kind == .directory else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(
                atPath: url.path
            )
        } catch {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        var snapshots = [rootSnapshot]
        for name in names {
            let childURL = url.appendingPathComponent(name)
            guard let child = try snapshotIfPresent(at: childURL) else {
                throw PrivateRuntimeDirectoryError.unsafeNode
            }
            switch child.security.kind {
            case .directory:
                snapshots.append(
                    contentsOf: try collectKnownTree(
                        at: childURL,
                        rootSnapshot: child
                    )
                )
            case .regularFile:
                snapshots.append(child)
            case .other:
                throw PrivateRuntimeDirectoryError.unsafeNode
            }
        }
        return snapshots
    }

    private static func validateMigratable(
        _ snapshot: NodeSnapshot,
        expectedKind: PrivateRuntimeNodeKind
    ) throws {
        guard
            PrivateRuntimeDirectoryPolicy.canMigrate(
                snapshot.security,
                currentUserUID: getuid(),
                expectedKind: expectedKind
            )
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
    }

    private static func validatePrivate(
        _ snapshot: NodeSnapshot,
        expectedKind: PrivateRuntimeNodeKind,
        permissions: Int
    ) throws {
        guard
            PrivateRuntimeDirectoryPolicy.canMigrate(
                snapshot.security,
                currentUserUID: getuid(),
                expectedKind: expectedKind
            ),
            snapshot.security.permissions == permissions
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        let descriptor = try openNode(
            snapshot,
            expectedKind: expectedKind,
            writable: false
        )
        defer { _ = close(descriptor) }
        try verifyOpenedNode(
            descriptor,
            matches: snapshot,
            expectedKind: expectedKind,
            permissions: permissions
        )
        guard try !hasExtendedACL(at: snapshot.url) else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        try verifyPathStillMatches(
            snapshot.url,
            device: snapshot.device,
            inode: snapshot.inode,
            expectedKind: expectedKind,
            permissions: permissions
        )
    }

    private static func migrate(
        _ snapshot: NodeSnapshot,
        to permissions: Int
    ) throws {
        let expectedKind = snapshot.security.kind
        let descriptor = try openNode(
            snapshot,
            expectedKind: expectedKind,
            writable: false
        )
        defer { _ = close(descriptor) }

        try verifyOpenedNode(
            descriptor,
            matches: snapshot,
            expectedKind: expectedKind,
            permissions: snapshot.security.permissions
        )
        guard
            try !hasExtendedACL(at: snapshot.url),
            fchmod(descriptor, mode_t(permissions)) == 0
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        try verifyOpenedNode(
            descriptor,
            matches: snapshot,
            expectedKind: expectedKind,
            permissions: permissions
        )
        guard try !hasExtendedACL(at: snapshot.url) else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        try verifyPathStillMatches(
            snapshot.url,
            device: snapshot.device,
            inode: snapshot.inode,
            expectedKind: expectedKind,
            permissions: permissions
        )
    }

    private static func openNode(
        _ snapshot: NodeSnapshot,
        expectedKind: PrivateRuntimeNodeKind,
        writable: Bool
    ) throws -> Int32 {
        var flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC
        if expectedKind == .directory {
            flags |= O_DIRECTORY
        }
        let descriptor = open(snapshot.url.path, flags)
        guard descriptor >= 0 else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        return descriptor
    }

    private static func verifyOpenedNode(
        _ descriptor: Int32,
        matches snapshot: NodeSnapshot,
        expectedKind: PrivateRuntimeNodeKind,
        permissions: Int
    ) throws {
        var status = stat()
        guard
            fstat(descriptor, &status) == 0,
            status.st_dev == snapshot.device,
            status.st_ino == snapshot.inode
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        let security = metadata(
            for: status,
            hasExtendedACL: snapshot.security.hasExtendedACL
        )
        guard
            security.ownerUID == getuid(),
            security.kind == expectedKind,
            security.permissions == permissions
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
    }

    private static func snapshotIfPresent(
        at url: URL
    ) throws -> NodeSnapshot? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            guard errno == ENOENT else {
                throw PrivateRuntimeDirectoryError.unsafeNode
            }
            return nil
        }
        let acl = try hasExtendedACL(at: url)
        return NodeSnapshot(
            url: url,
            security: metadata(for: status, hasExtendedACL: acl),
            device: status.st_dev,
            inode: status.st_ino
        )
    }

    private static func verifyPathStillMatches(
        _ url: URL,
        device: dev_t,
        inode: ino_t,
        expectedKind: PrivateRuntimeNodeKind,
        permissions: Int
    ) throws {
        guard
            let current = try snapshotIfPresent(at: url),
            current.device == device,
            current.inode == inode,
            current.security.ownerUID == getuid(),
            current.security.kind == expectedKind,
            current.security.permissions == permissions,
            !current.security.hasExtendedACL
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
    }

    private static func metadata(
        for status: stat,
        hasExtendedACL: Bool
    ) -> PrivateRuntimeNodeSecurity {
        let kind: PrivateRuntimeNodeKind
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            kind = .directory
        case S_IFREG:
            kind = .regularFile
        default:
            kind = .other
        }
        return PrivateRuntimeNodeSecurity(
            ownerUID: status.st_uid,
            permissions: Int(status.st_mode & 0o777),
            kind: kind,
            hasExtendedACL: hasExtendedACL
        )
    }

    private static func hasExtendedACL(at url: URL) throws -> Bool {
        errno = 0
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw PrivateRuntimeDirectoryError.unsafeNode
            }
            return false
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private static func migrationOrder(
        _ lhs: NodeSnapshot,
        _ rhs: NodeSnapshot
    ) -> Bool {
        if lhs.security.kind != rhs.security.kind {
            return lhs.security.kind == .regularFile
        }
        return lhs.url.pathComponents.count > rhs.url.pathComponents.count
    }
}

public struct TaskSourceBackupStore: Sendable {
    public let backupsRootURL: URL

    public init(backupsRootURL: URL) {
        self.backupsRootURL = backupsRootURL.standardizedFileURL
    }

    public func save(
        _ data: Data,
        fileName: String,
        batchName: String? = nil
    ) throws -> URL {
        guard
            isSinglePathComponent(fileName),
            batchName.map(isSinglePathComponent) ?? true
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        let runtimeRoot = backupsRootURL.deletingLastPathComponent()
        try PrivateRuntimeDirectory.prepareRootAndKnownTree(
            rootURL: runtimeRoot,
            treeURL: backupsRootURL
        )

        let resolvedBatchName = batchName ?? defaultBatchName()
        let batchURL = backupsRootURL.appendingPathComponent(
            resolvedBatchName,
            isDirectory: true
        )
        try PrivateRuntimeDirectory.createPrivateDirectory(at: batchURL)
        let fileURL = batchURL.appendingPathComponent(fileName)
        try PrivateRuntimeDirectory.writePrivateFile(data, to: fileURL)
        guard
            try Data(contentsOf: fileURL) == data
        else {
            throw PrivateRuntimeDirectoryError.unsafeNode
        }
        return fileURL
    }

    private func defaultBatchName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString)"
    }

    private func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }
}
