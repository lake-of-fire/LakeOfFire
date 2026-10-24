import Foundation
import RealmSwift
import RealmSwiftGaps

struct FeedRefreshLease: Sendable, Equatable {
    let feedID: UUID
    let generation: UUID
}

final class FeedRefreshRegistry: @unchecked Sendable {
    static let shared = FeedRefreshRegistry()

    private let lock = NSLock()
    private var currentGenerationByFeedID = [UUID: UUID]()

    func begin(feedID: UUID) -> FeedRefreshLease {
        let lease = FeedRefreshLease(feedID: feedID, generation: UUID())
        lock.lock()
        currentGenerationByFeedID[feedID] = lease.generation
        lock.unlock()
        return lease
    }

    func isCurrent(_ lease: FeedRefreshLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentGenerationByFeedID[lease.feedID] == lease.generation
    }

    func end(_ lease: FeedRefreshLease) {
        lock.lock()
        if currentGenerationByFeedID[lease.feedID] == lease.generation {
            currentGenerationByFeedID.removeValue(forKey: lease.feedID)
        }
        lock.unlock()
    }
}


/// Must be checked on the writer's Realm inside the admitted transaction.
/// This ports request-generation and URL fencing; it is not account/store fencing.
@RealmBackgroundActor
func checkFeedRefreshIsCurrent(
    in realm: Realm,
    expectedRSSURL: URL,
    refreshLease: FeedRefreshLease
) throws {
    try Task.checkCancellation()
    guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: refreshLease.feedID),
          !feed.isDeleted,
          feed.rssUrl == expectedRSSURL,
          FeedRefreshRegistry.shared.isCurrent(refreshLease) else {
        throw CancellationError()
    }
}
