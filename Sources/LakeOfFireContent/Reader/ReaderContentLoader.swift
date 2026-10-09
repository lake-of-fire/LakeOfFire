import SwiftUI
import LakeOfFireCore
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



fileprivate extension URL {
    func settingScheme(_ value: String) -> URL {
        let components = NSURLComponents.init(url: self, resolvingAgainstBaseURL: true)
        components?.scheme = value
        return (components?.url!)!
    }
}

public extension URL {
    var isReaderURLLoaderURL: Bool {
        return scheme == "internal" && host == "local" && path == "/load/reader"
    }
}

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
    }

    private struct DiscoveryStorage: @unchecked Sendable {
        let bookmarkConfiguration: Realm.Configuration
        let historyConfiguration: Realm.Configuration
        let feedConfiguration: Realm.Configuration
        let bookmarkAdmission: RealmStorageAdmission
        let historyAdmission: RealmStorageAdmission
        let feedAdmission: RealmStorageAdmission
        let identity: DiscoveryStorageIdentity

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
            identity = DiscoveryStorageIdentity(bookmark: bookmark.scopeIdentity,
                history: history.scopeIdentity, feed: feed.scopeIdentity)
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
            let admission = content.objectSchema.objectClass == Bookmark.self ? bookmarkAdmission
                : content is FeedEntry ? feedAdmission : historyAdmission
            return ContentReference(content: content, storageAdmission: admission)
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

    public struct ContentReference {
        public let contentType: RealmSwift.Object.Type
        public let contentKey: String
        public let realmConfiguration: Realm.Configuration
        public let storageAdmission: RealmStorageAdmission
        
        public init?(content: any ReaderContentProtocol) {
            self.init(content: content, storageAdmission: nil)
        }

        public init?(content: any ReaderContentProtocol, storageAdmission: RealmStorageAdmission?) {
            guard !content.isInvalidated, let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type, let config = content.realm?.configuration else { return nil }
            self.contentType = contentType
            contentKey = content.compoundKey
            realmConfiguration = config
            self.storageAdmission = storageAdmission ?? RealmBackgroundActor.shared.captureStorageAdmission(for: config)
        }
        
        public func validateStorage() throws {
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        }

        @RealmBackgroundActor
        public func resolveOnBackgroundActor() async throws -> (any ReaderContentProtocol)? {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration, storageAdmission: storageAdmission)
            await realm.asyncRefresh()
            try validateStorage()
            try Task.checkCancellation()
            return realm.object(ofType: contentType, forPrimaryKey: contentKey) as? any ReaderContentProtocol
        }
        
        @MainActor
        public func resolveOnMainActor() async throws -> (any ReaderContentProtocol)? {
            try await RealmBackgroundActor.shared.prepareStorage(for: realmConfiguration, storageAdmission: storageAdmission)
            try validateStorage()
            let realm = try await Realm.open(configuration: realmConfiguration)
            try validateStorage()
            await realm.asyncRefresh()
            try validateStorage()
            try Task.checkCancellation()
            return realm.object(ofType: contentType, forPrimaryKey: contentKey) as? any ReaderContentProtocol
        }
    }
    
    public static var bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var historyRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration

    /// The storage selected when a snippet edit began. A delayed save must not
    /// follow mutable global configurations into another account's Realm.
    public struct SnippetStorage {
        public let bookmarkConfiguration: Realm.Configuration
        public let historyConfiguration: Realm.Configuration

        private init(
            bookmarkConfiguration: Realm.Configuration,
            historyConfiguration: Realm.Configuration
        ) {
            self.bookmarkConfiguration = bookmarkConfiguration
            self.historyConfiguration = historyConfiguration
        }

        /// The app stores both snippet representations in the selected
        /// content's Reader Realm. Its owning Realm outranks mutable globals.
        @MainActor
        public init?(content: any ReaderContentProtocol) {
            guard let configuration = content.realm?.configuration else { return nil }
            bookmarkConfiguration = configuration
            historyConfiguration = configuration
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
        pageURL.readerLoaderContentURL
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
            guard let content = destination.realm.object(ofType: destination.reference.contentType,
                forPrimaryKey: destination.reference.contentKey) as? any ReaderContentProtocol,
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
            return candidates.compactMap { storage.reference(for: $0) }
        }

        inFlightLoadAllTasks[taskKey] = task
        defer { inFlightLoadAllTasks[taskKey] = nil }
        return try await task.value
    }

    @RealmBackgroundActor
    private static func storedContentReference(
        for url: URL,
        storage: DiscoveryStorage
    ) async throws -> ReaderContentLoader.ContentReference? {
        try Task.checkCancellation()
        guard !(url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/")) else {
            return nil
        }
        guard url.absoluteString != "about:blank" else {
            return nil
        }

        let candidates = try await loadAll(
            url: url,
            skipContentFiles: false,
            skipFeedEntries: false,
            storage: storage
        )
        let match = candidates.max(by: {
            ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
        })
        guard let match else {
            return nil
        }
        return storage.reference(for: match)
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
        let resolvedURL = getContentURL(fromLoaderURL: url) ?? url
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
        let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL) ?? pageURL
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
            if let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL),
               let content = try await ReaderContentLoader.load(
                url: contentURL,
                persist: true,
                countsAsHistoryVisit: countsAsHistoryVisit,
                source: "\(source).loaderRedirect",
                storage: storage
               ) {
                try Task.checkCancellation()
                return content
            } else if let content = try await ReaderContentLoader.load(
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

    /// Update all reader-content objects that share the given URL. The updater returns true if it mutated the object.
    @RealmBackgroundActor
    public static func updateContent(
        url: URL,
        skipContentFiles: Bool = false,
        skipFeedEntries: Bool = false,
        mutate: (Object & ReaderContentProtocol) -> Bool
    ) async throws {
        let storage = DiscoveryStorage()
        let references = try await discoverContentReferences(
            url: url,
            skipContentFiles: skipContentFiles,
            skipFeedEntries: skipFeedEntries,
            storage: storage
        )
        let timestamp = Date()
        for reference in references {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: reference.realmConfiguration, storageAdmission: reference.storageAdmission)
            try await realm.asyncWritePreservingOwnership {
                // Realm's async transaction can begin after its caller was
                // cancelled (for example by a superseding WebView document).
                // Fence the actual commit, not only the preceding lookup.
                guard !Task.isCancelled else { return }
                try reference.validateStorage()
                guard let object = realm.object(ofType: reference.contentType,
                    forPrimaryKey: reference.contentKey) as? (Object & ReaderContentProtocol),
                    !object.isDeleted else { return }
                if mutate(object) {
                    object.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            }
        }
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
            
            if url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/") {
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
            guard let content = realm.object(ofType: reference.contentType,
                forPrimaryKey: reference.contentKey) as? any ReaderContentProtocol,
                !content.isDeleted else { return nil }
            return reference
        }
        await contentWriteGateForTesting?(.loadedContent)
        return try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            try reference.validateStorage()
            guard let content = realm.object(ofType: reference.contentType,
                forPrimaryKey: reference.contentKey) as? any ReaderContentProtocol else { return nil }
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
        let storage = DiscoveryStorage()
        let contentURL = content.url
        let canonicalReaderBackingURL = readerFileManager.canonicalReaderBackingURL(for: contentURL)
        let contentHasLocallyRetrievableHTML = try await hasLocallyRetrievableHTML(
            for: content,
            readerFileManager: readerFileManager
        )

        if contentURL.isSnippetURL {
            if contentHasLocallyRetrievableHTML, let loaderURL = readerLoaderURL(for: contentURL) {
                return loaderURL
            }
            return content.url
        }

        if ["http", "https"].contains(contentURL.scheme?.lowercased()) {
            if content.isReaderModeByDefault,
               contentHasLocallyRetrievableHTML,
               let loaderURL = readerLoaderURL(for: contentURL) {
                return loaderURL
            }

            if let matchingContent = try await lookupStoredContent(url: contentURL, storage: storage),
               matchingContent.isReaderModeByDefault,
               (try? await hasLocallyRetrievableHTML(
                    for: matchingContent,
                    readerFileManager: readerFileManager
               )) == true,
               let matchingURL = readerLoaderURL(for: matchingContent.url) {
                return matchingURL
            }
            return content.url
        }

        if let canonicalReaderBackingURL,
           !contentURL.isReaderFileURL {
            _ = try await readerFileManager.resolveReadableLocalURL(
                forReaderBackingURL: canonicalReaderBackingURL
            )
        }

        if contentURL.isReaderFileURL,
           contentHasLocallyRetrievableHTML,
           let loaderURL = readerLoaderURL(for: contentURL) {
            return loaderURL
        }
        
        return content.url
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
        guard let encodedURL = contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return URL(string: "internal://local/load/reader?reader-url=\(encodedURL)")
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
            guard let content = realm.object(ofType: reference.contentType,
                forPrimaryKey: reference.contentKey) as? any ReaderContentProtocol,
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
        try await appendSnippetHTML(appendedHTML, toContentURL: content.url)
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
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        guard contentURL.isSnippetURL, permitsCommit() else { return false }
        let normalizedAppendedHTML = normalizeSnippetSourceHTML(appendedHTML)
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, permitsCommit: permitsCommit
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
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard contentURL.isSnippetURL, !trimmedTitle.isEmpty, permitsCommit() else { return false }
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, permitsCommit: permitsCommit
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
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        guard contentURL.isSnippetURL, permitsCommit() else { return false }
        let normalizedHTML = snippetHTML(fromHTML: html)
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, permitsCommit: permitsCommit
            ) { object in
                // The unchanged draft is the exact source supplied to the
                // editor. Do not reserialize its body, even if current storage
                // has since received a newer body from another writer.
                let bodyIsUnchanged = html == object.html
                    || originalEditorHTML.map { $0 == html } == true
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
                    || (!bodyIsUnchanged && currentHTML != normalizedHTML)
                guard objectDidChange else { return false }
                object.title = resolvedTitleUpdate.title
                object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                if !bodyIsUnchanged && currentHTML != normalizedHTML {
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
        permitsCommit: @escaping @Sendable () -> Bool,
        mutate: (any ReaderContentProtocol) -> Bool
    ) async throws -> Bool {
        let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.bookmarkConfiguration
        )
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.historyConfiguration
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
                guard !Task.isCancelled, permitsCommit() else { throw CancellationError() }
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
                guard !Task.isCancelled, permitsCommit() else { throw CancellationError() }
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
        return UTType(filenameExtension: self.pathExtension) ?? .data
    }
}

// MARK: - User-owned Home imports

public extension ReaderContentLoader {
    enum ImportPayload: Sendable {
        case url(URL, fromClipboard: Bool = false)
        case html(String, fromClipboard: Bool)
    }

    /// Capture alongside the logical account admission, before permissions,
    /// transferable loading, OCR, or an actor hop can suspend the user action.
    struct ImportStorage {
        let bookmarks: Realm.Configuration
        let history: Realm.Configuration
        let feeds: Realm.Configuration

        @MainActor
        public static func capture() -> Self {
            Self(bookmarks: bookmarkRealmConfiguration,
                 history: historyRealmConfiguration,
                 feeds: feedEntryRealmConfiguration)
        }
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
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> ContentReference? {
        guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: storage.history)
        switch payload {
        case let .html(html, fromClipboard):
            let normalizedHTML = normalizeSnippetSourceHTML(html)
            let data = normalizedHTML.readerContentData
            let title = generatedSnippetTitle(fromSourceHTML: normalizedHTML) ?? ""
            return try await historyRealm.asyncWritePreservingOwnership { () throws -> ContentReference? in
                guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
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
                guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
                return ContentReference(content: record)
            }

        case let .url(url, fromClipboard):
            guard url.absoluteString != "about:blank",
                  !(url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/")) else {
                return nil
            }
            let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: storage.bookmarks)
            let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: storage.feeds)
            return try await historyRealm.asyncWritePreservingOwnership { () throws -> ContentReference? in
                guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
                // These are read-only source stores. All import writes, including
                // bookmark links and demotion metadata, stay in captured History.
                if bookmarkRealm != historyRealm { bookmarkRealm.refresh() }
                if feedRealm != historyRealm && feedRealm != bookmarkRealm { feedRealm.refresh() }
                let timestamp = Date()
                let source = importSource(for: url, bookmarks: bookmarkRealm,
                                          history: historyRealm, feeds: feedRealm)
                let record: HistoryRecord
                if let history = source as? HistoryRecord {
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
                    // Do not invoke configureBookmark: its legacy implementation
                    // schedules an unfenced Task after this transaction returns.
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
                if fromClipboard && record.url.isSnippetURL {
                    record.isFromClipboard = true
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
                guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
                return ContentReference(content: record)
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
