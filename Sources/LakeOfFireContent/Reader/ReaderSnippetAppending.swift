import Foundation
import BigSyncKit
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps

public extension ReaderContentLoader {
    /// The destination accepted by one append action, before its task starts.
    /// Captured references carry storage/creation identity, never managed rows
    /// across the Realm actor boundary. Separate actions remain additive.
    struct SnippetAppendTarget: @unchecked Sendable {
        public let contentURL: URL
        fileprivate let origin: ReaderSnippetAppendOrigin
        fileprivate let command: ReaderSnippetAppendCommand

        @MainActor
        fileprivate init(content: any ReaderContentProtocol) {
            contentURL = content.url
            origin = ReaderSnippetAppendOrigin(content: content)
            command = ReaderSnippetAppendCommand(content: content)
        }

        /// Presentation may use only the original object and captured identity.
        /// Selection/account/navigation admission remains with the UI owner.
        @MainActor
        public func matchesPresentationContent(_ content: any ReaderContentProtocol) -> Bool {
            // Frozen captures can still authorize a durable append, but their
            // snapshot cannot supply a refreshed presentation. Realm's Swift
            // asyncRefresh actor precondition also excludes frozen Realms.
            guard let original = origin.originalContent(), original === content,
                  original.realm?.isFrozen != true else { return false }
            do {
                try command.primaryReference?.validateStorage()
                return true
            } catch {
                return false
            }
        }
    }

    @MainActor
    struct SnippetAppendResult {
        /// Actual settled changes, including an earlier group when a later
        /// cancellation withdraws remaining work. This is not cross-store atomicity.
        public let didChange: Bool
        /// Optional original presentation record after an identity-checked refresh.
        /// Its absence never erases the durable result or authorizes a URL reload.
        public let content: (any ReaderContentProtocol)?
    }

    /// A later Realm group failed after an earlier group committed. Appending
    /// the whole payload again is not a safe automatic retry of this operation.
    struct SnippetAppendPartialCommitError: Error {
        public let underlyingError: Error
        public var didChange: Bool { true }
    }

    @MainActor
    static func captureSnippetAppendTarget(
        for content: any ReaderContentProtocol
    ) -> SnippetAppendTarget? {
        guard !content.isInvalidated, !content.isDeleted, content.url.isSnippetURL else { return nil }
        let target = SnippetAppendTarget(content: content)
        guard content.realm == nil || target.command.primaryReference != nil else { return nil }
        return target
    }

    /// Persist an accepted append on its captured destination. Current HTML and
    /// generated-title policy are derived independently for each admitted row.
    /// The caller supplies its real captured account/command admission.
    @MainActor
    static func appendSnippetHTML(
        _ appendedHTML: String,
        to target: SnippetAppendTarget,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> SnippetAppendResult {
        try checkSnippetAppendAdmission(permitsCommit)
        let normalizedHTML = normalizedSnippetAppendHTML(appendedHTML, contentURL: target.contentURL)

        // An unmanaged capture grants authority only over its original local
        // object. Never discover a managed replacement by URL or promote it.
        if target.command.primaryReference == nil {
            guard let original = target.origin.originalContent(), original.realm == nil else {
                return SnippetAppendResult(didChange: false, content: nil)
            }
            try checkSnippetAppendAdmission(permitsCommit)
            guard target.origin.originalContent() === original, original.realm == nil else {
                return SnippetAppendResult(didChange: false, content: nil)
            }
            let didChange = applySnippetAppend(normalizedHTML, to: original)
            let presentation = !Task.isCancelled && permitsCommit()
                && target.matchesPresentationContent(original) ? original : nil
            return SnippetAppendResult(didChange: didChange, content: presentation)
        }

        let didChange = try await updateCapturedSnippetRecords(
            target: target, permitsCommit: permitsCommit
        ) { object in
            applySnippetAppend(normalizedHTML, to: object)
        }

        guard !Task.isCancelled, permitsCommit(),
              let original = target.origin.originalContent(),
              target.matchesPresentationContent(original) else {
            return SnippetAppendResult(didChange: didChange, content: nil)
        }
        if let realm = original.realm {
            do {
                try target.command.primaryReference?.validateStorage()
                await realm.asyncRefresh()
                try target.command.primaryReference?.validateStorage()
            } catch {
                // Optional presentation refresh cannot erase settled writes.
                return SnippetAppendResult(didChange: didChange, content: nil)
            }
        }
        guard !Task.isCancelled, permitsCommit(),
              target.matchesPresentationContent(original) else {
            return SnippetAppendResult(didChange: didChange, content: nil)
        }
        return SnippetAppendResult(didChange: didChange, content: original)
    }
}

@MainActor
fileprivate final class ReaderSnippetAppendOrigin {
    private weak var content: (any ReaderContentProtocol)?
    private let contentType: ObjectIdentifier
    private let contentKey: String
    private let contentURL: URL
    private let contentCreatedAt: Date
    private let wasManaged: Bool

    init(content: any ReaderContentProtocol) {
        self.content = content
        contentType = ObjectIdentifier(content.objectSchema.objectClass)
        contentKey = content.compoundKey
        contentURL = content.url
        contentCreatedAt = content.createdAt
        wasManaged = content.realm != nil
    }

    func originalContent() -> (any ReaderContentProtocol)? {
        guard let content, !content.isInvalidated, !content.isDeleted,
              ObjectIdentifier(content.objectSchema.objectClass) == contentType,
              content.compoundKey == contentKey, content.url == contentURL,
              content.createdAt == contentCreatedAt,
              (content.realm != nil) == wasManaged else { return nil }
        return content
    }
}

fileprivate struct ReaderSnippetAppendCommand: @unchecked Sendable {
    let primaryReference: ReaderContentLoader.ContentReference?
    let contentURL: URL
    let historyStore: ReaderSnippetAppendStore
    let feedStore: ReaderSnippetAppendStore
    let providers: [ReaderContentAdditionalProvider]

    @MainActor
    init(content: any ReaderContentProtocol) {
        primaryReference = ReaderContentLoader.ContentReference(content: content)
        contentURL = content.url
        historyStore = ReaderSnippetAppendStore(configuration: ReaderContentLoader.historyRealmConfiguration)
        feedStore = ReaderSnippetAppendStore(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
        providers = ReaderContentLoader.additionalContentProviders
    }
}

fileprivate struct ReaderSnippetAppendStore: @unchecked Sendable {
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

fileprivate func checkSnippetAppendAdmission(_ permitsCommit: @Sendable () -> Bool) throws {
    try Task.checkCancellation()
    guard permitsCommit() else { throw CancellationError() }
    try Task.checkCancellation()
}

extension ReaderContentLoader {
    /// The shipping append writer. The mutator prepares the existing append
    /// fields; this boundary owns resolution, transactions and sync metadata.
    @RealmBackgroundActor
    static func updateCapturedSnippetRecords(
        target: SnippetAppendTarget,
        permitsCommit: @escaping @Sendable () -> Bool,
        mutate: @RealmBackgroundActor (any ReaderContentProtocol) throws -> Bool
    ) async throws -> Bool {
        let command = target.command
        try checkSnippetAppendAdmission(permitsCommit)
        guard let primaryReference = command.primaryReference else { return false }
        try primaryReference.validateStorage()
        let references = try await snippetAppendReferences(command: command, permitsCommit: permitsCommit)

        // Every reference is immutable. Resolve live rows only after this
        // writer acquires each transaction; same-Realm representations settle
        // together and separate stores remain independently atomic.
        var groups = [(realm: Realm, references: [ContentReference])]()
        for reference in references {
            try checkSnippetAppendAdmission(permitsCommit)
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
            if didChange { invalidateCachedContent(for: command.contentURL) }
        }
        for group in groups {
            do {
                try checkSnippetAppendAdmission(permitsCommit)
                let result = try await group.realm.asyncWritePreservingOwnership { () throws -> (admitted: Bool, changed: Bool) in
                    try checkSnippetAppendAdmission(permitsCommit)
                    try primaryReference.validateStorage()
                    for reference in group.references { try reference.validateStorage() }

                    // The original primary wins over later URL discovery.
                    if group.references.contains(where: { sameSnippetAppendSlot($0, primaryReference) }) {
                        guard let primary = primaryReference.resolveForMutation(in: group.realm),
                              !primary.isDeleted else { return (false, false) }
                    }

                    let timestamp = Date()
                    var changed = false
                    var changedRecords = [(reference: ContentReference, record: any ReaderContentProtocol)]()
                    for reference in group.references {
                        try checkSnippetAppendAdmission(permitsCommit)
                        guard let record = reference.resolveForMutation(in: group.realm),
                              !record.isDeleted else { continue }
                        guard try mutate(record) else { continue }
                        record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                        try reference.validateStorage()
                        guard reference.matchesStoredIdentity(of: record), !record.isDeleted else {
                            throw CancellationError()
                        }
                        changedRecords.append((reference, record))
                        changed = true
                    }

                    try checkSnippetAppendAdmission(permitsCommit)
                    try primaryReference.validateStorage()
                    for reference in group.references { try reference.validateStorage() }
                    // A later metadata callback may retire an earlier row.
                    // Check admitted objects rather than recapturing successors.
                    for changedRecord in changedRecords {
                        guard changedRecord.reference.matchesStoredIdentity(of: changedRecord.record),
                              !changedRecord.record.isDeleted else { throw CancellationError() }
                    }
                    return (true, changed)
                }
                guard result.admitted else { return didChange }
                didChange = didChange || result.changed
            } catch is CancellationError {
                if didChange { return true }
                throw CancellationError()
            } catch {
                if didChange { throw SnippetAppendPartialCommitError(underlyingError: error) }
                throw error
            }
        }
        return didChange
    }
}

fileprivate extension ReaderContentLoader {
    @RealmBackgroundActor
    static func snippetAppendReferences(
        command: ReaderSnippetAppendCommand,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> [ContentReference] {
        let historyRealm = try await command.historyStore.open()
        try checkSnippetAppendAdmission(permitsCommit)
        let feedRealm = try await command.feedStore.open()
        try checkSnippetAppendAdmission(permitsCommit)
        try command.primaryReference?.validateStorage()
        try command.historyStore.validate()
        try command.feedStore.validate()

        var references = command.primaryReference.map { [$0] } ?? []
        // Preserve selected discovery: one canonical opened History record,
        // ContentFile/Bookmark representations and the existing feed fallback.
        // Do not expand an append into every historical visit of the URL.
        let candidates: [any ReaderContentProtocol] = [
            ContentFile.get(forURL: command.contentURL, realm: historyRealm),
            Bookmark.get(forURL: command.contentURL, realm: historyRealm),
            HistoryRecord.getOpenedRecord(forURL: command.contentURL, in: historyRealm),
        ].compactMap { $0 }
        references.append(contentsOf: candidates.compactMap {
            ContentReference(content: $0, configuration: command.historyStore.configuration,
                             storageAdmission: command.historyStore.admission)
        })

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

        // Snapshot built-ins before providers suspend, and use the providers
        // captured at the action rather than their mutable current registrations.
        for provider in command.providers {
            try checkSnippetAppendAdmission(permitsCommit)
            references.append(contentsOf: try await provider.load(command.contentURL))
            try checkSnippetAppendAdmission(permitsCommit)
        }

        var unique = [ContentReference]()
        for reference in references where !unique.contains(where: { sameSnippetAppendSlot($0, reference) }) {
            unique.append(reference)
        }
        return unique
    }

    static func sameSnippetAppendSlot(_ lhs: ContentReference, _ rhs: ContentReference) -> Bool {
        guard lhs.contentType == rhs.contentType, lhs.contentKey == rhs.contentKey else { return false }
        if let identifier = lhs.realmConfiguration.inMemoryIdentifier {
            return rhs.realmConfiguration.inMemoryIdentifier == identifier
        }
        guard rhs.realmConfiguration.inMemoryIdentifier == nil,
              let left = lhs.realmConfiguration.fileURL, let right = rhs.realmConfiguration.fileURL else { return false }
        return left.standardizedFileURL == right.standardizedFileURL
    }
}
