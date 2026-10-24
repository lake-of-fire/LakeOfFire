import Foundation
import BigSyncKit
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps

public extension ReaderContentLoader {
    /// Capture on the primary content's owner before suspending. This freezes
    /// discovery stores and provider registrations, not the reader selection.
    struct ReaderModePropagationContext: @unchecked Sendable {
        fileprivate let primaryReference: ContentReference?
        fileprivate let historyStore: ReaderModePropagationStore
        fileprivate let feedStore: ReaderModePropagationStore
        fileprivate let providers: [ReaderContentAdditionalProvider]

        public init(primaryContent: any ReaderContentProtocol) {
            self.init(primaryReference: ContentReference(content: primaryContent))
        }

        /// Mutations without a selected primary still capture the same stores
        /// and provider registrations before discovery suspends.
        public init() {
            self.init(primaryReference: nil)
        }

        private init(primaryReference: ContentReference?) {
            self.primaryReference = primaryReference
            historyStore = ReaderModePropagationStore(configuration: ReaderContentLoader.historyRealmConfiguration)
            feedStore = ReaderModePropagationStore(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
            providers = ReaderContentLoader.additionalContentProviders
        }
    }

    /// Share uncached discovery with generic mutations while preserving each
    /// caller's content-file and feed-entry exclusions.
    @RealmBackgroundActor
    internal static func contentMutationReferences(
        for url: URL,
        context: ReaderModePropagationContext,
        skipContentFiles: Bool,
        skipFeedEntries: Bool
    ) async throws -> [ContentReference] {
        try await readerModePropagationReferences(
            for: url, context: context,
            skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries
        )
    }

    /// Updates related stored representations without excluding another class
    /// or store that happens to use the primary record's key.
    /// Returns the number of related candidates whose record or owning Feed
    /// changed, counting each candidate once even when both owners changed.
    @RealmBackgroundActor
    @discardableResult
    static func propagateReaderModeDefaults(
        for url: URL,
        context: ReaderModePropagationContext,
        readabilityHTML: String,
        resolvedTitle: String?
    ) async throws -> Int {
        try Task.checkCancellation()
        guard !url.isSnippetURL else { return 0 }
        try context.primaryReference?.validateStorage()
        let references = try await readerModePropagationReferences(for: url, context: context)
        var updatedCount = 0

        for reference in references {
            try Task.checkCancellation()
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: reference.realmConfiguration,
                storageAdmission: reference.storageAdmission
            )
            let didChange = try await realm.asyncWritePreservingOwnership {
                try Task.checkCancellation()
                try context.primaryReference?.validateStorage()
                try reference.validateStorage()
                guard let record = reference.resolveForMutation(in: realm), !record.isDeleted,
                      context.primaryReference?.matchesStoredIdentity(of: record) != true else {
                    return false
                }
                // Admission can wait behind another authoritative edit. Sample
                // time here, then share it between this record and its Feed.
                let timestamp = Date()
                let changes = applyReaderModeDefaults(
                    to: record, for: url,
                    readabilityHTML: readabilityHTML, resolvedTitle: resolvedTitle,
                    at: timestamp
                )
                if changes.recordChanged {
                    record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
                // Metadata hooks can change storage or cancel the operation.
                // Revalidate after both owners' callouts before committing.
                try Task.checkCancellation()
                try context.primaryReference?.validateStorage()
                try reference.validateStorage()
                return changes.recordChanged || changes.ownerChanged
            }
            if didChange { updatedCount += 1 }
        }
        return updatedCount
    }
}

fileprivate struct ReaderModePropagationStore: @unchecked Sendable {
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
        try validate()
        return realm
    }
}

private extension ReaderContentLoader {
    @RealmBackgroundActor
    static func readerModePropagationReferences(
        for url: URL,
        context: ReaderModePropagationContext,
        skipContentFiles: Bool = false,
        skipFeedEntries: Bool = false
    ) async throws -> [ContentReference] {
        // Authoritative propagation must not consume the URL-only completed
        // loadAll cache or a task that captured another account's configuration.
        let historyRealm = try await context.historyStore.open()
        let feedRealm: Realm?
        if skipFeedEntries {
            feedRealm = nil
        } else {
            feedRealm = try await context.feedStore.open()
        }
        try Task.checkCancellation()
        try context.historyStore.validate()
        if !skipFeedEntries { try context.feedStore.validate() }

        var references = readerModeBuiltInPropagationReferences(
            for: url, context: context, historyRealm: historyRealm, feedRealm: feedRealm,
            skipContentFiles: skipContentFiles
        )
        for provider in context.providers {
            try Task.checkCancellation()
            let providerReferences = try await provider.load(url)
            try Task.checkCancellation()
            // Preserve the producer's original store and incarnation. Resolving
            // and recapturing here could silently adopt a same-key successor.
            references.append(contentsOf: providerReferences)
        }
        return references
    }

    @RealmBackgroundActor
    static func readerModeBuiltInPropagationReferences(
        for url: URL,
        context: ReaderModePropagationContext,
        historyRealm: Realm,
        feedRealm: Realm?,
        skipContentFiles: Bool
    ) -> [ContentReference] {
        // Preserve the selected history-store discovery policy, canonical
        // history matching, and HTTPS feed fallback. Snapshot before providers
        // suspend so a replacement cannot acquire the original row's identity.
        var references = [ContentReference]()
        let historyCandidates: [any ReaderContentProtocol] = [
            skipContentFiles ? nil : ContentFile.get(forURL: url, realm: historyRealm),
            Bookmark.get(forURL: url, realm: historyRealm),
            HistoryRecord.getOpenedRecord(forURL: url, in: historyRealm),
        ].compactMap { $0 }
        references.append(contentsOf: historyCandidates.compactMap {
            ContentReference(content: $0, configuration: context.historyStore.configuration,
                             storageAdmission: context.historyStore.admission)
        })

        guard let feedRealm else { return references }
        let feeds = feedRealm.objects(FeedEntry.self)
            .where { !$0.isDeleted }
            .sorted(by: \.createdAt, ascending: false)
        var feed: FeedEntry?
        if url.scheme == "https" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.scheme = "http"
            let fallbackURL = components?.url ?? url
            feed = feeds.filter(NSPredicate(
                format: "url == %@ OR url == %@",
                url.absoluteString as CVarArg, fallbackURL.absoluteString as CVarArg
            )).first
        } else if !url.isReaderFileURL {
            feed = feeds.filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg)).first
        }
        if let feed,
           let reference = ContentReference(content: feed, configuration: context.feedStore.configuration,
                                            storageAdmission: context.feedStore.admission) {
            references.append(reference)
        }

        return references
    }

    @RealmBackgroundActor
    static func applyReaderModeDefaults(
        to record: any ReaderContentProtocol,
        for url: URL,
        readabilityHTML: String,
        resolvedTitle: String?,
        at timestamp: Date
    ) -> (recordChanged: Bool, ownerChanged: Bool) {
        var changed = false
        var ownerChanged = false
        if !record.isReaderModeByDefault {
            record.isReaderModeByDefault = true
            // FeedEntry's mode setters expose policy without persisting it.
            // Count the resulting value, not an attempted assignment.
            changed = record.isReaderModeByDefault
        }
        if record.isReaderModeAvailable {
            record.isReaderModeAvailable = false
            changed = changed || !record.isReaderModeAvailable
        }
        if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
            if !url.isReaderFileURL, record.content?.isEmpty ?? true,
               record.html != readabilityHTML {
                record.html = readabilityHTML
                changed = true
            }
            if let resolvedTitle,
               record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               record.title != resolvedTitle {
                record.title = resolvedTitle
                changed = true
            }
            if let entry = record as? FeedEntry {
                // RSS completeness belongs to the Feed. Resolve and journal
                // that live owner in this same admitted transaction.
                if let feed = entry.getFeed(), !feed.isDeleted,
                   !feed.rssContainsFullContent {
                    feed.rssContainsFullContent = true
                    feed.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                    ownerChanged = true
                }
            } else if !record.rssContainsFullContent {
                record.rssContainsFullContent = true
                changed = changed || record.rssContainsFullContent
            }
        }
        return (changed, ownerChanged)
    }
}
