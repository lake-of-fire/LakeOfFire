import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

// The concrete Feed/FeedCategory `id` properties are persisted UUIDs. Select
// Realm's UInt64 protocol requirement, which identifies the physical row.
private func libraryFeedPhysicalRowID<T: ObjectKeyIdentifiable>(_ object: T) -> UInt64 {
    object.id
}

struct LibraryFeedPhysicalIdentity: Hashable, Sendable {
    let feedRowID: UInt64?
    let categoryRowID: UInt64?

    // Called only on the supplied Realm object's owner. No managed object is
    // retained or transported by the immutable, repeatable command identity.
    init(feed: Feed) {
        guard !feed.isInvalidated, feed.realm != nil else {
            feedRowID = nil
            categoryRowID = nil
            return
        }
        feedRowID = libraryFeedPhysicalRowID(feed)
        categoryRowID = feed.getCategory().flatMap { category in
            category.isInvalidated ? nil : libraryFeedPhysicalRowID(category)
        }
    }

    func matches(_ feed: Feed) -> Bool {
        guard let feedRowID, !feed.isInvalidated, feed.realm != nil,
              libraryFeedPhysicalRowID(feed) == feedRowID else { return false }
        let currentCategoryRowID = feed.getCategory().flatMap { category in
            category.isInvalidated ? nil : libraryFeedPhysicalRowID(category)
        }
        return currentCategoryRowID == categoryRowID
    }
}

final class LibraryFeedWriteOrdering: @unchecked Sendable {
    private struct Scope: Hashable {
        let storage: String
        let encryptionKey: Data?
        let schemaVersion: UInt64
        let feedID: UUID
        let createdAt: Date
        let categoryID: UUID?
        let categoryCreatedAt: Date?
        let physicalIdentity: LibraryFeedPhysicalIdentity
    }
    private final class WeakOrdering {
        weak var value: LibraryFeedWriteOrdering?
        init(_ value: LibraryFeedWriteOrdering) { self.value = value }
    }
    @MainActor private static var orderings: [Scope: WeakOrdering] = [:]
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var newest: [LibraryFeedEditorField: UInt64] = [:]

    @MainActor
    static func shared(
        configuration: Realm.Configuration, storageAdmission: RealmStorageAdmission,
        feedID: UUID, createdAt: Date, categoryID: UUID?, categoryCreatedAt: Date?,
        physicalIdentity: LibraryFeedPhysicalIdentity
    ) -> LibraryFeedWriteOrdering {
        orderings = orderings.filter { $0.value.value != nil }
        let scope = Scope(
            storage: storageAdmission.scopeIdentity,
            encryptionKey: configuration.encryptionKey, schemaVersion: configuration.schemaVersion,
            feedID: feedID, createdAt: createdAt,
            categoryID: categoryID, categoryCreatedAt: categoryCreatedAt,
            physicalIdentity: physicalIdentity
        )
        if let existing = orderings[scope]?.value { return existing }
        let ordering = LibraryFeedWriteOrdering()
        orderings[scope] = WeakOrdering(ordering)
        return ordering
    }

    // Input publication reserves its order before debounce or any actor hop.
    func issueSequence(field: LibraryFeedEditorField) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        newest[field] = sequence
        return sequence
    }

    // Plain transient input admission only; no persisted field clocks or sync merge policy.
    func withAdmission(field: LibraryFeedEditorField, sequence: UInt64, apply: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard newest[field] == sequence else { return }
        apply()
    }

    func snapshot() -> [LibraryFeedEditorField: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return newest
    }

    func withMetadataAdmission(
        field: LibraryFeedEditorField, expected: [LibraryFeedEditorField: UInt64], apply: () -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard newest[field] == expected[field], newest[.url] == expected[.url] else { return }
        apply()
    }
}

enum LibraryFeedEditorField: Int, Hashable, Sendable {
    case title, description, enabled, url, iconURL, readerMode, headerImage
    case extractImage, fullContent, publicationDate
}

struct LibraryFeedOpenGraphMetadata: Sendable {
    let url: URL?
    let title: String?
    let description: String?
}

struct LibraryFeedMetadataRequest: Sendable {
    let identifier: UUID
    let rssURL: URL
    let revisions: [LibraryFeedEditorField: UInt64]
    let sharedIntents: [LibraryFeedEditorField: UInt64]
}

// Only plain input revisions cross actors. Realm objects stay on their owner.
// The lock makes synchronous UI input publication visible in the final writer
// without suspending a Realm transaction to consult MainActor state.
final class LibraryFeedMetadataAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier = UUID()
    private var revisions: [LibraryFeedEditorField: UInt64] = [:]
    private var values: [LibraryFeedEditorField: String] = [:]

    func update(field: LibraryFeedEditorField, value: String, isUserEdit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isUserEdit || values[field] != value {
            revisions[field, default: 0] &+= 1
        }
        values[field] = value
    }

    func begin(identifier: UUID, rssURL: URL, sharedIntents: [LibraryFeedEditorField: UInt64]) -> LibraryFeedMetadataRequest {
        lock.lock()
        defer { lock.unlock() }
        self.identifier = identifier
        return LibraryFeedMetadataRequest(
            identifier: identifier, rssURL: rssURL, revisions: revisions, sharedIntents: sharedIntents
        )
    }

    // An old task can retire only its own metadata generation.
    func invalidate(identifier expectedIdentifier: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard identifier == expectedIdentifier else { return }
        identifier = UUID()
    }

    func admits(_ request: LibraryFeedMetadataRequest, field: LibraryFeedEditorField) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identifier == request.identifier
            && values[.url] == request.rssURL.absoluteString
            && revisions[.url] == request.revisions[.url]
            && revisions[field] == request.revisions[field]
            && (values[field] ?? "").isEmpty
    }
}

struct LibraryFeedFieldCommand: Sendable {
    let feedID: UUID
    let feedCreatedAt: Date
    let categoryID: UUID?
    let categoryCreatedAt: Date?
    let physicalIdentity: LibraryFeedPhysicalIdentity
    let realmConfiguration: Realm.Configuration
    let storageAdmission: RealmStorageAdmission
    let field: LibraryFeedEditorField
    let sequence: UInt64
    let metadataIntent: [LibraryFeedEditorField: UInt64]?
    let writeOrdering: LibraryFeedWriteOrdering
    let apply: @RealmBackgroundActor @Sendable (Feed) -> Bool

    @RealmBackgroundActor
    func write(beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration, storageAdmission: storageAdmission
        )
        try await beforeWrite?()
        try Task.checkCancellation()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
                  physicalIdentity.matches(feed),
                  feed.createdAt == feedCreatedAt, feed.categoryID == categoryID,
                  !feed.isDeleted, let categoryID,
                  let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                  category.createdAt == categoryCreatedAt, !category.isDeleted,
                  !category.isArchived, category.opmlURL == nil else { return }
            let applyChange = {
                let previousRSSURL = feed.rssUrl
                guard apply(feed) else { return }
                if feed.rssUrl != previousRSSURL {
                    feed.lastFetchedETag = nil
                    feed.lastFetchedModifiedAt = nil
                    feed.lastRefreshedEntriesAt = nil
                }
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
            if let metadataIntent {
                writeOrdering.withMetadataAdmission(field: field, expected: metadataIntent, apply: applyChange)
            } else {
                writeOrdering.withAdmission(field: field, sequence: sequence, apply: applyChange)
            }
        }
    }
}
