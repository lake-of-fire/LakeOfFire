import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ReaderEBookPackageSnapshotError: Error, Equatable, Sendable {
    case invalidSource
    case unsupportedSource
    case coordinationUnavailable
    case coordinationDidNotRead
    case limitExceeded
    case sourceChanged
    case unavailable
}

/// Owns the bytes of one open document, not its current pathname or its reading
/// state. Retain this value for as long as any parser/viewer/entry source reads
/// packageURL. There is deliberately no close() that can invalidate another
/// consumer's retained reference. The last owner removes only its private copy.
public final class ReaderEBookPackageSnapshot: Sendable {
    public let packageURL: URL
    public let observationToken: String
    private let directory: URL
    private let retainedFile: FileObservation

    private init(directory: URL, packageURL: URL, retainedFile: FileObservation) {
        self.directory = directory
        self.packageURL = packageURL
        self.retainedFile = retainedFile
        observationToken = UUID().uuidString.lowercased()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// File coordination may wait for a provider download. Do not call this to
    /// enumerate an entire cloud library: automatic discovery must pass only
    /// already-readable items. User-requested opening can follow normal download
    /// admission. Cancellation also cancels the pending coordination request.
    ///
    /// forUploading is used for its documented snapshot semantics, NOT to upload
    /// anything. A coordinated directory read alone does not exclude child-file
    /// writers. Foundation supplies a temporary ZIP for directory packages; the
    /// private copy is completed inside its accessor, before Foundation unlinks it.
    /// Always use packageURL for parsing AND viewing, not the original live URL.
    public static func capture(
        at sourceURL: URL,
        maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    ) async throws -> ReaderEBookPackageSnapshot {
        guard sourceURL.isFileURL, sourceURL.baseURL == nil, maximumBytes >= 0 else {
            throw ReaderEBookPackageSnapshotError.invalidSource
        }
        try Task.checkCancellation()
#if canImport(Darwin)
        let coordination = SnapshotCoordination()
        let worker = Task.detached(priority: .userInitiated) {
            try coordination.capture(at: sourceURL, maximumBytes: maximumBytes)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await worker.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            worker.cancel()
            coordination.cancel()
        }
#else
        throw ReaderEBookPackageSnapshotError.coordinationUnavailable
#endif
    }

    /// A live owner and its exact token must accompany every file observation.
    /// This validates the private observation, not the current contents of the
    /// original URL. A reader remains on its captured revision after an external
    /// edit; opening the edited source creates a new observation and binding.
    public func validateObservation(_ token: String) throws {
        try Task.checkCancellation()
        guard token.utf8.elementsEqual(observationToken.utf8) else {
            throw ReaderEBookPackageSnapshotError.unavailable
        }
        let input = try Self.openRegularFile(packageURL)
        defer { try? input.close() }
        guard try Self.fileObservation(input.fileDescriptor) == retainedFile else {
            throw ReaderEBookPackageSnapshotError.unavailable
        }
    }

    /// Internal seam: the production accessor supplies a Foundation-owned stable
    /// file here. Tests may supply an immutable fixture. This is NOT a replacement
    /// for coordination when reading a live user file or an unpacked directory.
    static func retainCoordinatedFile(
        at coordinatedURL: URL,
        maximumBytes: Int64,
        temporaryParent: URL = FileManager.default.temporaryDirectory,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> ReaderEBookPackageSnapshot {
        guard coordinatedURL.isFileURL, coordinatedURL.baseURL == nil,
              temporaryParent.isFileURL, maximumBytes >= 0 else {
            throw ReaderEBookPackageSnapshotError.invalidSource
        }
        try checkCancellation()
        let input = try openRegularFile(coordinatedURL)
        defer { try? input.close() }
        let original = try fileObservation(input.fileDescriptor)
        guard original.size <= maximumBytes else {
            throw ReaderEBookPackageSnapshotError.limitExceeded
        }
        let directory = temporaryParent.appendingPathComponent(
            "manabi-epub-snapshot-" + UUID().uuidString.lowercased(), isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        let outputURL = directory.appendingPathComponent("package.epub", isDirectory: false)
        let fd = outputURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw posixError() }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            try checkCancellation()
            guard Int64(chunk.count) <= maximumBytes - copied else {
                throw ReaderEBookPackageSnapshotError.limitExceeded
            }
            guard Int64(chunk.count) <= original.size - copied else {
                throw ReaderEBookPackageSnapshotError.sourceChanged
            }
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
        }
        try checkCancellation()
        guard copied == original.size, try fileObservation(input.fileDescriptor) == original else {
            throw ReaderEBookPackageSnapshotError.sourceChanged
        }
        try output.close()
        // Readers get a private read-only file, never a hard link to provider data.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: outputURL.path)
        let retained = try openRegularFile(outputURL)
        defer { try? retained.close() }
        let result = ReaderEBookPackageSnapshot(directory: directory, packageURL: outputURL,
            retainedFile: try fileObservation(retained.fileDescriptor))
        try checkCancellation()
        committed = true
        return result
    }

    private struct FileObservation: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private static func fileObservation(_ fd: Int32) throws -> FileObservation {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posixError() }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_size >= 0 else {
            throw ReaderEBookPackageSnapshotError.unsupportedSource
        }
#if canImport(Darwin)
        let modified = value.st_mtimespec
        let changed = value.st_ctimespec
#else
        let modified = value.st_mtim
        let changed = value.st_ctim
#endif
        return .init(device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(truncatingIfNeeded: value.st_ino), size: Int64(value.st_size),
            modifiedSeconds: Int64(modified.tv_sec), modifiedNanoseconds: Int64(modified.tv_nsec),
            changedSeconds: Int64(changed.tv_sec), changedNanoseconds: Int64(changed.tv_nsec))
    }

    private static func openRegularFile(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw ReaderEBookPackageSnapshotError.invalidSource }
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            // NONBLOCK prevents a malicious special file from hanging before
            // fstat rejects it. NOFOLLOW prevents a final-component symlink race.
            return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { throw posixError() }
        let result = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { _ = try fileObservation(fd); return result }
        catch { try? result.close(); throw error }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

#if canImport(Darwin)
/// NSFileCoordinator supports cancellation from the requesting task. The
/// accessor/result variables themselves remain confined to the worker thread.
private final class SnapshotCoordination: @unchecked Sendable {
    private let coordinator = NSFileCoordinator(filePresenter: nil)

    func cancel() { coordinator.cancel() }

    func capture(at sourceURL: URL, maximumBytes: Int64) throws -> ReaderEBookPackageSnapshot {
        try Task.checkCancellation()
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let attributes = try sourceURL.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey
        ])
        guard attributes.isSymbolicLink != true,
              attributes.isRegularFile == true || attributes.isDirectory == true else {
            throw ReaderEBookPackageSnapshotError.unsupportedSource
        }
        var coordinationError: NSError?
        var result: Result<ReaderEBookPackageSnapshot, Error>?
        coordinator.coordinate(readingItemAt: sourceURL, options: .forUploading,
            error: &coordinationError) { coordinatedURL in
            result = Result {
                try Task.checkCancellation()
                return try ReaderEBookPackageSnapshot.retainCoordinatedFile(
                    at: coordinatedURL, maximumBytes: maximumBytes
                )
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ReaderEBookPackageSnapshotError.coordinationDidNotRead }
        try Task.checkCancellation()
        let retained = try result.get()
        if attributes.isDirectory == true {
            return try ReaderEBookDirectorySnapshotArchive.retainContents(
                of: retained, rootName: sourceURL.lastPathComponent, maximumBytes: maximumBytes
            )
        }
        return retained
    }
}
#endif
