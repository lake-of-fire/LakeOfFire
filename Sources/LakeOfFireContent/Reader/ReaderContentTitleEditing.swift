import Foundation
import BigSyncKit
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps

/// Opaque equality for one captured title-edit record, without live Realm access.
public struct ReaderContentTitleEditIdentity: Hashable, Sendable {
    fileprivate enum Storage: Hashable, Sendable {
        case managed(String)
        case unmanaged(ObjectIdentifier)
    }

    fileprivate let storage: Storage
    fileprivate let contentType: ObjectIdentifier
    fileprivate let contentKey: String
    fileprivate let contentURL: URL
    fileprivate let contentCreatedAt: Date

    @MainActor
    fileprivate init(
        content: any ReaderContentProtocol,
        reference: ReaderContentLoader.ContentReference?
    ) {
        if let reference {
            storage = .managed(reference.storageAdmission.scopeIdentity)
            contentType = ObjectIdentifier(reference.contentType)
            contentKey = reference.contentKey
            contentURL = reference.contentURL
            contentCreatedAt = reference.contentCreatedAt
        } else {
            storage = .unmanaged(ObjectIdentifier(content))
            contentType = ObjectIdentifier(content.objectSchema.objectClass)
            contentKey = content.compoundKey
            contentURL = content.url
            contentCreatedAt = content.createdAt
        }
    }
}

public extension ReaderContent {
    /// An explicit edit's original record and storage, captured before a modal
    /// or debounce suspends. Navigation retirement only fences UI publication.
    struct TitleEditTarget: @unchecked Sendable {
        public typealias Identity = ReaderContentTitleEditIdentity
        public let identity: Identity
        public let initialTitle: String
        public let contentURL: URL
        fileprivate let origin: ReaderTitleEditOrigin
        fileprivate let command: ReaderTitleEditCommand

        @MainActor
        fileprivate init(reader: ReaderContent, content: any ReaderContentProtocol) {
            initialTitle = content.title
            contentURL = content.url
            origin = ReaderTitleEditOrigin(reader: reader, content: content)
            let captured = ReaderTitleEditCommand(content: content)
            command = captured
            identity = Identity(content: content, reference: captured.primaryReference)
        }
    }

    /// Capture on the displayed object's owner before any asynchronous work.
    func captureTitleEditTarget() -> TitleEditTarget? {
        guard let content, !content.isInvalidated, !content.isDeleted else { return nil }
        let target = TitleEditTarget(reader: self, content: content)
        guard content.realm == nil || target.command.primaryReference != nil else { return nil }
        return target
    }

    /// Returns actual committed changes. A later cancellation or navigation
    /// cannot undo a settled commit; it only suppresses stale UI publication.
    /// Distinct Realm groups settle independently. A storage/write error in a
    /// later group can therefore follow an earlier successful commit.
    @discardableResult
    func updateContentTitle(
        _ newTitle: String,
        target: TitleEditTarget,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, target.origin.reader === self else { return false }
        try checkTitleEditAdmission(permitsCommit)

        // An unmanaged capture grants only local-object authority. Do not
        // discover a managed replacement by URL or let an unrelated store or
        // provider failure prevent the selected local rename behavior.
        if target.command.primaryReference == nil {
            guard let original = target.origin.originalContent(), original.realm == nil else { return false }
            let prefix = original.url.isSnippetURL
                && ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
                    title, sourceHTML: original.html
                )
            try checkTitleEditAdmission(permitsCommit)
            guard target.origin.originalContent() === original, original.realm == nil else { return false }
            guard original.title != title || original.isTitlePrefixOfContent != prefix else { return false }
            original.title = title
            original.isTitlePrefixOfContent = prefix
            if !Task.isCancelled, permitsCommit(), target.origin.currentContent(in: self) != nil {
                refreshObservedContentState()
            }
            return true
        }

        let didChange = try await ReaderContentLoader.persistTitleEdit(
            title, command: target.command, permitsCommit: permitsCommit
        )

        guard !Task.isCancelled, permitsCommit(),
              let displayed = target.origin.currentContent(in: self) else { return didChange }
        if let realm = displayed.realm {
            // Refresh the original MainActor Realm, not an object reopened by
            // URL after account/storage/selection replacement.
            do {
                try target.command.primaryReference?.validateStorage()
                await realm.asyncRefresh()
                try target.command.primaryReference?.validateStorage()
            } catch {
                return didChange
            }
        }
        guard !Task.isCancelled, permitsCommit(),
              target.origin.currentContent(in: self) != nil else { return didChange }
        refreshObservedContentState()
        return didChange
    }
}

@MainActor
fileprivate final class ReaderTitleEditOrigin {
    weak var reader: ReaderContent?
    private weak var content: (any ReaderContentProtocol)?
    private let contentType: ObjectIdentifier
    private let contentKey: String
    private let contentURL: URL
    private let contentCreatedAt: Date
    private let selectionID: UUID?
    private let selectionIsCurrent: @Sendable () -> Bool

    init(reader: ReaderContent, content: any ReaderContentProtocol) {
        self.reader = reader
        self.content = content
        contentType = ObjectIdentifier(content.objectSchema.objectClass)
        contentKey = content.compoundKey
        contentURL = content.url
        contentCreatedAt = content.createdAt
        selectionID = reader.currentSelectionID
        selectionIsCurrent = reader.makeSelectionCommitFence(requiring: selectionID)
    }

    func originalContent() -> (any ReaderContentProtocol)? {
        guard let content, !content.isInvalidated, !content.isDeleted,
              ObjectIdentifier(content.objectSchema.objectClass) == contentType,
              content.compoundKey == contentKey, content.url == contentURL,
              content.createdAt == contentCreatedAt else { return nil }
        return content
    }

    func currentContent(in owner: ReaderContent) -> (any ReaderContentProtocol)? {
        guard reader === owner, selectionIsCurrent(),
              owner.currentSelectionID == selectionID,
              let original = originalContent(), let displayed = owner.content,
              displayed === original else { return nil }
        return original
    }
}

fileprivate struct ReaderTitleEditCommand: @unchecked Sendable {
    let primaryReference: ReaderContentLoader.ContentReference?
    let contentURL: URL
    let historyStore: ReaderTitleEditStore
    let feedStore: ReaderTitleEditStore
    let providers: [ReaderContentAdditionalProvider]

    @MainActor
    init(content: any ReaderContentProtocol) {
        primaryReference = ReaderContentLoader.ContentReference(content: content)
        contentURL = content.url
        historyStore = ReaderTitleEditStore(configuration: ReaderContentLoader.historyRealmConfiguration)
        feedStore = ReaderTitleEditStore(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
        providers = ReaderContentLoader.additionalContentProviders
    }
}

fileprivate struct ReaderTitleEditStore: @unchecked Sendable {
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

fileprivate func checkTitleEditAdmission(_ permitsCommit: @Sendable () -> Bool) throws {
    try Task.checkCancellation()
    guard permitsCommit() else { throw CancellationError() }
    try Task.checkCancellation()
}

fileprivate extension ReaderContentLoader {
    @RealmBackgroundActor
    static func persistTitleEdit(
        _ title: String,
        command: ReaderTitleEditCommand,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        try checkTitleEditAdmission(permitsCommit)
        try command.primaryReference?.validateStorage()
        let references = try await titleEditReferences(command: command, permitsCommit: permitsCommit)

        // Group the actual Realm owners before writing. Related representations
        // in the same store share one owned transaction and metadata timestamp.
        // Separate stores can settle independently; this is not global atomicity.
        var groups = [(realm: Realm, references: [ContentReference])]()
        for reference in references {
            try checkTitleEditAdmission(permitsCommit)
            try reference.validateStorage()
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: reference.realmConfiguration, storageAdmission: reference.storageAdmission
            )
            if let index = groups.firstIndex(where: { $0.realm == realm }) {
                groups[index].references.append(reference)
            } else {
                groups.append((realm, [reference]))
            }
        }

        var didChange = false
        defer {
            // A later store can fail or lose admission after an earlier group
            // settled. Its durable change must still invalidate discovery.
            if didChange { invalidateCachedContent(for: command.contentURL) }
        }
        for group in groups {
            do {
                try checkTitleEditAdmission(permitsCommit)
                let result = try await group.realm.asyncWritePreservingOwnership { () throws -> (admitted: Bool, changed: Bool) in
                    try checkTitleEditAdmission(permitsCommit)
                    try command.primaryReference?.validateStorage()
                    for reference in group.references { try reference.validateStorage() }

                    // The captured primary wins over URL discovery. A deleted or
                    // recreated primary must not authorize editing its successors
                    // or the other representations in this transaction.
                    if let primary = command.primaryReference,
                       group.references.contains(where: { sameTitleEditSlot($0, primary) }) {
                        guard let record = primary.resolveForMutation(in: group.realm),
                              !record.isDeleted else { return (false, false) }
                    }

                    let timestamp = Date()
                    var changed = false
                    var changedRecords = [(reference: ContentReference, record: any ReaderContentProtocol)]()
                    for reference in group.references {
                        try checkTitleEditAdmission(permitsCommit)
                        guard let record = reference.resolveForMutation(in: group.realm),
                              !record.isDeleted else { continue }
                        let prefix = record.url.isSnippetURL && snippetTitleMatchesGeneratedPrefix(
                            title, sourceHTML: record.html
                        )
                        guard record.title != title || record.isTitlePrefixOfContent != prefix else { continue }
                        record.title = title
                        record.isTitlePrefixOfContent = prefix
                        record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                        try reference.validateStorage()
                        guard reference.matchesStoredIdentity(of: record), !record.isDeleted else {
                            throw CancellationError()
                        }
                        changedRecords.append((reference, record))
                        changed = true
                    }

                    // Metadata hooks may retire account/storage authority. Throw
                    // while this writer still owns the transaction so it rolls back.
                    try checkTitleEditAdmission(permitsCommit)
                    try command.primaryReference?.validateStorage()
                    for reference in group.references { try reference.validateStorage() }
                    // A later metadata hook may retire an earlier changed row.
                    // Validate the actual admitted objects, never recapture a
                    // successor by key after such a callback.
                    for changedRecord in changedRecords {
                        guard changedRecord.reference.matchesStoredIdentity(of: changedRecord.record),
                              !changedRecord.record.isDeleted else { throw CancellationError() }
                    }
                    return (true, changed)
                }
                guard result.admitted else { return didChange }
                didChange = didChange || result.changed
            } catch is CancellationError {
                // Cancellation rolls back only the current owned group. Do
                // not report an earlier settled group as an uncommitted edit.
                if didChange { return true }
                throw CancellationError()
            }
        }
        return didChange
    }

    @RealmBackgroundActor
    static func titleEditReferences(
        command: ReaderTitleEditCommand,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> [ContentReference] {
        // Never use loadAll's URL-only completed cache or discover through
        // account defaults read after the explicit edit was captured.
        let historyRealm = try await command.historyStore.open()
        try checkTitleEditAdmission(permitsCommit)
        let feedRealm = try await command.feedStore.open()
        try checkTitleEditAdmission(permitsCommit)
        try command.primaryReference?.validateStorage()
        try command.historyStore.validate()
        try command.feedStore.validate()

        var references = command.primaryReference.map { [$0] } ?? []
        let candidates: [any ReaderContentProtocol] = [
            ContentFile.get(forURL: command.contentURL, realm: historyRealm),
            Bookmark.get(forURL: command.contentURL, realm: historyRealm),
            HistoryRecord.getOpenedRecord(forURL: command.contentURL, in: historyRealm),
        ].compactMap { $0 }
        references.append(contentsOf: candidates.compactMap {
            ContentReference(content: $0, configuration: command.historyStore.configuration,
                             storageAdmission: command.historyStore.admission)
        })

        // Retain the selected loader's feed fallback, including the record's
        // own URL in its captured mutation identity.
        let feeds = feedRealm.objects(FeedEntry.self)
            .where { !$0.isDeleted }
            .sorted(by: \.createdAt, ascending: false)
        var feed: FeedEntry?
        if command.contentURL.scheme == "https" {
            var components = URLComponents(url: command.contentURL, resolvingAgainstBaseURL: true)
            components?.scheme = "http"
            let fallbackURL = components?.url ?? command.contentURL
            feed = feeds.filter(NSPredicate(format: "url == %@ OR url == %@",
                command.contentURL.absoluteString as CVarArg, fallbackURL.absoluteString as CVarArg)).first
        } else if !command.contentURL.isReaderFileURL {
            feed = feeds.filter(NSPredicate(format: "url == %@", command.contentURL.absoluteString as CVarArg)).first
        }
        if let feed,
           let reference = ContentReference(content: feed, configuration: command.feedStore.configuration,
                                            storageAdmission: command.feedStore.admission) {
            references.append(reference)
        }

        // Built-ins are captured before a provider can suspend. Keep the
        // provider's supplied creation/store identity rather than recapturing it.
        for provider in command.providers {
            try checkTitleEditAdmission(permitsCommit)
            references.append(contentsOf: try await provider.load(command.contentURL))
            try checkTitleEditAdmission(permitsCommit)
        }

        var unique = [ContentReference]()
        for reference in references where !unique.contains(where: { sameTitleEditSlot($0, reference) }) {
            unique.append(reference)
        }
        return unique
    }

    static func sameTitleEditSlot(_ lhs: ContentReference, _ rhs: ContentReference) -> Bool {
        guard lhs.contentType == rhs.contentType, lhs.contentKey == rhs.contentKey else { return false }
        if let identifier = lhs.realmConfiguration.inMemoryIdentifier {
            return rhs.realmConfiguration.inMemoryIdentifier == identifier
        }
        guard rhs.realmConfiguration.inMemoryIdentifier == nil,
              let left = lhs.realmConfiguration.fileURL, let right = rhs.realmConfiguration.fileURL else { return false }
        return left.standardizedFileURL == right.standardizedFileURL
    }
}
