import Foundation
#if canImport(Darwin)
import Darwin

/// Relocates the visible children of an old ubiquity-container root into
/// Documents. Directories (including unpacked EPUBs) remain indivisible: a
/// collision preserves the entire incoming item under a recovered name.
///
/// Cloud inventory snapshots may suspend and overlap other attempts. The actor
/// serializes synchronous commit loops; every resume revalidates admission and
/// directory identity. Apple file coordination protects cooperative writers;
/// descriptor-relative exclusive
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
        case admissionExpired
        case inventoryUnavailable
        case payloadUnavailable
    }

    /// Foundation supplies this immutable, opaque account identity. It is only
    /// retained and compared, never mutated or inspected across executors.
    public struct Admission: @unchecked Sendable {
        public let root: URL
        private let identity: any NSObjectProtocol
        private let identifier: String

        public init(root: URL, identity: any NSCoding & NSCopying & NSObjectProtocol, identifier: String) {
            self.root = root.standardizedFileURL
            self.identity = identity.copy(with: nil) as? any NSObjectProtocol ?? identity
            self.identifier = identifier
        }

        public func isCurrent() -> Bool {
            let manager = FileManager.default
            guard let current = manager.ubiquityIdentityToken,
                  identity.isEqual(current),
                  let currentRoot = manager.url(forUbiquityContainerIdentifier: identifier) else { return false }
            return currentRoot.standardizedFileURL == root
        }
    }

    // Internal boundaries exercise account loss, cloud-only inventory and failed
    // storage commits using real temporary files without requiring an iCloud account.
    struct Environment: Sendable {
        var isCurrent: @Sendable () -> Bool = { true }
        var inventory: (@Sendable (URL) async throws -> [URL])?
        var requirePayload: @Sendable (URL) throws -> Void = { try ReaderLegacyDocumentsMigration.requireAvailablePayload($0) }
        var rename: @Sendable (Int32, String, Int32, String) -> Int32 = { source, name, destination, target in
            name.withCString { from in
                target.withCString { to in renameatx_np(source, from, destination, to, UInt32(RENAME_EXCL)) }
            }
        }
        var moveNotification: @Sendable (URL, URL, Bool) -> Void = { _, _, _ in }
    }

    private let environment: Environment
    public init() { environment = Environment() }
    init(environment: Environment) { self.environment = environment }

    public func migrate(containerURL: URL, validateAdmission: (@Sendable () -> Bool)? = nil) async throws -> Report {
        func requireAdmission() throws {
            try Task.checkCancellation()
            guard environment.isCurrent(), validateAdmission?() ?? true else { throw Failure.admissionExpired }
        }
        try requireAdmission()
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
            try requireAdmission()
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
            try requireAdmission()
            try Self.requireRoot(root, identity: rootIdentity)
            guard try Self.identity(parent: rootDescriptor, name: "Documents") == destinationIdentity else {
                throw Failure.invalidDestination
            }
        }

        try requireCurrentDirectories()
        func inventory() async throws -> [URL] {
            let entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isHiddenKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey], options: []
            )
            var local: [URL] = []
            for entry in entries {
                let values = try entry.resourceValues(forKeys: [.isHiddenKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                // Hidden container metadata is excluded independently of its
                // cloud download state. Logical user URLs come from the public
                // query snapshot; private placeholder names are never inferred.
                if !entry.lastPathComponent.hasPrefix("."), values.isHidden != true {
                    local.append(entry)
                }
            }
            let cloud: [URL]
            if let discover = environment.inventory { cloud = try await discover(root) }
            else if validateAdmission != nil { cloud = try await Self.cloudInventory(root: root) }
            else { cloud = [] }
            try requireCurrentDirectories()
            // Metadata includes descendants and logical URLs for evicted items.
            // Collapse to an indivisible top-level user item, never a private
            // placeholder filename or a hidden container metadata directory.
            let children = try Self.logicalChildren(cloud, root: root)
            for url in cloud {
                let top = try Self.logicalChildren([url], root: root)
                if let child = top.first,
                   (try? Self.identity(parent: rootDescriptor, name: child.lastPathComponent)) != destinationIdentity {
                    try environment.requirePayload(url)
                }
            }
            return Array(Set(local + children)).sorted {
                $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)
            }
        }
        let items = try await inventory()
        try requireCurrentDirectories()
        var movedCount = 0
        var recoveredCount = 0
        for item in items {
            try requireCurrentDirectories()
            let name = item.lastPathComponent
            // Never traverse or download the existing destination's library.
            // Its filesystem identity also handles case-insensitive spelling.
            if (try? Self.identity(parent: rootDescriptor, name: name)) == destinationIdentity { continue }
            // Public resource/download APIs run before requiring lstat: a logical cloud
            // URL need not have a local directory entry yet.
            try environment.requirePayload(item)
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
                    try environment.requirePayload(item)
                    try requireAdmission()
                    coordinator.item(at: item, willMoveTo: target)
                    environment.moveNotification(item, target, false)
                    var committedURL = item
                    defer {
                        coordinator.item(at: item, didMoveTo: committedURL)
                        environment.moveNotification(item, committedURL, true)
                    }
                    // Recheck after presenter notification, immediately before
                    // the exclusive storage commit. All exits balance willMove.
                    try requireCurrentDirectories()
                    guard try Self.identity(parent: rootDescriptor, name: name) == sourceIdentity else {
                        throw Failure.sourceChanged
                    }
                    let result = environment.rename(rootDescriptor, name, destinationDescriptor, targetName)
                    if result == 0 {
                        committedURL = target
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
        let remaining = try await inventory()
        for item in remaining {
            guard try Self.identity(parent: rootDescriptor, name: item.lastPathComponent) == destinationIdentity else {
                throw Failure.sourceChanged
            }
        }
        try requireCurrentDirectories()
        return Report(movedItemCount: movedCount, recoveredItemCount: recoveredCount)
    }

    static func logicalChildren(_ urls: [URL], root: URL) throws -> [URL] {
        let prefix = root.standardizedFileURL.path + "/"
        var children = Set<URL>()
        for url in urls {
            guard url.isFileURL else { throw Failure.inventoryUnavailable }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard let name = relative.split(separator: "/").first, !name.hasPrefix(".") else { continue }
            children.insert(root.appendingPathComponent(String(name)))
        }
        return Array(children)
    }

    private static func requireAvailablePayload(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isDirectoryKey]
        func requireDownloaded(_ item: URL) throws {
            let values = try item.resourceValues(forKeys: keys)
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current,
               values.ubiquitousItemDownloadingStatus != .downloaded {
                try FileManager.default.startDownloadingUbiquitousItem(at: item)
                throw Failure.payloadUnavailable
            }
        }
        try requireDownloaded(url)
        if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            var traversalError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys), options: [],
                errorHandler: { _, error in traversalError = error; return false }
            ) else { throw Failure.payloadUnavailable }
            for case let descendant as URL in enumerator { try requireDownloaded(descendant) }
            if let traversalError { throw traversalError }
        }
    }

    /// A finite initial-gathering snapshot discovers logical URLs absent from
    /// local enumeration. The query lives on the main run loop and is stopped
    /// on success, cancellation, timeout or start failure. Retry owns downloads.
    @MainActor
    private static func cloudInventory(root: URL) async throws -> [URL] {
        let query = NSMetadataQuery()
        let gathering = GatheringState()
        let observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { _ in
            Task { @MainActor in gathering.finished = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(value: true)
        guard query.start() else { throw Failure.inventoryUnavailable }
        defer { query.stop() }
        let deadline = Date().addingTimeInterval(10)
        while !gathering.finished {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Failure.inventoryUnavailable }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        query.disableUpdates()
        defer { query.enableUpdates() }
        var urls: [URL] = []
        for result in query.results {
            guard let item = result as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else {
                throw Failure.inventoryUnavailable
            }
            urls.append(url)
        }
        return urls
    }

    @MainActor
    private final class GatheringState {
        var finished = false
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
