import SwiftUI
import LakeOfFireCore
import struct LakeKit.AccountSessionAccess
import struct LakeKit.AccountSessionSnapshot
import RealmSwift
import MarkdownKit
import SwiftSoup
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealmSwiftGaps
import UniformTypeIdentifiers


private func logReaderLoad(_ message: String) {
#if DEBUG
    debugPrint("# READERLOAD \(message)")
#endif
}

private func logSnippetEvent(_ stage: String, _ parts: String...) {
#if DEBUG
    debugPrint("# SNIPPETS", stage, parts.joined(separator: " "))
#endif
}

private let readerContentLoaderVerboseLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_READERLOAD_VERBOSE_CONTENT_LOADER"] == "1"
private let readerContentLoaderSlowStepThreshold: TimeInterval = 0.010
private let readerContentLoaderSlowSummaryThreshold: TimeInterval = 0.050

@inline(__always)
private func shouldLogLoadAllStep(found: Bool, elapsed: TimeInterval) -> Bool {
    readerContentLoaderVerboseLoggingEnabled || found || elapsed >= readerContentLoaderSlowStepThreshold
}

@inline(__always)
private func shouldLogLoadAllSummary(candidateCount: Int, elapsed: TimeInterval) -> Bool {
    readerContentLoaderVerboseLoggingEnabled || candidateCount > 0 || elapsed >= readerContentLoaderSlowSummaryThreshold
}

fileprivate extension URL {
    func settingScheme(_ value: String) -> URL {
        let components = NSURLComponents.init(url: self, resolvingAgainstBaseURL: true)
        components?.scheme = value
        return (components?.url!)!
    }
}

public struct ReaderContentAdditionalProvider: Sendable {
    public let id: String
    public let load: @Sendable (URL) async throws -> [ReaderContentLoader.ContentReference]

    public init(
        id: String,
        load: @escaping @Sendable (URL) async throws -> [ReaderContentLoader.ContentReference]
    ) {
        self.id = id
        self.load = load
    }
}

public enum ReaderContentBackgroundAnalysisLoader {
    nonisolated(unsafe) public static var inlineHTMLAnalysisEnqueuer: (@Sendable (URL, URL?, String?, String) async -> Void)?
}

/// Execute a synchronous commit under its captured account publication fence.
public typealias ReaderContentCommitIfCurrent = @Sendable (_ commit: () throws -> Void) throws -> Bool

/// Loads from any source by URL.
public struct ReaderContentLoader {
    // Task-scoped input lets behavior tests exercise the public pasteboard route.
    @TaskLocal static var pasteboardStringsForTesting: (html: String?, text: String?)? = nil

    // Synchronous task-local observation verifies capture and actual task
    // joining without adding a scheduling point to production admission.
    enum GetContentEvent: Sendable { case capturedStorage, joinedTask }
    @TaskLocal static var getContentObservationForTesting: (@Sendable (GetContentEvent) -> Void)? = nil

    /// Immutable Realm routing for one reader discovery operation. Capture this
    /// before an actor hop: account replacement may otherwise make one query
    /// read one store and a later write land in another.
    private struct DiscoveryStorageIdentity: Hashable, Sendable {
        let bookmark: String
        let history: String
        let feed: String
        let providerRevision: UInt64
    }

    private struct DiscoveryStorage: @unchecked Sendable {
        let bookmarkConfiguration: Realm.Configuration
        let historyConfiguration: Realm.Configuration
        let feedConfiguration: Realm.Configuration
        let bookmarkAdmission: RealmStorageAdmission
        let historyAdmission: RealmStorageAdmission
        let feedAdmission: RealmStorageAdmission
        let identity: DiscoveryStorageIdentity
        let providers: [ReaderContentAdditionalProvider]

        init(
            bookmarkConfiguration: Realm.Configuration = ReaderContentLoader.bookmarkRealmConfiguration,
            historyConfiguration: Realm.Configuration = ReaderContentLoader.historyRealmConfiguration,
            feedConfiguration: Realm.Configuration = ReaderContentLoader.feedEntryRealmConfiguration
        ) {
            self.bookmarkConfiguration = bookmarkConfiguration
            self.historyConfiguration = historyConfiguration
            self.feedConfiguration = feedConfiguration
            let actor = RealmBackgroundActor.shared
            let history = actor.captureStorageAdmission(for: historyConfiguration)
            let bookmark = actor.realmCacheKey(for: bookmarkConfiguration) == actor.realmCacheKey(for: historyConfiguration)
                ? history : actor.captureStorageAdmission(for: bookmarkConfiguration)
            let feedKey = actor.realmCacheKey(for: feedConfiguration)
            let feed = feedKey == actor.realmCacheKey(for: historyConfiguration) ? history
                : feedKey == actor.realmCacheKey(for: bookmarkConfiguration) ? bookmark
                : actor.captureStorageAdmission(for: feedConfiguration)
            historyAdmission = history
            bookmarkAdmission = bookmark
            feedAdmission = feed
            providers = ReaderContentLoader.additionalContentProviders
            identity = DiscoveryStorageIdentity(bookmark: bookmark.scopeIdentity,
                history: history.scopeIdentity, feed: feed.scopeIdentity,
                providerRevision: ReaderContentLoader.additionalContentProviderRevision)
        }
        func validate(includeFeed: Bool = true) throws {
            let actor = RealmBackgroundActor.shared
            for (configuration, admission) in [(historyConfiguration, historyAdmission),
                (bookmarkConfiguration, bookmarkAdmission)] + (includeFeed ? [(feedConfiguration, feedAdmission)] : []) {
                guard admission.matchesCurrentStorageIdentity({ actor.realmCacheKey(for: configuration) }) else {
                    throw RealmBackgroundActorError.realmFileChangedDuringOpen
                }
            }
        }

        func reference(for content: any ReaderContentProtocol) -> ContentReference? {
            if content.objectSchema.objectClass == Bookmark.self {
                return ContentReference(content: content, configuration: bookmarkConfiguration, storageAdmission: bookmarkAdmission)
            }
            if content is FeedEntry {
                return ContentReference(content: content, configuration: feedConfiguration, storageAdmission: feedAdmission)
            }
            if content is ContentFile || content is HistoryRecord {
                return ContentReference(content: content, configuration: historyConfiguration, storageAdmission: historyAdmission)
            }
            return ContentReference(content: content)
        }
    }

    private struct LoadAllTaskKey: Hashable, Sendable {
        let url: String
        let skipContentFiles: Bool
        let skipFeedEntries: Bool
        let storage: DiscoveryStorageIdentity
    }

    private struct GetContentTaskKey: Hashable, Sendable {
        let url: String
        let countsAsHistoryVisit: Bool
        let storage: DiscoveryStorageIdentity
    }

    @MainActor
    private static var inFlightGetContentTasks: [GetContentTaskKey: Task<(any ReaderContentProtocol)?, Error>] = [:]
    @RealmBackgroundActor
    private static var inFlightLoadAllTasks: [LoadAllTaskKey: Task<[ContentReference], Error>] = [:]
    @RealmBackgroundActor
    static var loadAllDiscoveryGateForTesting: (@Sendable () async -> Void)?

    enum ContentWriteOperation: Sendable, Equatable {
        case historyCreation, loadedContent, clipboard, demotion
    }
    @RealmBackgroundActor
    static var contentWriteGateForTesting: (@Sendable (ContentWriteOperation) async -> Void)?

    public struct ContentReference: @unchecked Sendable {
        public let contentType: RealmSwift.Object.Type
        public let contentKey: String
        public let contentCreatedAt: Date
        public let contentURL: URL
        public let realmConfiguration: Realm.Configuration
        public let storageAdmission: RealmStorageAdmission
        private let objectID: UInt64

        public init?(content: any ReaderContentProtocol) {
            self.init(content: content, storageAdmission: nil)
        }

        public init?(content: any ReaderContentProtocol, storageAdmission: RealmStorageAdmission?) {
            guard !content.isInvalidated, let configuration = content.realm?.configuration else { return nil }
            self.init(content: content, configuration: configuration,
                      storageAdmission: storageAdmission ?? RealmBackgroundActor.shared.captureStorageAdmission(for: configuration))
        }

        init?(content: any ReaderContentProtocol, configuration: Realm.Configuration,
              storageAdmission: RealmStorageAdmission) {
            guard !content.isInvalidated, content.realm != nil,
                  let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type else { return nil }
            self.contentType = contentType
            contentKey = content.compoundKey
            contentCreatedAt = content.createdAt
            contentURL = content.url
            objectID = content.id
            realmConfiguration = configuration
            self.storageAdmission = storageAdmission
        }

        public func validateStorage() throws {
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        }

        fileprivate func matches(_ content: any ReaderContentProtocol) -> Bool {
            guard !content.isInvalidated, content.objectSchema.objectClass == contentType,
                  content.compoundKey == contentKey, content.id == objectID,
                  content.createdAt == contentCreatedAt, content.url == contentURL,
                  let candidateConfiguration = content.realm?.configuration,
                  storageAdmission.matchesCurrentStorageIdentity({
                      RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
                  }) else { return false }
            if let identifier = realmConfiguration.inMemoryIdentifier {
                return candidateConfiguration.inMemoryIdentifier == identifier
            }
            guard candidateConfiguration.inMemoryIdentifier == nil,
                  let originalURL = realmConfiguration.fileURL,
                  let candidateURL = candidateConfiguration.fileURL else { return false }
            return originalURL.standardizedFileURL == candidateURL.standardizedFileURL
        }

        fileprivate func matchesSelectedURL(of content: any ReaderContentProtocol) -> Bool {
            matches(content)
        }

        func resolveForMutation(in realm: Realm) -> (any ReaderContentProtocol)? { resolve(in: realm) }

        func matchesStoredIdentity(of content: any ReaderContentProtocol) -> Bool { matches(content) }

        func resolve(in realm: Realm) -> (any ReaderContentProtocol)? {
            guard let content = realm.object(ofType: contentType, forPrimaryKey: contentKey)
                    as? any ReaderContentProtocol, matches(content) else { return nil }
            return content
        }

        @RealmBackgroundActor
        public func resolveOnBackgroundActor() async throws -> (any ReaderContentProtocol)? {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: realmConfiguration, storageAdmission: storageAdmission
            )
            await realm.asyncRefresh()
            try Task.checkCancellation()
            try validateStorage()
            return resolve(in: realm)
        }

        @MainActor
        public func resolveOnMainActor() async throws -> (any ReaderContentProtocol)? {
            try await RealmBackgroundActor.shared.prepareStorage(for: realmConfiguration, storageAdmission: storageAdmission)
            try validateStorage()
            let realm = try await Realm.open(configuration: realmConfiguration)
            await realm.asyncRefresh()
            try Task.checkCancellation()
            try validateStorage()
            return resolve(in: realm)
        }

        @RealmBackgroundActor
        func mutateIfAdmitted(
            admittingMutation: @escaping @Sendable () -> Bool,
            commitIfCurrent: ReaderContentCommitIfCurrent? = nil,
            beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
            mutate: @RealmBackgroundActor (any ReaderContentProtocol) -> Bool
        ) async throws {
            try Task.checkCancellation()
            guard admittingMutation() else { throw CancellationError() }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: realmConfiguration, storageAdmission: storageAdmission
            )
            try await beforeWrite?()
            try await realm.asyncWritePreservingOwnership {
                try Task.checkCancellation()
                guard admittingMutation() else { throw CancellationError() }
                try validateStorage()
                guard let content = resolve(in: realm), !content.isDeleted else { return }
                if mutate(content) { content.refreshChangeMetadata(explicitlyModified: true) }
                try Task.checkCancellation()
                guard admittingMutation(), resolve(in: realm) != nil else { throw CancellationError() }
                try validateStorage()
                if let commitIfCurrent {
                    try ReaderContentLoader.commitMutation(in: realm, ifCurrent: commitIfCurrent)
                }
            }
        }
    }

    // Routing is read synchronously by both UI and Realm actors. Only copied
    // configurations escape this lock; no Realm access or callback runs under it.
    private final class RealmConfigurationStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var configuration: Realm.Configuration = .defaultConfiguration

        var value: Realm.Configuration {
            get { lock.withLock { configuration } }
            set { lock.withLock { configuration = newValue } }
        }
    }

    private static let bookmarkConfigurationStorage = RealmConfigurationStorage()
    private static let historyConfigurationStorage = RealmConfigurationStorage()
    private static let feedEntryConfigurationStorage = RealmConfigurationStorage()

    public static var bookmarkRealmConfiguration: Realm.Configuration {
        get { bookmarkConfigurationStorage.value }
        set { bookmarkConfigurationStorage.value = newValue }
    }
    public static var historyRealmConfiguration: Realm.Configuration {
        get { historyConfigurationStorage.value }
        set { historyConfigurationStorage.value = newValue }
    }
    public static var feedEntryRealmConfiguration: Realm.Configuration {
        get { feedEntryConfigurationStorage.value }
        set { feedEntryConfigurationStorage.value = newValue }
    }
    nonisolated(unsafe) public static var transcriptRealmConfiguration: Realm.Configuration = .defaultConfiguration
    nonisolated(unsafe) private static var additionalContentProviderRevision: UInt64 = 0
    nonisolated(unsafe) public static var additionalContentProviders: [ReaderContentAdditionalProvider] = [] {
        didSet { additionalContentProviderRevision &+= 1 }
    }

    public static func registerAdditionalContentProvider(_ provider: ReaderContentAdditionalProvider) {
        additionalContentProviders.removeAll { $0.id == provider.id }
        additionalContentProviders.append(provider)
    }

    @RealmBackgroundActor
    static func invalidateCachedContent(for url: URL) {
        // Only overlapping discovery is coalesced; there is no completed-result
        // cache to invalidate after a committed content change.
    }

    /// The storage selected when a snippet edit began. A delayed save must not
    /// follow mutable global configurations into another account's Realm.
    /// Immutable capture passed to RealmBackgroundActor: configurations are value
    /// snapshots, admissions are synchronized, and the optional row is frozen.
    public struct SnippetStorage: @unchecked Sendable {
        public let bookmarkConfiguration: Realm.Configuration
        public let historyConfiguration: Realm.Configuration

        fileprivate let bookmarkAdmission: RealmStorageAdmission
        fileprivate let historyAdmission: RealmStorageAdmission
        // Frozen rows are immutable and cross-actor safe. Recreate a one-use
        // reference per operation so repeated saves retain the original ObjKey,
        // even if a row is deleted and recreated with the same primary key.
        private let target: CapturedSnippetTarget?

        private final class CapturedSnippetTarget: @unchecked Sendable {
            let row: any ReaderContentProtocol
            init(_ content: any ReaderContentProtocol) { row = content.freeze() }
        }

        fileprivate func containsCapturedTarget(in realm: Realm) -> Bool {
            guard let target else { return true } // Legacy multi-store API.
            return Self.containsFrozenTarget(target.row, in: realm)
        }

        // Open the existential only within this generic call. The invariant
        // ThreadSafeReference<T> stays local; no erased reference escapes.
        private static func containsFrozenTarget<T: ReaderContentProtocol>(
            _ target: T, in realm: Realm
        ) -> Bool {
            guard let row = realm.resolve(ThreadSafeReference(to: target)),
                  !row.isInvalidated, !row.isDeleted,
                  row.url.matchesReaderURL(target.url) else { return false }
            return true
        }

        @MainActor
        private init(
            bookmarkConfiguration: Realm.Configuration,
            historyConfiguration: Realm.Configuration,
            target: (any ReaderContentProtocol)? = nil
        ) {
            self.target = target.map(CapturedSnippetTarget.init)
            self.bookmarkConfiguration = bookmarkConfiguration
            self.historyConfiguration = historyConfiguration
            bookmarkAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: bookmarkConfiguration)
            historyAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: historyConfiguration)
        }

        /// The app stores both snippet representations in the selected
        /// content's Reader Realm. Its owning Realm outranks mutable globals.
        @MainActor
        public init?(content: any ReaderContentProtocol) {
            guard !content.isInvalidated, !content.isDeleted,
                  let configuration = content.realm?.configuration else { return nil }
            self.init(bookmarkConfiguration: configuration, historyConfiguration: configuration, target: content)
        }

        @MainActor
        public func containsOriginalTarget(for content: any ReaderContentProtocol) -> Bool {
            guard !content.isInvalidated, !content.isDeleted, let realm = content.realm else { return false }
            return containsCapturedTarget(in: realm)
        }

        public func validateStorage() throws {
            guard bookmarkAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: bookmarkConfiguration)
            }), historyAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: historyConfiguration)
            }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        }

        /// Legacy storage can span two Realms. Its edits are atomic per Realm,
        /// not across stores; a later failure may follow an earlier commit.
        @MainActor
        public static func capture() -> Self {
            Self(
                bookmarkConfiguration: ReaderContentLoader.bookmarkRealmConfiguration,
                historyConfiguration: ReaderContentLoader.historyRealmConfiguration
            )
        }
    }

    public static func resetTransientCachesForTesting() async {
        await MainActor.run {
            inFlightGetContentTasks.removeAll()
        }
        await { @RealmBackgroundActor in
            inFlightLoadAllTasks.removeAll()
            loadAllDiscoveryGateForTesting = nil
            contentWriteGateForTesting = nil
        }()
    }

    @MainActor
    public static func hasLocallyRetrievableHTML(
        for content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager
    ) async throws -> Bool {
        let html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
        return html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
 
    public static func extractHTML(from content: any ReaderContentProtocol) -> String? {
        if let html = content.html {
            return html
        }
        guard let contentData = content.content else { return nil }
        let nsData = contentData as NSData
        guard let decompressed = try? nsData.decompressed(using: .lzfse) as Data else { return nil }
        return String(decoding: decompressed, as: UTF8.self)
    }

    public static var unsavedHome: (any ReaderContentProtocol) {
//        return try await Self.load(url: URL(string: "about:blank")!, persist: false)!
        let historyRecord = HistoryRecord()
        historyRecord.url = URL(string: "about:blank")!
        historyRecord.updateCompoundKey()
        return historyRecord
    }
    
    @MainActor
    public static var home: (any ReaderContentProtocol) {
        get async throws {
            return try await Self.load(url: URL(string: "about:blank")!, persist: true)!
        }
    }
    
    public static func getContentURL(fromLoaderURL pageURL: URL) -> URL? {
        if let key = pageURL.snippetKey, let snippet = snippetURL(key: key) { return snippet }
        guard pageURL.isReaderURLLoaderURL else { return nil }
        return pageURL.removingFragmentIfNeeded().readerContentURL
    }

    // The fragment on a loader document belongs to same-page navigation.
    // Look up the stable URL encoded in its query; never create a new stored
    // content record for each anchor in the rendered document.
    static func backingContentURL(fromLoaderURL pageURL: URL) -> URL? {
        getContentURL(fromLoaderURL: pageURL.removingFragmentIfNeeded())
    }

    @RealmBackgroundActor
    private static func resolveContentReferences(
        _ references: [ContentReference]
    ) async throws -> [(any ReaderContentProtocol)] {
        var destinations = [(reference: ContentReference, realm: Realm)]()
        destinations.reserveCapacity(references.count)
        for reference in references {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: reference.realmConfiguration, storageAdmission: reference.storageAdmission)
            await realm.asyncRefresh()
            destinations.append((reference, realm))
        }
        try Task.checkCancellation()
        // Resolve objects only after the last suspension. A later store opening
        // must not invalidate a managed candidate collected from an earlier one.
        for destination in destinations { try destination.reference.validateStorage() }
        return destinations.compactMap { destination in
            guard let content = destination.reference.resolve(in: destination.realm),
                !content.isDeleted else { return nil }
            return content
        }
    }
    
    @RealmBackgroundActor
    public static func loadAll(url: URL, skipContentFiles: Bool = false, skipFeedEntries: Bool = false) async throws -> [(any ReaderContentProtocol)] {
        try await loadAll(
            url: url,
            skipContentFiles: skipContentFiles,
            skipFeedEntries: skipFeedEntries,
            storage: DiscoveryStorage()
        )
    }

    @RealmBackgroundActor
    private static func loadAll(
        url: URL,
        skipContentFiles: Bool,
        skipFeedEntries: Bool,
        storage: DiscoveryStorage
    ) async throws -> [(any ReaderContentProtocol)] {
        let references = try await discoverContentReferences(
            url: url,
            skipContentFiles: skipContentFiles,
            skipFeedEntries: skipFeedEntries,
            storage: storage
        )
        return try await resolveContentReferences(references)
    }

    @RealmBackgroundActor
    private static func discoverContentReferences(
        url: URL,
        skipContentFiles: Bool,
        skipFeedEntries: Bool,
        storage: DiscoveryStorage
    ) async throws -> [ContentReference] {
        let taskKey = LoadAllTaskKey(
            url: url.absoluteString,
            skipContentFiles: skipContentFiles,
            skipFeedEntries: skipFeedEntries,
            storage: storage.identity
        )
        // Coalesce only overlapping queries. Completed membership can become
        // obsolete as soon as load() creates a history record or a bookmark is
        // added, so authoritative reads and writes must query it again.
        if let existingTask = inFlightLoadAllTasks[taskKey] {
            return try await existingTask.value
        }

        let task = Task<[ContentReference], Error> { @RealmBackgroundActor in
            try Task.checkCancellation()
            await loadAllDiscoveryGateForTesting?()

            return try await discoverCapturedContent(
                url: url, skipContentFiles: skipContentFiles,
                skipFeedEntries: skipFeedEntries, storage: storage,
                capture: { storage.reference(for: $0) }
            )
        }

        inFlightLoadAllTasks[taskKey] = task
        defer { inFlightLoadAllTasks[taskKey] = nil }
        return try await task.value
    }

    /// Capture on the discovery actor immediately after matching, before another
    /// suspension can retarget or replace a selected row. Legacy references keep
    /// their existing semantics; only scoped Reader writes retain row lifetimes.
    @RealmBackgroundActor
    private static func discoverCapturedContent<Value>(
        url: URL, skipContentFiles: Bool, skipFeedEntries: Bool,
        storage: DiscoveryStorage,
        capture: (any ReaderContentProtocol) -> Value?
    ) async throws -> [Value] {
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.historyConfiguration, storageAdmission: storage.historyAdmission
        )
        let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.bookmarkConfiguration, storageAdmission: storage.bookmarkAdmission
        )
        await historyRealm.asyncRefresh()
        await bookmarkRealm.asyncRefresh()

        let feedRealm: Realm?
        if skipFeedEntries {
            feedRealm = nil
        } else {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: storage.feedConfiguration, storageAdmission: storage.feedAdmission)
            await realm.asyncRefresh()
            feedRealm = realm
        }
        try Task.checkCancellation()

        try storage.validate(includeFeed: !skipFeedEntries)
        var contentFile: ContentFile?
        if !skipContentFiles {
            contentFile = historyRealm.objects(ContentFile.self)
                .filter(NSPredicate(format: "isDeleted == false AND url == %@", url.absoluteString as CVarArg))
                .sorted(byKeyPath: "createdAt", ascending: false)
                .first
        }
        let history = HistoryRecord.getOpenedRecord(forURL: url, in: historyRealm)
        let bookmark = Bookmark.get(forURL: url, realm: bookmarkRealm)

        var feed: FeedEntry?
        if let feedRealm {
            let feeds = feedRealm.objects(FeedEntry.self)
                .where { !$0.isDeleted }
                .sorted(by: \.createdAt, ascending: false)

            if url.scheme == "https" {
                feed = feeds.filter(NSPredicate(format: "url == %@ OR url == %@", url.absoluteString as CVarArg, url.settingScheme("http").absoluteString as CVarArg)).first
            } else if !url.isReaderFileURL {
                feed = feeds.filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg)).first
            }
        }

        let candidates: [any ReaderContentProtocol] = [contentFile, bookmark, history, feed].compactMap { $0 }
        var captured = candidates.compactMap(capture)
        // Capture built-in witnesses before any provider suspension.
        for provider in storage.providers {
            try Task.checkCancellation()
            for reference in try await provider.load(url) {
                guard let content = try await reference.resolveOnBackgroundActor(),
                      !content.isDeleted else { continue }
                if let value = capture(content) { captured.append(value) }
            }
            try storage.validate(includeFeed: !skipFeedEntries)
        }
        return captured
    }

    /// Capture when presenting a destructive confirmation, or before a file
    /// deletion's first suspension. Carry this value through follow-up cleanup.
    /// The source history Realm can have a narrower schema than the selected inventory.
    /// Preserve both configurations; an omitted owner class is not proof of absence.
    public struct TranscriptDeletionContext: @unchecked Sendable {
        struct Store: @unchecked Sendable {
            let configuration: Realm.Configuration
            let admission: RealmStorageAdmission

            init(configuration: Realm.Configuration) {
                self.configuration = configuration
                admission = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
            }

            func validate() throws {
                guard admission.matchesCurrentStorageIdentity({
                    RealmBackgroundActor.shared.realmCacheKey(for: configuration)
                }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
            }

            @RealmBackgroundActor
            func open() async throws -> Realm {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: configuration, storageAdmission: admission
                )
                await realm.asyncRefresh()
                try Task.checkCancellation()
                try validate()
                return realm
            }
        }

        let sourceHistoryStore: Store
        let historyStore: Store
        let feedStore: Store
        let transcriptStore: Store
        let providers: [ReaderContentAdditionalProvider]
        private let selectedHistory: String
        private let selectedFeed: String
        private let selectedTranscript: String
        private let sharesHistoryStorage: Bool

        public init(
            historyRealmConfiguration: Realm.Configuration,
            ownerHistoryRealmConfiguration: Realm.Configuration
        ) {
            sourceHistoryStore = Store(configuration: historyRealmConfiguration)
            historyStore = Store(configuration: ownerHistoryRealmConfiguration)
            feedStore = Store(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
            transcriptStore = Store(configuration: ReaderContentLoader.transcriptRealmConfiguration)
            providers = ReaderContentLoader.additionalContentProviders
            selectedHistory = Self.selectionKey(ReaderContentLoader.historyRealmConfiguration)
            selectedFeed = Self.selectionKey(feedStore.configuration)
            selectedTranscript = Self.selectionKey(transcriptStore.configuration)
            if let identifier = historyRealmConfiguration.inMemoryIdentifier {
                sharesHistoryStorage = identifier == ownerHistoryRealmConfiguration.inMemoryIdentifier
            } else {
                sharesHistoryStorage = ownerHistoryRealmConfiguration.inMemoryIdentifier == nil
                    && historyRealmConfiguration.fileURL != nil
                    && historyRealmConfiguration.fileURL?.standardizedFileURL
                        == ownerHistoryRealmConfiguration.fileURL?.standardizedFileURL
            }
        }

        private static func selectionKey(_ configuration: Realm.Configuration) -> String {
            // A pending store may be created only by its captured admission.
            // That changes its resource ID, not the selected configuration.
            RealmBackgroundActor.shared.realmCacheKey(
                for: configuration, includingFileResourceIdentifier: false
            )
        }

        func validate() throws {
            try Task.checkCancellation()
            guard sharesHistoryStorage,
                  selectedHistory == Self.selectionKey(ReaderContentLoader.historyRealmConfiguration),
                  selectedFeed == Self.selectionKey(ReaderContentLoader.feedEntryRealmConfiguration),
                  selectedTranscript == Self.selectionKey(ReaderContentLoader.transcriptRealmConfiguration)
            else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
            try sourceHistoryStore.validate()
            try historyStore.validate()
            try feedStore.validate()
            try transcriptStore.validate()
        }
    }

    // Task-scoped native fixture observation of the real publication boundary.
    // Neither hook runs while the account publication lock is held.
    enum TranscriptDeletionObservation {
        @TaskLocal static var beforeCommit: (@RealmBackgroundActor @Sendable () throws -> Void)? = nil
        @TaskLocal static var didCommit: (@RealmBackgroundActor @Sendable () -> Void)? = nil
    }

    struct TranscriptDeletionAccount {
        let access: AccountSessionAccess
        let session: AccountSessionSnapshot

        func validate() throws {
            try Task.checkCancellation()
            guard session.identity != .transitioning, access.snapshot == session else {
                throw CancellationError()
            }
        }

        @RealmBackgroundActor
        func commit(_ realm: Realm) throws {
            try Task.checkCancellation()
            // The actual durable boundary must be inside the account fence.
            // No account snapshot, provider or async work runs under this lock.
            guard try access.publish(ifCurrent: session, {
                try realm.commitWrite()
            }) else { throw CancellationError() }
            TranscriptDeletionObservation.didCommit?()
        }
    }

    /// Earlier URLs have settled, including decisions to retain a live owner's
    /// transcript. Retry only `remainingURLs` with the original captured context.
    public struct TranscriptDeletionBatchError: Error, @unchecked Sendable {
        public let completedURLs: [URL]
        public let remainingURLs: [URL]
        public let underlyingError: any Error
    }

    /// Clean up only the stores and provider inventory captured by the original
    /// confirmation. A primary Settings deletion may already be committed; a
    /// failure here is a separate, retryable cleanup result.
    @RealmBackgroundActor
    public static func softDeleteTranscriptsIfNoRemainingOwners(
        contentURLs: [URL],
        context: TranscriptDeletionContext,
        accountSessionAccess: AccountSessionAccess,
        accountSession: AccountSessionSnapshot,
        explicitlyModified: Bool = true
    ) async throws {
        let account = TranscriptDeletionAccount(access: accountSessionAccess, session: accountSession)
        try context.validate()
        try account.validate()
        let urls = Set(contentURLs.map { MediaTranscript.canonicalContentURL(from: $0) })
            .sorted { $0.absoluteString < $1.absoluteString }
        for (index, contentURL) in urls.enumerated() {
            do {
                try await softDeleteTranscriptsIfNoRemainingOwners(
                    contentURL: contentURL,
                    context: context,
                    explicitlyModified: explicitlyModified,
                    account: account
                )
            } catch {
                guard index > 0 else { throw error }
                throw TranscriptDeletionBatchError(
                    completedURLs: Array(urls[..<index]),
                    remainingURLs: Array(urls[index...]),
                    underlyingError: error
                )
            }
        }
    }

    /// The file and index have already settled on their captured owner. Cleanup
    /// must not switch to newly selected stores after those awaits.
    @RealmBackgroundActor
    static func softDeleteTranscriptsIfNoRemainingOwners(
        contentURL: URL,
        context: TranscriptDeletionContext,
        explicitlyModified: Bool = true,
        account: TranscriptDeletionAccount? = nil
    ) async throws {
        func validate() throws {
            try context.validate()
            try account?.validate()
        }
        try validate()
        let canonicalContentURL = MediaTranscript.canonicalContentURL(from: contentURL)
        let ownerURLs = relatedURLStrings(for: canonicalContentURL)
        let ownerRealm = try await context.historyStore.open()
        try validate()
        let feedRealm = try await context.feedStore.open()
        try validate()
        func canQuery(_ type: RealmSwift.Object.Type, in realm: Realm) -> Bool {
            realm.schema.objectSchema.contains { $0.className == type.className() }
        }
        // The native actor/path cache may already hold a narrower schema view.
        // Retain derived data until a complete owner inventory can be queried.
        guard [Bookmark.self, HistoryRecord.self, ContentFile.self].allSatisfy({
            canQuery($0, in: ownerRealm)
        }), canQuery(FeedEntry.self, in: feedRealm) else { return }

        func hasBuiltInOwner() -> Bool {
            hasLiveOwner(in: ownerRealm, type: Bookmark.self, ownerURLs: ownerURLs)
                || hasLiveOwner(in: ownerRealm, type: HistoryRecord.self, ownerURLs: ownerURLs)
                || hasLiveOwner(in: ownerRealm, type: ContentFile.self, ownerURLs: ownerURLs)
                || hasLiveOwner(in: feedRealm, type: FeedEntry.self, ownerURLs: ownerURLs)
        }
        guard !hasBuiltInOwner() else { return }

        var providerOwners: [(reference: ContentReference, realm: Realm, store: TranscriptDeletionContext.Store)] = []
        for provider in context.providers {
            let references = try await provider.load(canonicalContentURL)
            try validate()
            for reference in references {
                let store = TranscriptDeletionContext.Store(configuration: reference.realmConfiguration)
                let providerRealm = try await store.open()
                try validate()
                guard canQuery(reference.contentType, in: providerRealm) else { return }
                let content = try await reference.resolveOnBackgroundActor()
                try validate()
                try store.validate()
                if let content, !content.isInvalidated, !content.isDeleted { return }
                // A missing reference can acquire a live owner while the
                // transcript write queues. Retain its store/key for that check.
                providerOwners.append((reference, providerRealm, store))
            }
        }

        let realm = try await context.transcriptStore.open()
        try validate()
        guard canQuery(MediaTranscript.self, in: realm) else { return }
        try await realm.asyncWritePreservingOwnership {
            try validate()
            for owner in providerOwners { try owner.store.validate() }

            // Refresh known owner stores after queued write admission. Do not
            // treat another transaction's tentative deletions as committed
            // absence. A later deletion retry can perform this cleanup.
            var refreshedRealms: [Realm] = []
            for owner in [ownerRealm, feedRealm] + providerOwners.map(\.realm) {
                guard owner != realm, !refreshedRealms.contains(owner) else { continue }
                guard !owner.isInWriteTransaction else { return }
                owner.refresh()
                refreshedRealms.append(owner)
            }
            try validate()
            for owner in providerOwners { try owner.store.validate() }
            guard !hasBuiltInOwner() else { return }
            for owner in providerOwners {
                if let content = owner.realm.object(
                    ofType: owner.reference.contentType, forPrimaryKey: owner.reference.contentKey
                ) as? any ReaderContentProtocol, !content.isInvalidated, !content.isDeleted {
                    return
                }
            }

            // Query after admission so a tombstone retry is a metadata no-op.
            let transcripts = realm.objects(MediaTranscript.self)
                .where { $0.isDeleted == false }
                .filter(NSPredicate(format: "contentURL == %@", canonicalContentURL.absoluteString))
            guard !transcripts.isEmpty else { return }
            let timestamp = Date()
            for transcript in Array(transcripts) {
                guard !transcript.isInvalidated, !transcript.isDeleted else { continue }
                transcript.isDeleted = true
                transcript.refreshChangeMetadata(explicitlyModified: explicitlyModified, at: timestamp)
            }
            for owner in providerOwners { try owner.store.validate() }
            try validate()
            // The owned writer recognizes this synchronous commit and will not
            // settle or roll back a notification callback's successor write.
            // File deletion callers keep their existing async settlement.
            if let account {
                try TranscriptDeletionObservation.beforeCommit?()
                for owner in providerOwners { try owner.store.validate() }
                try context.validate()
                try account.commit(realm)
            }
        }
    }

    @RealmBackgroundActor
    public static func softDeleteTranscriptsIfNoRemainingOwners(
        contentURLs: [URL],
        explicitlyModified: Bool = true
    ) async throws {
        for contentURL in Set(contentURLs) {
            try await softDeleteTranscriptsIfNoRemainingOwners(
                contentURL: contentURL,
                explicitlyModified: explicitlyModified
            )
        }
    }

    @RealmBackgroundActor
    public static func softDeleteTranscriptsIfNoRemainingOwners(
        contentURL: URL,
        explicitlyModified: Bool = true
    ) async throws {
        let canonicalContentURL = MediaTranscript.canonicalContentURL(from: contentURL)
        let ownerURLs = relatedURLStrings(for: canonicalContentURL)
        let ownerRealm = try await Realm(configuration: historyRealmConfiguration, actor: RealmBackgroundActor.shared)
        await ownerRealm.asyncRefresh()
        let feedRealm = try await Realm(configuration: feedEntryRealmConfiguration, actor: RealmBackgroundActor.shared)
        await feedRealm.asyncRefresh()
        guard !hasLiveOwner(in: ownerRealm, type: Bookmark.self, ownerURLs: ownerURLs),
              !hasLiveOwner(in: ownerRealm, type: HistoryRecord.self, ownerURLs: ownerURLs),
              !hasLiveOwner(in: ownerRealm, type: ContentFile.self, ownerURLs: ownerURLs),
              !hasLiveOwner(in: feedRealm, type: FeedEntry.self, ownerURLs: ownerURLs)
        else { return }
        let hasLiveAdditionalOwner = try await hasLiveAdditionalContentOwner(contentURL: canonicalContentURL)
        guard !hasLiveAdditionalOwner else { return }

        let realm = try await Realm(configuration: transcriptRealmConfiguration, actor: RealmBackgroundActor.shared)
        await realm.asyncRefresh()
        let transcripts = realm.objects(MediaTranscript.self)
            .where { $0.isDeleted == false }
            .filter(NSPredicate(format: "contentURL == %@", canonicalContentURL.absoluteString))
        guard !transcripts.isEmpty else { return }
        try await realm.asyncWrite {
            for transcript in transcripts {
                transcript.isDeleted = true
                transcript.refreshChangeMetadata(explicitlyModified: explicitlyModified)
            }
        }
    }

    private static func relatedURLStrings(for url: URL) -> [String] {
        var urls = [url.absoluteString]
        if url.scheme == "https" {
            urls.append(url.settingScheme("http").absoluteString)
        } else if url.scheme == "http" {
            urls.append(url.settingScheme("https").absoluteString)
        }
        return Array(Set(urls))
    }

    private static func hasLiveOwner<T: Object & ReaderContentProtocol>(
        in realm: Realm,
        type: T.Type,
        ownerURLs: [String]
    ) -> Bool {
        if let objectTypes = realm.configuration.objectTypes,
           !objectTypes.contains(where: { $0 == type }) {
            return false
        }
        return realm.objects(type)
            .where { $0.isDeleted == false }
            .filter(NSPredicate(format: "url IN %@", ownerURLs))
            .isEmpty == false
    }

    @RealmBackgroundActor
    private static func hasLiveAdditionalContentOwner(contentURL: URL) async throws -> Bool {
        for provider in additionalContentProviders {
            try Task.checkCancellation()
            for reference in try await provider.load(contentURL) {
                guard let content = try await reference.resolveOnBackgroundActor() else { continue }
                if !content.isDeleted {
                    return true
                }
            }
        }
        return false
    }

    @RealmBackgroundActor
    private static func storedContentReference(
        for url: URL,
        storage: DiscoveryStorage
    ) async throws -> ReaderContentLoader.ContentReference? {
        try Task.checkCancellation()
        guard !url.isInternalReaderLoadingURL else {
            return nil
        }
        guard url.absoluteString != "about:blank" else {
            return nil
        }

        let references = try await discoverContentReferences(
            url: url, skipContentFiles: false, skipFeedEntries: false, storage: storage
        )
        return try await selectStoredContentReference(references)
    }

    @RealmBackgroundActor
    private static func resolveContentCandidates(
        _ references: [ContentReference],
        resolveReference: @RealmBackgroundActor (ContentReference) async throws -> (any ReaderContentProtocol)? = {
            try await $0.resolveOnBackgroundActor()
        }
    ) async throws -> [(reference: ContentReference, content: any ReaderContentProtocol)] {
        var candidates = [(reference: ContentReference, content: any ReaderContentProtocol)]()
        for reference in references {
            if let content = try await resolveReference(reference) { candidates.append((reference, content)) }
        }
        try Task.checkCancellation()
        for reference in references { try reference.validateStorage() }
        return candidates.filter { !$0.content.isInvalidated && !$0.content.isDeleted
            && $0.reference.matchesSelectedURL(of: $0.content) }
    }

    @RealmBackgroundActor
    internal static func selectStoredContentReference(
        _ references: [ContentReference],
        resolveReference: @RealmBackgroundActor (ContentReference) async throws -> (any ReaderContentProtocol)? = {
            try await $0.resolveOnBackgroundActor()
        }
    ) async throws -> ContentReference? {
        let candidates = try await resolveContentCandidates(references, resolveReference: resolveReference)
        return candidates.max {
            (($0.content as? HistoryRecord)?.lastVisitedAt ?? $0.content.createdAt)
                < (($1.content as? HistoryRecord)?.lastVisitedAt ?? $1.content.createdAt)
        }?.reference
    }

    @MainActor
    public static func lookupStoredContent(url: URL) async throws -> (any ReaderContentProtocol)? {
        try await lookupStoredContent(url: url, storage: DiscoveryStorage())
    }

    @MainActor
    private static func lookupStoredContent(
        url: URL,
        storage: DiscoveryStorage
    ) async throws -> (any ReaderContentProtocol)? {
        let backingURL = backingContentURL(fromLoaderURL: url)
        guard !url.isReaderURLLoaderURL || backingURL != nil else { return nil }
        let resolvedURL = backingURL ?? url
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            try await storedContentReference(for: resolvedURL, storage: storage)
        }()
        try Task.checkCancellation()
        let result = try await contentRef?.resolveOnMainActor()
        guard let result, !result.isDeleted else { return nil }
        return result
    }

    @MainActor
    public static func recordHistoryVisit(
        for content: any ReaderContentProtocol,
        source: String = "ReaderContentLoader.recordHistoryVisit"
    ) async throws {
        let pageURL = content.url
        let storage = DiscoveryStorage()
        if let contentReference = ContentReference(content: content) {
            let didRecordVisit = try await { @RealmBackgroundActor in
                guard let resolvedContent =
                    try await contentReference.resolveOnBackgroundActor() else {
                    return false
                }
                try contentReference.validateStorage()
                _ = try await resolvedContent.addHistoryRecord(
                    realmConfiguration: storage.historyConfiguration,
                    pageURL: pageURL,
                    bookmarkRealmConfiguration: storage.bookmarkConfiguration,
                    historyStorageAdmission: storage.historyAdmission,
                    bookmarkStorageAdmission: storage.bookmarkAdmission
                )
                return true
            }()
            if didRecordVisit {
                return
            }
        }

        _ = try await load(
            url: pageURL,
            persist: true,
            countsAsHistoryVisit: true,
            source: source,
            storage: storage
        )
    }

    @MainActor
    public static func getContent(
        forURL pageURL: URL,
        countsAsHistoryVisit: Bool = false,
        source: String = "ReaderContentLoader.getContent"
    ) async throws -> (any ReaderContentProtocol)? {
        let backingURL = backingContentURL(fromLoaderURL: pageURL)
        guard !pageURL.isReaderURLLoaderURL || backingURL != nil else { return nil }
        let resolvedURL = backingURL ?? pageURL
        let storage = DiscoveryStorage()
        getContentObservationForTesting?(.capturedStorage)
        let taskKey = GetContentTaskKey(
            url: resolvedURL.absoluteString,
            countsAsHistoryVisit: countsAsHistoryVisit,
            storage: storage.identity
        )
        if let existingTask = inFlightGetContentTasks[taskKey] {
            getContentObservationForTesting?(.joinedTask)
            return try await existingTask.value
        }

        let task = Task<(any ReaderContentProtocol)?, Error> { @MainActor in
            if let contentURL = backingURL {
                let content = try await ReaderContentLoader.load(
                    url: contentURL,
                    persist: true,
                    countsAsHistoryVisit: countsAsHistoryVisit,
                    source: "\(source).loaderRedirect",
                    storage: storage
                )
                try Task.checkCancellation()
                return content
            }
            if let content = try await ReaderContentLoader.load(
                url: pageURL,
                persist: !pageURL.isNativeReaderView,
                countsAsHistoryVisit: countsAsHistoryVisit,
                source: "\(source).directLoad",
                storage: storage
            ) {
                try Task.checkCancellation()
                return content
            }
            try Task.checkCancellation()
            return nil
        }

        inFlightGetContentTasks[taskKey] = task
        defer { inFlightGetContentTasks[taskKey] = nil }
        return try await task.value
    }

    /// Propagate prepared Reader HTML only while its originating selection remains
    /// live. Discovery and queued Realm writes can each suspend; the lifetime
    /// fence must be checked by the final, storage-admitted transaction.
    @RealmBackgroundActor
    public static func propagateReaderModeDefaults(
        for url: URL,
        excluding primaryReference: ContentReference?,
        readabilityHTML: String,
        resolvedTitle: String?,
        account: (access: AccountSessionAccess, snapshot: AccountSessionSnapshot)? = nil,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws {
        _ = try await propagateReaderModeDefaults(
            for: url, context: ReaderModePropagationContext(primaryReference: primaryReference),
            readabilityHTML: readabilityHTML, resolvedTitle: resolvedTitle,
            account: account, permitsCommit: permitsCommit
        )
    }

    /// Synchronously settle an admitted write under its original account fence.
    /// A later callback failure cannot erase a commit that already became durable.
    public static func commitMutation(
        in realm: Realm,
        ifCurrent: ReaderContentCommitIfCurrent,
        validatingBeforeCommit: @escaping @Sendable () throws -> Void = {}
    ) throws {
        var didCommit = false
        do {
            _ = try ifCurrent {
                guard !didCommit else { return }
                try Task.checkCancellation()
                try validatingBeforeCommit()
                try realm.commitWrite()
                didCommit = true
            }
        } catch {
            if !didCommit { throw error }
        }
        guard didCommit else { throw CancellationError() }
    }

    @RealmBackgroundActor
    public static func updateContent(
        url: URL,
        skipContentFiles: Bool = false,
        skipFeedEntries: Bool = false,
        account: (access: AccountSessionAccess, snapshot: AccountSessionSnapshot)? = nil,
        permitsCommit: (@Sendable () -> Bool)? = nil,
        admittingMutation: @escaping @Sendable () -> Bool = { true },
        commitIfCurrent: ReaderContentCommitIfCurrent? = nil,
        mutate: @RealmBackgroundActor (Object & ReaderContentProtocol) -> Bool
    ) async throws {
        try await updateContent(
            url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries,
            account: account, permitsCommit: permitsCommit,
            admittingMutation: admittingMutation, commitIfCurrent: commitIfCurrent
        ) { record, _ in mutate(record) }
    }

    /// Preserve one batch timestamp for related model and journal mutations.
    @RealmBackgroundActor
    public static func updateContent(
        url: URL,
        skipContentFiles: Bool = false,
        skipFeedEntries: Bool = false,
        account: (access: AccountSessionAccess, snapshot: AccountSessionSnapshot)? = nil,
        permitsCommit: (@Sendable () -> Bool)? = nil,
        admittingMutation: @escaping @Sendable () -> Bool = { true },
        commitIfCurrent: ReaderContentCommitIfCurrent? = nil,
        mutate: @RealmBackgroundActor (Object & ReaderContentProtocol, Date) -> Bool
    ) async throws {
        func validate() throws {
            try Task.checkCancellation()
            guard admittingMutation(), permitsCommit?() != false else { throw CancellationError() }
        }
        try validate()
        let storage = DiscoveryStorage()
        let references = try await discoverContentReferences(
            url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries, storage: storage
        )
        let timestamp = Date()
        for reference in references {
            try validate()
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: reference.realmConfiguration, storageAdmission: reference.storageAdmission
            )
            try await realm.asyncWritePreservingOwnership {
                try validate()
                try reference.validateStorage()
                guard let object = reference.resolve(in: realm) as? (Object & ReaderContentProtocol),
                      !object.isDeleted else { return }
                if mutate(object, timestamp) {
                    object.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
                try validate()
                try reference.validateStorage()
                guard let current = reference.resolve(in: realm), !current.isDeleted else { throw CancellationError() }
                // Arbitrary permission callbacks finish before Session's nonrecursive lock.
                if let commitIfCurrent {
                    try commitMutation(in: realm, ifCurrent: commitIfCurrent)
                } else if let account {
                    try ReaderContentAccountCommit.commit(in: realm, account: account)
                }
            }
        }
    }

    /// Inspect only an already-stored representation for a readability callback.
    /// Navigation's persistence-producing shared loader never runs from this path.
    @MainActor
    public static func readabilityContent(
        forURL url: URL,
        admittingMutation: @escaping @Sendable () -> Bool
    ) async throws -> (any ReaderContentProtocol)? {
        try Task.checkCancellation()
        guard admittingMutation() else { throw CancellationError() }
        let storage = DiscoveryStorage()
        let reference = try await { @RealmBackgroundActor in
            try await storedContentReference(for: url, storage: storage)
        }()
        let content = try await reference?.resolveOnMainActor()
        try Task.checkCancellation()
        guard admittingMutation() else { throw CancellationError() }
        return content
    }

    @MainActor
    public static func load(
        url: URL,
        persist: Bool = true,
        countsAsHistoryVisit: Bool = false,
        source: String = "ReaderContentLoader.load"
    ) async throws -> (any ReaderContentProtocol)? {
        try await load(
            url: url,
            persist: persist,
            countsAsHistoryVisit: countsAsHistoryVisit,
            source: source,
            storage: DiscoveryStorage()
        )
    }

    @MainActor
    private static func load(
        url: URL,
        persist: Bool,
        countsAsHistoryVisit: Bool,
        source: String,
        storage: DiscoveryStorage
    ) async throws -> (any ReaderContentProtocol)? {
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            try Task.checkCancellation()
            
            if url.isInternalReaderLoadingURL {
                // Don't persist about:load
                // TODO: Perhaps return an empty history record to avoid catching the wrong content in this interim, though.
                return nil
            } else if url.absoluteString == "about:blank" { //}&& !persist {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                historyRecord.isDemoted = true
                historyRecord.updateCompoundKey()
                return storage.reference(for: historyRecord)
            }
            
            var match: (any ReaderContentProtocol)?
            var historyVisitPending = countsAsHistoryVisit && persist
            let candidates = try await loadAll(
                url: url,
                skipContentFiles: false,
                skipFeedEntries: false,
                storage: storage
            )
            match = candidates.max(by: {
                ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
            })
            if let nonHistoryMatch = match, countsAsHistoryVisit && persist, nonHistoryMatch.objectSchema.objectClass != HistoryRecord.self {
                try storage.validate()
                match = try await nonHistoryMatch.addHistoryRecord(
                    realmConfiguration: storage.historyConfiguration,
                    pageURL: url,
                    bookmarkRealmConfiguration: storage.bookmarkConfiguration,
                    historyStorageAdmission: storage.historyAdmission,
                    bookmarkStorageAdmission: storage.bookmarkAdmission
                )
                historyVisitPending = false
            } else if match == nil, !url.isEBookURL {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                //        historyRecord.isReaderModeByDefault
                historyRecord.updateCompoundKey()
                if persist {
                    let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(
                        for: storage.historyConfiguration, storageAdmission: storage.historyAdmission
                    )
                    // Another load/capture may have committed while this query
                    // was suspended. Never replace that row with new defaults.
                    match = try await historyRealm.asyncWritePreservingOwnership {
                        try Task.checkCancellation()
                        try storage.validate()
                        let timestamp = Date()
                        if let existing = historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: historyRecord.compoundKey) {
                            if countsAsHistoryVisit {
                                existing.lastVisitedAt = timestamp
                                existing.isDeleted = false
                                existing.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                            }
                            return existing
                        }
                        if countsAsHistoryVisit { historyRecord.lastVisitedAt = timestamp }
                        historyRealm.add(historyRecord)
                        historyRecord.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                        return historyRecord
                    }
                    historyVisitPending = false
                } else {
                    match = historyRecord
                }
            }
            
            try Task.checkCancellation()
            guard let match, !match.isInvalidated,
                  let reference = storage.reference(for: match) else {
                try await HistoryRecord.refreshDemotedStatus(forURL: url,
                    historyRealmConfiguration: storage.historyConfiguration,
                    historyStorageAdmission: storage.historyAdmission,
                    bookmarkRealmConfiguration: storage.bookmarkConfiguration,
                    bookmarkStorageAdmission: storage.bookmarkAdmission)
                return nil
            }
            let loadedReference = try await finishLoadedContentAndRefreshDemotion(
                reference,
                countsAsHistoryVisit: historyVisitPending,
                readerModeRequired: persist && ((url.isReaderFileURL && url.contains(.plainText)) || url.isEBookURL),
                bookmarkRealmConfiguration: storage.bookmarkConfiguration,
                bookmarkStorageAdmission: storage.bookmarkAdmission
            )
            return loadedReference
        }()
        try Task.checkCancellation()
        let result = try await contentRef?.resolveOnMainActor()
        guard let result, !result.isDeleted else { return nil }
        return result
    }
    
    @RealmBackgroundActor
    static func finishLoadedContentAndRefreshDemotion(
        _ reference: ContentReference,
        countsAsHistoryVisit: Bool,
        readerModeRequired: Bool,
        bookmarkRealmConfiguration: Realm.Configuration,
        bookmarkStorageAdmission: RealmStorageAdmission
    ) async throws -> ContentReference? {
        let loadedReference = try await finishLoadedContent(reference,
            countsAsHistoryVisit: countsAsHistoryVisit, readerModeRequired: readerModeRequired)
        // A live final read can reject a provisionally deleted identity. The
        // delivered demotion still belongs to its captured store and must reach
        // settled write evaluation, even when there is no load result to return.
        try await HistoryRecord.refreshDemotedStatus(for: reference,
            bookmarkRealmConfiguration: bookmarkRealmConfiguration,
            bookmarkStorageAdmission: bookmarkStorageAdmission)
        return loadedReference
    }

    @RealmBackgroundActor
    static func finishLoadedContent(
        _ reference: ContentReference,
        countsAsHistoryVisit: Bool,
        readerModeRequired: Bool
    ) async throws -> ContentReference? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: reference.realmConfiguration, storageAdmission: reference.storageAdmission)
        if !countsAsHistoryVisit && !readerModeRequired {
            // Discovery alone does not queue a writer. Refresh, then return only
            // a live identity; any demotion update has its own guarded writer.
            await realm.asyncRefresh()
            try Task.checkCancellation()
            try reference.validateStorage()
            guard let content = reference.resolve(in: realm),
                !content.isDeleted else { return nil }
            return reference
        }
        await contentWriteGateForTesting?(.loadedContent)
        return try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            try reference.validateStorage()
            guard let content = reference.resolve(in: realm) else { return nil }
            let visit = countsAsHistoryVisit && reference.contentType == HistoryRecord.self
            // Only an explicit visit revives history. Cache/background loads and
            // reader-mode updates never revive deleted content.
            guard !content.isDeleted || visit else { return nil }
            let timestamp = Date()
            var changed = false
            if visit, let history = content as? HistoryRecord {
                history.lastVisitedAt = timestamp
                history.isDeleted = false
                changed = true
            }
            if readerModeRequired && !content.isReaderModeByDefault {
                content.isReaderModeByDefault = true
                changed = true
            }
            if changed { content.refreshChangeMetadata(explicitlyModified: true, at: timestamp) }
            return reference
        }
    }

    @MainActor
    public static func load(urlString: String, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
        return try await load(
            url: url,
            countsAsHistoryVisit: countsAsHistoryVisit,
            source: "ReaderContentLoader.load.urlString"
        )
    }
    
    @MainActor
    public static func load(
        html: String,
        allowContentMatch: Bool = true,
        snippetIdentifier: UUID? = nil
    ) async throws -> (any ReaderContentProtocol)? {
        // A transient startup host can lose cancellation ownership after the
        // import commits. Its retry must retain that import's identity rather
        // than create another snippet. Ordinary imports still receive fresh IDs.
        guard snippetIdentifier == nil || !allowContentMatch else {
            throw CancellationError()
        }
        return try await load(
            html: html,
            allowContentMatch: allowContentMatch,
            storage: DiscoveryStorage(),
            snippetIdentifier: snippetIdentifier
        )
    }

    @MainActor
    private static func load(
        html: String,
        allowContentMatch: Bool,
        storage: DiscoveryStorage,
        snippetIdentifier: UUID? = nil
    ) async throws -> (any ReaderContentProtocol)? {
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: storage.bookmarkConfiguration, storageAdmission: storage.bookmarkAdmission
            )
            let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: storage.historyConfiguration, storageAdmission: storage.historyAdmission
            )
            let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: storage.feedConfiguration, storageAdmission: storage.feedAdmission
            )
            await bookmarkRealm.asyncRefresh()
            await historyRealm.asyncRefresh()
            await feedRealm.asyncRefresh()
            
            try storage.validate()
            let normalizedHTML = normalizeSnippetSourceHTML(html)
            let data = normalizedHTML.readerContentData
            let generatedTitle = generatedSnippetTitle(fromSourceHTML: normalizedHTML) ?? ""

            if allowContentMatch {
                let bookmark = bookmarkRealm.objects(Bookmark.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { !$0.isDeleted && $0.content == data }
                    .first
                let history = historyRealm.objects(HistoryRecord.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { !$0.isDeleted && $0.content == data }
                    .first
                let feed = feedRealm.objects(FeedEntry.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { !$0.isDeleted && $0.content == data }
                    .first
                let candidates: [any ReaderContentProtocol] = [bookmark, history, feed].compactMap { $0 }

                if let match = candidates.max(by: { $0.createdAt < $1.createdAt }) {
                    return storage.reference(for: match)
                }
            }
            
            let historyRecord = HistoryRecord()
            if !allowContentMatch {
                let freshSnippetKey = (snippetIdentifier ?? UUID()).uuidString.uppercased()
                historyRecord.compoundKey = freshSnippetKey
                historyRecord.url = snippetURL(key: freshSnippetKey) ?? historyRecord.url
            }
            historyRecord.publicationDate = Date()
            historyRecord.content = data
            historyRecord.title = generatedTitle
            historyRecord.isTitlePrefixOfContent = !generatedTitle.isEmpty
            // isReaderModeByDefault used to be commented out... why?
            historyRecord.isReaderModeByDefault = true
            historyRecord.isDemoted = false
            if allowContentMatch {
                historyRecord.updateCompoundKey()
                historyRecord.url = snippetURL(key: historyRecord.compoundKey) ?? historyRecord.url
            }
            historyRecord.rssContainsFullContent = true
//            await historyRealm.asyncRefresh()
            // The cached actor-bound Realm may still be committing an earlier
            // async write when another startup load enters this actor. Queue
            // this transaction instead of synchronously beginning a second one.
            let committedRecord = try await historyRealm.asyncWritePreservingOwnership {
                try Task.checkCancellation()
                try storage.validate()
                if snippetIdentifier != nil,
                   let existing = historyRealm.object(ofType: HistoryRecord.self,
                       forPrimaryKey: historyRecord.compoundKey) {
                    // Replay cannot revive a deletion or overwrite a later edit.
                    // Successful reuse performs no metadata refresh or journal write.
                    guard !existing.isDeleted, existing.url == historyRecord.url,
                          existing.content == data else { throw CancellationError() }
                    return existing
                }
                historyRealm.add(historyRecord, update: .modified)
                historyRecord.refreshChangeMetadata(explicitlyModified: true)
                return historyRecord
            }

            
            return storage.reference(for: committedRecord)
        }()
        
        let result = try await contentRef?.resolveOnMainActor()
        guard let result, !result.isDeleted else { return nil }
        return result
    }
    
    /// Returns a URL to load for the given content into a Reader instance. The URL is either a resource (like a web location),
    /// or an internal "local" URL for loading HTML content in Reader Mode.
    @MainActor
    public static func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager
    ) async throws -> URL? {
        try Task.checkCancellation()
        guard !content.isInvalidated else { throw CancellationError() }
        let contentURL = content.url
        func validateContent() throws {
            try Task.checkCancellation()
            guard !content.isInvalidated, content.url == contentURL else {
                throw CancellationError()
            }
        }

        let storage = DiscoveryStorage()
        let canonicalReaderBackingURL = readerFileManager.canonicalReaderBackingURL(for: contentURL)
        let contentHasLocallyRetrievableHTML = try await hasLocallyRetrievableHTML(
            for: content,
            readerFileManager: readerFileManager
        )
        try validateContent()

        if contentURL.isSnippetURL {
            if contentHasLocallyRetrievableHTML, let loaderURL = readerLoaderURL(for: contentURL) {
                return loaderURL
            }
            return contentURL
        }

        if ["http", "https"].contains(contentURL.scheme?.lowercased()) {
            if content.isReaderModeByDefault,
               contentHasLocallyRetrievableHTML,
               let loaderURL = readerLoaderURL(for: contentURL) {
                return loaderURL
            }

            let matchingContent = try await lookupStoredContent(url: contentURL, storage: storage)
            try validateContent()
            if let matchingContent, !matchingContent.isInvalidated,
               matchingContent.isReaderModeByDefault {
                let matchingContentURL = matchingContent.url
                let matchingContentHasHTML = (try? await hasLocallyRetrievableHTML(
                    for: matchingContent,
                    readerFileManager: readerFileManager
                )) == true
                try validateContent()
                if matchingContentHasHTML,
                   !matchingContent.isInvalidated,
                   matchingContent.url == matchingContentURL,
                   let matchingURL = readerLoaderURL(for: matchingContentURL) {
                    return matchingURL
                }
            }
            return contentURL
        }

        if let canonicalReaderBackingURL,
           !contentURL.isReaderFileURL {
            _ = try await readerFileManager.resolveReadableLocalURL(
                forReaderBackingURL: canonicalReaderBackingURL
            )
            try validateContent()
        }

        if contentURL.isReaderFileURL,
           contentHasLocallyRetrievableHTML,
           let loaderURL = readerLoaderURL(for: contentURL) {
            return loaderURL
        }

        return contentURL
    }

    static func docIsPlainText(doc: SwiftSoup.Document) -> Bool {
        return (
            ((doc.body()?.children().isEmpty()) ?? true)
            || ((doc.body()?.children().first()?.tagNameNormal() ?? "") == "pre" && doc.body()?.children().count == 1) )
    }
    
    public static func textToHTMLDoc(_ text: String) throws -> SwiftSoup.Document {
        let html = textToHTML(text)
        return try SwiftSoup.parse(html)
    }

    private static func rawPlainTextToHTML(_ text: String) -> String {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        var paragraphs = [String]()
        var currentParagraphLines = [String]()

        let flushParagraph = {
            guard !currentParagraphLines.isEmpty else { return }
            paragraphs.append("<p>\(currentParagraphLines.joined(separator: "<br>"))</p>")
            currentParagraphLines.removeAll()
        }

        for line in normalizedText.components(separatedBy: "\n") {
            if line.isEmpty {
                flushParagraph()
            } else {
                currentParagraphLines.append(line.escapeHtml())
            }
        }
        flushParagraph()

        return "<html><body>\(paragraphs.joined())</body></html>"
    }
    
    public static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        var convertedText = text
        if forceRaw {
            convertedText = rawPlainTextToHTML(text)
        } else if let doc = try? SwiftSoup.parse(text) {
            if docIsPlainText(doc: doc) {
                convertedText = "<html><body>\(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>"))</body></html>"
            }
        } else {
            convertedText = "<html><body>\(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>"))</body></html>"
        }
        return convertedText
    }
    
    public static func snippetURL(key: String) -> URL? {
        return URL(string: "internal://local/snippet?key=\(key)")
    }

    public static func readerLoaderURL(for contentURL: URL) -> URL? {
        guard let contentURL = contentURL.readerContentURL,
              let encodedURL = contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        guard let loaderURL = URL(string: "internal://local/load/reader?reader-url=\(encodedURL)"),
              loaderURL.readerContentURL == contentURL else { return nil }
        return loaderURL
    }
    
    @MainActor
    public static func load(
        text: String,
        allowContentMatch: Bool = true
    ) async throws -> (any ReaderContentProtocol)? {
        let html = snippetHTML(fromRawText: text)
        return try await load(html: html, allowContentMatch: allowContentMatch)
    }
    
    @MainActor
    public static func loadPasteboard(
        bookmarkRealmConfiguration: Realm.Configuration = ReaderContentLoader.bookmarkRealmConfiguration,
        historyRealmConfiguration: Realm.Configuration = ReaderContentLoader.historyRealmConfiguration,
        feedEntryRealmConfiguration: Realm.Configuration = ReaderContentLoader.feedEntryRealmConfiguration,
        allowContentMatch: Bool = true
    ) async throws -> (any ReaderContentProtocol)? {
        let storage = DiscoveryStorage(
            bookmarkConfiguration: bookmarkRealmConfiguration,
            historyConfiguration: historyRealmConfiguration,
            feedConfiguration: feedEntryRealmConfiguration
        )
        var match: (any ReaderContentProtocol)?
        let (html, text) = pasteboardImportStrings()
        
        if let text, let url = URL(string: text), url.absoluteString == text, url.scheme != nil, url.host != nil {
            match = try await load(url: url, persist: true, countsAsHistoryVisit: true,
                source: "ReaderContentLoader.loadPasteboard", storage: storage)
        } else if let payload = preferredPasteboardPayload(html: html, text: text) {
            let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
            match = try await load(html: normalized.html, allowContentMatch: allowContentMatch, storage: storage)
        }

        guard let match, !match.isInvalidated, !match.isDeleted,
              let reference = storage.reference(for: match) else { return nil }
        guard match.url.isSnippetURL else { return match }
        let clipboardReference = try await markSnippetFromClipboard(reference)
        guard let clipboardReference else { return nil }
        let result = try await clipboardReference.resolveOnMainActor()
        guard let result, !result.isDeleted else { return nil }
        return result
    }

    @RealmBackgroundActor
    static func markSnippetFromClipboard(_ reference: ContentReference) async throws -> ContentReference? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: reference.realmConfiguration, storageAdmission: reference.storageAdmission)
        await contentWriteGateForTesting?(.clipboard)
        return try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            try reference.validateStorage()
            // The import itself owns revival. This delayed follow-up must not
            // undo a deletion committed after the import returned.
            guard let content = reference.resolve(in: realm),
                !content.isDeleted, content.url.isSnippetURL else { return nil }
            let url = snippetURL(key: content.compoundKey) ?? content.url
            if !content.isFromClipboard || !content.rssContainsFullContent || !content.isReaderModeByDefault || content.url != url {
                content.isFromClipboard = true
                content.rssContainsFullContent = true
                content.isReaderModeByDefault = true
                content.url = url
                content.refreshChangeMetadata(explicitlyModified: true)
            }
            return reference
        }
    }

    @MainActor
    private static func pasteboardImportStrings() -> (html: String?, text: String?) {
        if let strings = pasteboardStringsForTesting { return strings }

#if os(macOS)
        let html = NSPasteboard.general.string(forType: .html)
        let text = NSPasteboard.general.string(forType: .string)
#else
        let pasteboard = UIPasteboard.general
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let htmlFromData = htmlData.flatMap {
            String(data: $0, encoding: .utf8)
                ?? String(data: $0, encoding: .unicode)
                ?? String(data: $0, encoding: .utf16LittleEndian)
                ?? String(data: $0, encoding: .utf16BigEndian)
        }
        let htmlFromValue = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
        let html = htmlFromData ?? htmlFromValue
        let text = pasteboard.string
#endif
        return (html, text)
    }

    public static func snippetHTML(fromRawText text: String) -> String {
        normalizeSnippetSourceHTML(textToHTML(text, forceRaw: true))
    }

    public static func snippetHTMLFromPasteText(_ text: String) -> String {
        let normalized = normalizeIngestedText(text, explicitHTML: false, source: .paste)
        return normalizeSnippetSourceHTML(normalized.html)
    }

    public static func snippetHTML(fromHTML html: String) -> String {
        normalizeSnippetSourceHTML(html)
    }

    public static let snippetReaderTitleSuppressionBodyClass = "mnb-hide-redundant-snippet-reader-title"

    public static func normalizedDisplayTitle(
        _ rawTitle: String,
        needsClipboardIndicator: Bool
    ) -> String {
        var displayTitle = rawTitle.removingClipboardIndicatorIfNeeded(needsClipboardIndicator)
        // Preserve one-layer decoding: entity-encoded angle brackets are display text, not markup.
        displayTitle = displayTitle.removingHTMLTags() ?? displayTitle
        if displayTitle.contains("&") {
            displayTitle = (try? Entities.unescape(displayTitle)) ?? displayTitle
        }
        return displayTitle
    }

    public static func resolvedDisplayTitle(
        _ rawTitle: String,
        needsClipboardIndicator: Bool,
        addClipboardIndicator: Bool = false
    ) -> String {
        var displayTitle = normalizedDisplayTitle(
            rawTitle,
            needsClipboardIndicator: needsClipboardIndicator
        )
        if displayTitle.isEmpty {
            displayTitle = "Untitled"
        }
        if addClipboardIndicator {
            return "📎 " + displayTitle
        }
        return displayTitle
    }

    public static func resolvedSnippetLocationBarTitle(
        title: String,
        createdAt: Date,
        needsClipboardIndicator: Bool,
        isTitlePrefixOfContent: Bool
    ) -> String {
        let fallbackTitle = "Snippet — \(createdAt.readerSnippetChromeDateString)"
        if isTitlePrefixOfContent {
            return fallbackTitle
        }
        let cleanedTitle = resolvedDisplayTitle(
            title,
            needsClipboardIndicator: needsClipboardIndicator
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedTitle.isEmpty ? fallbackTitle : cleanedTitle
    }

    private static func snippetAutoTitleCompactComparisonValue(_ raw: String?) -> String? {
        canonicalSnippetAutoTitleComparisonValue(raw)?
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func canonicalSnippetAutoTitleComparisonValue(_ raw: String?) -> String? {
        normalizedSnippetAutoTitle(raw)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespacesAndNewlines))
    }

    public static func normalizedSnippetAutoTitle(_ raw: String?) -> String? {
        let rawValue = raw ?? ""
        let sanitized = rawValue.removingHTMLTags() ?? rawValue
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.truncate(36)
    }

    public static func generatedSnippetTitle(fromSourceHTML html: String) -> String? {
        titleFromReadabilityHTML(normalizeSnippetSourceHTML(html))
            .flatMap { normalizedSnippetAutoTitle($0) }
    }

    private static func titleFromReadabilityHTML(_ html: String) -> String? {
        if let doc = try? SwiftSoup.parse(html) {
            if let readerTitleText = try? doc.getElementById("reader-title")?.text(),
               let title = normalizedSnippetAutoTitle(readerTitleText) {
                return title
            }
            if let headingText = try? doc.getElementsByTag("h1").first()?.text(),
               let title = normalizedSnippetAutoTitle(headingText) {
                return title
            }
            if let headTitle = try? doc.title(),
               let title = normalizedSnippetAutoTitle(headTitle) {
                return title
            }
            if let bodyText = try? doc.body()?.text(),
               let title = normalizedSnippetAutoTitle(bodyText) {
                return title
            }
        }
        let stripped = html.removingHTMLTags() ?? html
        return normalizedSnippetAutoTitle(stripped.components(separatedBy: "\n").first ?? stripped)
    }

    public static func snippetTitleMatchesGeneratedPrefix(
        _ title: String,
        sourceHTML: String?
    ) -> Bool {
        let generatedTitle = sourceHTML.flatMap { generatedSnippetTitle(fromSourceHTML: $0) }
        let canonicalTitle = canonicalSnippetAutoTitleComparisonValue(title)
        let canonicalGeneratedTitle = canonicalSnippetAutoTitleComparisonValue(generatedTitle)
        let compactTitle = snippetAutoTitleCompactComparisonValue(title)
        let compactGeneratedTitle = snippetAutoTitleCompactComparisonValue(generatedTitle)
        let matches = {
            let canonicalMatch = {
                guard let canonicalTitle, let canonicalGeneratedTitle else { return false }
                return canonicalTitle == canonicalGeneratedTitle
                || canonicalGeneratedTitle.hasPrefix(canonicalTitle)
                || canonicalTitle.hasPrefix(canonicalGeneratedTitle)
            }()
            let compactMatch = {
                guard let compactTitle, let compactGeneratedTitle else { return false }
                return compactTitle == compactGeneratedTitle
                    || compactGeneratedTitle.hasPrefix(compactTitle)
                    || compactTitle.hasPrefix(compactGeneratedTitle)
            }()
            return canonicalMatch || compactMatch
        }()
        return matches
    }

    private static func resolvedSnippetTitleAfterHTMLUpdate(
        currentTitle: String,
        currentHTML: String?,
        updatedHTML: String,
        requestedTitle: String? = nil,
        currentIsTitlePrefixOfContent: Bool? = nil
    ) -> (title: String, isTitlePrefixOfContent: Bool) {
        let desiredTitle = requestedTitle ?? currentTitle
        let shouldAutoRetitle =
            desiredTitle == currentTitle &&
            (currentIsTitlePrefixOfContent
                ?? snippetTitleMatchesGeneratedPrefix(currentTitle, sourceHTML: currentHTML))
        let resolvedTitle: String
        if shouldAutoRetitle,
           let generatedTitle = generatedSnippetTitle(fromSourceHTML: updatedHTML) {
            resolvedTitle = generatedTitle
        } else {
            resolvedTitle = desiredTitle
        }
        return (
            resolvedTitle,
            snippetTitleMatchesGeneratedPrefix(resolvedTitle, sourceHTML: updatedHTML)
        )
    }

    @MainActor
    public static func snippetEditorHTML(
        for content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = .shared
    ) async throws -> String {
        if let html = try await content.htmlToDisplay(readerFileManager: readerFileManager),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizeSnippetSourceHTML(html)
        }
        return normalizeSnippetSourceHTML("<html><body></body></html>")
    }

    public static func loadPasteboardSnippetHTML() -> String? {
#if os(macOS)
        let html = NSPasteboard.general.string(forType: .html)
        let text = NSPasteboard.general.string(forType: .string)
#else
        let pasteboard = UIPasteboard.general
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let htmlFromData = htmlData.flatMap {
            String(data: $0, encoding: .utf8)
                ?? String(data: $0, encoding: .unicode)
                ?? String(data: $0, encoding: .utf16LittleEndian)
                ?? String(data: $0, encoding: .utf16BigEndian)
        }
        let htmlFromValue = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
        let html = htmlFromData ?? htmlFromValue
        let text = pasteboard.string
#endif

        guard let payload = preferredPasteboardPayload(html: html, text: text) else {
            return nil
        }
        let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
   return normalizeSnippetSourceHTML(normalized.html)
    }

#if DEBUG
    public static let debugSnippetFallbackRawText = """
# Updated via Snippet Helper

This snippet loads when the pasteboard is empty in a debug build.

- First line borrowed from snippet loader tests.
- Second line is plain Markdown for quick UI checks.
- Third line makes the preview a little less bare.
"""
#endif

    @MainActor
    public static func appendSnippetHTML(
        _ appendedHTML: String,
        to content: any ReaderContentProtocol
    ) async throws -> (any ReaderContentProtocol)? {
        guard let target = captureSnippetAppendTarget(for: content) else { return nil }
        let result = try await appendSnippetHTML(appendedHTML, to: target, permitsCommit: { true })
        return result.content
    }

    static func normalizedSnippetAppendHTML(_ html: String, contentURL: URL) -> String {
        let normalizedHTML = normalizeSnippetSourceHTML(html)
        logSnippetEvent(
            "appendSnippetHTML.begin",
            "contentURL=\(contentURL.absoluteString)",
            "incomingBytes=\(normalizedHTML.utf8.count)"
        )
        return normalizedHTML
    }

    /// Shared field mutator used by the captured writer on its owning actor.
    /// Transaction admission and authoritative metadata belong to that writer.
    static func applySnippetAppend(
        _ normalizedAppendedHTML: String,
        to object: any ReaderContentProtocol
    ) -> Bool {
        let currentHTML = object.html
        guard let mergedHTML = try? appendSnippetHTML(
            normalizedAppendedHTML,
            toExistingHTML: currentHTML
        ) else { return false }

        let normalizedCurrentHTML = snippetHTML(fromHTML: currentHTML ?? "<html><body></body></html>")
        let normalizedMergedHTML = snippetHTML(fromHTML: mergedHTML)
        let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
            currentTitle: object.title,
            currentHTML: currentHTML,
            updatedHTML: mergedHTML,
            currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
        )
        var objectDidChange = false

        if normalizedCurrentHTML != normalizedMergedHTML {
            object.html = mergedHTML
            objectDidChange = true
        }
        if object.title != resolvedTitleUpdate.title {
            object.title = resolvedTitleUpdate.title
            objectDidChange = true
        }
        if object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent {
            object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
            objectDidChange = true
        }
        if object.rssContainsFullContent == false {
            object.rssContainsFullContent = true
            objectDidChange = true
        }
        if object.isReaderModeByDefault == false {
            object.isReaderModeByDefault = true
            objectDidChange = true
        }

        logSnippetEvent(
            "appendSnippetHTML.merge",
            "contentURL=\(object.url.absoluteString)",
            "currentBytes=\((currentHTML ?? "").utf8.count)",
            "mergedBytes=\(mergedHTML.utf8.count)",
            "didChange=\(objectDidChange)",
            "title=\(object.title.truncate(80))"
        )
        return objectDidChange
    }

    /// A delayed import keeps its original destination across recognition and UI navigation.
    @MainActor
    public static func appendSnippetHTML(
        _ appendedHTML: String,
        toContentURL contentURL: URL
    ) async throws -> (any ReaderContentProtocol)? {
        guard contentURL.isSnippetURL else { return nil }
        let normalizedAppendedHTML = normalizeSnippetSourceHTML(appendedHTML)
    try await { @RealmBackgroundActor in
            try await updateContent(url: contentURL) { object in
                let currentHTML = object.html
                guard let mergedHTML = try? appendSnippetHTML(
                    normalizedAppendedHTML,
                    toExistingHTML: currentHTML
                ) else {
                    return false
                }

                let normalizedCurrentHTML = snippetHTML(fromHTML: currentHTML ?? "<html><body></body></html>")
                let normalizedMergedHTML = snippetHTML(fromHTML: mergedHTML)
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: currentHTML,
                    updatedHTML: mergedHTML,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                var objectDidChange = false

                if normalizedCurrentHTML != normalizedMergedHTML {
                    object.html = mergedHTML
                    objectDidChange = true
                }
                if object.title != resolvedTitleUpdate.title {
                    object.title = resolvedTitleUpdate.title
                    objectDidChange = true
                }
                if object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent {
                    object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                    objectDidChange = true
                }
                if object.rssContainsFullContent == false {
                    object.rssContainsFullContent = true
                    objectDidChange = true
                }
                if object.isReaderModeByDefault == false {
                    object.isReaderModeByDefault = true
                    objectDidChange = true
                }

            return objectDidChange
            }
        }()

   return try await load(
            url: contentURL,
            persist: false,
            countsAsHistoryVisit: false,
            source: "ReaderContentLoader.appendSnippetHTML.reload"
        )
    }

    @MainActor
    public static func appendSnippetHTML(
        _ appendedHTML: String,
        toContentURL contentURL: URL,
        storage: SnippetStorage,
        account: (access: AccountSessionAccess, snapshot: AccountSessionSnapshot)? = nil,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        guard contentURL.isSnippetURL, permitsCommit() else { return false }
        let normalizedAppendedHTML = normalizeSnippetSourceHTML(appendedHTML)
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, account: account, permitsCommit: permitsCommit
            ) { object in
                let currentHTML = object.html
                guard let mergedHTML = try? appendSnippetHTML(
                    normalizedAppendedHTML, toExistingHTML: currentHTML
                ) else { return false }
                let normalizedCurrentHTML = snippetHTML(
                    fromHTML: currentHTML ?? "<html><body></body></html>"
                )
                let normalizedMergedHTML = snippetHTML(fromHTML: mergedHTML)
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: currentHTML,
                    updatedHTML: mergedHTML,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                let objectDidChange = normalizedCurrentHTML != normalizedMergedHTML
                    || object.title != resolvedTitleUpdate.title
                    || object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent
                    || !object.rssContainsFullContent
                    || !object.isReaderModeByDefault
                guard objectDidChange else { return false }
                if normalizedCurrentHTML != normalizedMergedHTML {
                    object.html = mergedHTML
                }
                object.title = resolvedTitleUpdate.title
                object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                object.rssContainsFullContent = true
                object.isReaderModeByDefault = true
                return true
            }
        }()
    }

    @MainActor
    public static func updateSnippetHTML(
        contentURL: URL,
        html: String
    ) async throws -> Bool {
        let normalizedHTML = snippetHTML(fromHTML: html)
        return try await { @RealmBackgroundActor in
            var didChange = false
            try await updateContent(url: contentURL) { object in
                let existingHTML = snippetHTML(fromHTML: object.html ?? "<html><body></body></html>")
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: object.html,
                    updatedHTML: normalizedHTML,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                var objectDidChange = false

                if existingHTML != normalizedHTML {
                    object.html = normalizedHTML
                    objectDidChange = true
                }
                if object.title != resolvedTitleUpdate.title {
                    object.title = resolvedTitleUpdate.title
                    objectDidChange = true
                }
                if object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent {
                    object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                    objectDidChange = true
                }

                if objectDidChange {
                    didChange = true
                }
                return objectDidChange
            }
            return didChange
        }()
    }

    @MainActor
    public static func updateSnippetTitle(
        contentURL: URL,
        title: String
    ) async throws -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard contentURL.isSnippetURL, !trimmedTitle.isEmpty else { return false }
        return try await { @RealmBackgroundActor in
            var didChange = false
            try await updateContent(url: contentURL) { object in
                let isTitlePrefixOfContent = snippetTitleMatchesGeneratedPrefix(
                    trimmedTitle,
                    sourceHTML: object.html
                )
                guard object.title != trimmedTitle
                    || object.isTitlePrefixOfContent != isTitlePrefixOfContent else {
                    return false
                }
                object.title = trimmedTitle
                object.isTitlePrefixOfContent = isTitlePrefixOfContent
                didChange = true
                return true
            }
            return didChange
        }()
    }

    @MainActor
    public static func updateSnippetTitle(
        contentURL: URL,
        title: String,
        storage: SnippetStorage,
        account: (access: AccountSessionAccess, snapshot: AccountSessionSnapshot)? = nil,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard contentURL.isSnippetURL, !trimmedTitle.isEmpty, permitsCommit() else { return false }
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, account: account, permitsCommit: permitsCommit
            ) { object in
                let isTitlePrefixOfContent = snippetTitleMatchesGeneratedPrefix(
                    trimmedTitle, sourceHTML: object.html
                )
                guard object.title != trimmedTitle
                    || object.isTitlePrefixOfContent != isTitlePrefixOfContent else { return false }
                object.title = trimmedTitle
                object.isTitlePrefixOfContent = isTitlePrefixOfContent
                return true
            }
        }()
    }

    @MainActor
    public static func updateSnippetContent(
        contentURL: URL,
        title: String,
        html: String
    ) async throws -> Bool {
        try await updateSnippetContent(
            contentURL: contentURL,
            title: title,
            html: html,
            storage: .capture(),
            permitsCommit: { !Task.isCancelled }
        )
    }

    /// Update every live bookmark and history representation in the original
    /// storage. Check admission inside the transaction, after any Realm wait.
    @MainActor
    public static func updateSnippetContent(
        contentURL: URL,
        title: String,
        html: String,
        originalEditorHTML: String? = nil,
        storage: SnippetStorage,
        account: (access: AccountSessionAccess, snapshot: AccountSessionSnapshot)? = nil,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        guard contentURL.isSnippetURL, permitsCommit() else { return false }
        let normalizedHTML = snippetHTML(fromHTML: html)
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, account: account, permitsCommit: permitsCommit
            ) { object in
                // The unchanged draft is the exact source supplied to the
                // editor. Do not reserialize its body, even if current storage
                // has since received a newer body from another writer.
                let bodyIsUnchanged = object.html.map { html.utf8.elementsEqual($0.utf8) } == true
                    || originalEditorHTML.map { $0.utf8.elementsEqual(html.utf8) } == true
                let currentHTML = snippetHTML(fromHTML: object.html ?? "<html><body></body></html>")
                let updatedHTML = bodyIsUnchanged ? currentHTML : normalizedHTML
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: object.html,
                    updatedHTML: updatedHTML,
                    requestedTitle: title,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                let objectDidChange = object.title != resolvedTitleUpdate.title
                    || object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent
                    || (!bodyIsUnchanged && !currentHTML.utf8.elementsEqual(normalizedHTML.utf8))
                guard objectDidChange else { return false }
                object.title = resolvedTitleUpdate.title
                object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                if !bodyIsUnchanged && !currentHTML.utf8.elementsEqual(normalizedHTML.utf8) {
                    object.html = normalizedHTML
                }
                return true
            }
        }()
    }

    @RealmBackgroundActor
    // Shared transaction boundary for append, rename and editor saves. Internal
    // visibility allows deterministic tests of real writer interleavings.
    // Separate-store compatibility remains atomic per Realm only: a thrown
    // error can follow a prior store's commit and must not imply total rollback.
    static func updateCapturedSnippetRecords(
        contentURL: URL,
        storage: SnippetStorage,
        account: (access: AccountSessionAccess, snapshot: AccountSessionSnapshot)? = nil,
        permitsCommit: @escaping @Sendable () -> Bool,
        mutate: (any ReaderContentProtocol) -> Bool
    ) async throws -> Bool {
        try storage.validateStorage()
        let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.bookmarkConfiguration, storageAdmission: storage.bookmarkAdmission
        )
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.historyConfiguration, storageAdmission: storage.historyAdmission
        )
        // App-owned snippets put both representations in the same Realm.
        // Group before writing so an account/cancellation change cannot commit
        // one representation and roll back the other in that same store.
        let groups: [(realm: Realm, bookmarks: Bool, histories: Bool)] = bookmarkRealm == historyRealm
            ? [(bookmarkRealm, true, true)]
            : [(bookmarkRealm, true, false), (historyRealm, false, true)]
        var didChange = false
        for group in groups {
            let groupDidChange = try await group.realm.asyncWritePreservingOwnership { () throws -> Bool in
                try storage.validateStorage()
                guard storage.containsCapturedTarget(in: group.realm) else { return false }
                guard !Task.isCancelled, permitsCommit() else { throw CancellationError() }
                try storage.validateStorage()
                // Query live records only after acquiring the write. No
                // managed object selected before an await can be revived or
                // mutated after another writer deletes/replaces it.
                var objects = [any ReaderContentProtocol]()
                if group.bookmarks {
                    objects += group.realm.objects(Bookmark.self)
                        .filter(NSPredicate(format: "isDeleted == false AND url == %@", contentURL.absoluteString))
                        .map { $0 as any ReaderContentProtocol }
                }
                if group.histories {
                    objects += HistoryRecord.openedRecords(matching: contentURL, in: group.realm)
                        .map { $0 as any ReaderContentProtocol }
                }
                let timestamp = Date()
                var changed = false
                for object in objects {
                    if mutate(object) {
                        object.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                        changed = true
                    }
                }
                try storage.validateStorage()
                guard !Task.isCancelled, permitsCommit(),
                      storage.containsCapturedTarget(in: group.realm) else { throw CancellationError() }
                try storage.validateStorage()
                if let account {
                    try ReaderContentAccountCommit.commit(in: group.realm, account: account)
                }
                return changed
            }
            didChange = didChange || groupDidChange
        }
        return didChange
    }

    static func preferredPasteboardPayload(html: String?, text: String?) -> (text: String, explicitHTML: Bool)? {
        func normalizedClipboardText(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let stripped = (raw.removingHTMLTags() ?? raw)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            return stripped
        }

        let normalizedHTMLText = normalizedClipboardText(html)
        let normalizedPlainText = normalizedClipboardText(text)

        if let normalizedHTMLText, let normalizedPlainText, normalizedHTMLText == normalizedPlainText {
       return (normalizedPlainText, false)
        }

        if let html {
            if normalizeIngestedText(html, explicitHTML: false, source: .paste).format == .html {
           return (html, true)
            }
        }
        if let text {
       return (text, false)
        }
        if let html {
       return (html, false)
        }
        return nil
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String?, title: String?, url: URL, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        if let text = text {
            try await _ = Bookmark.add(url: url, title: title ?? "", html: textToHTML(text), isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
        } else {
            try await _ = Bookmark.add(url: url, title: title ?? "", isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
        }
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String, title: String?, url: URL?, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        let html = Self.textToHTML(text)
        try await _ = Bookmark.add(url: url, title: title ?? "", html: html, isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
    }

    private static let snippetWrapperClass = "mnb-snippet"

    static func normalizeSnippetSourceHTML(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html),
              let body = doc.body() else {
            return html
        }

        let bodyHTML = (try? body.html())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bodyHTML.isEmpty else {
            return html
        }

        let bodyChildren = body.children()
        let isAlreadyWrapped = !bodyChildren.isEmpty && bodyChildren.allSatisfy {
            $0.hasClass(snippetWrapperClass)
        }

        guard !isAlreadyWrapped else {
            return (try? doc.outerHtml()) ?? html
        }

        try? body.html(#"<div class="\#(snippetWrapperClass)">\#(bodyHTML)</div>"#)
        return (try? doc.outerHtml()) ?? html
    }

    private static func repairedCanonicalSnippetHTMLIfNeeded(_ html: String) -> String? {
        guard let document = try? SwiftSoup.parse(html),
              let candidates = try? document.select("#reader-content").array() else { return nil }
        func isLive(_ element: Element) -> Bool {
            var current: Node? = element
            while let node = current {
                if let ancestor = node as? Element,
                   ancestor.namespace() == .html, ancestor.tagNameNormal() == "template" { return false }
                current = node.parent()
            }
            return true
        }
        let contents = candidates.filter(isLive)
        guard contents.count > 1, let inner = contents.last else { return nil }
        let ancestors = contents.dropLast()
        // Repair only genuinely nested generated wrappers. Keep author template
        // fragments and unrelated sibling content in their original document.
        for outer in ancestors {
            var parent = inner.parent()
            while let current = parent, current !== outer { parent = current.parent() }
            guard parent != nil else { return nil }
        }
        do {
            for outer in ancestors.reversed() { _ = try outer.unwrap() }
            return try document.outerHtml()
        } catch { return nil }
    }

    private static func escapeSnippetHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func appendSnippetHTML(_ appendedHTML: String, toExistingHTML existingHTML: String?) throws -> String {
        let baseHTML = normalizeSnippetSourceHTML(existingHTML ?? "<html><body></body></html>")
        let baseDoc = try SwiftSoup.parse(baseHTML)
        let appendedDoc = try SwiftSoup.parse(normalizeSnippetSourceHTML(appendedHTML))

        let existingBody = try baseDoc.body()
        let appendedBody = try appendedDoc.body()
        let appendedBodyHTML = try appendedBody?.html().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if appendedBodyHTML.isEmpty {
            return try baseDoc.outerHtml()
        }

        try existingBody?.append(appendedBodyHTML)
        return try baseDoc.outerHtml()
    }
}

/// Forked from: https://github.com/objecthub/swift-markdownkit/issues/6
open class PasteboardHTMLGenerator: HtmlGenerator {
    override open func generate(text: MarkdownKit.Text) -> String {
        var res = ""
        for (idx, fragment) in text.enumerated() {
            if (idx + 1) < text.count {
                let next = text[idx + 1]
                switch (fragment as TextFragment, next as TextFragment) {
                case (.softLineBreak, .text(let text)):
                    if text.hasPrefix("　") || text.hasPrefix("    ") {
                        res += "<br/><br/>" // TODO: Morph to paragraph
                        continue
                    }
                case (.softLineBreak, .softLineBreak):
                    res += "<br/><br/>" // TODO: Morph to paragraph
                    continue
                default:
                    break
                }
            }
            
            res += generate(textFragment: fragment)
        }
        return res
    }
    
//    override open func generate(textFragment fragment: TextFragment) -> String {
//        switch fragment {
//        case .softLineBreak:
//            return "<br/>"
//        default:
//            return super.generate(textFragment: fragment)
//        }
//    }
}

fileprivate extension URL {
    var contentType: UTType {
        return UTType(filenameExtension: (self as NSURL).pathExtension ?? "") ?? .data
    }
}

public enum ReaderContentImportError: Error, Sendable {
    case sourceWriteInProgress
}

// MARK: - User-owned Home imports

public extension ReaderContentLoader {
    enum ImportPayload: Sendable {
        case url(URL, fromClipboard: Bool = false)
        case html(String, fromClipboard: Bool)
    }

    /// Capture alongside the logical account admission, before permissions,
    /// transferable loading, OCR, or an actor hop can suspend the user action.
    struct ImportStorage: @unchecked Sendable {
        let bookmarks: Realm.Configuration
        let history: Realm.Configuration
        let feeds: Realm.Configuration
        fileprivate let bookmarkAdmission: RealmStorageAdmission
        fileprivate let historyAdmission: RealmStorageAdmission
        fileprivate let feedAdmission: RealmStorageAdmission

        @MainActor
        public static func capture() -> Self {
            let actor = RealmBackgroundActor.shared
            let bookmarks = bookmarkRealmConfiguration
            let history = historyRealmConfiguration
            let feeds = feedEntryRealmConfiguration
            let historyAdmission = actor.captureStorageAdmission(for: history)
            let bookmarkAdmission = actor.realmCacheKey(for: bookmarks) == actor.realmCacheKey(for: history)
                ? historyAdmission : actor.captureStorageAdmission(for: bookmarks)
            let feedAdmission = actor.realmCacheKey(for: feeds) == actor.realmCacheKey(for: history)
                ? historyAdmission : (actor.realmCacheKey(for: feeds) == actor.realmCacheKey(for: bookmarks)
                    ? bookmarkAdmission : actor.captureStorageAdmission(for: feeds))
            return Self(bookmarks: bookmarks, history: history, feeds: feeds,
                        bookmarkAdmission: bookmarkAdmission, historyAdmission: historyAdmission,
                        feedAdmission: feedAdmission)
        }

        fileprivate func validateCurrentStorage() throws {
            let actor = RealmBackgroundActor.shared
            guard historyAdmission.matchesCurrentStorageIdentity({ actor.realmCacheKey(for: history) }),
                  bookmarkAdmission.matchesCurrentStorageIdentity({ actor.realmCacheKey(for: bookmarks) }),
                  feedAdmission.matchesCurrentStorageIdentity({ actor.realmCacheKey(for: feeds) }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
        }
    }

    struct ImportResult: Sendable {
        public let reference: ContentReference
        public let objectID: UInt64
    }

    static func importPayload(fromText text: String) -> ImportPayload? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""), url.host != nil {
            return .url(url)
        }
        return .html(snippetHTML(fromRawText: text), fromClipboard: false)
    }

    /// Snapshot the pasteboard at the user action, not in a later Task.
    @MainActor
    static func capturePasteboardImportPayload() -> ImportPayload? {
        let (html, text) = pasteboardImportStrings()
        if let text, let url = URL(string: text), url.absoluteString == text,
           url.scheme != nil, url.host != nil {
            return .url(url, fromClipboard: true)
        }
        guard let payload = preferredPasteboardPayload(html: html, text: text) else { return nil }
        let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
        return .html(normalized.html, fromClipboard: true)
    }

    /// Creates a fresh snippet or records an explicit URL visit in one owned
    /// History transaction. Generic readers keep their existing load semantics.
    /// A returned reference is a durable result; resolving/displaying it is a
    /// separate operation and must never turn a later cancellation into rollback.
    @RealmBackgroundActor
    static func importContent(
        _ payload: ImportPayload,
        storage: ImportStorage,
        permitsCommit: @escaping @Sendable () -> Bool,
        commitIfCurrent: @escaping ReaderContentCommitIfCurrent
    ) async throws -> ImportResult? {
        func validateAdmission() throws {
            try Task.checkCancellation()
            guard permitsCommit() else { throw CancellationError() }
            try Task.checkCancellation()
            try storage.validateCurrentStorage()
        }
        try validateAdmission()
        let transcript: TranscriptPageAsset?
        if case let .url(url, _) = payload, url.isTranscriptPageURL {
            guard let key = url.transcriptAssetKey,
                  let asset = await TranscriptPageRegistry.shared.asset(forKey: key),
                  asset.pageURL == url else { return nil }
            transcript = asset
        } else { transcript = nil }
        try validateAdmission()
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.history, storageAdmission: storage.historyAdmission)
        func finish(_ record: HistoryRecord) throws -> ImportResult {
            try validateAdmission()
            guard let reference = ContentReference(content: record, storageAdmission: storage.historyAdmission) else {
                throw CancellationError()
            }
            let result = ImportResult(reference: reference, objectID: record.id)
            try commitMutation(in: historyRealm, ifCurrent: commitIfCurrent, validatingBeforeCommit: {
                // Account publication may hold its lock while invoking commit.
                // Its admission is authoritative; do not reenter the account predicate.
                try Task.checkCancellation()
                try storage.validateCurrentStorage()
            })
            return result
        }
        switch payload {
        case let .html(html, fromClipboard):
            let normalizedHTML = normalizeSnippetSourceHTML(html)
            let data = normalizedHTML.readerContentData
            let title = generatedSnippetTitle(fromSourceHTML: normalizedHTML) ?? ""
            return try await historyRealm.asyncWritePreservingOwnership { () throws -> ImportResult? in
                try validateAdmission()
                let timestamp = Date()
                let record = HistoryRecord()
                let key = UUID().uuidString.uppercased()
                record.compoundKey = key
                record.createdAt = timestamp
                record.lastVisitedAt = timestamp
                record.url = snippetURL(key: key) ?? record.url
                record.publicationDate = timestamp
                record.content = data
                record.title = title
                record.isTitlePrefixOfContent = !title.isEmpty
                record.isReaderModeByDefault = true
                record.isDemoted = false
                record.rssContainsFullContent = true
                record.isFromClipboard = fromClipboard
                historyRealm.add(record)
                record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                return try finish(record)
            }

        case let .url(url, fromClipboard):
            guard url.absoluteString != "about:blank",
                  !url.isInternalReaderLoadingURL else {
                return nil
            }
            let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: storage.bookmarks, storageAdmission: storage.bookmarkAdmission)
            let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: storage.feeds, storageAdmission: storage.feedAdmission)
            func validateSources() throws {
                try validateAdmission()
                guard (bookmarkRealm == historyRealm || !bookmarkRealm.isInWriteTransaction),
                      (feedRealm == historyRealm || !feedRealm.isInWriteTransaction) else {
                    throw ReaderContentImportError.sourceWriteInProgress
                }
            }
            try validateSources()
            return try await historyRealm.asyncWritePreservingOwnership { () throws -> ImportResult? in
                try validateAdmission()
                // Separate source stores are read-only; never borrow a peer's provisional write.
                try validateSources()
                if bookmarkRealm != historyRealm { bookmarkRealm.refresh() }
                if feedRealm != historyRealm && feedRealm != bookmarkRealm { feedRealm.refresh() }
                try validateSources()
                let timestamp = Date()
                let source = importSource(for: url, bookmarks: bookmarkRealm,
                                          history: historyRealm, feeds: feedRealm)
                let record: HistoryRecord
                if let transcript {
                    let candidates = HistoryRecord.records(matching: url, in: historyRealm)
                    let canonical = HistoryRecord.makePrimaryKey(url: url, html: nil)
                        .flatMap { historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: $0) }
                    let order = [SortDescriptor(keyPath: "lastVisitedAt", ascending: false),
                                 SortDescriptor(keyPath: "compoundKey", ascending: true)]
                    record = candidates.where({ !$0.isDeleted }).sorted(by: order).first
                        ?? canonical ?? candidates.where({ $0.isDeleted }).sorted(by: order).first
                        ?? HistoryRecord()
                    if record.realm == nil {
                        record.url = url
                        record.createdAt = timestamp
                        record.updateCompoundKey()
                    }
                    record.title = transcript.title
                    record.sourceDownloadURL = transcript.canonicalContentURL
                    record.html = transcript.html
                    record.rssContainsFullContent = true
                    record.isReaderModeByDefault = true
                    record.isDemoted = false
                    if record.realm == nil { historyRealm.add(record) }
                } else if let history = source as? HistoryRecord {
                    record = history
                } else if let source {
                    let historyURL = HistoryRecord.canonicalHistoryURL(for: url)
                    let records = HistoryRecord.records(matching: historyURL, in: historyRealm)
                    let canonical = HistoryRecord.makePrimaryKey(url: historyURL, html: source.html)
                        .flatMap { historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: $0) }
                    let sort = [SortDescriptor(keyPath: "lastVisitedAt", ascending: false),
                                SortDescriptor(keyPath: "compoundKey", ascending: true)]
                    if let existing = records.where({ !$0.isDeleted }).sorted(by: sort).first
                        ?? canonical ?? records.where({ $0.isDeleted }).sorted(by: sort).first {
                        record = existing
                    } else {
                        record = HistoryRecord()
                        record.url = historyURL
                    }
                    configureImportHistory(record, from: source)
                    record.isDeleted = false
                    if record.realm == nil {
                        record.createdAt = timestamp
                        record.updateCompoundKey()
                        historyRealm.add(record)
                    }
                    // Keep bookmark links inside the same owned transaction as the visit.
                    if source.objectSchema.objectClass == Bookmark.self {
                        let deletedIDs = Set(bookmarkRealm.objects(Bookmark.self)
                            .where { $0.isDeleted }.map(\.compoundKey))
                        for linked in HistoryRecord.openedRecords(matching: source.url, in: historyRealm)
                            .where({ $0.bookmarkID == nil || $0.bookmarkID.in(deletedIDs) }) {
                            linked.bookmarkID = source.compoundKey
                            if linked !== record {
                                linked.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                            }
                        }
                    }
                } else if let key = url.snippetKey {
                    // An explicit import may revive this stored snippet. A missing
                    // key cannot manufacture an empty replacement document.
                    guard let existing = historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: key),
                          existing.url.snippetKey == key else { return nil }
                    record = existing
                } else {
                    guard !url.isEBookURL else { return nil }
                    let candidate = HistoryRecord()
                    candidate.url = url
                    candidate.updateCompoundKey()
                    if let existing = historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: candidate.compoundKey) {
                        record = existing
                    } else {
                        record = candidate
                        record.createdAt = timestamp
                        historyRealm.add(record)
                    }
                }
                record.lastVisitedAt = timestamp
                record.isDeleted = false
                if record.url.isSnippetURL {
                    if let html = record.html, let repaired = repairedCanonicalSnippetHTMLIfNeeded(html) {
                        record.html = repaired
                    }
                    record.isFromClipboard = fromClipboard
                    record.rssContainsFullContent = true
                    record.isReaderModeByDefault = true
                    record.url = snippetURL(key: record.compoundKey) ?? record.url
                }
                if (url.isReaderFileURL && url.contains(.plainText)) || url.isEBookURL {
                    record.isReaderModeByDefault = true
                }
                if record.isDemoted != false {
                    let bookmarked = bookmarkRealm.objects(Bookmark.self)
                        .filter(NSPredicate(format: "isDeleted == false AND url == %@", record.url.absoluteString))
                        .first != nil
                    record.isDemoted = !(record.isReaderModeByDefault || record.isReaderModeAvailable
                        || record.rssContainsFullContent || record.isFromClipboard
                        || record.isPhysicalMedia || bookmarked)
                }
                record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                return try finish(record)
            }
        }
    }
}

private extension ReaderContentLoader {
    @RealmBackgroundActor
    static func importSource(for url: URL, bookmarks: Realm, history: Realm, feeds: Realm) -> (any ReaderContentProtocol)? {
        let exactURL = NSPredicate(format: "isDeleted == false AND url == %@", url.absoluteString)
        let file = history.objects(ContentFile.self).filter(exactURL).sorted(byKeyPath: "createdAt", ascending: false).first
        let bookmark = bookmarks.objects(Bookmark.self).filter(exactURL).sorted(byKeyPath: "createdAt", ascending: false).first
        let opened = HistoryRecord.openedRecords(matching: url, in: history)
            .sorted(by: [SortDescriptor(keyPath: "lastVisitedAt", ascending: false),
                         SortDescriptor(keyPath: "compoundKey", ascending: true)]).first
        var feed: FeedEntry?
        if url.scheme == "https" {
            feed = feeds.objects(FeedEntry.self)
                .filter(NSPredicate(format: "isDeleted == false AND (url == %@ OR url == %@)",
                                    url.absoluteString, url.settingScheme("http").absoluteString))
                .sorted(byKeyPath: "createdAt", ascending: false).first
        } else if !url.isReaderFileURL {
            feed = feeds.objects(FeedEntry.self).filter(exactURL).sorted(byKeyPath: "createdAt", ascending: false).first
        }
        let candidates: [any ReaderContentProtocol] = [file, bookmark, opened, feed].compactMap { $0 }
        return candidates.max {
            (($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt)
                < (($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt)
        }
    }

    @RealmBackgroundActor
    static func configureImportHistory(_ record: HistoryRecord, from source: any ReaderContentProtocol) {
        record.title = source.title
        record.author = source.author
        record.isPhysicalMedia = source.isPhysicalMedia
        record.redditTranslationsUrl = source.redditTranslationsUrl
        record.redditTranslationsTitle = source.redditTranslationsTitle
        record.isTitlePrefixOfContent = source.isTitlePrefixOfContent
        record.imageUrl = source.imageUrl
        if record.imageUrl == nil, let feed = source as? FeedEntry {
            record.imageUrl = feed.importImageURLWithoutCaching()
        }
        record.sourceIconURL = source.sourceIconURL
        record.isFromClipboard = source.isFromClipboard
        record.rssContainsFullContent = source.rssContainsFullContent
        if source.rssContainsFullContent { record.content = source.content }
        record.voiceFrameUrl = source.voiceFrameUrl
        let audio = source.resolvedVoiceAudioURLs
        record.voiceAudioURL = audio.first
        record.voiceAudioURLs.removeAll()
        record.voiceAudioURLs.append(objectsIn: audio)
        record.audioSubtitlesURL = source.audioSubtitlesURL
        record.audioSubtitlesRoleRawValue = source.audioSubtitlesRoleRawValue
            ?? (source.audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil)
        record.autoOpenMediaPlayer = source.autoOpenMediaPlayer
        record.injectEntryImageIntoHeader = source.injectEntryImageIntoHeader
        record.publicationDate = source.publicationDate
        record.readerContentKind = source.readerContentKind
        record.feedEntryCollectionKey = source.feedEntryCollectionKey
        record.feedEntryCollectionScheme = source.feedEntryCollectionScheme
        record.feedEntryCollectionTerm = source.feedEntryCollectionTerm
        record.feedEntryCollectionTitle = source.feedEntryCollectionTitle
        record.isReaderModeByDefault = source.isReaderModeByDefault
        record.isReaderModeAvailable = source.isReaderModeAvailable
        record.isReaderModeOfferHidden = source.isReaderModeOfferHidden
        record.displayPublicationDate = source.displayPublicationDate
    }
}
