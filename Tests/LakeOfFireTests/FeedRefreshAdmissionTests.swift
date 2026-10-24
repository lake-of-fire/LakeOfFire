import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class FeedRefreshAdmissionTests: XCTestCase {
    func testNewRequestSupersedesOlderRequestForSameFeed() {
        let registry = FeedRefreshRegistry()
        let feedID = UUID()
        let old = registry.begin(feedID: feedID)
        let current = registry.begin(feedID: feedID)
        XCTAssertFalse(registry.isCurrent(old))
        XCTAssertTrue(registry.isCurrent(current))
    }

    func testOldCompletionCannotRetireNewerRequest() {
        let registry = FeedRefreshRegistry()
        let feedID = UUID()
        let old = registry.begin(feedID: feedID)
        let current = registry.begin(feedID: feedID)
        registry.end(old)
        XCTAssertTrue(registry.isCurrent(current))
        registry.end(current)
        XCTAssertFalse(registry.isCurrent(current))
    }

    func testDifferentFeedsHaveIndependentRequests() {
        let registry = FeedRefreshRegistry()
        let first = registry.begin(feedID: UUID())
        let second = registry.begin(feedID: UUID())
        registry.end(first)
        XCTAssertFalse(registry.isCurrent(first))
        XCTAssertTrue(registry.isCurrent(second))
    }

    func testCurrentRequestCanPublishMetadata() async throws {
        try await verifyWriterAdmission(change: .none, shouldCommit: true)
    }

    func testChangedURLRejectsMetadataInsideTransaction() async throws {
        try await verifyWriterAdmission(change: .url, shouldCommit: false)
    }

    func testDeletedFeedRejectsMetadataInsideTransaction() async throws {
        try await verifyWriterAdmission(change: .deleted, shouldCommit: false)
    }

    func testNewerRequestRejectsOldMetadataInsideTransaction() async throws {
        try await verifyWriterAdmission(change: .newRequest, shouldCommit: false)
    }

    func testRetiredRequestRejectsMetadataInsideTransaction() async throws {
        try await verifyWriterAdmission(change: .retired, shouldCommit: false)
    }

    private enum Change: Sendable {
        case none, url, deleted, newRequest, retired
    }

    @RealmBackgroundActor
    private func verifyWriterAdmission(change: Change, shouldCommit: Bool) async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Feed.self]
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let feed = Feed()
        let originalURL = URL(string: "https://example.com/original.xml")!
        feed.rssUrl = originalURL
        try realm.write { realm.add(feed) }

        let registry = FeedRefreshRegistry.shared
        let original = registry.begin(feedID: feed.id)
        var newest: FeedRefreshLease?
        defer {
            registry.end(original)
            if let newest { registry.end(newest) }
        }
        switch change {
        case .none:
            break
        case .url:
            try realm.write { feed.rssUrl = URL(string: "https://example.com/replacement.xml")! }
        case .deleted:
            try realm.write { feed.isDeleted = true }
        case .newRequest:
            newest = registry.begin(feedID: feed.id)
        case .retired:
            registry.end(original)
        }

        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            try await realm.asyncWritePreservingOwnership {
                try checkFeedRefreshIsCurrent(
                    in: realm, expectedRSSURL: originalURL, refreshLease: original
                )
                feed.lastRefreshedEntriesAt = completedAt
                feed.lastFetchedETag = "completed"
            }
            XCTAssertTrue(shouldCommit)
        } catch is CancellationError {
            XCTAssertFalse(shouldCommit)
        }
        XCTAssertEqual(feed.lastRefreshedEntriesAt, shouldCommit ? completedAt : nil)
        XCTAssertEqual(feed.lastFetchedETag, shouldCommit ? "completed" : nil)
    }
}
