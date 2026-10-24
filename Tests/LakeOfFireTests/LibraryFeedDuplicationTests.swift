import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor FeedDuplicationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(onSuspension: @Sendable () -> Void) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            onSuspension()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct DuplicatedFeedState: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let categoryID: UUID?
    let directoryID: UUID?
    let title: String
    let markdownDescription: String?
    let rssURL: URL
    let iconURL: URL
    let isReaderModeByDefault: Bool
    let rssContainsFullContent: Bool
    let deleteOrphans: Bool
    let isFollowed: Bool
    let lastRefreshedEntriesAt: Date?
    let isArchived: Bool
    let isDeleted: Bool
    let modifiedAt: Date
    let explicitlyModifiedAt: Date?
}

private struct DuplicationCategoryState: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let title: String
    let opmlURL: URL?
    let isDeleted: Bool
    let modifiedAt: Date
    let explicitlyModifiedAt: Date?
}

private struct FeedDuplicationSnapshot: Equatable, Sendable {
    let feeds: [DuplicatedFeedState]
    let categories: [DuplicationCategoryState]
    let generations: [String: String]
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LibraryFeedDuplicationTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let realm: Realm
        let sourceID: UUID
        let existingID: UUID
        let categoryID: UUID
    }

    private func configured(_ input: Realm.Configuration) -> Realm.Configuration {
        var configuration = input
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func suppressDownloadObserverInitialization() {
        let previous = LibraryDataManager.observesDownloadController
        LibraryDataManager.observesDownloadController = false
        _ = LibraryDataManager.shared
        LibraryDataManager.observesDownloadController = previous
    }

    private func makeFixture(description: String? = "Source description") async throws -> Fixture {
        suppressDownloadObserverInitialization()
        let configuration = configured(Realm.Configuration(inMemoryIdentifier: UUID().uuidString))
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let sourceID = UUID()
        let existingID = UUID()
        let categoryID = UUID()
        try await Self.write(configuration) { writer in
            Self.populate(
                writer, sourceID: sourceID, existingID: existingID, categoryID: categoryID,
                description: description
            )
        }
        realm.refresh()
        return Fixture(realm: realm, sourceID: sourceID, existingID: existingID, categoryID: categoryID)
    }

    @RealmBackgroundActor
    private static func write(
        _ configuration: Realm.Configuration,
        _ mutation: @escaping @RealmBackgroundActor @Sendable (Realm) throws -> Void
    ) async throws {
        let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await writer.asyncWritePreservingOwnership { try mutation(writer) }
    }

    private nonisolated static func populate(
        _ realm: Realm, sourceID: UUID, existingID: UUID, categoryID: UUID,
        description: String? = "Source description", storeLabel: String = ""
    ) {
        let sourceCategory = FeedCategory()
        sourceCategory.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        sourceCategory.title = "Source category" + storeLabel
        sourceCategory.backgroundImageUrl = URL(string: "about:blank")!
        realm.add(sourceCategory)
        sourceCategory.refreshChangeMetadata(explicitlyModified: true)
        let destination = FeedCategory()
        destination.id = categoryID
        destination.createdAt = Date(timeIntervalSinceReferenceDate: 200)
        destination.title = "Destination category" + storeLabel
        destination.backgroundImageUrl = URL(string: "about:blank")!
        realm.add(destination)
        destination.refreshChangeMetadata(explicitlyModified: true)
        let library = LibraryConfiguration()
        library.categoryIDs.append(objectsIn: [sourceCategory.id, destination.id])
        realm.add(library)
        library.refreshChangeMetadata(explicitlyModified: true)

        let source = Feed()
        source.id = sourceID
        source.createdAt = Date(timeIntervalSinceReferenceDate: 300)
        source.categoryID = sourceCategory.id
        source.title = "Source feed" + storeLabel
        source.markdownDescription = description
        source.rssUrl = URL(string: "https://example.com/duplicate.xml")!
        source.iconUrl = URL(string: "https://example.com/source.png")!
        source.isReaderModeByDefault = false
        source.deleteOrphans = true
        realm.add(source)
        source.refreshChangeMetadata(explicitlyModified: true)
        let existing = Feed()
        existing.id = existingID
        existing.createdAt = Date(timeIntervalSinceReferenceDate: 400)
        existing.categoryID = destination.id
        existing.title = "Existing destination" + storeLabel
        existing.markdownDescription = "Keep destination settings"
        existing.rssUrl = source.rssUrl
        existing.iconUrl = URL(string: "https://example.com/existing.png")!
        existing.rssContainsFullContent = true
        existing.isFollowed = true
        existing.lastRefreshedEntriesAt = Date(timeIntervalSinceReferenceDate: 500)
        realm.add(existing)
        existing.refreshChangeMetadata(explicitlyModified: true)
    }

    private func manager(_ configuration: Realm.Configuration) -> LibraryManagerViewModel {
        let previous = LibraryDataManager.realmConfiguration
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = previous }
        return LibraryManagerViewModel(observesRealm: false)
    }

    private func source(_ fixture: Fixture) throws -> Feed {
        try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.sourceID))
    }

    private func category(_ fixture: Fixture) throws -> FeedCategory {
        try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: fixture.categoryID))
    }

    private func state(_ feed: Feed) -> DuplicatedFeedState {
        DuplicatedFeedState(
            id: feed.id, createdAt: feed.createdAt, categoryID: feed.categoryID,
            directoryID: feed.directoryID, title: feed.title, markdownDescription: feed.markdownDescription,
            rssURL: feed.rssUrl, iconURL: feed.iconUrl, isReaderModeByDefault: feed.isReaderModeByDefault,
            rssContainsFullContent: feed.rssContainsFullContent, deleteOrphans: feed.deleteOrphans,
            isFollowed: feed.isFollowed, lastRefreshedEntriesAt: feed.lastRefreshedEntriesAt,
            isArchived: feed.isArchived, isDeleted: feed.isDeleted, modifiedAt: feed.modifiedAt,
            explicitlyModifiedAt: feed.explicitlyModifiedAt
        )
    }

    private func snapshot(_ realm: Realm) -> FeedDuplicationSnapshot {
        FeedDuplicationSnapshot(
            feeds: realm.objects(Feed.self).map { state($0) }.sorted { $0.id.uuidString < $1.id.uuidString },
            categories: realm.objects(FeedCategory.self).map {
                DuplicationCategoryState(
                    id: $0.id, createdAt: $0.createdAt, title: $0.title, opmlURL: $0.opmlURL,
                    isDeleted: $0.isDeleted, modifiedAt: $0.modifiedAt,
                    explicitlyModifiedAt: $0.explicitlyModifiedAt
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            generations: Dictionary(uniqueKeysWithValues:
                realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
            )
        )
    }

    private func duplicate(
        _ fixture: Fixture,
        overwriteExisting: Bool,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> LibraryFeedDuplicationResult? {
        try await LibraryDataManager.shared.duplicateFeedWithIdentity(
            ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)),
            overwriteExisting: overwriteExisting,
            realmConfiguration: fixture.realm.configuration,
            beforeWrite: beforeWrite
        )
    }

    func testManagerForwardsNonOverwriteAndAwaitsSelectionWithoutChangingExistingDuplicate() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let before = snapshot(fixture.realm)
        let existing = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.existingID))
        let originalExisting = state(existing)
        try await model.duplicate(
            feed: ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)),
            overwriteExisting: false
        )
        fixture.realm.refresh()
        let selected = try XCTUnwrap(model.selectedFeed)
        XCTAssertNotEqual(selected.id, fixture.sourceID)
        XCTAssertNotEqual(selected.id, fixture.existingID)
        XCTAssertEqual(selected.categoryID, fixture.categoryID)
        XCTAssertEqual(selected.title, try source(fixture).title)
        XCTAssertEqual(model.navigationPath.count, 1, "The awaited method publishes navigation before returning")
        XCTAssertEqual(state(existing), originalExisting)
        let after = snapshot(fixture.realm)
        XCTAssertEqual(after.feeds.count, before.feeds.count + 1)
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertEqual(after.feeds.first { $0.id == fixture.sourceID }, before.feeds.first { $0.id == fixture.sourceID })
        for (recordName, generation) in before.generations {
            XCTAssertEqual(after.generations[recordName], generation)
        }
        XCTAssertEqual(after.generations.count, before.generations.count + 1)
    }

    func testOverwriteRetainsDestinationCreationAndExactReplayDoesNotRejournal() async throws {
        let fixture = try await makeFixture()
        let before = snapshot(fixture.realm)
        let existing = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.existingID))
        let creation = existing.createdAt
        let duplication = try await duplicate(fixture, overwriteExisting: true)
        let result = try XCTUnwrap(duplication)
        fixture.realm.refresh()
        XCTAssertEqual(result.feedID, fixture.existingID)
        XCTAssertEqual(result.feedCreatedAt, creation)
        XCTAssertEqual(result.categoryID, fixture.categoryID)
        XCTAssertEqual(result.categoryCreatedAt, try category(fixture).createdAt)
        XCTAssertEqual(existing.title, try source(fixture).title)
        XCTAssertEqual(existing.markdownDescription, try source(fixture).markdownDescription)
        XCTAssertEqual(existing.createdAt, creation)
        XCTAssertFalse(existing.isArchived)
        XCTAssertFalse(existing.isDeleted)
        let after = snapshot(fixture.realm)
        XCTAssertEqual(after.feeds.count, before.feeds.count)
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertEqual(after.feeds.first { $0.id == fixture.sourceID }, before.feeds.first { $0.id == fixture.sourceID })
        XCTAssertNotEqual(after.generations, before.generations)

        let retry = try await duplicate(fixture, overwriteExisting: true)
        fixture.realm.refresh()
        XCTAssertEqual(retry, result)
        XCTAssertEqual(snapshot(fixture.realm), after)
    }

    func testNormalFeedWithNoDescriptionCanBeDuplicated() async throws {
        let fixture = try await makeFixture(description: nil)
        let duplication = try await duplicate(fixture, overwriteExisting: false)
        let result = try XCTUnwrap(duplication)
        fixture.realm.refresh()
        let copied = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: result.feedID))
        XCTAssertNil(copied.markdownDescription)
        XCTAssertEqual(copied.title, try source(fixture).title)
        XCTAssertEqual(copied.categoryID, fixture.categoryID)
        XCTAssertNotEqual(copied.id, fixture.existingID)
    }

    private func assertQueuedRejection(
        _ fixture: Fixture,
        mutation: @escaping @RealmBackgroundActor @Sendable (Realm) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let configuration = fixture.realm.configuration
        let feedReference = ThreadSafeReference(to: try source(fixture))
        let categoryReference = ThreadSafeReference(to: try category(fixture))
        let gate = FeedDuplicationGate()
        let entered = expectation(description: "Duplication captured rows before admission")
        let operation = Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.duplicateFeedWithIdentity(
                feedReference, inCategory: categoryReference, overwriteExisting: true,
                realmConfiguration: configuration,
                beforeWrite: { await gate.wait(onSuspension: { entered.fulfill() }) }
            )
        }
        addTeardownBlock { operation.cancel(); await gate.release(); _ = await operation.result }
        await fulfillment(of: [entered], timeout: 5)
        try await Self.write(configuration, mutation)
        fixture.realm.refresh()
        let afterMutation = snapshot(fixture.realm)
        await gate.release()
        let result = try await operation.value
        fixture.realm.refresh()
        XCTAssertNil(result, file: file, line: line)
        XCTAssertEqual(snapshot(fixture.realm), afterMutation, file: file, line: line)
    }

    func testQueuedDuplicationRejectsRecreatedSource() async throws {
        let fixture = try await makeFixture()
        let id = fixture.sourceID
        try await assertQueuedRejection(fixture) { writer in
            let original = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: id))
            let replacement = Feed(value: original)
            replacement.createdAt = original.createdAt.addingTimeInterval(1)
            replacement.title = "Replacement source"
            writer.delete(original)
            writer.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
    }

    func testQueuedDuplicationRejectsRecreatedDestinationCategory() async throws {
        let fixture = try await makeFixture()
        let id = fixture.categoryID
        try await assertQueuedRejection(fixture) { writer in
            let original = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: id))
            let replacement = FeedCategory(value: original)
            replacement.createdAt = original.createdAt.addingTimeInterval(1)
            replacement.title = "Replacement category"
            writer.delete(original)
            writer.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
    }

    func testQueuedOverwriteRejectsRecreatedDestinationFeed() async throws {
        let fixture = try await makeFixture()
        let id = fixture.existingID
        try await assertQueuedRejection(fixture) { writer in
            let original = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: id))
            let replacement = Feed(value: original)
            replacement.createdAt = original.createdAt.addingTimeInterval(1)
            replacement.title = "Replacement duplicate"
            writer.delete(original)
            writer.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
    }

    func testQueuedDuplicationRejectsNewlyManagedOrDeletedDestination() async throws {
        for managed in [true, false] {
            let fixture = try await makeFixture()
            let id = fixture.categoryID
            try await assertQueuedRejection(fixture) { writer in
                let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: id))
                if managed {
                    category.opmlURL = URL(string: "https://example.com/managed.opml")!
                } else {
                    category.isDeleted = true
                }
                category.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }

    func testQueuedDuplicationRejectsChangedSourceRSS() async throws {
        let fixture = try await makeFixture()
        let id = fixture.sourceID
        try await assertQueuedRejection(fixture) { writer in
            let source = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: id))
            source.rssUrl = URL(string: "https://example.com/replacement.xml")!
            source.refreshChangeMetadata(explicitlyModified: true)
        }
    }

    func testManagerRetainsCapturedStoreAfterGlobalRoutesChange() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let other = try await makeFixture()
        BigSyncMutationTracking.install(
            configurations: [fixture.realm.configuration, other.realm.configuration],
            excludedClassNames: []
        )
        let otherBefore = snapshot(other.realm)
        let previousLibrary = LibraryDataManager.realmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        LibraryDataManager.realmConfiguration = other.realm.configuration
        ReaderContentLoader.feedEntryRealmConfiguration = other.realm.configuration
        defer {
            LibraryDataManager.realmConfiguration = previousLibrary
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }
        try await model.duplicate(
            feed: ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)),
            overwriteExisting: false
        )
        fixture.realm.refresh()
        other.realm.refresh()
        XCTAssertEqual(snapshot(other.realm), otherBefore)
        XCTAssertEqual(model.selectedFeed?.categoryID, fixture.categoryID)
        XCTAssertEqual(model.selectedFeed?.realm?.configuration.inMemoryIdentifier, fixture.realm.configuration.inMemoryIdentifier)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 3)
    }

    func testRecreatedCategoryBeforePublicationDoesNotReplaceCurrentSelection() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        model.selectedFeed = try source(fixture)
        let originalSelection = try source(fixture).id
        let configuration = fixture.realm.configuration
        let categoryID = fixture.categoryID
        try await model.duplicate(
            feed: ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)),
            overwriteExisting: false,
            beforePublication: {
                try await Self.write(configuration) { writer in
                    let original = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                    let replacement = FeedCategory(value: original)
                    replacement.createdAt = original.createdAt.addingTimeInterval(1)
                    writer.delete(original)
                    writer.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        )
        fixture.realm.refresh()
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 3, "The committed duplicate remains durable")
        XCTAssertEqual(model.selectedFeed?.id, originalSelection)
        XCTAssertEqual(model.navigationPath.count, 0)
    }

    func testRecreatedDuplicatedFeedBeforePublicationDoesNotReplaceCurrentSelection() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        model.selectedFeed = try source(fixture)
        let configuration = fixture.realm.configuration
        let sourceID = fixture.sourceID
        let existingID = fixture.existingID
        try await model.duplicate(
            feed: ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)),
            overwriteExisting: false,
            beforePublication: {
                try await Self.write(configuration) { writer in
                    let original = try XCTUnwrap(writer.objects(Feed.self).first {
                        $0.id != sourceID && $0.id != existingID
                    })
                    let replacement = Feed(value: original)
                    replacement.createdAt = original.createdAt.addingTimeInterval(1)
                    replacement.title = "Replacement published row"
                    writer.delete(original)
                    writer.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        )
        fixture.realm.refresh()
        XCTAssertEqual(model.selectedFeed?.id, sourceID)
        XCTAssertEqual(model.navigationPath.count, 0)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 3)
    }

    func testCancellationBeforeAdmissionMakesNoCopyAndFreshReferencesCanRetry() async throws {
        let fixture = try await makeFixture()
        let before = snapshot(fixture.realm)
        let configuration = fixture.realm.configuration
        let feedReference = ThreadSafeReference(to: try source(fixture))
        let categoryReference = ThreadSafeReference(to: try category(fixture))
        let gate = FeedDuplicationGate()
        let entered = expectation(description: "Duplication waits before cancellation")
        let operation = Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.duplicateFeedWithIdentity(
                feedReference, inCategory: categoryReference, overwriteExisting: false,
                realmConfiguration: configuration,
                beforeWrite: { await gate.wait(onSuspension: { entered.fulfill() }) }
            )
        }
        addTeardownBlock { operation.cancel(); await gate.release(); _ = await operation.result }
        await fulfillment(of: [entered], timeout: 5)
        operation.cancel()
        await gate.release()
        do {
            _ = try await operation.value
            XCTFail("An uncommitted cancelled copy cannot report success")
        } catch is CancellationError {}
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), before)

        let retry = try await duplicate(fixture, overwriteExisting: false)
        fixture.realm.refresh()
        XCTAssertNotNil(retry)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, before.feeds.count + 1)
    }

    func testCancellationAfterCommitSubmissionReturnsDurableIdentityAndReplayIsANoOp() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let feedReference = ThreadSafeReference(to: try source(fixture))
        let categoryReference = ThreadSafeReference(to: try category(fixture))
        let operation = RealmWriteCommitObservation.$didSubmit.withValue({
            withUnsafeCurrentTask { $0?.cancel() }
        }) {
            Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.duplicateFeedWithIdentity(
                    feedReference, inCategory: categoryReference, overwriteExisting: true,
                    realmConfiguration: configuration
                )
            }
        }
        let duplication = try await operation.value
        let result = try XCTUnwrap(duplication)
        XCTAssertTrue(operation.isCancelled)
        XCTAssertEqual(result.feedID, fixture.existingID)
        fixture.realm.refresh()
        let afterCommit = snapshot(fixture.realm)
        XCTAssertEqual(
            fixture.realm.object(ofType: Feed.self, forPrimaryKey: result.feedID)?.title,
            try source(fixture).title
        )
        let retry = try await duplicate(fixture, overwriteExisting: true)
        fixture.realm.refresh()
        XCTAssertEqual(retry, result)
        XCTAssertEqual(snapshot(fixture.realm), afterCommit)
    }

    func testNewerDuplicationKeepsSelectionWhenOlderCommittedPublicationResumes() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let firstFeed = ThreadSafeReference(to: try source(fixture))
        let firstCategory = ThreadSafeReference(to: try category(fixture))
        let gate = FeedDuplicationGate()
        let committed = expectation(description: "First duplicate committed before publication")
        let first = Task { @RealmBackgroundActor in
            try await model.duplicate(
                feed: firstFeed, inCategory: firstCategory, overwriteExisting: false,
                beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) }
            )
        }
        addTeardownBlock { first.cancel(); await gate.release(); _ = await first.result }
        await fulfillment(of: [committed], timeout: 5)
        fixture.realm.refresh()
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 3)

        try await model.duplicate(
            feed: ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)),
            overwriteExisting: false
        )
        let newerSelection = try XCTUnwrap(model.selectedFeed?.id)
        let navigationCount = model.navigationPath.count
        await gate.release()
        try await first.value
        fixture.realm.refresh()
        XCTAssertEqual(model.selectedFeed?.id, newerSelection)
        XCTAssertEqual(model.navigationPath.count, navigationCount)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 4, "Both committed copies survive")
    }

    func testAlreadyCancelledNewcomerDoesNotRetireCommittedPublication() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let firstFeed = ThreadSafeReference(to: try source(fixture))
        let firstCategory = ThreadSafeReference(to: try category(fixture))
        let gate = FeedDuplicationGate()
        let committed = expectation(description: "First duplicate awaits publication")
        let first = Task { @RealmBackgroundActor in
            try await model.duplicate(
                feed: firstFeed, inCategory: firstCategory, overwriteExisting: false,
                beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) }
            )
        }
        addTeardownBlock { first.cancel(); await gate.release(); _ = await first.result }
        await fulfillment(of: [committed], timeout: 5)
        let cancelledFeed = ThreadSafeReference(to: try source(fixture))
        let cancelledCategory = ThreadSafeReference(to: try category(fixture))
        let newcomer = Task { @RealmBackgroundActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await model.duplicate(
                feed: cancelledFeed, inCategory: cancelledCategory, overwriteExisting: false
            )
        }
        do {
            try await newcomer.value
            XCTFail("The cancelled newcomer must stop before claiming publication")
        } catch is CancellationError {}
        await gate.release()
        try await first.value
        fixture.realm.refresh()
        let selected = try XCTUnwrap(model.selectedFeed)
        XCTAssertNotEqual(selected.id, fixture.sourceID)
        XCTAssertNotEqual(selected.id, fixture.existingID)
        XCTAssertEqual(selected.categoryID, fixture.categoryID)
        XCTAssertEqual(model.navigationPath.count, 1)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 3)
    }

    private struct DiskFixture {
        let configuration: Realm.Configuration
        let replacementConfiguration: Realm.Configuration
        let retiredConfiguration: Realm.Configuration
        let sourceID: UUID
        let categoryID: UUID
        let original: FeedDuplicationSnapshot
        let replacement: FeedDuplicationSnapshot
    }

    private func diskReferences(_ fixture: DiskFixture) throws -> (
        feed: ThreadSafeReference<Feed>, category: ThreadSafeReference<FeedCategory>
    ) {
        try autoreleasepool {
            let realm = try Realm(configuration: fixture.configuration)
            defer { realm.invalidate() }
            return (
                ThreadSafeReference(to: try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: fixture.sourceID))),
                ThreadSafeReference(to: try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: fixture.categoryID)))
            )
        }
    }

    private func diskSnapshot(_ configuration: Realm.Configuration) throws -> FeedDuplicationSnapshot {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            defer { realm.invalidate() }
            return snapshot(realm)
        }
    }

    @RealmBackgroundActor
    private static func releaseDiskCache(_ configuration: Realm.Configuration) {
        let actor = RealmBackgroundActor.shared
        let keys = actor.cachedRealms.keys.filter {
            actor.cachedRealms[$0]?.configuration.fileURL == configuration.fileURL
        }
        for key in keys {
            guard let realm = actor.cachedRealms[key], !realm.isInWriteTransaction else { continue }
            actor.cachedRealms.removeValue(forKey: key)
            realm.invalidate()
        }
    }

    private func makeDiskFixture() throws -> DiskFixture {
        suppressDownloadObserverInitialization()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-duplication-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = configured(Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm")))
        var replacementConfiguration = configuration
        replacementConfiguration.fileURL = directory.appendingPathComponent("replacement.realm")
        var retiredConfiguration = configuration
        retiredConfiguration.fileURL = directory.appendingPathComponent("retired.realm")
        BigSyncMutationTracking.install(
            configurations: [configuration, replacementConfiguration],
            excludedClassNames: []
        )
        addTeardownBlock {
            await Self.releaseDiskCache(configuration)
            try? FileManager.default.removeItem(at: directory)
        }
        let sourceID = UUID()
        let existingID = UUID()
        let categoryID = UUID()
        for (store, label) in [(configuration, " original"), (replacementConfiguration, " replacement")] {
            try autoreleasepool {
                let realm = try Realm(configuration: store)
                defer { realm.invalidate() }
                try realm.write {
                    Self.populate(
                        realm, sourceID: sourceID, existingID: existingID,
                        categoryID: categoryID, storeLabel: label
                    )
                }
            }
        }
        return DiskFixture(
            configuration: configuration, replacementConfiguration: replacementConfiguration,
            retiredConfiguration: retiredConfiguration, sourceID: sourceID, categoryID: categoryID,
            original: try diskSnapshot(configuration), replacement: try diskSnapshot(replacementConfiguration)
        )
    }

    private func replaceDiskFile(_ fixture: DiskFixture) throws {
        let current = try XCTUnwrap(fixture.configuration.fileURL)
        let replacement = try XCTUnwrap(fixture.replacementConfiguration.fileURL)
        let retired = try XCTUnwrap(fixture.retiredConfiguration.fileURL)
        try FileManager.default.moveItem(at: current, to: retired)
        do { try FileManager.default.moveItem(at: replacement, to: current) }
        catch {
            try? FileManager.default.moveItem(at: retired, to: current)
            throw error
        }
    }

    private func duplicateAfterReplacingDiskFile(_ fixture: DiskFixture) async throws {
        let references = try diskReferences(fixture)
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: fixture.configuration)
        try replaceDiskFile(fixture)
        _ = try await LibraryDataManager.shared.duplicateFeedWithIdentity(
            references.feed, inCategory: references.category, overwriteExisting: true,
            realmConfiguration: fixture.configuration, storageAdmission: admission
        )
    }

    func testCapturedDuplicationRejectsSamePathReplacementBeforeOpening() async throws {
        let fixture = try makeDiskFixture()
        do {
            // This helper scopes the unresolved references so they are released
            // before either physical file is reopened for the final snapshots.
            try await duplicateAfterReplacingDiskFile(fixture)
            XCTFail("A captured duplication must not adopt the replacement file")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
    }

    func testDuplicationRevalidatesSamePathReplacementAfterOpening() async throws {
        let fixture = try makeDiskFixture()
        let references = try diskReferences(fixture)
        let configuration = fixture.configuration
        let gate = FeedDuplicationGate()
        let opened = expectation(description: "Original file and rows resolved before duplication")
        let operation = Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.duplicateFeedWithIdentity(
                references.feed, inCategory: references.category, overwriteExisting: true,
                realmConfiguration: configuration,
                beforeWrite: { await gate.wait(onSuspension: { opened.fulfill() }) }
            )
        }
        addTeardownBlock { operation.cancel(); await gate.release(); _ = await operation.result }
        await fulfillment(of: [opened], timeout: 5)
        try replaceDiskFile(fixture)
        await gate.release()
        do {
            _ = try await operation.value
            XCTFail("The owned write must revalidate the opened store")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
    }

}
