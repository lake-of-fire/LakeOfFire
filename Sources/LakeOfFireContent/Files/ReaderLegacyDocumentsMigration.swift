import Foundation
#if canImport(Darwin)
import Darwin

/// Relocates the visible children of an old ubiquity-container root into
/// Documents. Directories (including unpacked EPUBs) remain indivisible: a
/// collision preserves the entire incoming item under a recovered name.
///
/// This actor serializes in-process migrations, not all writers. Apple file
/// coordination protects cooperative writers; descriptor-relative exclusive
/// rename is the storage commit point. There is no copy-then-delete path.
public actor ReaderLegacyDocumentsMigration {
    public static let shared = ReaderLegacyDocumentsMigration()

    public struct Report: Sendable, Equatable {
        public let movedItemCount: Int
        public let recoveredItemCount: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidContainer
        case invalidDestination
        case sourceChanged
        case unsupportedItem
        case recoveryNameExhausted
        case coordinationDidNotRun
    }

    public init() {}

    public func migrate(containerURL: URL) throws -> Report {
        try Task.checkCancellation()
        guard containerURL.isFileURL else { throw Failure.invalidContainer }
        let root = containerURL.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != "/" else { throw Failure.invalidContainer }
        let rootDescriptor = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard rootDescriptor >= 0 else { throw Self.posixError() }
        defer { close(rootDescriptor) }
        let rootIdentity = try Self.identity(descriptor: rootDescriptor)
        let destination = root.appendingPathComponent("Documents", isDirectory: true)

        try Self.coordinate(url: destination, options: .forMerging) {
            try Self.requireRoot(root, identity: rootIdentity)
            let result = mkdirat(rootDescriptor, "Documents", 0o777)
            if result != 0 && errno != EEXIST { throw Self.posixError() }
        }
        let destinationDescriptor = openat(rootDescriptor, "Documents", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard destinationDescriptor >= 0 else { throw Failure.invalidDestination }
        defer { close(destinationDescriptor) }
        let destinationIdentity = try Self.identity(descriptor: destinationDescriptor)
        guard destinationIdentity.device == rootIdentity.device else { throw Failure.invalidDestination }

        func requireCurrentDirectories() throws {
            try Task.checkCancellation()
            try Self.requireRoot(root, identity: rootIdentity)
            guard try Self.identity(parent: rootDescriptor, name: "Documents") == destinationIdentity else {
                throw Failure.invalidDestination
            }
        }

        try requireCurrentDirectories()
        let items = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ).sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        try requireCurrentDirectories()
        var movedCount = 0
        var recoveredCount = 0
        for item in items {
            try requireCurrentDirectories()
            let name = item.lastPathComponent
            let sourceIdentity = try Self.identity(parent: rootDescriptor, name: name)
            // Compare filesystem identity too: case-insensitive volumes may
            // spell the existing directory differently from "Documents".
            if sourceIdentity == destinationIdentity { continue }
            guard sourceIdentity.device == rootIdentity.device,
                  [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(sourceIdentity.kind) else {
                throw Failure.unsupportedItem
            }
            var didMove = false
            for ordinal in 0...10_000 {
                try requireCurrentDirectories()
                let targetName = ordinal == 0 ? name : try Self.recoveredName(name, ordinal: ordinal)
                if try Self.exists(parent: destinationDescriptor, name: targetName) { continue }
                let target = destination.appendingPathComponent(targetName)
                didMove = try Self.coordinateMove(from: item, to: target) { coordinator in
                    try requireCurrentDirectories()
                    guard try Self.identity(parent: rootDescriptor, name: name) == sourceIdentity else {
                        throw Failure.sourceChanged
                    }
                    coordinator.item(at: item, willMoveTo: target)
                    let result = name.withCString { sourceName in
                        targetName.withCString { destinationName in
                            renameatx_np(rootDescriptor, sourceName, destinationDescriptor, destinationName, UInt32(RENAME_EXCL))
                        }
                    }
                    if result == 0 {
                        coordinator.item(at: item, didMoveTo: target)
                        return true
                    }
                    let code = errno
                    if code == EEXIST { return false }
                    // In particular EXDEV never degrades into copy + deletion.
                    throw Self.posixError(code)
                }
                try requireCurrentDirectories()
                if didMove {
                    movedCount += 1
                    if ordinal > 0 { recoveredCount += 1 }
                    break
                }
            }
            guard didMove else { throw Failure.recoveryNameExhausted }
        }
        try requireCurrentDirectories()
        // Do not publish completion for an unprocessed item created during the
        // pass. Already committed moves remain and a retry finishes the rest.
        let remaining = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        for item in remaining {
            guard try Self.identity(parent: rootDescriptor, name: item.lastPathComponent) == destinationIdentity else {
                throw Failure.sourceChanged
            }
        }
        try requireCurrentDirectories()
        return Report(movedItemCount: movedCount, recoveredItemCount: recoveredCount)
    }

    /// Preserve the extension, including for directory-backed EPUBs, while
    /// leaving room for the suffix on the supported Apple filesystems.
    static func recoveredName(_ name: String, ordinal: Int) throws -> String {
        guard ordinal > 0, ordinal <= 10_000 else { throw Failure.recoveryNameExhausted }
        let path = name as NSString
        let fileExtension = path.pathExtension
        let extensionSuffix = fileExtension.isEmpty ? "" : "." + fileExtension
        let suffix = " (Recovered \(ordinal))" + extensionSuffix
        let available = 255 - suffix.utf8.count
        guard available > 0 else { throw Failure.recoveryNameExhausted }
        let basename = fileExtension.isEmpty ? name : path.deletingPathExtension
        var prefix = ""
        for character in basename {
            let next = String(character)
            guard prefix.utf8.count + next.utf8.count <= available else { break }
            prefix += next
        }
        guard !prefix.isEmpty else { throw Failure.recoveryNameExhausted }
        return prefix + suffix
    }

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let kind: mode_t
        init(_ value: stat) {
            device = UInt64(bitPattern: Int64(value.st_dev))
            inode = UInt64(value.st_ino)
            kind = value.st_mode & mode_t(S_IFMT)
        }
    }

    private static func identity(descriptor: Int32) throws -> Identity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw posixError() }
        return Identity(value)
    }

    private static func identity(parent: Int32, name: String) throws -> Identity {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw Failure.unsupportedItem
        }
        var value = stat()
        guard name.withCString({ fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw posixError() }
        return Identity(value)
    }

    private static func exists(parent: Int32, name: String) throws -> Bool {
        do { _ = try identity(parent: parent, name: name); return true }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return false
        }
    }

    private static func requireRoot(_ root: URL, identity expected: Identity) throws {
        var value = stat()
        guard root.path.withCString({ lstat($0, &value) }) == 0,
              Identity(value) == expected else { throw Failure.sourceChanged }
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func coordinate(url: URL, options: NSFileCoordinator.WritingOptions, action: () throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { actualURL in
            result = Result {
                guard actualURL.standardizedFileURL == url.standardizedFileURL else { throw Failure.sourceChanged }
                try Task.checkCancellation()
                try action()
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.coordinationDidNotRun }
        try result.get()
    }

    private static func coordinateMove(from source: URL, to destination: URL,
                                       action: (NSFileCoordinator) throws -> Bool) throws -> Bool {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Bool, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            result = Result {
                guard from.standardizedFileURL == source.standardizedFileURL,
                      to.standardizedFileURL == destination.standardizedFileURL else { throw Failure.sourceChanged }
                try Task.checkCancellation()
                return try action(coordinator)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.coordinationDidNotRun }
        return try result.get()
    }
}
#endif
