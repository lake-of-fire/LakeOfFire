import CryptoKit
import Foundation

public enum ReaderEBookServingError: Error, Equatable, Sendable {
    case invalidSource
    case unavailableSession
    case sessionRequired
    case capacityExceeded
    case mismatchedResource
}

/// The parser, fingerprint, and resource responses all own this exact private
/// snapshot. Creating this value does not associate or mutate reading progress.
/// Strict-v1 rejection must leave the caller's original file and history intact.
public final class ReaderEBookServingPackage: Sendable {
    public let sourceURL: URL
    public let fingerprint: ReaderEBookPackageFingerprint
    public let entries: [ReaderPackageEntryMetadata]
    private let snapshot: ReaderEBookPackageSnapshot
    private let source: ReaderPackageEntrySource
    private let resources: [Data: ReaderEBookPackageFingerprint.Resource]

    public init(sourceURL: URL, snapshot: ReaderEBookPackageSnapshot,
                packageDocumentPath: String? = nil,
                limits: ReaderEBookFingerprintLimits = .default) throws {
        guard sourceURL.baseURL == nil, sourceURL.scheme == "ebook",
              sourceURL.host == "ebook", sourceURL.user == nil,
              sourceURL.password == nil, sourceURL.port == nil,
              sourceURL.pathComponents.starts(with: ["/", "load"]) else {
            throw ReaderEBookServingError.invalidSource
        }
        // Validate before opening the generic ZIP reader: its dependency may
        // interpret header metadata differently or without the v1 bounds checks.
        let selectedPath = try ReaderEBookRenditionSelection.path(in: snapshot, preferred: packageDocumentPath, limits: limits)
        let fingerprint = try snapshot.fingerprint(packageDocumentPath: selectedPath, limits: limits)
        let source = try ReaderPackageEntrySource(localURL: snapshot.packageURL)
        let entries = try source.enumerateEntries()
        let resources = Dictionary(uniqueKeysWithValues: fingerprint.resources.map {
            (Data($0.path.utf8), $0)
        })
        guard entries.count == resources.count,
              Set(entries.map { Data($0.path.utf8) }) == Set(resources.keys),
              entries.allSatisfy({ entry in
                  guard entry.size >= 0, let resource = resources[Data(entry.path.utf8)] else { return false }
                  return UInt64(entry.size) == resource.byteCount
              }) else { throw ReaderEBookServingError.mismatchedResource }
        try snapshot.validateObservation(snapshot.observationToken)
        self.sourceURL = sourceURL
        self.snapshot = snapshot
        self.fingerprint = fingerprint
        self.source = source
        self.entries = entries
        self.resources = resources
    }

    /// Stable content observation for binding enrollment, unlike a session's
    /// random capability or the private snapshot's ephemeral ownership token.
    public var fileVersionToken: String { fingerprint.packageSHA256 }

    fileprivate func validate() throws {
        try snapshot.validateObservation(snapshot.observationToken)
    }

    fileprivate func readEntry(subpath: String) throws -> Data {
        try validate()
        guard let resource = resources[Data(subpath.utf8)] else {
            throw ReaderPackageEntrySourceError.entryNotFound
        }
        let bytes = try source.readEntry(subpath: subpath)
        try validate()
        guard UInt64(bytes.count) == resource.byteCount,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == resource.sha256 else {
            throw ReaderEBookServingError.mismatchedResource
        }
        return bytes
    }

    fileprivate func metadata(subpath: String, data: Data) throws -> ReaderPackageEntryResponseMetadata {
        try validate()
        guard resources[Data(subpath.utf8)] != nil else {
            throw ReaderPackageEntrySourceError.entryNotFound
        }
        return try source.mimeType(subpath: subpath, data: data)
    }
}

/// One native-issued document capability. A retained lease keeps its snapshot
/// alive, but withdrawal still revokes publication by already queued requests.
/// The lock protects only revocation, never file IO or arbitrary callbacks.
public final class ReaderEBookServingLease: @unchecked Sendable {
    public let id: String
    public let generationID: String
    public let package: ReaderEBookServingPackage
    private let lock = NSLock()
    private var revoked = false

    fileprivate init(package: ReaderEBookServingPackage) {
        id = UUID().uuidString.lowercased()
        generationID = "g1-" + SHA256.hash(data: Data(("ebook-serving-v1\0" + id).utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.package = package
    }

    fileprivate func revoke() {
        lock.lock(); revoked = true; lock.unlock()
    }

    public func validate() throws {
        lock.lock(); let active = !revoked; lock.unlock()
        guard active else { throw ReaderEBookServingError.unavailableSession }
        try package.validate()
        lock.lock(); let stillActive = !revoked; lock.unlock()
        guard stillActive else { throw ReaderEBookServingError.unavailableSession }
    }

    public func readEntry(subpath: String) throws -> Data {
        try validate()
        let data = try package.readEntry(subpath: subpath)
        try validate()
        return data
    }

    public func metadata(subpath: String, data: Data) throws -> ReaderPackageEntryResponseMetadata {
        try validate()
        let metadata = try package.metadata(subpath: subpath, data: data)
        try validate()
        return metadata
    }
}

/// Per-reader registration, not a global source-URL cache. Core installs a
/// verified package before issuing loadEBook(packageSessionID:). Every package
/// request carries that capability; a malformed/unknown/revoked capability must
/// never fall back to the original pathname or another window's latest copy.
public final class ReaderEBookServingSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [String: ReaderEBookServingLease] = [:]
    private var requiresSession = false
    private var closed = false
    private let maximumSessions: Int

    public init(maximumSessions: Int = 8) {
        self.maximumSessions = max(1, maximumSessions)
    }

    deinit { close() }

    public func install(_ package: ReaderEBookServingPackage) throws -> ReaderEBookServingLease {
        try package.validate()
        let lease = ReaderEBookServingLease(package: package)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw ReaderEBookServingError.unavailableSession }
        guard leases.count < maximumSessions else { throw ReaderEBookServingError.capacityExceeded }
        requiresSession = true
        leases[lease.id] = lease
        return lease
    }

    /// nil means this reader has never enabled session-bound serving. Once it
    /// has, absence is an error even after all leases are withdrawn.
    public func capture(sourceURL: URL, sessionID: String?, generationID: String? = nil) throws -> ReaderEBookServingLease? {
        lock.lock()
        let isClosed = closed
        let required = requiresSession
        let lease = sessionID.flatMap { leases[$0] }
        lock.unlock()
        guard !isClosed else { throw ReaderEBookServingError.unavailableSession }
        guard let sessionID else {
            guard !required else { throw ReaderEBookServingError.sessionRequired }
            return nil
        }
        guard Self.isCanonicalSessionID(sessionID), let lease,
              lease.package.sourceURL.absoluteString.utf8.elementsEqual(sourceURL.absoluteString.utf8),
              generationID.map({ $0.utf8.elementsEqual(lease.generationID.utf8) }) != false else {
            throw ReaderEBookServingError.unavailableSession
        }
        try lease.validate()
        return lease
    }

    public func withdraw(_ lease: ReaderEBookServingLease) {
        lock.lock()
        guard leases[lease.id] === lease else { lock.unlock(); return }
        leases.removeValue(forKey: lease.id)
        // Revoke under the membership lock: capture cannot see a removed member
        // as live while withdrawal returns. No IO/callback runs under this lock.
        lease.revoke()
        lock.unlock()
    }

    public func close() {
        lock.lock()
        closed = true
        let old = Array(leases.values)
        leases.removeAll()
        old.forEach { $0.revoke() }
        lock.unlock()
    }

    fileprivate func validateLegacyAccess() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !requiresSession else { throw ReaderEBookServingError.sessionRequired }
    }

    public static func isCanonicalSessionID(_ value: String) -> Bool {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return false }
        return value.utf8.elementsEqual(uuid.uuidString.lowercased().utf8)
    }
}

/// A stable reader registration. Replacing its store revokes that reader's
/// captured requests without closing a store that another window still owns.
public final class ReaderEBookServingSessionBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var store: ReaderEBookServingSessionStore
    private var generation = UUID()

    public init(store: ReaderEBookServingSessionStore = ReaderEBookServingSessionStore()) {
        self.store = store
    }

    public var currentStore: ReaderEBookServingSessionStore {
        lock.lock(); defer { lock.unlock() }; return store
    }

    public func replace(with store: ReaderEBookServingSessionStore) {
        lock.lock(); defer { lock.unlock() }
        if self.store !== store { self.store = store; generation = UUID() }
    }

    public func capture(sourceURL: URL, sessionID: String?, generationID: String? = nil) throws -> ReaderEBookServingAccess {
        lock.lock(); let store = self.store; let generation = self.generation; lock.unlock()
        let lease = try store.capture(sourceURL: sourceURL, sessionID: sessionID, generationID: generationID)
        let result = ReaderEBookServingAccess(sourceURL: sourceURL, lease: lease,
            binding: self, store: store, generation: generation)
        try result.validate()
        return result
    }

    fileprivate func matches(store: ReaderEBookServingSessionStore, generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.store === store && self.generation == generation
    }
}

public struct ReaderEBookServingAccess: Sendable {
    public let sourceURL: URL
    public let lease: ReaderEBookServingLease?
    fileprivate let binding: ReaderEBookServingSessionBinding
    fileprivate let store: ReaderEBookServingSessionStore
    fileprivate let generation: UUID

    public func validate() throws {
        try Task.checkCancellation()
        guard binding.matches(store: store, generation: generation) else {
            throw ReaderEBookServingError.unavailableSession
        }
        if let lease { try lease.validate() }
        else { try store.validateLegacyAccess() }
        guard binding.matches(store: store, generation: generation) else {
            throw ReaderEBookServingError.unavailableSession
        }
    }
}
