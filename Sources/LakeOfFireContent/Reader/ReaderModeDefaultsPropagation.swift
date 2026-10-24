import Foundation
import BigSyncKit
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps

public extension ReaderContentLoader {
    /// Capture on the primary content's owner before suspending. The caller
    /// captures its selection fence before resolving or preparing that content.
    /// Legacy propagation callers may omit the fence; Reader-mode rendering
    /// supplies the originating ReaderContent selection's withdraw-only permit.
    struct ReaderModePropagationContext: @unchecked Sendable {
        fileprivate let primaryReference: ContentReference?
        fileprivate let historyStore: ReaderModePropagationStore
        fileprivate let feedStore: ReaderModePropagationStore
        fileprivate let providers: [ReaderContentAdditionalProvider]
        fileprivate let permitsCommit: @Sendable () -> Bool

        public init(
            primaryContent: any ReaderContentProtocol,
            permitsCommit: @escaping @Sendable () -> Bool = { true }
        ) {
            primaryReference = ContentReference(content: primaryContent)
            historyStore = ReaderModePropagationStore(configuration: ReaderContentLoader.historyRealmConfiguration)
            feedStore = ReaderModePropagationStore(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
            providers = ReaderContentLoader.additionalContentProviders
            self.permitsCommit = permitsCommit
        }

        fileprivate func validateOrigin() throws {
            try Task.checkCancellation()
            guard permitsCommit() else { throw CancellationError() }
            try primaryReference?.validateStorage()
        }
    }

    /// Persists only the captured primary representation. Unmanaged content has
    /// no durable target. This does not use the generic content writer or TSR
    /// transfer; the existing captured identity is resolved at owned admission.
    @RealmBackgroundActor
    @discardableResult
    static func persistPrimaryReaderModeDefaults(
        context: ReaderModePropagationContext,
        readabilityHTML: String?,
        resolvedTitle: String?
    ) async throws -> Bool {
        try context.validateOrigin()
        guard let reference = context.primaryReference else { return false }
        return try await updateReaderModeDefaults(
            reference: reference, context: context, for: reference.contentURL,
            readabilityHTML: readabilityHTML, resolvedTitle: resolvedTitle,
            isPrimary: true
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
        try context.validateOrigin()
        guard !url.isSnippetURL else { return 0 }
        let references = try await readerModePropagationReferences(for: url, context: context)
        var updatedCount = 0

        for reference in references {
            let didChange = try await updateReaderModeDefaults(
                reference: reference, context: context, for: url,
                readabilityHTML: readabilityHTML, resolvedTitle: resolvedTitle,
                isPrimary: false
            )
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
    static func updateReaderModeDefaults(
        reference: ContentReference,
        context: ReaderModePropagationContext,
        for url: URL,
        readabilityHTML: String?,
        resolvedTitle: String?,
        isPrimary: Bool
    ) async throws -> Bool {
        try context.validateOrigin()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: reference.realmConfiguration,
            storageAdmission: reference.storageAdmission
        )
        return try await realm.asyncWritePreservingOwnership {
            try context.validateOrigin()
            try reference.validateStorage()
            guard let record = reference.resolveForMutation(in: realm), !record.isDeleted,
                  isPrimary || context.primaryReference?.matchesStoredIdentity(of: record) != true else {
                return false
            }
            // Admission can wait behind another authoritative edit. Sample
            // time here, then share it between this record and its Feed.
            let timestamp = Date()
            let changes = applyReaderModeDefaults(
                to: record, for: url,
                readabilityHTML: readabilityHTML, resolvedTitle: resolvedTitle,
                isPrimary: isPrimary, at: timestamp
            )
            if changes.recordChanged {
                record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            }
            // Metadata hooks can withdraw the selection, replace storage or
            // change the row. Reject those effects inside our owned transaction.
            try context.validateOrigin()
            try reference.validateStorage()
            guard reference.matchesStoredIdentity(of: record), !record.isDeleted else {
                throw CancellationError()
            }
            return changes.recordChanged || changes.ownerChanged
        }
    }

    @RealmBackgroundActor
    static func readerModePropagationReferences(
        for url: URL,
        context: ReaderModePropagationContext
    ) async throws -> [ContentReference] {
        // Authoritative propagation must not consume the URL-only completed
        // loadAll cache or a task that captured another account's configuration.
        let historyRealm = try await context.historyStore.open()
        try context.validateOrigin()
        let feedRealm = try await context.feedStore.open()
        try context.validateOrigin()
        try context.historyStore.validate()
        try context.feedStore.validate()

        var references = readerModeBuiltInPropagationReferences(
            for: url, context: context, historyRealm: historyRealm, feedRealm: feedRealm
        )
        for provider in context.providers {
            try context.validateOrigin()
            let providerReferences = try await provider.load(url)
            try context.validateOrigin()
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
        feedRealm: Realm
    ) -> [ContentReference] {
        // Preserve the selected history-store discovery policy, canonical
        // history matching, and HTTPS feed fallback. Snapshot before providers
        // suspend so a replacement cannot acquire the original row's identity.
        var references = [ContentReference]()
        let historyCandidates: [any ReaderContentProtocol] = [
            ContentFile.get(forURL: url, realm: historyRealm),
            Bookmark.get(forURL: url, realm: historyRealm),
            HistoryRecord.getOpenedRecord(forURL: url, in: historyRealm),
        ].compactMap { $0 }
        references.append(contentsOf: historyCandidates.compactMap {
            ContentReference(content: $0, configuration: context.historyStore.configuration,
                             storageAdmission: context.historyStore.admission)
        })

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
        readabilityHTML: String?,
        resolvedTitle: String?,
        isPrimary: Bool,
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
        if isPrimary, record.isReaderModeOfferHidden {
            record.isReaderModeOfferHidden = false
            changed = changed || !record.isReaderModeOfferHidden
        }
        if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
            if let readabilityHTML, !url.isReaderFileURL, record.content?.isEmpty ?? true,
               record.html != readabilityHTML {
                record.html = readabilityHTML
                changed = true
            }
            let titleIsEmpty = isPrimary ? record.title.isEmpty
                : record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let resolvedTitle, titleIsEmpty,
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
