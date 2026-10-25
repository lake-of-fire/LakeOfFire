import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

enum FeedViewProjectionKind: Hashable, Sendable {
    case entries, collections, followedStatus
}

enum FeedViewProjectionFailure: Error {
    case retiredSource
}

/// Capture on the presenting actor, before observer setup or a reload suspends.
/// Fresh references retain the original physical row across repeated reloads.
/// Keep the caller's actor-owned accessor rather than pinning a frozen version
/// for the retained model's lifetime. Only each short-lived reference travels.
@MainActor
struct FeedViewProjectionSource {
    let owner: FeedViewProjectionOwner
    let title: String
    private let feed: Feed

    init?(feed: Feed) {
        guard !feed.isInvalidated, let realm = feed.realm, !feed.isDeleted else { return nil }
        let configuration = realm.configuration
        owner = FeedViewProjectionOwner(
            feedID: feed.id, createdAt: feed.createdAt,
            canonicalURLKey: feed.canonicalFollowingFeedURLKey,
            configuration: configuration,
            storage: RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        )
        title = feed.title
        self.feed = feed
    }

    func request() throws -> FeedViewProjectionRequest {
        guard !feed.isInvalidated else { throw FeedViewProjectionFailure.retiredSource }
        return FeedViewProjectionRequest(owner: owner, reference: ThreadSafeReference(to: feed))
    }

    func matchesPresentedFeed(_ feed: Feed) -> Bool {
        guard !feed.isInvalidated, let realm = feed.realm, !feed.isDeleted,
              feed.id == owner.feedID,
              feed.createdAt == owner.createdAt,
              feed.canonicalFollowingFeedURLKey == owner.canonicalURLKey else { return false }
        return owner.storage.matchesCurrentStorageIdentity {
            RealmBackgroundActor.shared.realmCacheKey(for: realm.configuration)
        }
    }
}

struct FeedViewProjectionOwner: Sendable {
    let feedID: UUID
    let createdAt: Date
    let canonicalURLKey: String
    let configuration: Realm.Configuration
    let storage: RealmStorageAdmission

    var matchesStorage: Bool {
        storage.matchesCurrentStorageIdentity {
            RealmBackgroundActor.shared.realmCacheKey(for: configuration)
        }
    }

    // Synchronous, on the supplied Realm/accessor's current owning actor.
    // No live Realm or accessor is transferred between actors by this value.
    func contains(_ original: Feed, in realm: Realm) -> Bool {
        guard matchesStorage, !original.isInvalidated,
              let current = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
              current.isSameObject(as: original), !current.isDeleted,
              current.createdAt == createdAt,
              current.canonicalFollowingFeedURLKey == canonicalURLKey else { return false }
        return true
    }
}

struct FeedViewProjectionRequest: Sendable {
    let owner: FeedViewProjectionOwner
    let reference: ThreadSafeReference<Feed>

    @MainActor
    func openOnMainActor() async throws -> (Realm, Feed) {
        try Task.checkCancellation()
        guard owner.matchesStorage else { throw FeedViewProjectionFailure.retiredSource }
        let realm = try await Realm.open(configuration: owner.configuration)
        // The SDK forbids reference resolution inside a write. A peer can
        // hold this actor's cached Realm; queue without settling its write.
        while realm.isInWriteTransaction {
            try await realm.asyncWritePreservingOwnership { }
            try Task.checkCancellation()
        }
        return try resolve(in: realm)
    }

    @RealmBackgroundActor
    func openOnRealmActor() async throws -> (Realm, Feed) {
        try Task.checkCancellation()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: owner.configuration, storageAdmission: owner.storage
        )
        while realm.isInWriteTransaction {
            try await realm.asyncWritePreservingOwnership { }
            try Task.checkCancellation()
        }
        return try resolve(in: realm)
    }

    private func resolve(in realm: Realm) throws -> (Realm, Feed) {
        try Task.checkCancellation()
        guard owner.matchesStorage, !reference.isInvalidated,
              let feed = realm.resolve(reference), owner.contains(feed, in: realm) else {
            throw FeedViewProjectionFailure.retiredSource
        }
        return (realm, feed)
    }
}
