import BigSyncKit
import Foundation
import Combine
import RealmSwift
@testable import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor WebFeedAddGate {
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

private struct WebFeedAddSnapshot: Equatable, Sendable {
    struct FeedState: Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let categoryID: UUID?
        let title: String
        let rssURL: URL
        let meaningfulContentMinLength: Int
        let isDeleted: Bool
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    struct CategoryState: Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let title: String
        let opmlURL: URL?
        let isDeleted: Bool
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    struct LibraryState: Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let categoryIDs: [UUID]
        let isDeleted: Bool
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    let libraries: [LibraryState]
    let feeds: [FeedState]
    let categories: [CategoryState]
    let generations: [String: String]
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
private final class WebFeedAddPresentation {
    var published: [UUID] = []
    var route: ContentPaneRoute?
    var path = NavigationPath()

    var routeBinding: Binding<ContentPaneRoute?> {
        .init(get: { self.route }, set: { self.route = $0 })
    }

    var pathBinding: Binding<NavigationPath> {
        .init(get: { self.path }, set: { self.path = $0 })
    }
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LibraryWebFeedAddTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let realm: Realm
        let category: FeedCategory
        let library: LibraryConfiguration
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

    private func makeFixture() async throws -> Fixture {
        suppressDownloadObserverInitialization()
        let configuration = configured(Realm.Configuration(inMemoryIdentifier: UUID().uuidString))
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let categoryID = UUID()
        let libraryID = UUID()
        try await Self.write(configuration) { writer in
            let category = FeedCategory()
            category.id = categoryID
            category.createdAt = Date(timeIntervalSinceReferenceDate: 100)
            category.title = "Destination"
            writer.add(category)
            category.refreshChangeMetadata(explicitlyModified: true)
            let library = LibraryConfiguration()
            library.id = libraryID
            library.createdAt = Date(timeIntervalSinceReferenceDate: 200)
            library.categoryIDs.append(categoryID)
            writer.add(library)
            library.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        return Fixture(
            realm: realm,
            category: try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)),
            library: try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID))
        )
    }

    @RealmBackgroundActor
    private static func write(
        _ configuration: Realm.Configuration,
        _ mutation: @escaping @RealmBackgroundActor @Sendable (Realm) throws -> Void
    ) async throws {
        let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await writer.asyncWritePreservingOwnership { try mutation(writer) }
    }

    private func snapshot(_ realm: Realm) -> WebFeedAddSnapshot {
        WebFeedAddSnapshot(
            libraries: realm.objects(LibraryConfiguration.self).map {
                .init(id: $0.id, createdAt: $0.createdAt, categoryIDs: Array($0.categoryIDs),
                      isDeleted: $0.isDeleted, modifiedAt: $0.modifiedAt,
                      explicitlyModifiedAt: $0.explicitlyModifiedAt)
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            feeds: realm.objects(Feed.self).map {
                .init(
                    id: $0.id, createdAt: $0.createdAt, categoryID: $0.categoryID,
                    title: $0.title, rssURL: $0.rssUrl,
                    meaningfulContentMinLength: $0.meaningfulContentMinLength,
                    isDeleted: $0.isDeleted, modifiedAt: $0.modifiedAt,
                    explicitlyModifiedAt: $0.explicitlyModifiedAt
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            categories: realm.objects(FeedCategory.self).map {
                .init(
                    id: $0.id, createdAt: $0.createdAt, title: $0.title,
                    opmlURL: $0.opmlURL, isDeleted: $0.isDeleted,
                    modifiedAt: $0.modifiedAt, explicitlyModifiedAt: $0.explicitlyModifiedAt
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            generations: Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
                ($0.recordName, $0.generation)
            })
        )
    }

    private let rssURL = URL(string: "https://example.com/complete-feed.xml")!

    private func manager(_ configuration: Realm.Configuration) -> LibraryManagerViewModel {
        let previous = LibraryDataManager.realmConfiguration
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = previous }
        return LibraryManagerViewModel(observesRealm: false)
    }

    private func destination(_ fixture: Fixture) -> LibraryFeedCreationDestination {
        .category(id: fixture.category.id, createdAt: fixture.category.createdAt)
    }

    private func create(
        _ fixture: Fixture,
        destination: LibraryFeedCreationDestination? = nil,
        title: String? = "Complete title",
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> LibraryFeedCreationResult? {
        try await LibraryDataManager.shared.createFeedWithIdentity(
            destination: destination ?? self.destination(fixture),
            rssURL: rssURL, title: title,
            realmConfiguration: fixture.realm.configuration,
            beforeWrite: beforeWrite
        )
    }

    private func assertCompleteFeed(
        _ realm: Realm, id: UUID, title: String = "Complete title",
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Feed {
        let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: id), file: file, line: line)
        XCTAssertEqual(feed.rssUrl, rssURL, file: file, line: line)
        XCTAssertEqual(feed.title, title, file: file, line: line)
        XCTAssertEqual(feed.meaningfulContentMinLength, 0, file: file, line: line)
        XCTAssertFalse(feed.isDeleted, file: file, line: line)
        XCTAssertNotNil(feed.explicitlyModifiedAt, file: file, line: line)
        return feed
    }

    func testExplicitFeedBirthIsCompleteEvenWhenCancelledAfterCommitSubmission() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let destination = destination(fixture)
        let rssURL = rssURL
        let before = snapshot(fixture.realm)
        let task = RealmWriteCommitObservation.$didSubmit.withValue({
            withUnsafeCurrentTask { $0?.cancel() }
        }) {
            Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.createFeedWithIdentity(
                    destination: destination, rssURL: rssURL, title: "Complete title",
                    realmConfiguration: configuration
                )
            }
        }
        let creation = try await task.value
        let result = try XCTUnwrap(creation)
        fixture.realm.refresh()
        XCTAssertTrue(task.isCancelled)
        let feed = try assertCompleteFeed(fixture.realm, id: result.feedID)
        XCTAssertEqual(feed.createdAt, result.feedCreatedAt)
        XCTAssertEqual(feed.categoryID, result.categoryID)
        let after = snapshot(fixture.realm)
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertEqual(after.libraries, before.libraries)
        XCTAssertEqual(after.generations.count, before.generations.count + 1)
        for (id, generation) in before.generations {
            XCTAssertEqual(after.generations[id], generation)
        }
    }

    func testNewCategoryMembershipAndCompletedFeedAreBornTogether() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let originalCategoryID = fixture.category.id
        let libraryID = fixture.library.id
        let before = snapshot(fixture.realm)
        let creation = try await create(fixture, destination: .newUserCategory, beforeWrite: {
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertTrue(writer.objects(Feed.self).isEmpty)
            XCTAssertEqual(writer.objects(FeedCategory.self).count, 1)
            XCTAssertEqual(Array(try XCTUnwrap(writer.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID)).categoryIDs), [originalCategoryID])
        })
        let result = try XCTUnwrap(creation)
        fixture.realm.refresh()
        let feed = try assertCompleteFeed(fixture.realm, id: result.feedID)
        let category = try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: result.categoryID))
        XCTAssertEqual(category.title, "My Library")
        XCTAssertEqual(category.createdAt, result.categoryCreatedAt)
        XCTAssertTrue(category.isUserEditable)
        XCTAssertEqual(feed.categoryID, category.id)
        XCTAssertEqual(category.explicitlyModifiedAt, feed.explicitlyModifiedAt)
        XCTAssertEqual(fixture.library.explicitlyModifiedAt, feed.explicitlyModifiedAt)
        XCTAssertEqual(Array(fixture.library.categoryIDs), [originalCategoryID, category.id])
        XCTAssertEqual(fixture.realm.objects(FeedCategory.self).count, 2)
        let after = snapshot(fixture.realm)
        XCTAssertEqual(after.generations.count, before.generations.count + 2)
        let unchangedCategory = before.categories[0]
        XCTAssertEqual(after.categories.first { $0.id == originalCategoryID }, unchangedCategory)
        let categoryRecord = "\(FeedCategory.className()).\(originalCategoryID)"
        XCTAssertNotNil(before.generations[categoryRecord])
        XCTAssertEqual(after.generations[categoryRecord], before.generations[categoryRecord])
    }

    func testSuppliedAndAbsentTitlesPreserveCreationDefaults() async throws {
        let fixture = try await makeFixture()
        let untitled = try await create(fixture, title: nil)
        let empty = try await create(fixture, title: "")
        fixture.realm.refresh()
        _ = try assertCompleteFeed(fixture.realm, id: try XCTUnwrap(untitled?.feedID), title: Feed().title)
        _ = try assertCompleteFeed(fixture.realm, id: try XCTUnwrap(empty?.feedID), title: "")
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 2)
    }

    func testExplicitDestinationIsCapturedBeforeTaskAndNeverFallsBack() async throws {
        enum Retirement: CaseIterable { case delete, recreate, manage, tombstone }
        for retirement in Retirement.allCases {
            let fixture = try await makeFixture()
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            await RealmBackgroundActor.shared.removeCachedRealm(for: fixture.realm.configuration)
            let task = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "Complete title", toCategory: fixture.category,
                didPublish: { presentation.published.append($0) }
            ))
            addTeardownBlock { task.cancel(); _ = await task.result }
            // The new MainActor task has not run yet. Change the rendered row in
            // a real transaction before actor resolution, with no intervening await.
            try fixture.realm.write {
                switch retirement {
                case .delete:
                    fixture.realm.delete(fixture.category)
                case .recreate:
                    let replacement = FeedCategory(value: fixture.category)
                    replacement.createdAt = fixture.category.createdAt.addingTimeInterval(1)
                    fixture.realm.delete(fixture.category)
                    fixture.realm.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                case .manage:
                    fixture.category.opmlURL = URL(string: "https://example.com/managed.opml")
                    fixture.category.refreshChangeMetadata(explicitlyModified: true)
                case .tombstone:
                    fixture.category.isDeleted = true
                    fixture.category.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            let authoritative = snapshot(fixture.realm)
            let result = try await task.value
            fixture.realm.refresh()
            XCTAssertNil(result)
            XCTAssertEqual(snapshot(fixture.realm), authoritative)
            XCTAssertNil(model.selectedFeed)
            XCTAssertTrue(presentation.published.isEmpty)
        }
    }

    func testOwnedWriteRevalidatesExplicitCategoryEligibilityAndIncarnation() async throws {
        enum Retirement: CaseIterable, Sendable { case delete, recreate, manage, tombstone }
        for retirement in Retirement.allCases {
            let fixture = try await makeFixture()
            let configuration = fixture.realm.configuration
            let categoryID = fixture.category.id
            let result = try await create(fixture, beforeWrite: {
                try await Self.write(configuration) { writer in
                    let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                    switch retirement {
                    case .delete:
                        writer.delete(category)
                    case .recreate:
                        let replacement = FeedCategory(value: category)
                        replacement.createdAt = category.createdAt.addingTimeInterval(1)
                        writer.delete(category)
                        writer.add(replacement)
                        replacement.refreshChangeMetadata(explicitlyModified: true)
                    case .manage:
                        category.opmlURL = URL(string: "https://example.com/managed.opml")
                        category.refreshChangeMetadata(explicitlyModified: true)
                    case .tombstone:
                        category.isDeleted = true
                        category.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            })
            fixture.realm.refresh()
            XCTAssertNil(result)
            XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)
            XCTAssertEqual(fixture.realm.objects(FeedCategory.self).count, retirement == .delete ? 0 : 1)
            XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 2)
        }
    }

    func testRetiredConsolidatedLibraryLeavesNoNewCategoryOrFeed() async throws {
        enum Retirement: CaseIterable, Sendable { case recreate, tombstone }
        for retirement in Retirement.allCases {
            let fixture = try await makeFixture()
            let configuration = fixture.realm.configuration
            let libraryID = fixture.library.id
            let before = snapshot(fixture.realm)
            let result = try await create(fixture, destination: .newUserCategory, beforeWrite: {
                try await Self.write(configuration) { writer in
                    let library = try XCTUnwrap(writer.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID))
                    switch retirement {
                    case .recreate:
                        let replacement = LibraryConfiguration(value: library)
                        replacement.createdAt = library.createdAt.addingTimeInterval(1)
                        writer.delete(library)
                        writer.add(replacement)
                        replacement.refreshChangeMetadata(explicitlyModified: true)
                    case .tombstone:
                        library.isDeleted = true
                        library.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            })
            fixture.realm.refresh()
            XCTAssertNil(result)
            XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)
            XCTAssertEqual(snapshot(fixture.realm).categories, before.categories)
            XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 2)
        }
    }

    func testFailureBeforeBirthLeavesNoPartialRowsAndRetrySucceeds() async throws {
        enum ExpectedFailure: Error { case rejected }
        let fixture = try await makeFixture()
        let before = snapshot(fixture.realm)
        do {
            _ = try await create(fixture, destination: .newUserCategory, beforeWrite: { throw ExpectedFailure.rejected })
            XCTFail("The actual creation must propagate the preparation failure")
        } catch ExpectedFailure.rejected {}
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), before)
        let result = try await create(fixture, destination: .newUserCategory)
        fixture.realm.refresh()
        _ = try assertCompleteFeed(fixture.realm, id: try XCTUnwrap(result?.feedID))
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
        XCTAssertEqual(fixture.realm.objects(FeedCategory.self).count, 2)
    }

    func testCancellationAfterConsolidationKeepsNormalizationWithoutStartingFeedBirth() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let orphanID = UUID()
        try await Self.write(configuration) { writer in
            let category = FeedCategory()
            category.id = orphanID
            category.title = "Existing orphan"
            writer.add(category)
            category.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let before = snapshot(fixture.realm)
        let rssURL = rssURL
        let task = RealmWriteCommitObservation.$didSubmit.withValue({
            withUnsafeCurrentTask { $0?.cancel() }
        }) {
            Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.createFeedWithIdentity(
                    destination: .newUserCategory, rssURL: rssURL, title: "Never born",
                    realmConfiguration: configuration
                )
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation after normalization must stop before feed birth")
        } catch is CancellationError {}
        fixture.realm.refresh()
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(Array(fixture.library.categoryIDs), [fixture.category.id, orphanID])
        let after = snapshot(fixture.realm)
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertTrue(after.feeds.isEmpty)
        XCTAssertEqual(Set(after.generations.keys), Set(before.generations.keys))
        let libraryRecord = "\(LibraryConfiguration.className()).\(fixture.library.id)"
        XCTAssertNotEqual(after.generations[libraryRecord], before.generations[libraryRecord])
        for (record, generation) in before.generations where record != libraryRecord {
            XCTAssertEqual(after.generations[record], generation)
        }
    }

    func testCapturedManagerStoreWinsOverBothReplacementGlobalsAndRoutesCommittedRows() async throws {
        let original = try await makeFixture()
        let replacement = try await makeFixture()
        let model = manager(original.realm.configuration)
        let presentation = WebFeedAddPresentation()
        let replacementBefore = snapshot(replacement.realm)
        let oldLibrary = LibraryDataManager.realmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        LibraryDataManager.realmConfiguration = replacement.realm.configuration
        ReaderContentLoader.feedEntryRealmConfiguration = replacement.realm.configuration
        defer {
            LibraryDataManager.realmConfiguration = oldLibrary
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
        }
        for category in [nil, original.category] {
            let task = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "Complete title", toCategory: category,
                didPublish: { presentation.published.append($0) }
            ))
            let returnedID = try await task.value
            let id = try XCTUnwrap(returnedID)
            original.realm.refresh()
            let feed = try assertCompleteFeed(original.realm, id: id)
            model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            var expectedPath = NavigationPath()
            expectedPath.append(feed)
            XCTAssertEqual(presentation.route, .contentCategory(try XCTUnwrap(feed.categoryID)))
            XCTAssertEqual(presentation.path, expectedPath)
            XCTAssertEqual(model.selectedFeed?.id, id)
        }
        replacement.realm.refresh()
        XCTAssertEqual(snapshot(replacement.realm), replacementBefore)
        XCTAssertEqual(presentation.published.count, 2)
        XCTAssertEqual(original.realm.objects(Feed.self).count, 2)
        XCTAssertEqual(original.realm.objects(FeedCategory.self).count, 2)
    }

    func testCancelledBeforeBirthCanRetryWithoutPartialRowsOrPresentation() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let presentation = WebFeedAddPresentation()
        let gate = WebFeedAddGate()
        let entered = expectation(description: "Add prepared its owner before the birth write")
        let before = snapshot(fixture.realm)
        let task = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Complete title",
            beforeWrite: { await gate.wait(onSuspension: { entered.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation before admission cannot publish a feed")
        } catch is CancellationError {}
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), before)
        XCTAssertTrue(presentation.published.isEmpty)
        let retry = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Complete title",
            didPublish: { presentation.published.append($0) }
        ))
        let returnedID = try await retry.value
        let id = try XCTUnwrap(returnedID)
        fixture.realm.refresh()
        _ = try assertCompleteFeed(fixture.realm, id: id)
        XCTAssertEqual(presentation.published, [id])
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
    }

    func testCancelledQueuedBirthDoesNotRollBackAnotherOwnersTransaction() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let categoryID = fixture.category.id
        let destination = destination(fixture)
        let rssURL = rssURL
        let gate = WebFeedAddGate()
        let peerEntered = expectation(description: "Peer owns the write transaction")
        let submitted = expectation(description: "Completed-feed birth submits an independent ticket")
        let peer = Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try writer.beginWrite()
            let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            category.title = "Peer owns this change"
            category.refreshChangeMetadata(explicitlyModified: true)
            await gate.wait(onSuspension: { peerEntered.fulfill() })
            XCTAssertTrue(writer.isInWriteTransaction)
            XCTAssertEqual(category.title, "Peer owns this change")
            try writer.commitWrite()
        }
        addTeardownBlock { await gate.release(); _ = await peer.result }
        await fulfillment(of: [peerEntered], timeout: 5)
        let task = RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
            Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.createFeedWithIdentity(
                    destination: destination, rssURL: rssURL, title: "Complete title",
                    realmConfiguration: configuration
                )
            }
        }
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [submitted], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Only the queued birth should be cancelled")
        } catch is CancellationError {}
        await gate.release()
        try await peer.value
        fixture.realm.refresh()
        XCTAssertEqual(fixture.category.title, "Peer owns this change")
        XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 2)
    }

    func testCancellationAfterCommitKeepsCompleteFeedWithoutPresenting() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let presentation = WebFeedAddPresentation()
        let gate = WebFeedAddGate()
        let committed = expectation(description: "Completed feed is durable before presentation")
        let task = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Complete title", toCategory: fixture.category,
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [committed], timeout: 5)
        fixture.realm.refresh()
        let id = try XCTUnwrap(fixture.realm.objects(Feed.self).first?.id)
        _ = try assertCompleteFeed(fixture.realm, id: id)
        let committedState = snapshot(fixture.realm)
        task.cancel()
        await gate.release()
        let returned = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(returned)
        XCTAssertEqual(snapshot(fixture.realm), committedState)
        XCTAssertNil(model.selectedFeed)
        XCTAssertTrue(presentation.published.isEmpty)
    }

    func testNewerAddPublishesWhileAnOlderCommittedAddIsHeld() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let presentation = WebFeedAddPresentation()
        let gate = WebFeedAddGate()
        let committed = expectation(description: "Older feed committed")
        let older = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Older", toCategory: fixture.category,
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { older.cancel(); await gate.release(); _ = await older.result }
        await fulfillment(of: [committed], timeout: 5)
        let newer = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Newer", toCategory: fixture.category,
            didPublish: { presentation.published.append($0) }
        ))
        let returnedID = try await newer.value
        let newerID = try XCTUnwrap(returnedID)
        let request = model.detailSelectionRequest
        await gate.release()
        let olderID = try await older.value
        fixture.realm.refresh()
        XCTAssertNil(olderID)
        XCTAssertEqual(model.selectedFeed?.id, newerID)
        XCTAssertEqual(model.detailSelectionRequest, request)
        XCTAssertEqual(presentation.published, [newerID])
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 2)
    }

    func testSidebarAndDirectDetailIntentRetireCommittedAddPresentation() async throws {
        for useSidebar in [true, false] {
            let fixture = try await makeFixture()
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            let gate = WebFeedAddGate()
            let committed = expectation(description: "Older feed committed before navigation")
            let task = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "Complete title", toCategory: fixture.category,
                beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
                didPublish: { presentation.published.append($0) }
            ))
            addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
            await fulfillment(of: [committed], timeout: 5)
            if useSidebar {
                // nil-to-nil is a real sidebar intent, not an equal-value no-op.
                model.selectContentRoute(nil, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            } else {
                var path = NavigationPath()
                path.append("User-selected detail")
                model.selectDetailPath(path, detailPath: presentation.pathBinding)
            }
            let request = model.detailSelectionRequest
            let expectedPath = presentation.path
            await gate.release()
            let returned = try await task.value
            fixture.realm.refresh()
            XCTAssertNil(returned)
            XCTAssertEqual(model.detailSelectionRequest, request)
            XCTAssertEqual(presentation.path, expectedPath)
            XCTAssertNil(model.selectedFeed)
            XCTAssertTrue(presentation.published.isEmpty)
            XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
        }
    }

    func testRejectedForeignCategoryDoesNotRetireAnAcceptedPendingAdd() async throws {
        let fixture = try await makeFixture()
        let foreign = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let presentation = WebFeedAddPresentation()
        let gate = WebFeedAddGate()
        let committed = expectation(description: "Accepted feed committed")
        let task = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Complete title", toCategory: fixture.category,
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [committed], timeout: 5)
        let rejected = model.add(rssURL: rssURL, title: "Foreign", toCategory: foreign.category)
        XCTAssertNil(rejected)
        await gate.release()
        let returnedID = try await task.value
        let id = try XCTUnwrap(returnedID)
        XCTAssertEqual(model.selectedFeed?.id, id)
        XCTAssertEqual(presentation.published, [id])
        foreign.realm.refresh()
        XCTAssertTrue(foreign.realm.objects(Feed.self).isEmpty)
    }

    func testRetiredCommittedFeedOrCategoryIsNotPresented() async throws {
        enum Retirement: CaseIterable, Sendable { case recreateFeed, deleteFeed, recreateCategory, manageCategory }
        for retirement in Retirement.allCases {
            let fixture = try await makeFixture()
            let configuration = fixture.realm.configuration
            let categoryID = fixture.category.id
            let model = manager(configuration)
            let presentation = WebFeedAddPresentation()
            let task = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "Complete title", toCategory: fixture.category,
                beforePublication: {
                    try await Self.write(configuration) { writer in
                        let feed = try XCTUnwrap(writer.objects(Feed.self).first)
                        let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                        switch retirement {
                        case .recreateFeed:
                            let replacement = Feed(value: feed)
                            replacement.createdAt = feed.createdAt.addingTimeInterval(1)
                            writer.delete(feed)
                            writer.add(replacement)
                            replacement.refreshChangeMetadata(explicitlyModified: true)
                        case .deleteFeed:
                            feed.isDeleted = true
                            feed.refreshChangeMetadata(explicitlyModified: true)
                        case .recreateCategory:
                            let replacement = FeedCategory(value: category)
                            replacement.createdAt = category.createdAt.addingTimeInterval(1)
                            writer.delete(category)
                            writer.add(replacement)
                            replacement.refreshChangeMetadata(explicitlyModified: true)
                        case .manageCategory:
                            category.opmlURL = URL(string: "https://example.com/managed.opml")
                            category.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                },
                didPublish: { presentation.published.append($0) }
            ))
            let result = try await task.value
            fixture.realm.refresh()
            XCTAssertNil(result)
            XCTAssertNil(model.selectedFeed)
            XCTAssertTrue(presentation.published.isEmpty)
            XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
        }
    }

    func testNewCommandStartedBySelectionPublisherRetainsPriorRouteUntilItSettles() async throws {
        enum ExpectedFailure: Error { case rejected }
        for newerFails in [false, true] {
            let fixture = try await makeFixture()
            let priorCreation = try await create(fixture, title: "Prior")
            fixture.realm.refresh()
            let priorID = try XCTUnwrap(priorCreation?.feedID)
            let prior = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: priorID))
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            model.selectedFeed = prior
            let priorRequest = model.detailSelectionRequest
            model.applyDetailSelectionRequest(priorRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            let priorPath = presentation.path
            let gate = WebFeedAddGate()
            let entered = expectation(description: "New command admitted from actual selection publisher")
            var newerTask: Task<UUID?, Error>?
            var startedNewer = false
            let subscription = model.$selectedFeed.sink { candidate in
                guard !startedNewer, let candidate, candidate.id != priorID else { return }
                startedNewer = true
                newerTask = model.add(
                    rssURL: self.rssURL, title: "Newer", toCategory: fixture.category,
                    beforeWrite: {
                        await gate.wait(onSuspension: { entered.fulfill() })
                        if newerFails { throw ExpectedFailure.rejected }
                    },
                    didPublish: { presentation.published.append($0) }
                )
                if let newer = newerTask {
                    self.addTeardownBlock { newer.cancel(); await gate.release(); _ = await newer.result }
                }
            }
            defer { subscription.cancel() }
            let older = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "Older", toCategory: fixture.category,
                didPublish: { presentation.published.append($0) }
            ))
            let olderResult = try await older.value
            let newer = try XCTUnwrap(newerTask)
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertNil(olderResult)
            XCTAssertEqual(model.selectedFeed?.id, priorID)
            XCTAssertEqual(model.detailSelectionRequest, priorRequest)
            model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            XCTAssertEqual(presentation.path, priorPath)
            XCTAssertTrue(presentation.published.isEmpty)
            await gate.release()
            if newerFails {
                do {
                    _ = try await newer.value
                    XCTFail("The newer failure must remain observable")
                } catch ExpectedFailure.rejected {}
                XCTAssertEqual(model.selectedFeed?.id, priorID)
                XCTAssertEqual(model.detailSelectionRequest, priorRequest)
                XCTAssertTrue(presentation.published.isEmpty)
            } else {
                let returnedID = try await newer.value
                let id = try XCTUnwrap(returnedID)
                XCTAssertEqual(model.selectedFeed?.id, id)
                XCTAssertEqual(presentation.published, [id])
            }
        }
    }

    func testNestedNilAndEqualRowSelectionsFromPublisherRetireOlderAdd() async throws {
        enum Selection: CaseIterable { case clear, prior, incoming }
        for selection in Selection.allCases {
            let fixture = try await makeFixture()
            let priorCreation = try await create(fixture, title: "Prior")
            fixture.realm.refresh()
            let priorID = try XCTUnwrap(priorCreation?.feedID)
            let prior = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: priorID))
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            model.selectedFeed = prior
            let oldRequest = model.detailSelectionRequest
            var reentered = false
            var expectedFeed: Feed?
            let subscription = model.$selectedFeed.sink { candidate in
                guard !reentered, let candidate, candidate.id != priorID else { return }
                reentered = true
                switch selection {
                case .clear: expectedFeed = nil
                case .prior: expectedFeed = prior
                case .incoming: expectedFeed = candidate
                }
                model.selectedFeed = expectedFeed
            }
            defer { subscription.cancel() }
            let task = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "New feed", toCategory: fixture.category,
                didPublish: { presentation.published.append($0) }
            ))
            let result = try await task.value
            XCTAssertNil(result)
            XCTAssertTrue(presentation.published.isEmpty)
            XCTAssertNotEqual(model.detailSelectionRequest, oldRequest)
            XCTAssertEqual(model.selectedFeed?.id, expectedFeed?.id)
            model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            var expected = NavigationPath()
            if let expectedFeed { expected.append(expectedFeed) }
            XCTAssertEqual(presentation.path, expected)
        }
    }

    private func addScript(_ fixture: Fixture) async throws -> UserScript {
        let id = UUID()
        try await Self.write(fixture.realm.configuration) { writer in
            let script = UserScript()
            script.id = id
            script.title = "Newest script"
            writer.add(script)
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        return try XCTUnwrap(fixture.realm.object(ofType: UserScript.self, forPrimaryKey: id))
    }

    func testNestedScriptSelectionFromFeedPublisherWinsWithoutAddPresentation() async throws {
        let fixture = try await makeFixture()
        let script = try await addScript(fixture)
        let model = manager(fixture.realm.configuration)
        let presentation = WebFeedAddPresentation()
        var reentered = false
        let subscription = model.$selectedFeed.sink { candidate in
            guard !reentered, candidate != nil else { return }
            reentered = true
            model.selectedScript = script
        }
        defer { subscription.cancel() }
        let task = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Complete title", toCategory: fixture.category,
            didPublish: { presentation.published.append($0) }
        ))
        let result = try await task.value
        XCTAssertNil(result)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertNil(model.selectedFeed)
        XCTAssertEqual(model.selectedScript?.id, script.id)
        model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
        var expected = NavigationPath()
        expected.append(script)
        XCTAssertEqual(presentation.route, .userScripts)
        XCTAssertEqual(presentation.path, expected)
    }

    func testCommandAdmittedFromScriptPublisherSurvivesScriptRestoration() async throws {
        let fixture = try await makeFixture()
        let script = try await addScript(fixture)
        let model = manager(fixture.realm.configuration)
        let presentation = WebFeedAddPresentation()
        let originalRequest = model.detailSelectionRequest
        let gate = WebFeedAddGate()
        let entered = expectation(description: "Add admitted during script publication")
        var task: Task<UUID?, Error>?
        var reentered = false
        let subscription = model.$selectedScript.sink { candidate in
            guard !reentered, candidate != nil else { return }
            reentered = true
            task = model.add(
                rssURL: self.rssURL, title: "Complete title", toCategory: fixture.category,
                beforeWrite: { await gate.wait(onSuspension: { entered.fulfill() }) },
                didPublish: { presentation.published.append($0) }
            )
        }
        defer { subscription.cancel() }
        model.selectedScript = script
        let command = try XCTUnwrap(task)
        addTeardownBlock { command.cancel(); await gate.release(); _ = await command.result }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertNil(model.selectedScript)
        XCTAssertEqual(model.detailSelectionRequest, originalRequest)
        XCTAssertTrue(presentation.published.isEmpty)
        await gate.release()
        let returnedID = try await command.value
        let id = try XCTUnwrap(returnedID)
        XCTAssertEqual(model.selectedFeed?.id, id)
        XCTAssertEqual(presentation.published, [id])
    }

    func testSelectionDuringRestorationSupersedesBothOlderPublicationAndPendingCommand() async throws {
        let fixture = try await makeFixture()
        let priorCreation = try await create(fixture, title: "Prior")
        let newestCreation = try await create(fixture, title: "User selection")
        fixture.realm.refresh()
        let priorID = try XCTUnwrap(priorCreation?.feedID)
        let newestID = try XCTUnwrap(newestCreation?.feedID)
        let prior = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: priorID))
        let newest = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: newestID))
        let model = manager(fixture.realm.configuration)
        let presentation = WebFeedAddPresentation()
        model.selectedFeed = prior
        let gate = WebFeedAddGate()
        let entered = expectation(description: "Intermediate command waits before birth")
        var intermediate: Task<UUID?, Error>?
        var phase = 0
        let subscription = model.$selectedFeed.sink { candidate in
            guard let candidate else { return }
            if phase == 0, candidate.id != priorID {
                phase = 1
                intermediate = model.add(
                    rssURL: self.rssURL, title: "Intermediate", toCategory: fixture.category,
                    beforeWrite: { await gate.wait(onSuspension: { entered.fulfill() }) },
                    didPublish: { presentation.published.append($0) }
                )
                if let held = intermediate {
                    self.addTeardownBlock { held.cancel(); await gate.release(); _ = await held.result }
                }
            } else if phase == 1, candidate.id == priorID {
                phase = 2
                model.selectedFeed = newest
            }
        }
        defer { subscription.cancel() }
        let older = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Older", toCategory: fixture.category,
            didPublish: { presentation.published.append($0) }
        ))
        let olderResult = try await older.value
        let held = try XCTUnwrap(intermediate)
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(phase, 2)
        XCTAssertNil(olderResult)
        XCTAssertEqual(model.selectedFeed?.id, newestID)
        let newestRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(newestRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
        var expected = NavigationPath()
        expected.append(newest)
        XCTAssertEqual(presentation.path, expected)
        await gate.release()
        let intermediateResult = try await held.value
        XCTAssertNil(intermediateResult)
        XCTAssertEqual(model.selectedFeed?.id, newestID)
        XCTAssertEqual(model.detailSelectionRequest, newestRequest)
        XCTAssertTrue(presentation.published.isEmpty)
    }

    func testAddAndDuplicateShareLatestPublicationIntentInBothDirections() async throws {
        for addIsNewer in [true, false] {
            let fixture = try await makeFixture()
            let sourceCreation = try await create(fixture, title: "Source")
            fixture.realm.refresh()
            let sourceID = try XCTUnwrap(sourceCreation?.feedID)
            let source = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: sourceID))
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            let gate = WebFeedAddGate()
            let committed = expectation(description: "First command committed before its successor")
            let feedReference = ThreadSafeReference(to: source)
            let categoryReference = ThreadSafeReference(to: fixture.category)
            if addIsNewer {
                let older = Task { @RealmBackgroundActor in
                    try await model.duplicate(
                        feed: feedReference, inCategory: categoryReference, overwriteExisting: false,
                        beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) }
                    )
                }
                addTeardownBlock { older.cancel(); await gate.release(); _ = await older.result }
                await fulfillment(of: [committed], timeout: 5)
                let newer = try XCTUnwrap(model.add(
                    rssURL: rssURL, title: "Newest Add", toCategory: fixture.category,
                    didPublish: { presentation.published.append($0) }
                ))
                let returnedID = try await newer.value
                let id = try XCTUnwrap(returnedID)
                let request = model.detailSelectionRequest
                await gate.release()
                try await older.value
                XCTAssertEqual(model.selectedFeed?.id, id)
                XCTAssertEqual(model.detailSelectionRequest, request)
                XCTAssertEqual(presentation.published, [id])
            } else {
                let older = try XCTUnwrap(model.add(
                    rssURL: rssURL, title: "Older Add", toCategory: fixture.category,
                    beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
                    didPublish: { presentation.published.append($0) }
                ))
                addTeardownBlock { older.cancel(); await gate.release(); _ = await older.result }
                await fulfillment(of: [committed], timeout: 5)
                try await model.duplicate(feed: feedReference, inCategory: categoryReference, overwriteExisting: false)
                let id = try XCTUnwrap(model.selectedFeed?.id)
                let request = model.detailSelectionRequest
                XCTAssertNotEqual(id, sourceID)
                XCTAssertEqual(model.selectedFeed?.title, "Source")
                await gate.release()
                let result = try await older.value
                XCTAssertNil(result)
                XCTAssertEqual(model.selectedFeed?.id, id)
                XCTAssertEqual(model.detailSelectionRequest, request)
                XCTAssertTrue(presentation.published.isEmpty)
            }
            fixture.realm.refresh()
            XCTAssertEqual(fixture.realm.objects(Feed.self).count, 3)
        }
    }

    func testNestedRejectedFeedDoesNotReturnThroughRestoration() async throws {
        for rejectedIsForeign in [true, false] {
            let fixture = try await makeFixture()
            let foreign = try await makeFixture()
            let priorCreation = try await create(fixture, title: "Prior")
            let localCreation = try await create(fixture, title: "Deleted")
            let foreignCreation = try await create(foreign, title: "Foreign")
            fixture.realm.refresh()
            foreign.realm.refresh()
            let prior = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: try XCTUnwrap(priorCreation?.feedID)))
            let localID = try XCTUnwrap(localCreation?.feedID)
            try await Self.write(fixture.realm.configuration) { writer in
                let row = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: localID))
                row.isDeleted = true
                row.refreshChangeMetadata(explicitlyModified: true)
            }
            fixture.realm.refresh()
            let rejected: Feed
            if rejectedIsForeign {
                rejected = try XCTUnwrap(foreign.realm.object(ofType: Feed.self, forPrimaryKey: try XCTUnwrap(foreignCreation?.feedID)))
            } else {
                rejected = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: localID))
            }
            let foreignBefore = snapshot(foreign.realm)
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            model.selectedFeed = prior
            var reentered = false
            let subscription = model.$selectedFeed.dropFirst().sink { _ in
                guard !reentered else { return }
                reentered = true
                model.selectedFeed = rejected
            }
            defer { subscription.cancel() }
            let task = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "Committed", toCategory: fixture.category,
                didPublish: { presentation.published.append($0) }
            ))
            let result = try await task.value
            XCTAssertNil(result)
            XCTAssertNil(model.selectedFeed)
            XCTAssertTrue(presentation.published.isEmpty)
            model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            XCTAssertTrue(presentation.path.isEmpty)
            if case .none = model.detailSelectionRequest.target {} else {
                XCTFail("Rejected nested feed must not survive as a detail request")
            }
            foreign.realm.refresh()
            XCTAssertEqual(snapshot(foreign.realm), foreignBefore)
        }
    }

    func testNestedRejectedScriptDoesNotReturnThroughRestoration() async throws {
        for rejectedIsForeign in [true, false] {
            let fixture = try await makeFixture()
            let foreign = try await makeFixture()
            let prior = try await addScript(fixture)
            let incoming = try await addScript(fixture)
            let localRejected = try await addScript(fixture)
            let foreignRejected = try await addScript(foreign)
            let deletedID = localRejected.id
            try await Self.write(fixture.realm.configuration) { writer in
                let script = try XCTUnwrap(writer.object(ofType: UserScript.self, forPrimaryKey: deletedID))
                script.isDeleted = true
                script.refreshChangeMetadata(explicitlyModified: true)
            }
            fixture.realm.refresh()
            let rejected = rejectedIsForeign ? foreignRejected : localRejected
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            model.selectedScript = prior
            let before = snapshot(fixture.realm)
            var reentered = false
            let subscription = model.$selectedScript.dropFirst().sink { _ in
                guard !reentered else { return }
                reentered = true
                model.selectedScript = rejected
            }
            defer { subscription.cancel() }
            model.selectedScript = incoming
            XCTAssertNil(model.selectedScript)
            model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            XCTAssertTrue(presentation.path.isEmpty)
            if case .none = model.detailSelectionRequest.target {} else {
                XCTFail("Rejected nested script must not survive as a detail request")
            }
            XCTAssertEqual(snapshot(fixture.realm), before)
        }
    }

    func testAcceptedSelectionDuringRejectionCleanupSurvivesBothOuterAssignments() async throws {
        for selectsScript in [true, false] {
            let fixture = try await makeFixture()
            let foreign = try await makeFixture()
            let priorCreation = try await create(fixture, title: "Prior")
            let foreignCreation = try await create(foreign, title: "Foreign")
            let script = try await addScript(fixture)
            fixture.realm.refresh()
            foreign.realm.refresh()
            let prior = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: try XCTUnwrap(priorCreation?.feedID)))
            let rejected = try XCTUnwrap(foreign.realm.object(ofType: Feed.self, forPrimaryKey: try XCTUnwrap(foreignCreation?.feedID)))
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            model.selectedFeed = prior
            var phase = 0
            let subscription = model.$selectedFeed.dropFirst().sink { candidate in
                if phase == 0 {
                    phase = 1
                    model.selectedFeed = rejected
                } else if phase == 1, candidate == nil {
                    phase = 2
                    if selectsScript {
                        model.selectedScript = script
                    } else {
                        model.selectedFeed = prior
                    }
                }
            }
            defer { subscription.cancel() }
            let task = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "Committed", toCategory: fixture.category,
                didPublish: { presentation.published.append($0) }
            ))
            let result = try await task.value
            XCTAssertEqual(phase, 2)
            XCTAssertNil(result)
            XCTAssertTrue(presentation.published.isEmpty)
            model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            var expected = NavigationPath()
            if selectsScript {
                expected.append(script)
                XCTAssertEqual(model.selectedScript?.id, script.id)
                XCTAssertNil(model.selectedFeed)
                XCTAssertEqual(presentation.route, .userScripts)
            } else {
                expected.append(prior)
                XCTAssertEqual(model.selectedFeed?.id, prior.id)
                XCTAssertNil(model.selectedScript)
                XCTAssertEqual(presentation.route, .contentCategory(fixture.category.id))
            }
            XCTAssertEqual(presentation.path, expected)
        }
    }

    func testCommandStartedDuringRejectionCleanupKeepsCleanSelectionAndItsOwnIntent() async throws {
        enum ExpectedFailure: Error { case rejected }
        for newerFails in [false, true] {
            let fixture = try await makeFixture()
            let foreign = try await makeFixture()
            let priorCreation = try await create(fixture, title: "Prior")
            let foreignCreation = try await create(foreign, title: "Foreign")
            fixture.realm.refresh()
            foreign.realm.refresh()
            let prior = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: try XCTUnwrap(priorCreation?.feedID)))
            let rejected = try XCTUnwrap(foreign.realm.object(ofType: Feed.self, forPrimaryKey: try XCTUnwrap(foreignCreation?.feedID)))
            let model = manager(fixture.realm.configuration)
            let presentation = WebFeedAddPresentation()
            model.selectedFeed = prior
            let gate = WebFeedAddGate()
            let entered = expectation(description: "New command admitted by rejection cleanup")
            var newerTask: Task<UUID?, Error>?
            var phase = 0
            let subscription = model.$selectedFeed.dropFirst().sink { candidate in
                if phase == 0 {
                    phase = 1
                    model.selectedFeed = rejected
                } else if phase == 1, candidate == nil {
                    phase = 2
                    newerTask = model.add(
                        rssURL: self.rssURL, title: "Newest", toCategory: fixture.category,
                        beforeWrite: {
                            await gate.wait(onSuspension: { entered.fulfill() })
                            if newerFails { throw ExpectedFailure.rejected }
                        },
                        didPublish: { presentation.published.append($0) }
                    )
                    if let newer = newerTask {
                        self.addTeardownBlock { newer.cancel(); await gate.release(); _ = await newer.result }
                    }
                }
            }
            defer { subscription.cancel() }
            let older = try XCTUnwrap(model.add(
                rssURL: rssURL, title: "Older", toCategory: fixture.category,
                didPublish: { presentation.published.append($0) }
            ))
            let olderResult = try await older.value
            let newer = try XCTUnwrap(newerTask)
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertEqual(phase, 2)
            XCTAssertNil(olderResult)
            XCTAssertNil(model.selectedFeed)
            if case .none = model.detailSelectionRequest.target {} else {
                XCTFail("A rejected row must remain cleared while its successor waits")
            }
            model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: presentation.routeBinding, detailPath: presentation.pathBinding)
            XCTAssertTrue(presentation.path.isEmpty)
            XCTAssertTrue(presentation.published.isEmpty)
            await gate.release()
            if newerFails {
                do {
                    _ = try await newer.value
                    XCTFail("The newer failure must remain observable")
                } catch ExpectedFailure.rejected {}
                XCTAssertNil(model.selectedFeed)
                if case .none = model.detailSelectionRequest.target {} else {
                    XCTFail("A failed successor cannot resurrect the rejected row")
                }
                XCTAssertTrue(presentation.published.isEmpty)
            } else {
                let returnedID = try await newer.value
                let id = try XCTUnwrap(returnedID)
                XCTAssertEqual(model.selectedFeed?.id, id)
                XCTAssertEqual(presentation.published, [id])
            }
        }
    }

    private struct DiskFixture {
        let configuration: Realm.Configuration
        let replacementConfiguration: Realm.Configuration
        let retiredConfiguration: Realm.Configuration
        let categoryID: UUID
        let original: WebFeedAddSnapshot
        let replacement: WebFeedAddSnapshot
    }

    private func diskSnapshot(_ configuration: Realm.Configuration) throws -> WebFeedAddSnapshot {
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
            .appendingPathComponent("web-feed-add-\(UUID())", isDirectory: true)
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
        let categoryID = UUID()
        for (store, label) in [(configuration, "Original"), (replacementConfiguration, "Replacement")] {
            try autoreleasepool {
                let realm = try Realm(configuration: store)
                defer { realm.invalidate() }
                try realm.write {
                    let category = FeedCategory()
                    category.id = categoryID
                    category.createdAt = Date(timeIntervalSinceReferenceDate: 100)
                    category.title = label
                    realm.add(category)
                    category.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
        let original = try diskSnapshot(configuration)
        let replacement = try diskSnapshot(replacementConfiguration)
        let expectedRecords: Set<String> = ["\(FeedCategory.className()).\(categoryID)"]
        XCTAssertEqual(Set(original.generations.keys), expectedRecords)
        XCTAssertEqual(Set(replacement.generations.keys), expectedRecords)
        return DiskFixture(
            configuration: configuration, replacementConfiguration: replacementConfiguration,
            retiredConfiguration: retiredConfiguration, categoryID: categoryID,
            original: original, replacement: replacement
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

    func testCompletedFeedRejectsPhysicalReplacementBeforeAndAfterOpening() async throws {
        for replaceAfterOpening in [false, true] {
            let fixture = try makeDiskFixture()
            let configuration = fixture.configuration
            let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
            let destination = LibraryFeedCreationDestination.category(
                id: fixture.categoryID, createdAt: Date(timeIntervalSinceReferenceDate: 100)
            )
            let rssURL = rssURL
            let gate = WebFeedAddGate()
            let opened = expectation(description: "Original store opened before birth")
            if !replaceAfterOpening { try replaceDiskFile(fixture) }
            let task = Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.createFeedWithIdentity(
                    destination: destination, rssURL: rssURL, title: "Complete title",
                    realmConfiguration: configuration, storageAdmission: admission,
                    beforeWrite: {
                        if replaceAfterOpening {
                            await gate.wait(onSuspension: { opened.fulfill() })
                        }
                    }
                )
            }
            addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
            if replaceAfterOpening {
                await fulfillment(of: [opened], timeout: 5)
                try replaceDiskFile(fixture)
                await gate.release()
            }
            do {
                _ = try await task.value
                XCTFail("Completed feed creation cannot adopt a replacement physical file")
            } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
            await Self.releaseDiskCache(configuration)
            XCTAssertEqual(try diskSnapshot(configuration), fixture.replacement)
            XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
        }
    }

    func testPhysicalReplacementAfterCommitKeepsOriginalFeedWithoutOpeningReplacement() async throws {
        let fixture = try makeDiskFixture()
        let model = manager(fixture.configuration)
        let presentation = WebFeedAddPresentation()
        let gate = WebFeedAddGate()
        let committed = expectation(description: "Original physical store has the committed feed")
        let task = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Complete title",
            destination: .category(id: fixture.categoryID, createdAt: Date(timeIntervalSinceReferenceDate: 100)),
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [committed], timeout: 5)
        let committedState = try diskSnapshot(fixture.configuration)
        XCTAssertEqual(committedState.feeds.count, 1)
        XCTAssertEqual(committedState.feeds.first?.rssURL, rssURL)
        XCTAssertEqual(committedState.feeds.first?.title, "Complete title")
        try replaceDiskFile(fixture)
        await gate.release()
        let result = try await task.value
        XCTAssertNil(result)
        XCTAssertNil(model.selectedFeed)
        XCTAssertTrue(presentation.published.isEmpty)
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), committedState)
    }

    func testNonobservingManagerCanAdmitFirstCreationOfAnAbsentDiskStore() async throws {
        // This isolates Add's first-open admission. The public initializer's
        // observer startup is a separate native scheduling gate: the Gaps open
        // observer is instance-scoped and cannot replace its fixed shared actor.
        suppressDownloadObserverInitialization()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-feed-first-creation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = configured(Realm.Configuration(fileURL: directory.appendingPathComponent("new.realm")))
        addTeardownBlock {
            await Self.releaseDiskCache(configuration)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
        let model = manager(configuration)
        let presentation = WebFeedAddPresentation()
        let task = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "Complete title",
            didPublish: { presentation.published.append($0) }
        ))
        let returnedID = try await task.value
        let id = try XCTUnwrap(returnedID)
        let after = try diskSnapshot(configuration)
        XCTAssertEqual(after.feeds.map(\.id), [id])
        XCTAssertEqual(after.feeds.first?.rssURL, rssURL)
        XCTAssertEqual(after.feeds.first?.title, "Complete title")
        XCTAssertEqual(after.categories.count, 1)
        XCTAssertEqual(after.categories.first?.title, "My Library")
        XCTAssertEqual(after.libraries.count, 1)
        XCTAssertEqual(after.libraries.first?.categoryIDs, after.categories.map(\.id))
        XCTAssertEqual(after.generations.count, 3)
        XCTAssertEqual(model.selectedFeed?.id, id)
        XCTAssertEqual(presentation.published, [id])
    }
}
