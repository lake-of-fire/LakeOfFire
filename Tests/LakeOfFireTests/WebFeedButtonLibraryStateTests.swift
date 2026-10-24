import BigSyncKit
import Combine
import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor WebFeedObservationGate {
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

@MainActor
private final class WebFeedObservationAttempts {
    var count = 0
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
private final class WebFeedMenuHostBindings {
    var contentRoute: ContentPaneRoute?
    var detailPath = NavigationPath()

    var route: Binding<ContentPaneRoute?> {
        Binding(get: { self.contentRoute }, set: { self.contentRoute = $0 })
    }

    var path: Binding<NavigationPath> {
        Binding(get: { self.detailPath }, set: { self.detailPath = $0 })
    }
}

@MainActor
private final class WebFeedPublicationProbe {
    private let expectation: XCTestExpectation
    private let predicate: @MainActor () -> Bool
    private var fulfilled = false
    private var subscription: AnyCancellable?

    init(
        state: WebFeedButtonLibraryState,
        expectation: XCTestExpectation,
        predicate: @escaping @MainActor () -> Bool
    ) {
        self.expectation = expectation
        self.predicate = predicate
        subscription = state.objectWillChange.sink { [weak self] _ in
            // @Published emits before assignment. Inspect the production output
            // on the next actor turn, after the observed publication settles.
            Task { @MainActor [weak self] in self?.check() }
        }
    }

    private func check() {
        guard !fulfilled, predicate() else { return }
        fulfilled = true
        expectation.fulfill()
    }
}

private struct WebFeedObservedStore: Equatable {
    struct Category: Equatable {
        let id: UUID
        let createdAt: Date
        let title: String
        let isDeleted: Bool
        let isArchived: Bool
        let opmlURL: URL?
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }
    struct FeedRow: Equatable {
        let id: UUID
        let createdAt: Date
        let title: String
        let rssURL: URL
        let categoryID: UUID?
        let isDeleted: Bool
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }
    struct Library: Equatable {
        let id: UUID
        let createdAt: Date
        let categoryIDs: [UUID]
        let userScriptIDs: [UUID]
        let isDeleted: Bool
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }
    struct Mutation: Equatable {
        let recordName: String
        let entityType: String
        let objectIdentifier: String
        let generation: String
        let accountScope: String?
        let replicaGeneration: String?
        let requiresRecovery: Bool
        let changedAt: Date
    }
    let categories: [Category]
    let feeds: [FeedRow]
    let libraries: [Library]
    let mutations: [Mutation]
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class WebFeedButtonLibraryStateTests: XCTestCase, @unchecked Sendable {
    private struct Identities: Sendable {
        let category = UUID()
        let secondCategory = UUID()
        let feed = UUID()
        let library = UUID()
    }

    private struct Fixture {
        let realm: Realm
        let identities: Identities
        let rssURL: URL
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

    @RealmBackgroundActor
    private static func write(
        _ configuration: Realm.Configuration,
        _ mutation: @escaping @RealmBackgroundActor @Sendable (Realm) throws -> Void
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await realm.asyncWritePreservingOwnership { try mutation(realm) }
    }

    private static func populate(
        _ realm: Realm, identities: Identities, label: String, rssURL: URL
    ) {
        let first = FeedCategory()
        first.id = identities.category
        first.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        first.title = label + " first"
        let second = FeedCategory()
        second.id = identities.secondCategory
        second.createdAt = Date(timeIntervalSinceReferenceDate: 101)
        second.title = label + " second"
        let feed = Feed()
        feed.id = identities.feed
        feed.createdAt = Date(timeIntervalSinceReferenceDate: 200)
        feed.categoryID = first.id
        feed.title = label + " feed"
        feed.rssUrl = rssURL
        let library = LibraryConfiguration()
        library.id = identities.library
        library.createdAt = Date(timeIntervalSinceReferenceDate: 300)
        library.categoryIDs.append(objectsIn: [first.id, second.id])
        realm.add([first, second])
        realm.add(feed)
        realm.add(library)
        first.refreshChangeMetadata(explicitlyModified: true)
        second.refreshChangeMetadata(explicitlyModified: true)
        feed.refreshChangeMetadata(explicitlyModified: true)
        library.refreshChangeMetadata(explicitlyModified: true)
    }

    private func fixture(label: String = "A", identities: Identities = .init()) async throws -> Fixture {
        let observesDownloads = LibraryDataManager.observesDownloadController
        LibraryDataManager.observesDownloadController = false
        _ = LibraryDataManager.shared
        LibraryDataManager.observesDownloadController = observesDownloads
        let configuration = configured(Realm.Configuration(inMemoryIdentifier: UUID().uuidString))
        let rssURL = URL(string: "https://example.com/" + label + ".rss")!
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        try realm.write {
            Self.populate(realm, identities: identities, label: label, rssURL: rssURL)
        }
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 4)
        return Fixture(realm: realm, identities: identities, rssURL: rssURL)
    }

    private func state(
        _ fixture: Fixture,
        beforeRefresh: (@MainActor @Sendable () async throws -> Void)? = nil,
        beforePublication: (@MainActor @Sendable () async throws -> Void)? = nil
    ) -> WebFeedButtonLibraryState {
        let configuration = fixture.realm.configuration
        let state = WebFeedButtonLibraryState(
            realmConfiguration: configuration,
            storageAdmission: RealmBackgroundActor.shared.captureStorageAdmission(for: configuration),
            beforeRefresh: beforeRefresh,
            beforePublication: beforePublication
        )
        addTeardownBlock { await state.stopObservation() }
        return state
    }

    private func start(_ state: WebFeedButtonLibraryState, presentationID: UUID = UUID()) async throws -> UUID {
        let work = try XCTUnwrap(state.beginObservation(for: presentationID))
        await work.value
        XCTAssertFalse(state.hasFailed)
        XCTAssertNotNil(state.userCategories)
        return presentationID
    }

    private func manager(_ fixture: Fixture) -> LibraryManagerViewModel {
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = fixture.realm.configuration
        return LibraryManagerViewModel(observesRealm: false)
    }

    private func snapshot(_ realm: Realm) -> WebFeedObservedStore {
        WebFeedObservedStore(
            categories: realm.objects(FeedCategory.self).map {
                .init(id: $0.id, createdAt: $0.createdAt, title: $0.title,
                      isDeleted: $0.isDeleted, isArchived: $0.isArchived, opmlURL: $0.opmlURL,
                      modifiedAt: $0.modifiedAt, explicitlyModifiedAt: $0.explicitlyModifiedAt)
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            feeds: realm.objects(Feed.self).map {
                .init(id: $0.id, createdAt: $0.createdAt, title: $0.title, rssURL: $0.rssUrl,
                      categoryID: $0.categoryID, isDeleted: $0.isDeleted,
                      modifiedAt: $0.modifiedAt, explicitlyModifiedAt: $0.explicitlyModifiedAt)
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            libraries: realm.objects(LibraryConfiguration.self).map {
                .init(id: $0.id, createdAt: $0.createdAt, categoryIDs: Array($0.categoryIDs),
                      userScriptIDs: Array($0.userScriptIDs), isDeleted: $0.isDeleted,
                      modifiedAt: $0.modifiedAt, explicitlyModifiedAt: $0.explicitlyModifiedAt)
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            mutations: realm.objects(BigSyncPendingMutation.self).map {
                .init(recordName: $0.recordName, entityType: $0.entityType,
                      objectIdentifier: $0.objectIdentifier, generation: $0.generation,
                      accountScope: $0.accountScopeIdentifier,
                      replicaGeneration: $0.replicaBindingGenerationIdentifier,
                      requiresRecovery: $0.requiresReplicaBindingRecovery, changedAt: $0.changedAt)
            }.sorted { $0.recordName < $1.recordName }
        )
    }

    func testActualManagerStateKeepsBothNotificationPathsOnItsCapturedStore() async throws {
        let identities = Identities()
        let original = try await fixture(label: "A", identities: identities)
        let replacement = try await fixture(label: "B", identities: identities)
        let originalGlobal = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalGlobal }
        LibraryDataManager.realmConfiguration = original.realm.configuration
        let model = LibraryManagerViewModel(observesRealm: false)
        LibraryDataManager.realmConfiguration = replacement.realm.configuration
        let state = model.webFeedButtonLibraryState
        addTeardownBlock { await state.stopObservation() }
        let untouchedA = snapshot(original.realm)
        let untouchedB = snapshot(replacement.realm)
        _ = try await start(state)
        XCTAssertEqual(state.userCategories?.map(\.title), ["A first", "A second"])
        XCTAssertEqual(state.feed(matching: [original.rssURL])?.feedID, identities.feed)
        XCTAssertNil(state.feed(matching: [replacement.rssURL]))
        original.realm.refresh()
        replacement.realm.refresh()
        XCTAssertEqual(snapshot(original.realm), untouchedA)
        XCTAssertEqual(snapshot(replacement.realm), untouchedB)

        let reordered = expectation(description: "Actual LibraryConfiguration observation publishes A order")
        let orderProbe = WebFeedPublicationProbe(state: state, expectation: reordered) {
            state.userCategories?.map(\.id) == [identities.secondCategory, identities.category]
        }
        try await Self.write(original.realm.configuration) { realm in
            let library = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: identities.library))
            library.categoryIDs.removeAll()
            library.categoryIDs.append(objectsIn: [identities.secondCategory, identities.category])
            library.refreshChangeMetadata(explicitlyModified: true)
        }
        await fulfillment(of: [reordered], timeout: 5)
        withExtendedLifetime(orderProbe) {}

        let newRSSURL = URL(string: "https://example.com/A-updated.rss")!
        let changedFeed = expectation(description: "Actual Feed observation publishes A URL")
        let feedProbe = WebFeedPublicationProbe(state: state, expectation: changedFeed) {
            state.feed(matching: [newRSSURL])?.feedID == identities.feed
        }
        try await Self.write(original.realm.configuration) { realm in
            let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: identities.feed))
            feed.rssUrl = newRSSURL
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        await fulfillment(of: [changedFeed], timeout: 5)
        withExtendedLifetime(feedProbe) {}
        XCTAssertNil(state.feed(matching: [original.rssURL]))
        replacement.realm.refresh()
        XCTAssertEqual(snapshot(replacement.realm), untouchedB)
    }

    func testCategoryNotificationsUpdateValueLabelsAndEligibility() async throws {
        let fixture = try await fixture()
        let state = state(fixture)
        _ = try await start(state)
        let captured = try XCTUnwrap(state.userCategories?.first)
        let choice = try XCTUnwrap(LibraryWebFeedAddChoice.choices(for: [captured]).first)
        let renamed = expectation(description: "Actual category observation updates value labels")
        let probe = WebFeedPublicationProbe(state: state, expectation: renamed) {
            state.userCategories?.first?.title == "New title"
                && state.userCategories?.count == 1
        }
        let identities = fixture.identities
        try await Self.write(fixture.realm.configuration) { realm in
            let first = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: identities.category))
            let second = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: identities.secondCategory))
            first.title = "New title"
            first.refreshChangeMetadata(explicitlyModified: true)
            second.opmlURL = URL(string: "https://example.com/managed.opml")
            second.refreshChangeMetadata(explicitlyModified: true)
        }
        await fulfillment(of: [renamed], timeout: 5)
        withExtendedLifetime(probe) {}
        XCTAssertEqual(captured.title, "A first")
        XCTAssertEqual(choice.title, "Add Feed to A first")
        XCTAssertEqual(captured.destination, .category(id: captured.id, createdAt: captured.createdAt))
    }

    func testPhysicalDeletionCannotEscapeTheCachedFeedAccessor() async throws {
        let fixture = try await fixture()
        let state = state(fixture)
        _ = try await start(state)
        let selection = try XCTUnwrap(state.feed(matching: [fixture.rssURL]))
        let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
        // Same-actor removal and immediate lookup precede the debounce turn.
        try fixture.realm.write { fixture.realm.delete(feed) }
        XCTAssertTrue(feed.isInvalidated)
        XCTAssertNil(state.feed(matching: [fixture.rssURL]))
        XCTAssertNil(state.resolve(selection))
    }

    func testCachedActionDoesNotReadOrCancelAnotherOwnersUncommittedWrite() async throws {
        let fixture = try await fixture()
        let state = state(fixture)
        _ = try await start(state)
        let selection = try XCTUnwrap(state.feed(matching: [fixture.rssURL]))
        let before = snapshot(fixture.realm)
        let category = try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: fixture.identities.category))
        try fixture.realm.beginWrite()
        defer { if fixture.realm.isInWriteTransaction { fixture.realm.cancelWrite() } }
        category.title = "Uncommitted title"
        category.refreshChangeMetadata(explicitlyModified: true)
        XCTAssertNil(state.resolve(selection))
        XCTAssertNil(state.feed(matching: [fixture.rssURL]))
        XCTAssertEqual(state.userCategories?.first?.title, "A first")
        XCTAssertTrue(fixture.realm.isInWriteTransaction)
        fixture.realm.cancelWrite()
        XCTAssertEqual(snapshot(fixture.realm), before)
        XCTAssertNotNil(state.resolve(selection))
    }

    func testCachedTombstonesAndRetargetedURLsAreRejectedBeforeRefreshPublication() async throws {
        for tombstone in [false, true] {
            let fixture = try await fixture()
            let state = state(fixture)
            _ = try await start(state)
            let selection = try XCTUnwrap(state.feed(matching: [fixture.rssURL]))
            let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
            try fixture.realm.write {
                if tombstone { feed.isDeleted = true }
                else { feed.rssUrl = URL(string: "https://example.com/retargeted.rss")! }
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
            XCTAssertNil(state.feed(matching: [fixture.rssURL]))
            XCTAssertNil(state.resolve(selection))
        }
    }

    func testSameKeyFeedAndCategoryRecreationCannotReuseCachedActionIdentity() async throws {
        for recreateCategory in [false, true] {
            let fixture = try await fixture()
            let state = state(fixture)
            _ = try await start(state)
            let selection = try XCTUnwrap(state.feed(matching: [fixture.rssURL]))
            try fixture.realm.write {
                if recreateCategory {
                    let old = try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: fixture.identities.category))
                    let replacement = FeedCategory(value: old)
                    replacement.createdAt = old.createdAt.addingTimeInterval(1)
                    fixture.realm.delete(old)
                    fixture.realm.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                } else {
                    let old = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
                    let replacement = Feed(value: old)
                    replacement.createdAt = old.createdAt.addingTimeInterval(1)
                    fixture.realm.delete(old)
                    fixture.realm.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            XCTAssertNil(state.resolve(selection))
            XCTAssertNil(state.feed(matching: [fixture.rssURL]))
        }
    }

    func testCapturedCategoryLabelsSurvivePhysicalRemovalAndDoNotRetargetAdd() async throws {
        let fixture = try await fixture()
        let state = state(fixture)
        _ = try await start(state)
        let captured = try XCTUnwrap(state.userCategories?.first)
        let choice = try XCTUnwrap(LibraryWebFeedAddChoice.choices(for: [captured]).first)
        let originalGlobal = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalGlobal }
        LibraryDataManager.realmConfiguration = fixture.realm.configuration
        let model = LibraryManagerViewModel(observesRealm: false)
        let category = try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: captured.id))
        try fixture.realm.write { fixture.realm.delete(category) }
        XCTAssertEqual(captured.title, "A first")
        XCTAssertEqual(choice.title, "Add Feed to A first")
        let before = snapshot(fixture.realm)
        let task = try XCTUnwrap(model.add(
            rssURL: URL(string: "https://example.com/new.rss")!,
            title: "Retired destination", destination: choice.destination
        ))
        let result = try await task.value
        XCTAssertNil(result)
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm).feeds, before.feeds)
        XCTAssertNil(model.selectedFeed)
    }

    func testOneDisappearingButtonKeepsTheOtherPresentationObserved() async throws {
        let fixture = try await fixture()
        let state = state(fixture)
        let first = try await start(state)
        let second = UUID()
        _ = state.beginObservation(for: second)
        XCTAssertNil(state.endObservation(for: first))
        XCTAssertNotNil(state.feed(matching: [fixture.rssURL]))
        let renamed = expectation(description: "Remaining button still receives category changes")
        let probe = WebFeedPublicationProbe(state: state, expectation: renamed) {
            state.userCategories?.first?.title == "Still observed"
        }
        let id = fixture.identities.category
        try await Self.write(fixture.realm.configuration) { realm in
            let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: id))
            category.title = "Still observed"
            category.refreshChangeMetadata(explicitlyModified: true)
        }
        await fulfillment(of: [renamed], timeout: 5)
        withExtendedLifetime(probe) {}
        let settlement = try XCTUnwrap(state.endObservation(for: second))
        await settlement.value
        XCTAssertNil(state.userCategories)
        XCTAssertNil(state.feed(matching: [fixture.rssURL]))
    }

    func testRetiredStartupFailureCannotClearANewerObservation() async throws {
        enum ExpectedFailure: Error { case oldRequest }
        let fixture = try await fixture()
        let gate = WebFeedObservationGate()
        let attempts = WebFeedObservationAttempts()
        let entered = expectation(description: "Old startup holds after captured consolidation")
        let state = state(fixture, beforePublication: {
            attempts.count += 1
            if attempts.count == 1 {
                await gate.wait(onSuspension: { entered.fulfill() })
                throw ExpectedFailure.oldRequest
            }
        })
        addTeardownBlock { await gate.release(); await state.stopObservation() }
        let first = UUID()
        let oldWork = try XCTUnwrap(state.beginObservation(for: first))
        await fulfillment(of: [entered], timeout: 5)
        let oldSettlement = try XCTUnwrap(state.endObservation(for: first))
        let second = UUID()
        let newerWork = try XCTUnwrap(state.beginObservation(for: second))
        await newerWork.value
        XCTAssertFalse(state.hasFailed)
        XCTAssertEqual(state.userCategories?.map(\.title), ["A first", "A second"])
        await gate.release()
        await oldWork.value
        await oldSettlement.value
        XCTAssertFalse(state.hasFailed)
        XCTAssertEqual(state.userCategories?.map(\.title), ["A first", "A second"])
        XCTAssertNotNil(state.feed(matching: [fixture.rssURL]))
    }

    func testCancelledStartupSettlesBeforeRetirementAndCanRestart() async throws {
        let fixture = try await fixture()
        let before = snapshot(fixture.realm)
        let gate = WebFeedObservationGate()
        let entered = expectation(description: "Startup waits before admitted work")
        let attempts = WebFeedObservationAttempts()
        let state = state(fixture, beforeRefresh: {
            attempts.count += 1
            if attempts.count == 1 {
                await gate.wait(onSuspension: { entered.fulfill() })
            }
        })
        addTeardownBlock { await gate.release(); await state.stopObservation() }
        let first = UUID()
        let work = try XCTUnwrap(state.beginObservation(for: first))
        await fulfillment(of: [entered], timeout: 5)
        let settlement = try XCTUnwrap(state.endObservation(for: first))
        XCTAssertTrue(work.isCancelled)
        XCTAssertNil(state.userCategories)
        await gate.release()
        await settlement.value
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), before)
        _ = try await start(state)
        XCTAssertNotNil(state.feed(matching: [fixture.rssURL]))
    }

    func testCurrentStartupFailureCanRetryWithoutAdoptingChangedGlobals() async throws {
        enum ExpectedFailure: Error { case firstAttempt }
        let fixture = try await fixture()
        let other = try await self.fixture(label: "B")
        let untouched = snapshot(other.realm)
        let attempts = WebFeedObservationAttempts()
        let state = state(fixture, beforeRefresh: {
            attempts.count += 1
            if attempts.count == 1 { throw ExpectedFailure.firstAttempt }
        })
        let first = try XCTUnwrap(state.beginObservation(for: UUID()))
        await first.value
        XCTAssertTrue(state.hasFailed)
        XCTAssertNil(state.userCategories)
        let originalGlobal = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalGlobal }
        LibraryDataManager.realmConfiguration = other.realm.configuration
        let retry = try XCTUnwrap(state.retry())
        await retry.value
        XCTAssertFalse(state.hasFailed)
        XCTAssertEqual(state.userCategories?.map(\.title), ["A first", "A second"])
        other.realm.refresh()
        XCTAssertEqual(snapshot(other.realm), untouched)
    }


    func testEditUsesAFreshReceiptAndPresentsTheCurrentFeed() async throws {
        let fixture = try await fixture()
        let model = manager(fixture)
        let state = model.webFeedButtonLibraryState
        addTeardownBlock { await state.stopObservation() }
        _ = try await start(state)
        let selection = try XCTUnwrap(state.feed(matching: [fixture.rssURL]))
        let previousRequest = model.detailSelectionRequest
        let published = model.selectExistingWebFeed(
            resolving: { state.resolve(selection) },
            didPublish: { model.isLibraryPresented = true }
        )
        XCTAssertTrue(published)
        XCTAssertTrue(model.isLibraryPresented)
        XCTAssertEqual(model.selectedFeed?.id, selection.feedID)
        XCTAssertNotEqual(model.detailSelectionRequest.id, previousRequest.id)
    }

    func testEditCannotPresentAnEqualPriorRowAfterPublisherAdmitsANewerAdd() async throws {
        enum ExpectedFailure: Error { case rejected }
        for newerFails in [false, true] {
            let fixture = try await fixture()
            let model = manager(fixture)
            let state = model.webFeedButtonLibraryState
            addTeardownBlock { await state.stopObservation() }
            _ = try await start(state)
            let selection = try XCTUnwrap(state.feed(matching: [fixture.rssURL]))
            let feed = try XCTUnwrap(state.resolve(selection))
            let category = try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: selection.categoryID))
            model.selectedFeed = feed
            let priorRequest = model.detailSelectionRequest
            let gate = WebFeedObservationGate()
            let entered = expectation(description: "New Add owns publication while the Edit assignment sends")
            var armed = false
            var reentered = false
            var command: Task<UUID?, Error>?
            let subscription = model.$selectedFeed.sink { candidate in
                guard armed, !reentered, candidate != nil else { return }
                reentered = true
                command = model.add(
                    rssURL: fixture.rssURL, title: "Newer Add", toCategory: category,
                    beforeWrite: {
                        await gate.wait(onSuspension: { entered.fulfill() })
                        if newerFails { throw ExpectedFailure.rejected }
                    },
                    didPublish: { _ in model.isLibraryPresented = true }
                )
            }
            defer { subscription.cancel() }
            armed = true
            let published = model.selectExistingWebFeed(
                resolving: { state.resolve(selection) },
                didPublish: { model.isLibraryPresented = true }
            )
            XCTAssertFalse(published)
            XCTAssertFalse(model.isLibraryPresented)
            XCTAssertEqual(model.selectedFeed?.id, selection.feedID)
            XCTAssertEqual(model.detailSelectionRequest, priorRequest)
            let task = try XCTUnwrap(command)
            addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
            await fulfillment(of: [entered], timeout: 5)
            await gate.release()
            if newerFails {
                do {
                    _ = try await task.value
                    XCTFail("The newer Add failure must remain observable")
                } catch ExpectedFailure.rejected {}
                XCTAssertFalse(model.isLibraryPresented)
                XCTAssertEqual(model.detailSelectionRequest, priorRequest)
            } else {
                let id = try await task.value
                XCTAssertEqual(model.selectedFeed?.id, try XCTUnwrap(id))
                XCTAssertTrue(model.isLibraryPresented)
            }
        }
    }

    func testNestedSameIncomingSelectionCannotMintTheEditReceipt() async throws {
        let fixture = try await fixture()
        let model = manager(fixture)
        let state = model.webFeedButtonLibraryState
        addTeardownBlock { await state.stopObservation() }
        _ = try await start(state)
        let selection = try XCTUnwrap(state.feed(matching: [fixture.rssURL]))
        var reentered = false
        let subscription = model.$selectedFeed.sink { candidate in
            guard !reentered, let candidate else { return }
            reentered = true
            model.selectedFeed = candidate
        }
        defer { subscription.cancel() }
        let published = model.selectExistingWebFeed(
            resolving: { state.resolve(selection) },
            didPublish: { model.isLibraryPresented = true }
        )
        XCTAssertTrue(reentered)
        XCTAssertFalse(published)
        XCTAssertFalse(model.isLibraryPresented)
        XCTAssertEqual(model.selectedFeed?.id, selection.feedID)
    }

    func testInitialEditResolutionDoesNotOverrideSynchronousRealmRefreshSelection() async throws {
        let fixture = try await fixture()
        let model = manager(fixture)
        let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
        let script = UserScript()
        try fixture.realm.write {
            fixture.realm.add(script)
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.autorefresh = false
        defer { fixture.realm.autorefresh = true }
        var notificationCount = 0
        let token = fixture.realm.observe { notification, _ in
            guard notification == .didChange else { return }
            notificationCount += 1
            model.selectedScript = script
        }
        defer { token.invalidate() }
        let feedID = fixture.identities.feed
        try await Self.write(fixture.realm.configuration) { realm in
            let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
            feed.title = "Intervening writer"
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        XCTAssertEqual(notificationCount, 0)
        let published = model.selectExistingWebFeed(
            resolving: {
                _ = fixture.realm.refresh()
                return feed
            },
            didPublish: { model.isLibraryPresented = true }
        )
        XCTAssertEqual(notificationCount, 1)
        XCTAssertFalse(published)
        XCTAssertFalse(model.isLibraryPresented)
        XCTAssertEqual(model.selectedScript?.id, script.id)
        XCTAssertNil(model.selectedFeed)
    }

    func testFinalEditResolutionRechecksTheExactRequestAfterReentry() async throws {
        let fixture = try await fixture()
        let model = manager(fixture)
        let state = model.webFeedButtonLibraryState
        addTeardownBlock { await state.stopObservation() }
        _ = try await start(state)
        let selection = try XCTUnwrap(state.feed(matching: [fixture.rssURL]))
        let script = UserScript()
        try fixture.realm.write {
            fixture.realm.add(script)
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        var resolutions = 0
        let published = model.selectExistingWebFeed(
            resolving: {
                resolutions += 1
                if resolutions == 2 {
                    // The real view's resolver refreshes Realm and can deliver
                    // synchronous selection callbacks at this same boundary.
                    model.selectedScript = script
                }
                return state.resolve(selection)
            },
            didPublish: { model.isLibraryPresented = true }
        )
        XCTAssertEqual(resolutions, 2)
        XCTAssertFalse(published)
        XCTAssertFalse(model.isLibraryPresented)
        XCTAssertEqual(model.selectedScript?.id, script.id)
        if case .script(let id, _) = model.detailSelectionRequest.target {
            XCTAssertEqual(id, script.id)
        } else {
            XCTFail("The resolver's successor must retain its exact detail request")
        }
    }

    func testManageCategoriesRetiresCommittedAddAndClearsTheActualTypedHost() async throws {
        for startsOnFeed in [true, false] {
            let fixture = try await fixture()
            let model = manager(fixture)
            let host = WebFeedMenuHostBindings()
            let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
            let category = try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: fixture.identities.category))
            let script = UserScript()
            try fixture.realm.write {
                fixture.realm.add(script)
                script.refreshChangeMetadata(explicitlyModified: true)
            }
            if startsOnFeed {
                model.selectedFeed = feed
            } else {
                model.selectedScript = script
            }
            let priorRequest = model.detailSelectionRequest
            model.applyDetailSelectionRequest(priorRequest, contentRoute: host.route, detailPath: host.path)
            XCTAssertNotNil(host.contentRoute)
            XCTAssertFalse(host.detailPath.isEmpty)
            let gate = WebFeedObservationGate()
            let committed = expectation(description: "Add committed before Manage Categories")
            let addedURL = URL(string: "https://example.com/committed-before-manage.rss")!
            var publications = 0
            let task = try XCTUnwrap(model.add(
                rssURL: addedURL, title: "Committed feed", toCategory: category,
                beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
                didPublish: { _ in
                    publications += 1
                    model.isLibraryPresented = true
                }
            ))
            addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
            await fulfillment(of: [committed], timeout: 5)
            fixture.realm.refresh()
            let committedStore = snapshot(fixture.realm)
            XCTAssertEqual(committedStore.feeds.filter { $0.rssURL == addedURL }.count, 1)

            XCTAssertTrue(model.manageLibraryCategories())
            XCTAssertTrue(model.isLibraryPresented)
            XCTAssertNil(model.selectedFeed)
            XCTAssertNil(model.selectedScript)
            let managementRequest = model.detailSelectionRequest
            XCTAssertEqual(managementRequest.target, .libraryRoot)
            model.applyDetailSelectionRequest(managementRequest, contentRoute: host.route, detailPath: host.path)
            XCTAssertNil(host.contentRoute)
            XCTAssertTrue(host.detailPath.isEmpty)

            // Dismissal makes any stale Add callback observably reopen the UI.
            model.isLibraryPresented = false
            await gate.release()
            let result = try await task.value
            XCTAssertNil(result)
            XCTAssertEqual(publications, 0)
            XCTAssertFalse(model.isLibraryPresented)
            XCTAssertEqual(model.detailSelectionRequest, managementRequest)
            XCTAssertNil(model.selectedFeed)
            XCTAssertNil(model.selectedScript)
            model.applyDetailSelectionRequest(priorRequest, contentRoute: host.route, detailPath: host.path)
            XCTAssertNil(host.contentRoute)
            XCTAssertTrue(host.detailPath.isEmpty)
            fixture.realm.refresh()
            XCTAssertEqual(snapshot(fixture.realm), committedStore)
        }
    }

    func testManageCategoriesCannotRetireAnAddAdmittedByEitherClearingPublisher() async throws {
        for startsDuringFeedClear in [true, false] {
            let fixture = try await fixture()
            let model = manager(fixture)
            let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
            let category = try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: fixture.identities.category))
            let script = UserScript()
            try fixture.realm.write {
                fixture.realm.add(script)
                script.refreshChangeMetadata(explicitlyModified: true)
            }
            model.selectedScript = script
            model.selectedFeed = feed
            let gate = WebFeedObservationGate()
            let entered = expectation(description: "New Add admitted during Manage clearing")
            var armed = false
            var command: Task<UUID?, Error>?
            var publications = 0
            func startNewAdd() {
                guard armed, command == nil else { return }
                command = model.add(
                    rssURL: URL(string: "https://example.com/newer-than-manage.rss")!,
                    title: "Newer Add", toCategory: category,
                    beforeWrite: { await gate.wait(onSuspension: { entered.fulfill() }) },
                    didPublish: { _ in
                        publications += 1
                        model.isLibraryPresented = true
                    }
                )
            }
            let subscription: AnyCancellable
            if startsDuringFeedClear {
                subscription = model.$selectedFeed.sink { if $0 == nil { startNewAdd() } }
            } else {
                subscription = model.$selectedScript.sink { if $0 == nil { startNewAdd() } }
            }
            defer { subscription.cancel() }
            armed = true
            XCTAssertFalse(model.manageLibraryCategories())
            XCTAssertFalse(model.isLibraryPresented)
            let task = try XCTUnwrap(command)
            addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertEqual(publications, 0)
            await gate.release()
            let feedID = try await task.value
            XCTAssertEqual(model.selectedFeed?.id, try XCTUnwrap(feedID))
            XCTAssertEqual(publications, 1)
            XCTAssertTrue(model.isLibraryPresented)
        }
    }

    func testManageCategoriesPreservesANewerManualSelectionDuringEitherClear() async throws {
        for startsDuringFeedClear in [true, false] {
            let fixture = try await fixture()
            let model = manager(fixture)
            let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
            let script = UserScript()
            try fixture.realm.write {
                fixture.realm.add(script)
                script.refreshChangeMetadata(explicitlyModified: true)
            }
            model.selectedScript = script
            model.selectedFeed = feed
            var armed = false
            var successor: LibraryDetailSelectionRequest?
            let subscription: AnyCancellable
            if startsDuringFeedClear {
                subscription = model.$selectedFeed.sink {
                    guard armed, successor == nil, $0 == nil else { return }
                    model.selectedScript = script
                    successor = model.detailSelectionRequest
                }
            } else {
                subscription = model.$selectedScript.sink {
                    guard armed, successor == nil, $0 == nil else { return }
                    model.selectedFeed = feed
                    successor = model.detailSelectionRequest
                }
            }
            defer { subscription.cancel() }
            armed = true
            XCTAssertFalse(model.manageLibraryCategories())
            XCTAssertFalse(model.isLibraryPresented)
            XCTAssertEqual(model.detailSelectionRequest, try XCTUnwrap(successor))
            let host = WebFeedMenuHostBindings()
            model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
            var expectedPath = NavigationPath()
            if startsDuringFeedClear {
                expectedPath.append(script)
                XCTAssertEqual(host.contentRoute, .userScripts)
            } else {
                expectedPath.append(feed)
                XCTAssertEqual(host.contentRoute, .contentCategory(fixture.identities.category))
            }
            XCTAssertEqual(host.detailPath, expectedPath)
        }
    }

    func testManageCategoriesPreservesANestedDerivedRequestPublisherSelection() async throws {
        let fixture = try await fixture()
        let model = manager(fixture)
        let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
        let script = UserScript()
        try fixture.realm.write {
            fixture.realm.add(script)
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        model.selectedFeed = feed
        var successor: LibraryDetailSelectionRequest?
        // This deliberately exercises the derived publisher's synchronous
        // contract. The live SwiftUI host uses deferred onChange instead.
        let subscription = model.$detailSelectionRequest.sink { request in
            guard request.target == .libraryRoot, successor == nil else { return }
            model.selectedScript = script
            successor = model.detailSelectionRequest
        }
        defer { subscription.cancel() }
        XCTAssertFalse(model.manageLibraryCategories())
        XCTAssertFalse(model.isLibraryPresented)
        XCTAssertEqual(model.detailSelectionRequest, try XCTUnwrap(successor))
        XCTAssertEqual(model.selectedScript?.id, script.id)
        let host = WebFeedMenuHostBindings()
        model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
        XCTAssertEqual(host.contentRoute, .userScripts)
        var expectedPath = NavigationPath()
        expectedPath.append(script)
        XCTAssertEqual(host.detailPath, expectedPath)
    }

    func testManageRootHostApplicationPreservesSelectionDuringRoutePublication() async throws {
        let fixture = try await fixture()
        let model = manager(fixture)
        let host = WebFeedMenuHostBindings()
        let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: fixture.identities.feed))
        let script = UserScript()
        try fixture.realm.write {
            fixture.realm.add(script)
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        model.selectedFeed = feed
        model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
        XCTAssertTrue(model.manageLibraryCategories())
        let managementRequest = model.detailSelectionRequest
        var successor: LibraryDetailSelectionRequest?
        let route = Binding<ContentPaneRoute?>(
            get: { host.contentRoute },
            set: {
                host.contentRoute = $0
                guard successor == nil else { return }
                model.selectedScript = script
                successor = model.detailSelectionRequest
                model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
            }
        )
        model.applyDetailSelectionRequest(managementRequest, contentRoute: route, detailPath: host.path)
        XCTAssertEqual(model.detailSelectionRequest, try XCTUnwrap(successor))
        XCTAssertEqual(host.contentRoute, .userScripts)
        var expectedPath = NavigationPath()
        expectedPath.append(script)
        XCTAssertEqual(host.detailPath, expectedPath)
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

    private func diskSnapshot(_ configuration: Realm.Configuration) throws -> WebFeedObservedStore {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            defer { realm.invalidate() }
            return snapshot(realm)
        }
    }

    private func verifyPhysicalReplacement(afterOpening: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-feed-state-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = configured(Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm")))
        var replacement = original
        replacement.fileURL = directory.appendingPathComponent("replacement.realm")
        var retired = original
        retired.fileURL = directory.appendingPathComponent("retired.realm")
        // Mutation policy belongs to the path, not the copied configuration.
        BigSyncMutationTracking.install(configurations: [original, replacement], excludedClassNames: [])
        addTeardownBlock {
            await Self.releaseDiskCache(original)
            try? FileManager.default.removeItem(at: directory)
        }
        let identities = Identities()
        for (configuration, label) in [(original, "A"), (replacement, "B")] {
            try autoreleasepool {
                let realm = try Realm(configuration: configuration)
                defer { realm.invalidate() }
                try realm.write {
                    Self.populate(
                        realm, identities: identities, label: label,
                        rssURL: URL(string: "https://example.com/" + label + ".rss")!
                    )
                }
                XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 4)
            }
        }
        let beforeOriginal = try diskSnapshot(original)
        let beforeReplacement = try diskSnapshot(replacement)
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: original)
        let gate = WebFeedObservationGate()
        let opened = expectation(description: "Original store opened before publication")
        let state = WebFeedButtonLibraryState(
            realmConfiguration: original, storageAdmission: admission,
            beforePublication: afterOpening ? {
                await gate.wait(onSuspension: { opened.fulfill() })
            } : nil
        )
        addTeardownBlock { await gate.release(); await state.stopObservation() }
        let originalURL = try XCTUnwrap(original.fileURL)
        let replacementURL = try XCTUnwrap(replacement.fileURL)
        let retiredURL = try XCTUnwrap(retired.fileURL)
        func replaceFile() throws {
            try FileManager.default.moveItem(at: originalURL, to: retiredURL)
            do { try FileManager.default.moveItem(at: replacementURL, to: originalURL) }
            catch {
                try? FileManager.default.moveItem(at: retiredURL, to: originalURL)
                throw error
            }
        }
        if !afterOpening { try replaceFile() }
        let task = try XCTUnwrap(state.beginObservation(for: UUID()))
        if afterOpening {
            await fulfillment(of: [opened], timeout: 5)
            try replaceFile()
            await gate.release()
        }
        await task.value
        XCTAssertTrue(state.hasFailed)
        XCTAssertNil(state.userCategories)
        XCTAssertNil(state.feed(matching: [URL(string: "https://example.com/A.rss")!]))
        await state.stopObservation()
        await Self.releaseDiskCache(original)
        XCTAssertEqual(try diskSnapshot(original), beforeReplacement)
        XCTAssertEqual(try diskSnapshot(retired), beforeOriginal)
    }

    func testPhysicalReplacementBeforeStartupCannotConsolidateOrPublishTheReplacement() async throws {
        try await verifyPhysicalReplacement(afterOpening: false)
    }

    func testPhysicalReplacementAfterOpeningCannotPublishTheReplacement() async throws {
        try await verifyPhysicalReplacement(afterOpening: true)
    }

    func testEmptyLibraryMenuChoiceCreatesACompletedFeedThroughTheOriginalModelAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-feed-state-new-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = configured(Realm.Configuration(fileURL: directory.appendingPathComponent("new.realm")))
        addTeardownBlock {
            await Self.releaseDiskCache(configuration)
            try? FileManager.default.removeItem(at: directory)
        }
        let originalGlobal = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalGlobal }
        LibraryDataManager.realmConfiguration = configuration
        let model = LibraryManagerViewModel(observesRealm: false)
        let state = model.webFeedButtonLibraryState
        addTeardownBlock { await state.stopObservation() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
        _ = try await start(state)
        XCTAssertEqual(state.userCategories, [])
        let choices = LibraryWebFeedAddChoice.choices(for: state.userCategories)
        XCTAssertEqual(choices.count, 1)
        let choice = try XCTUnwrap(choices.first)
        XCTAssertEqual(choice.destination, .newUserCategory)
        let rssURL = URL(string: "https://example.com/first.rss")!
        let add = try XCTUnwrap(model.add(
            rssURL: rssURL, title: "First complete feed", destination: choice.destination,
            didPublish: { _ in model.isLibraryPresented = true }
        ))
        let feedID = try await add.value
        XCTAssertNotNil(feedID)
        XCTAssertTrue(model.isLibraryPresented)
        await state.stopObservation()
        await Self.releaseDiskCache(configuration)
        let created = try diskSnapshot(configuration)
        XCTAssertEqual(created.libraries.count, 1)
        XCTAssertEqual(created.categories.count, 1)
        XCTAssertEqual(created.categories.first?.title, "My Library")
        XCTAssertEqual(created.feeds.count, 1)
        XCTAssertEqual(created.feeds.first?.id, feedID)
        XCTAssertEqual(created.feeds.first?.title, "First complete feed")
        XCTAssertEqual(created.feeds.first?.rssURL, rssURL)
        XCTAssertEqual(created.feeds.first?.categoryID, created.categories.first?.id)
        XCTAssertEqual(created.libraries.first?.categoryIDs, created.categories.map(\.id))
        XCTAssertEqual(created.mutations.count, 3)
        XCTAssertEqual(Set(created.mutations.map(\.entityType)), Set([
            LibraryConfiguration.className(), FeedCategory.className(), Feed.className(),
        ]))
    }
}
