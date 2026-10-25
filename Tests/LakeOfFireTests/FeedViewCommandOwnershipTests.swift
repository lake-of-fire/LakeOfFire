import Foundation
import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
import LakeOfFireContent
import LakeOfFireReader
@testable import LakeOfFireLibrary

private actor FeedCommandGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(entered: XCTestExpectation) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class FeedViewCommandOwnershipTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let realm: Realm
        let feed: Feed
        var configuration: Realm.Configuration { realm.configuration }
    }

    private enum CommandKind: CaseIterable {
        case following, viewed, seen

        @MainActor
        func capture(_ feed: Feed) -> FeedViewCommand? {
            switch self {
            case .following: return FeedViewCommand.following(true, feed: feed)
            case .viewed: return FeedViewCommand.markingViewed(feed: feed)
            case .seen: return FeedViewCommand.markingAllEntriesSeen(feed: feed, hasEntries: true)
            }
        }
    }

    private func fixture(
        id: UUID = UUID(), fileURL: URL? = nil,
        url: URL = URL(string: "https://example.com/feed.xml")!
    ) async throws -> Fixture {
        var configuration = Realm.Configuration()
        if let fileURL { configuration.fileURL = fileURL }
        else { configuration.inMemoryIdentifier = "feed-command-\(UUID())" }
        configuration.objectTypes = [Feed.self, FeedEntry.self, HistoryRecord.self, Bookmark.self, ContentFile.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let feed = Feed()
        feed.id = id
        feed.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        feed.title = "Original"
        feed.rssUrl = url
        feed.iconUrl = url
        try realm.write {
            realm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true, at: feed.createdAt)
        }
        return Fixture(realm: realm, feed: feed)
    }

    private func generations(_ realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }

    @RealmBackgroundActor
    private static func mutate(
        _ configuration: Realm.Configuration,
        _ operation: @RealmBackgroundActor @Sendable (Realm) throws -> Void
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await realm.asyncWritePreservingOwnership { try operation(realm) }
    }

    private func assertUnchanged(_ fixture: Fixture, generations before: [String: String]) {
        fixture.realm.refresh()
        XCTAssertFalse(fixture.feed.isFollowed)
        XCTAssertNil(fixture.feed.followingOrdinal)
        XCTAssertNil(fixture.feed.lastViewedAt)
        XCTAssertNil(fixture.feed.lastSeenFeedEntriesAt)
        XCTAssertEqual(generations(fixture.realm), before)
    }

    func testEveryCapturedCommandKeepsDisplayedStoreWhenGlobalConfigurationChanges() async throws {
        let saved = ReaderContentLoader.feedEntryRealmConfiguration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = saved }
        for kind in CommandKind.allCases {
            let original = try await fixture()
            let replacement = try await fixture(id: original.feed.id)
            XCTAssertEqual(original.feed.createdAt, replacement.feed.createdAt)
            ReaderContentLoader.feedEntryRealmConfiguration = original.configuration
            // ObservedRealmObject supplies a frozen presentation object.
            let command = try XCTUnwrap(kind.capture(original.feed.freeze()))
            let originalGenerations = generations(original.realm)
            let replacementGenerations = generations(replacement.realm)
            let explicitDate = original.feed.explicitlyModifiedAt
            let modifiedDate = original.feed.modifiedAt
            ReaderContentLoader.feedEntryRealmConfiguration = replacement.configuration

            try await command.write()
            original.realm.refresh()
            assertUnchanged(replacement, generations: replacementGenerations)
            switch kind {
            case .following:
                XCTAssertTrue(original.feed.isFollowed)
                XCTAssertNotNil(original.feed.followingOrdinal)
                XCTAssertNotEqual(generations(original.realm), originalGenerations)
                XCTAssertGreaterThan(original.feed.explicitlyModifiedAt ?? .distantPast, explicitDate ?? .distantPast)
            case .viewed:
                XCTAssertNotNil(original.feed.lastViewedAt)
                XCTAssertNil(original.feed.lastSeenFeedEntriesAt)
                XCTAssertEqual(generations(original.realm), originalGenerations)
                XCTAssertEqual(original.feed.explicitlyModifiedAt, explicitDate)
                XCTAssertEqual(original.feed.modifiedAt, modifiedDate)
            case .seen:
                XCTAssertNotNil(original.feed.lastSeenFeedEntriesAt)
                XCTAssertNil(original.feed.lastViewedAt)
                XCTAssertEqual(generations(original.realm), originalGenerations)
                XCTAssertEqual(original.feed.explicitlyModifiedAt, explicitDate)
                XCTAssertEqual(original.feed.modifiedAt, modifiedDate)
            }
        }
    }

    func testFollowingPreservesCanonicalGroupOrderNoOpAndUnfollowJournaling() async throws {
        let fixture = try await fixture()
        let duplicate = Feed()
        duplicate.rssUrl = URL(string: "https://EXAMPLE.com:443/feed.xml#duplicate")!
        duplicate.iconUrl = duplicate.rssUrl
        duplicate.followingOrdinal = 4
        let unrelated = Feed()
        unrelated.rssUrl = URL(string: "https://example.com/other.xml")!
        unrelated.iconUrl = unrelated.rssUrl
        unrelated.isFollowed = true
        unrelated.followingOrdinal = 9
        try fixture.realm.write {
            fixture.realm.add([duplicate, unrelated])
            duplicate.refreshChangeMetadata(explicitlyModified: true)
            unrelated.refreshChangeMetadata(explicitlyModified: true)
        }
        let unrelatedDate = unrelated.explicitlyModifiedAt
        let following = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        try await following.write()
        fixture.realm.refresh()
        XCTAssertTrue(fixture.feed.isFollowed)
        XCTAssertTrue(duplicate.isFollowed)
        XCTAssertEqual(fixture.feed.followingOrdinal, 4)
        XCTAssertEqual(duplicate.followingOrdinal, 4)
        XCTAssertEqual(fixture.feed.explicitlyModifiedAt, duplicate.explicitlyModifiedAt)
        let afterFollowing = generations(fixture.realm)
        let afterFollowingDate = fixture.feed.explicitlyModifiedAt

        // Reusing an already consumed reference must not throw an ObjC exception.
        try await following.write()
        let repeated = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        try await repeated.write()
        fixture.realm.refresh()
        XCTAssertEqual(generations(fixture.realm), afterFollowing)
        XCTAssertEqual(fixture.feed.explicitlyModifiedAt, afterFollowingDate)

        let unfollow = try XCTUnwrap(FeedViewCommand.following(false, feed: fixture.feed.freeze()))
        try await unfollow.write()
        fixture.realm.refresh()
        XCTAssertFalse(fixture.feed.isFollowed)
        XCTAssertFalse(duplicate.isFollowed)
        XCTAssertEqual(fixture.feed.followingOrdinal, 4)
        XCTAssertEqual(duplicate.followingOrdinal, 4)
        XCTAssertNotEqual(generations(fixture.realm), afterFollowing)
        XCTAssertTrue(unrelated.isFollowed)
        XCTAssertEqual(unrelated.followingOrdinal, 9)
        XCTAssertEqual(unrelated.explicitlyModifiedAt, unrelatedDate)
    }

    func testRetainedAppearanceSourceMakesFreshReferenceAfterCancelledInvocation() async throws {
        let original = try await fixture()
        let replacement = try await fixture(id: original.feed.id)
        let source = try XCTUnwrap(FeedViewCommandSource(feed: original.feed.freeze()))
        let originalGenerations = generations(original.realm)
        let replacementGenerations = generations(replacement.realm)
        let firstAppearance = try XCTUnwrap(source.markingViewed())
        let gate = FeedCommandGate()
        let resolved = expectation(description: "First appearance consumed its reference")
        let write = Task {
            try await firstAppearance.write(beforeWrite: { await gate.wait(entered: resolved) })
        }
        addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
        await fulfillment(of: [resolved], timeout: 5)
        write.cancel()
        await gate.release()
        switch await write.result {
        case .success: XCTFail("Cancelled appearance succeeded")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        assertUnchanged(original, generations: originalGenerations)
        let saved = ReaderContentLoader.feedEntryRealmConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacement.configuration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = saved }

        // Reinvoke the actual appearance producer without recapturing its owner
        // or relying on SwiftUI to evaluate body again after reappearance.
        let secondAppearance = try XCTUnwrap(source.markingViewed())
        try await secondAppearance.write()
        original.realm.refresh()
        XCTAssertNotNil(original.feed.lastViewedAt)
        XCTAssertEqual(generations(original.realm), originalGenerations)
        assertUnchanged(replacement, generations: replacementGenerations)
    }

    func testAppearanceSourcePreservesAlreadySeenEmptyFeedEligibility() async throws {
        let fixture = try await fixture()
        try fixture.realm.write { fixture.feed.lastViewedAt = Date() }
        let source = try XCTUnwrap(FeedViewCommandSource(feed: fixture.feed.freeze()))
        XCTAssertNil(source.markingViewed())
        XCTAssertNil(FeedViewCommand.markingViewed(feed: fixture.feed.freeze()))
    }

    func testCaptureRejectsUnmanagedDeletedAndIneligibleSources() async throws {
        let unmanaged = Feed()
        for kind in CommandKind.allCases { XCTAssertNil(kind.capture(unmanaged)) }
        let fixture = try await fixture()
        try fixture.realm.write { fixture.feed.entryContentKind = .contentListing }
        XCTAssertNil(FeedViewCommand.following(true, feed: fixture.feed))
        XCTAssertNil(FeedViewCommand.markingAllEntriesSeen(feed: fixture.feed, hasEntries: false))
        try fixture.realm.write { fixture.feed.showsUnseenBadge = false }
        XCTAssertNil(FeedViewCommand.markingAllEntriesSeen(feed: fixture.feed, hasEntries: true))
        try fixture.realm.write { fixture.feed.isDeleted = true }
        for kind in CommandKind.allCases { XCTAssertNil(kind.capture(fixture.feed)) }
        try fixture.realm.write { fixture.realm.delete(fixture.feed) }
        for kind in CommandKind.allCases { XCTAssertNil(kind.capture(fixture.feed)) }
    }

    func testRetargetedFeedRejectsCapturedCommandsBeforeResolution() async throws {
        for kind in CommandKind.allCases {
            let fixture = try await fixture()
            let alias = Feed()
            alias.rssUrl = fixture.feed.rssUrl
            alias.iconUrl = alias.rssUrl
            try fixture.realm.write {
                fixture.realm.add(alias)
                alias.refreshChangeMetadata(explicitlyModified: true)
            }
            let command = try XCTUnwrap(kind.capture(fixture.feed.freeze()))
            let id = fixture.feed.id
            try await Self.mutate(fixture.configuration) { realm in
                let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id))
                feed.rssUrl = URL(string: "https://example.com/replacement.xml")!
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
            fixture.realm.refresh()
            let before = generations(fixture.realm)
            try await command.write()
            assertUnchanged(fixture, generations: before)
            // The original group still exists. A missing source-URL guard
            // would follow this alias even though the displayed row moved.
            XCTAssertFalse(alias.isFollowed)
            XCTAssertNil(alias.followingOrdinal)
        }
    }

    func testEqualFieldPhysicalRecreationBeforeResolutionDoesNotRetargetCommand() async throws {
        let fixture = try await fixture()
        let command = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        let id = fixture.feed.id
        let createdAt = fixture.feed.createdAt
        let url = fixture.feed.rssUrl
        try await Self.mutate(fixture.configuration) { realm in
            let old = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id))
            realm.delete(old)
            let replacement = Feed()
            replacement.id = id
            replacement.createdAt = createdAt
            replacement.rssUrl = url
            replacement.iconUrl = url
            realm.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let replacement = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: id))
        let before = generations(fixture.realm)
        try await command.write()
        fixture.realm.refresh()
        XCTAssertFalse(replacement.isFollowed)
        XCTAssertNil(replacement.followingOrdinal)
        XCTAssertEqual(generations(fixture.realm), before)
    }

    func testEqualFieldPhysicalRecreationAfterResolutionRetiresOriginalAccessor() async throws {
        for kind in CommandKind.allCases {
            let fixture = try await fixture()
            let command = try XCTUnwrap(kind.capture(fixture.feed.freeze()))
            let id = fixture.feed.id
            let createdAt = fixture.feed.createdAt
            let url = fixture.feed.rssUrl
            let gate = FeedCommandGate()
            let resolved = expectation(description: "Original accessor resolved")
            let write = Task { try await command.write(beforeWrite: { await gate.wait(entered: resolved) }) }
            addTeardownBlock { await gate.release(); _ = await write.result }
            await fulfillment(of: [resolved], timeout: 5)
            try await Self.mutate(fixture.configuration) { realm in
                let old = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id))
                realm.delete(old)
                let replacement = Feed()
                replacement.id = id
                replacement.createdAt = createdAt
                replacement.rssUrl = url
                replacement.iconUrl = url
                realm.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
            }
            fixture.realm.refresh()
            let replacement = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: id))
            let before = generations(fixture.realm)
            await gate.release()
            try await write.value
            assertUnchanged(Fixture(realm: fixture.realm, feed: replacement), generations: before)
        }
    }

    func testFinalAdmissionRevalidatesLiveCreationURLAndFollowingCapability() async throws {
        for invalidation in ["soft-delete", "created-at", "url", "content-listing"] {
            let fixture = try await fixture()
            let command = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
            let id = fixture.feed.id
            let gate = FeedCommandGate()
            let resolved = expectation(description: "Resolved before eligibility replacement")
            let write = Task { try await command.write(beforeWrite: { await gate.wait(entered: resolved) }) }
            addTeardownBlock { await gate.release(); _ = await write.result }
            await fulfillment(of: [resolved], timeout: 5)
            try await Self.mutate(fixture.configuration) { realm in
                let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id))
                switch invalidation {
                case "soft-delete": feed.isDeleted = true
                case "created-at": feed.createdAt = feed.createdAt.addingTimeInterval(1)
                case "url": feed.rssUrl = URL(string: "https://example.com/retargeted.xml")!
                default: feed.entryContentKind = .contentListing
                }
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
            fixture.realm.refresh()
            let before = generations(fixture.realm)
            await gate.release()
            try await write.value
            assertUnchanged(fixture, generations: before)
        }
    }

    func testTitleOnlyChangeDoesNotRetireValidFollowingIntent() async throws {
        let fixture = try await fixture()
        let command = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        let id = fixture.feed.id
        let configuration = fixture.configuration
        let gate = FeedCommandGate()
        let entered = expectation(description: "Following command awaits final write")
        let write = Task { try await command.write(beforeWrite: { await gate.wait(entered: entered) }) }
        addTeardownBlock { await gate.release(); _ = await write.result }
        await fulfillment(of: [entered], timeout: 5)
        let interveningDate = Date()
        try await Self.mutate(configuration) { realm in
            let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id))
            feed.title = "Refreshed title"
            feed.refreshChangeMetadata(explicitlyModified: true, at: interveningDate)
        }
        await gate.release()
        try await write.value
        fixture.realm.refresh()
        XCTAssertTrue(fixture.feed.isFollowed)
        XCTAssertEqual(fixture.feed.title, "Refreshed title")
        XCTAssertGreaterThanOrEqual(fixture.feed.explicitlyModifiedAt ?? .distantPast, interveningDate)
    }

    func testCancellationBeforeEntryAndAfterResolutionPermitFreshRetry() async throws {
        for cancelBeforeEntry in [true, false] {
            let fixture = try await fixture()
            let command = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
            let before = generations(fixture.realm)
            let gate = FeedCommandGate()
            let entered = expectation(description: "Cancellation boundary entered")
            let write = Task {
                if cancelBeforeEntry {
                    await gate.wait(entered: entered)
                    try await command.write()
                } else {
                    try await command.write(beforeWrite: { await gate.wait(entered: entered) })
                }
            }
            addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
            await fulfillment(of: [entered], timeout: 5)
            write.cancel()
            await gate.release()
            switch await write.result {
            case .success: XCTFail("Cancelled command succeeded")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
            assertUnchanged(fixture, generations: before)
            let retry = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
            try await retry.write()
            fixture.realm.refresh()
            XCTAssertTrue(fixture.feed.isFollowed)
        }
    }

    func testFailureAfterResolutionDoesNotMutateAndFreshCaptureRetries() async throws {
        enum ExpectedFailure: Error { case heldProducer }
        let fixture = try await fixture()
        let command = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        let before = generations(fixture.realm)
        do {
            try await command.write(beforeWrite: { throw ExpectedFailure.heldProducer })
            XCTFail("Expected producer failure")
        } catch ExpectedFailure.heldProducer { }
        assertUnchanged(fixture, generations: before)
        let retry = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        try await retry.write()
        fixture.realm.refresh()
        XCTAssertTrue(fixture.feed.isFollowed)
    }

    func testForeignWriteBeforeResolutionIsPreservedThenCommandProgresses() async throws {
        for commits in [true, false] {
            let fixture = try await fixture()
            let command = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
            let configuration = fixture.configuration
            let id = fixture.feed.id
            let peerGate = FeedCommandGate()
            let peerEntered = expectation(description: "Peer holds original write")
            let peer = Task { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try realm.beginWrite()
                let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id))
                feed.title = "Peer edit"
                feed.refreshChangeMetadata(explicitlyModified: true)
                await peerGate.wait(entered: peerEntered)
                let stillOwned = realm.isInWriteTransaction
                if stillOwned {
                    if commits { try realm.commitWrite() }
                    else { realm.cancelWrite() }
                }
                return stillOwned
            }
            addTeardownBlock { await peerGate.release(); _ = await peer.result }
            await fulfillment(of: [peerEntered], timeout: 5)
            let submitted = expectation(description: "Command queued behind peer")
            submitted.assertForOverFulfill = false
            let write = Task { @RealmBackgroundActor in
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await command.write(beforeWrite: {
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                        XCTAssertFalse(realm.isInWriteTransaction)
                    })
                }
            }
            addTeardownBlock { write.cancel(); await peerGate.release(); _ = await write.result }
            await fulfillment(of: [submitted], timeout: 5)
            let peerStillOpen = try await Task { @RealmBackgroundActor in
                try await RealmBackgroundActor.shared.cachedRealm(for: configuration).isInWriteTransaction
            }.value
            XCTAssertTrue(peerStillOpen)
            await peerGate.release()
            let peerRetainedOwnership = try await peer.value
            XCTAssertTrue(peerRetainedOwnership)
            try await write.value
            fixture.realm.refresh()
            XCTAssertTrue(fixture.feed.isFollowed)
            XCTAssertEqual(fixture.feed.title, commits ? "Peer edit" : "Original")
        }
    }

    func testCancellationOfPreResolutionBarrierDoesNotSettlePeerWrite() async throws {
        let fixture = try await fixture()
        let command = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        let before = generations(fixture.realm)
        let configuration = fixture.configuration
        let peerGate = FeedCommandGate()
        let entered = expectation(description: "Peer owns write")
        let peer = Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try realm.beginWrite()
            await peerGate.wait(entered: entered)
            let stillOwned = realm.isInWriteTransaction
            if stillOwned { realm.cancelWrite() }
            return stillOwned
        }
        addTeardownBlock { await peerGate.release(); _ = await peer.result }
        await fulfillment(of: [entered], timeout: 5)
        let submitted = expectation(description: "Barrier begin ticket submitted")
        let settled = expectation(description: "Cancelled barrier settled")
        let write = Task { @RealmBackgroundActor in
            defer { settled.fulfill() }
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await command.write()
            }
        }
        addTeardownBlock { write.cancel(); await peerGate.release(); _ = await write.result }
        await fulfillment(of: [submitted], timeout: 5)
        write.cancel()
        await fulfillment(of: [settled], timeout: 5)
        let peerStillOpen = try await Task { @RealmBackgroundActor in
            try await RealmBackgroundActor.shared.cachedRealm(for: configuration).isInWriteTransaction
        }.value
        XCTAssertTrue(peerStillOpen)
        // Even a failed prompt-cancellation expectation must release the held
        // peer before joining a possibly still queued command.
        await peerGate.release()
        let peerRetainedOwnership = try await peer.value
        XCTAssertTrue(peerRetainedOwnership)
        switch await write.result {
        case .success: XCTFail("Cancelled barrier succeeded")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        assertUnchanged(fixture, generations: before)
        let retry = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        try await retry.write()
        fixture.realm.refresh()
        XCTAssertTrue(fixture.feed.isFollowed)
    }

    func testFinalWriteQueuesAfterResolvedAccessorAndRejectsPeerTombstone() async throws {
        let fixture = try await fixture()
        let command = try XCTUnwrap(FeedViewCommand.following(true, feed: fixture.feed.freeze()))
        let configuration = fixture.configuration
        let id = fixture.feed.id
        let commandGate = FeedCommandGate()
        let resolved = expectation(description: "Command resolved before final write")
        let submitted = expectation(description: "Final command ticket submitted")
        let write = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await command.write(beforeWrite: { await commandGate.wait(entered: resolved) })
            }
        }
        addTeardownBlock { write.cancel(); await commandGate.release(); _ = await write.result }
        await fulfillment(of: [resolved], timeout: 5)
        let peerGate = FeedCommandGate()
        let peerEntered = expectation(description: "Peer deletion owns write")
        let peer = Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try realm.beginWrite()
            let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id))
            feed.isDeleted = true
            feed.refreshChangeMetadata(explicitlyModified: true)
            let tombstoneGeneration = realm.objects(BigSyncPendingMutation.self).first?.generation
            await peerGate.wait(entered: peerEntered)
            let stillOwned = realm.isInWriteTransaction
            if stillOwned { try realm.commitWrite() }
            return (stillOwned, tombstoneGeneration)
        }
        addTeardownBlock { await peerGate.release(); _ = await peer.result }
        await fulfillment(of: [peerEntered], timeout: 5)
        await commandGate.release()
        await fulfillment(of: [submitted], timeout: 5)
        await peerGate.release()
        let (peerRetainedOwnership, tombstoneGeneration) = try await peer.value
        XCTAssertTrue(peerRetainedOwnership)
        try await write.value
        fixture.realm.refresh()
        XCTAssertTrue(fixture.feed.isDeleted)
        XCTAssertFalse(fixture.feed.isFollowed)
        XCTAssertNil(fixture.feed.followingOrdinal)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).first?.generation, tombstoneGeneration)
        XCTAssertNotNil(fixture.feed.explicitlyModifiedAt)
    }

    func testSeenCommandRechecksBadgeEligibilityWithoutJournalingLocalTimestamp() async throws {
        let fixture = try await fixture()
        let command = try XCTUnwrap(FeedViewCommand.markingAllEntriesSeen(feed: fixture.feed.freeze(), hasEntries: true))
        let id = fixture.feed.id
        try await Self.mutate(fixture.configuration) { realm in
            let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id))
            feed.showsUnseenBadge = false
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let before = generations(fixture.realm)
        try await command.write()
        assertUnchanged(fixture, generations: before)
    }

    func testCapturedStorageRejectsReplacementBeforeOpenAndAfterResolution() async throws {
        for replaceAfterResolution in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-command-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let originalURL = directory.appendingPathComponent("original.realm")
            let replacementURL = directory.appendingPathComponent("replacement.realm")
            let retiredURL = directory.appendingPathComponent("retired.realm")
            let original = try await fixture(fileURL: originalURL)
            let replacement = try await fixture(id: original.feed.id, fileURL: replacementURL)
            let command = try XCTUnwrap(FeedViewCommand.following(true, feed: original.feed.freeze()))
            let originalGenerations = generations(original.realm)
            let replacementGenerations = generations(replacement.realm)
            let gate = FeedCommandGate()
            let entered = expectation(description: "Storage replacement boundary")
            let write = Task {
                if replaceAfterResolution {
                    try await command.write(beforeWrite: { await gate.wait(entered: entered) })
                } else {
                    await gate.wait(entered: entered)
                    try await command.write()
                }
            }
            addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
            await fulfillment(of: [entered], timeout: 5)
            try FileManager.default.moveItem(at: originalURL, to: retiredURL)
            do { try FileManager.default.moveItem(at: replacementURL, to: originalURL) }
            catch {
                try? FileManager.default.moveItem(at: retiredURL, to: originalURL)
                throw error
            }
            defer {
                XCTAssertNoThrow(try FileManager.default.moveItem(at: originalURL, to: replacementURL))
                XCTAssertNoThrow(try FileManager.default.moveItem(at: retiredURL, to: originalURL))
            }
            await gate.release()
            do {
                try await write.value
                XCTAssertTrue(replaceAfterResolution)
            } catch RealmBackgroundActorError.realmFileChangedDuringOpen {
                XCTAssertFalse(replaceAfterResolution)
            } catch {
                XCTFail("Unexpected storage error: \(error)")
            }
            assertUnchanged(original, generations: originalGenerations)
            assertUnchanged(replacement, generations: replacementGenerations)
        }
    }
}
