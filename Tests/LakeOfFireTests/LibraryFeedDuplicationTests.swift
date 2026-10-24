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
private final class TypedLibraryHostBindings {
    var contentRoute: ContentPaneRoute?
    var detailPath = NavigationPath()
    var hasSynchronizedInitialSelection = false

    var route: Binding<ContentPaneRoute?> {
        Binding(get: { self.contentRoute }, set: { self.contentRoute = $0 })
    }

    var path: Binding<NavigationPath> {
        Binding(get: { self.detailPath }, set: { self.detailPath = $0 })
    }

    var initialSelection: Binding<Bool> {
        Binding(get: { self.hasSynchronizedInitialSelection }, set: { self.hasSynchronizedInitialSelection = $0 })
    }
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

    private func addScript(_ fixture: Fixture) async throws -> UserScript {
        let id = UUID()
        try await Self.write(fixture.realm.configuration) { writer in
            let script = UserScript()
            script.id = id
            script.createdAt = Date(timeIntervalSinceReferenceDate: 600)
            script.title = "Selected script"
            writer.add(script)
            script.refreshChangeMetadata(explicitlyModified: true)
            let library = try XCTUnwrap(writer.objects(LibraryConfiguration.self).first)
            library.userScriptIDs.append(id)
            library.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        return try XCTUnwrap(fixture.realm.object(ofType: UserScript.self, forPrimaryKey: id))
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

    func testManagerForwardsNonOverwriteAndRoutesSelectedCopyThroughTypedHost() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        host.contentRoute = .contentCategory(try XCTUnwrap(source(fixture).categoryID))
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
        model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
        var expectedPath = NavigationPath()
        expectedPath.append(selected)
        XCTAssertEqual(host.contentRoute, .contentCategory(fixture.categoryID))
        XCTAssertEqual(host.detailPath, expectedPath, "Use the bindings consumed by the real typed host")
        XCTAssertEqual(model.selectedFeed?.id, selected.id)
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

    func testRepeatedManagerOverwriteReopensSameFeedWithoutRejournal() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        try await model.duplicate(
            feed: ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)), overwriteExisting: true
        )
        fixture.realm.refresh()
        let selected = try XCTUnwrap(model.selectedFeed)
        let firstRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(firstRequest, contentRoute: host.route, detailPath: host.path)
        var expectedPath = NavigationPath()
        expectedPath.append(selected)
        XCTAssertEqual(host.detailPath, expectedPath)
        let committed = snapshot(fixture.realm)

        model.selectDetailPath(NavigationPath(), detailPath: host.path)
        XCTAssertTrue(host.detailPath.isEmpty, "The actual host pop preserves an empty detail path")
        try await model.duplicate(
            feed: ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)), overwriteExisting: true
        )
        fixture.realm.refresh()
        XCTAssertEqual(model.selectedFeed?.id, selected.id)
        XCTAssertNotEqual(model.detailSelectionRequest.id, firstRequest.id, "Reopening the row is a new command")
        model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
        XCTAssertEqual(host.contentRoute, .contentCategory(fixture.categoryID))
        XCTAssertEqual(host.detailPath, expectedPath)
        XCTAssertEqual(snapshot(fixture.realm), committed, "Reopening an exact overwrite must not create a mutation")

        let reopenedRequest = model.detailSelectionRequest
        try await model.duplicate(
            feed: ThreadSafeReference(to: source(fixture)),
            inCategory: ThreadSafeReference(to: category(fixture)), overwriteExisting: true
        )
        fixture.realm.refresh()
        XCTAssertEqual(model.selectedFeed?.id, selected.id)
        XCTAssertNotEqual(model.detailSelectionRequest.id, reopenedRequest.id, "Assigning the still-selected row is a new command")
        model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
        XCTAssertEqual(host.detailPath, expectedPath)
        XCTAssertEqual(snapshot(fixture.realm), committed)
    }

    func testInitialFeedAndScriptSelectionsSynchronizeOncePerHostMount() async throws {
        let fixture = try await makeFixture()
        let script = try await addScript(fixture)
        let before = snapshot(fixture.realm)
        for opensScript in [false, true] {
            let model = manager(fixture.realm.configuration)
            let host = TypedLibraryHostBindings()
            var expectedPath = NavigationPath()
            if opensScript {
                model.selectedScript = script
                expectedPath.append(script)
            } else {
                model.selectedFeed = try source(fixture)
                expectedPath.append(try source(fixture))
            }
            let expectedRoute: ContentPaneRoute = opensScript
                ? .userScripts : .contentCategory(try XCTUnwrap(source(fixture).categoryID))
            model.synchronizeInitialDetailSelection(
                hasSynchronized: host.initialSelection, contentRoute: host.route, detailPath: host.path
            )
            XCTAssertEqual(host.contentRoute, expectedRoute)
            XCTAssertEqual(host.detailPath, expectedPath)
            XCTAssertTrue(host.hasSynchronizedInitialSelection)

            model.selectDetailPath(NavigationPath(), detailPath: host.path)
            model.synchronizeInitialDetailSelection(
                hasSynchronized: host.initialSelection, contentRoute: host.route, detailPath: host.path
            )
            XCTAssertTrue(host.detailPath.isEmpty, "A later onAppear must not reopen a popped detail")
            XCTAssertEqual(host.contentRoute, expectedRoute)
        }
        XCTAssertEqual(snapshot(fixture.realm), before)
    }

    func testOldOtherKindCallbacksCannotClearNewerDetailSelection() async throws {
        let fixture = try await makeFixture()
        let script = try await addScript(fixture)
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        let before = snapshot(fixture.realm)
        host.contentRoute = .contentCategory(try XCTUnwrap(source(fixture).categoryID))
        model.selectedFeed = try source(fixture)
        let olderFeedRequest = model.detailSelectionRequest
        model.selectedScript = script
        let scriptRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(scriptRequest, contentRoute: host.route, detailPath: host.path)
        model.applyDetailSelectionRequest(olderFeedRequest, contentRoute: host.route, detailPath: host.path)
        var expectedScriptPath = NavigationPath()
        expectedScriptPath.append(script)
        XCTAssertNil(model.selectedFeed)
        XCTAssertEqual(model.selectedScript?.id, script.id)
        XCTAssertEqual(model.detailSelectionRequest, scriptRequest)
        XCTAssertEqual(host.contentRoute, .userScripts)
        XCTAssertEqual(host.detailPath, expectedScriptPath)

        let feed = try source(fixture)
        model.selectedFeed = feed
        let latestFeedRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(latestFeedRequest, contentRoute: host.route, detailPath: host.path)
        model.applyDetailSelectionRequest(scriptRequest, contentRoute: host.route, detailPath: host.path)
        var expectedFeedPath = NavigationPath()
        expectedFeedPath.append(feed)
        XCTAssertNil(model.selectedScript)
        XCTAssertEqual(model.selectedFeed?.id, feed.id)
        XCTAssertEqual(model.detailSelectionRequest, latestFeedRequest)
        XCTAssertEqual(host.contentRoute, .contentCategory(try XCTUnwrap(feed.categoryID)))
        XCTAssertEqual(host.detailPath, expectedFeedPath)
        model.selectContentRoute(.userScripts, contentRoute: host.route, detailPath: host.path)
        let sidebarRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(latestFeedRequest, contentRoute: host.route, detailPath: host.path)
        XCTAssertEqual(model.detailSelectionRequest, sidebarRequest)
        XCTAssertNil(model.selectedFeed)
        XCTAssertNil(model.selectedScript)
        XCTAssertEqual(host.contentRoute, .userScripts)
        XCTAssertTrue(host.detailPath.isEmpty)
        XCTAssertEqual(snapshot(fixture.realm), before)
    }

    func testRouteBindingReentryCannotOverwriteNewerOtherKindDetail() async throws {
        let fixture = try await makeFixture()
        let script = try await addScript(fixture)
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        let before = snapshot(fixture.realm)
        model.selectedFeed = try source(fixture)
        let olderRequest = model.detailSelectionRequest
        let reentrantRoute = Binding<ContentPaneRoute?>(
            get: { host.contentRoute },
            set: { route in
                host.contentRoute = route
                model.selectedScript = script
                model.applyDetailSelectionRequest(
                    model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path
                )
            }
        )
        model.applyDetailSelectionRequest(olderRequest, contentRoute: reentrantRoute, detailPath: host.path)
        var expectedPath = NavigationPath()
        expectedPath.append(script)
        XCTAssertNil(model.selectedFeed)
        XCTAssertEqual(model.selectedScript?.id, script.id)
        XCTAssertNotEqual(model.detailSelectionRequest.id, olderRequest.id)
        XCTAssertEqual(host.contentRoute, .userScripts)
        XCTAssertEqual(host.detailPath, expectedPath)
        XCTAssertEqual(snapshot(fixture.realm), before)
    }

    func testSynchronousRealmRefreshCannotPublishAnOlderSelection() async throws {
        let fixture = try await makeFixture()
        let script = try await addScript(fixture)
        let feed = try source(fixture)
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        fixture.realm.autorefresh = false
        defer { fixture.realm.autorefresh = true }
        var didChangeCount = 0
        let token = fixture.realm.observe { notification, _ in
            guard notification == .didChange else { return }
            didChangeCount += 1
            model.selectedScript = script
        }
        defer { token.invalidate() }
        let sourceID = fixture.sourceID
        try await Self.write(fixture.realm.configuration) { writer in
            let source = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: sourceID))
            source.title = "Authoritative newer title"
            source.refreshChangeMetadata(explicitlyModified: true)
        }
        XCTAssertEqual(didChangeCount, 0)
        model.selectedFeed = feed
        let olderRequest = model.detailSelectionRequest
        XCTAssertEqual(didChangeCount, 0, "Capturing the assigned row must not refresh and reenter selection")
        model.applyDetailSelectionRequest(olderRequest, contentRoute: host.route, detailPath: host.path)
        XCTAssertEqual(didChangeCount, 1, "The host's real Realm refresh delivers the intervening selection")
        XCTAssertEqual(model.selectedScript?.id, script.id)
        XCTAssertNotEqual(model.detailSelectionRequest.id, olderRequest.id)
        XCTAssertTrue(host.detailPath.isEmpty, "The superseded feed request cannot publish a partial path")
        let afterRefresh = snapshot(fixture.realm)
        model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
        var expectedPath = NavigationPath()
        expectedPath.append(script)
        XCTAssertEqual(host.contentRoute, .userScripts)
        XCTAssertEqual(host.detailPath, expectedPath)
        XCTAssertEqual(snapshot(fixture.realm), afterRefresh)
    }

    func testTypedHostRejectsRetiredFeedOrCategoryIdentitiesWithoutMutation() async throws {
        enum Retirement: CaseIterable, Sendable {
            case recreatedFeed, recreatedCategory, changedCreation, movedFeed, deletedFeed, deletedCategory
        }
        for retirement in Retirement.allCases {
            let fixture = try await makeFixture()
            let model = manager(fixture.realm.configuration)
            let host = TypedLibraryHostBindings()
            let feed = try source(fixture)
            let sourceID = feed.id
            let sourceCategoryID = try XCTUnwrap(feed.categoryID)
            let destinationID = fixture.categoryID
            model.selectedFeed = feed
            let request = model.detailSelectionRequest
            host.contentRoute = .contentCategory(sourceCategoryID)
            host.detailPath.append(feed)
            try await Self.write(fixture.realm.configuration) { writer in
                let row = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: sourceID))
                let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: sourceCategoryID))
                switch retirement {
                case .recreatedFeed:
                    let replacement = Feed(value: row)
                    replacement.createdAt = row.createdAt.addingTimeInterval(1)
                    writer.delete(row)
                    writer.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                case .recreatedCategory:
                    let replacement = FeedCategory(value: category)
                    replacement.createdAt = category.createdAt.addingTimeInterval(1)
                    writer.delete(category)
                    writer.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                case .changedCreation:
                    row.createdAt = row.createdAt.addingTimeInterval(1)
                    row.refreshChangeMetadata(explicitlyModified: true)
                case .movedFeed:
                    row.categoryID = destinationID
                    row.refreshChangeMetadata(explicitlyModified: true)
                case .deletedFeed:
                    row.isDeleted = true
                    row.refreshChangeMetadata(explicitlyModified: true)
                case .deletedCategory:
                    category.isDeleted = true
                    category.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            fixture.realm.refresh()
            let afterMutation = snapshot(fixture.realm)
            model.applyDetailSelectionRequest(request, contentRoute: host.route, detailPath: host.path)
            XCTAssertNil(model.selectedFeed, "Retired selection: \(retirement)")
            XCTAssertTrue(host.detailPath.isEmpty, "Retired selection: \(retirement)")
            XCTAssertEqual(model.detailSelectionRequest.target, .none)
            XCTAssertEqual(snapshot(fixture.realm), afterMutation)
        }
    }

    func testTypedHostRejectsRetiredScriptsAndInvalidatedInputPreservesOtherKind() async throws {
        for recreates in [false, true] {
            let fixture = try await makeFixture()
            let script = try await addScript(fixture)
            let scriptID = script.id
            let model = manager(fixture.realm.configuration)
            let host = TypedLibraryHostBindings()
            model.selectedScript = script
            let request = model.detailSelectionRequest
            host.contentRoute = .userScripts
            host.detailPath.append(script)
            try await Self.write(fixture.realm.configuration) { writer in
                let row = try XCTUnwrap(writer.object(ofType: UserScript.self, forPrimaryKey: scriptID))
                if recreates {
                    let replacement = UserScript(value: row)
                    replacement.createdAt = row.createdAt.addingTimeInterval(1)
                    writer.delete(row)
                    writer.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                } else {
                    row.isDeleted = true
                    row.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            fixture.realm.refresh()
            let afterMutation = snapshot(fixture.realm)
            model.applyDetailSelectionRequest(request, contentRoute: host.route, detailPath: host.path)
            XCTAssertNil(model.selectedScript)
            XCTAssertTrue(host.detailPath.isEmpty)
            XCTAssertEqual(model.detailSelectionRequest.target, .none)

            let feed = try source(fixture)
            model.selectedFeed = feed
            let feedRequest = model.detailSelectionRequest
            model.selectedScript = script
            XCTAssertNil(model.selectedScript, "Rejected input must not access invalidated persisted fields")
            XCTAssertEqual(model.detailSelectionRequest, feedRequest)
            model.applyDetailSelectionRequest(feedRequest, contentRoute: host.route, detailPath: host.path)
            var expectedPath = NavigationPath()
            expectedPath.append(feed)
            XCTAssertEqual(host.detailPath, expectedPath)
            XCTAssertEqual(model.selectedFeed?.id, feed.id)
            XCTAssertEqual(snapshot(fixture.realm), afterMutation)
        }

        let fixture = try await makeFixture()
        let feed = try source(fixture)
        let script = try await addScript(fixture)
        let model = manager(fixture.realm.configuration)
        let sourceID = fixture.sourceID
        try await Self.write(fixture.realm.configuration) { writer in
            writer.delete(try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: sourceID)))
        }
        fixture.realm.refresh()
        XCTAssertTrue(feed.isInvalidated)
        model.selectedScript = script
        let scriptRequest = model.detailSelectionRequest
        let afterMutation = snapshot(fixture.realm)
        model.selectedFeed = feed
        XCTAssertNil(model.selectedFeed)
        XCTAssertEqual(model.selectedScript?.id, script.id)
        XCTAssertEqual(model.detailSelectionRequest, scriptRequest)
        XCTAssertEqual(snapshot(fixture.realm), afterMutation)
    }

    func testSidebarNilToNilIntentRetiresCommittedDuplicatePublication() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        let feedReference = ThreadSafeReference(to: try source(fixture))
        let categoryReference = ThreadSafeReference(to: try category(fixture))
        let gate = FeedDuplicationGate()
        let committed = expectation(description: "Duplicate committed before sidebar replacement")
        let operation = Task { @RealmBackgroundActor in
            try await model.duplicate(
                feed: feedReference, inCategory: categoryReference, overwriteExisting: false,
                beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) }
            )
        }
        addTeardownBlock { operation.cancel(); await gate.release(); _ = await operation.result }
        await fulfillment(of: [committed], timeout: 5)
        fixture.realm.refresh()
        let committedSnapshot = snapshot(fixture.realm)
        XCTAssertEqual(committedSnapshot.feeds.count, 3)
        XCTAssertNil(host.contentRoute)
        let priorRequest = model.detailSelectionRequest
        model.selectContentRoute(nil, contentRoute: host.route, detailPath: host.path)
        let sidebarRequest = model.detailSelectionRequest
        XCTAssertNotEqual(sidebarRequest.id, priorRequest.id)
        await gate.release()
        try await operation.value
        fixture.realm.refresh()
        model.applyDetailSelectionRequest(priorRequest, contentRoute: host.route, detailPath: host.path)
        XCTAssertEqual(model.detailSelectionRequest, sidebarRequest)
        XCTAssertNil(model.selectedFeed)
        XCTAssertNil(model.selectedScript)
        XCTAssertNil(host.contentRoute)
        XCTAssertTrue(host.detailPath.isEmpty)
        XCTAssertEqual(snapshot(fixture.realm), committedSnapshot, "Presentation retirement preserves the committed copy")
    }

    func testNewScriptSelectionRetiresCommittedDuplicatePublication() async throws {
        let fixture = try await makeFixture()
        let script = try await addScript(fixture)
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        let feedReference = ThreadSafeReference(to: try source(fixture))
        let categoryReference = ThreadSafeReference(to: try category(fixture))
        let gate = FeedDuplicationGate()
        let committed = expectation(description: "Duplicate committed before direct script selection")
        let operation = Task { @RealmBackgroundActor in
            try await model.duplicate(
                feed: feedReference, inCategory: categoryReference, overwriteExisting: false,
                beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) }
            )
        }
        addTeardownBlock { operation.cancel(); await gate.release(); _ = await operation.result }
        await fulfillment(of: [committed], timeout: 5)
        fixture.realm.refresh()
        let committedSnapshot = snapshot(fixture.realm)
        XCTAssertEqual(committedSnapshot.feeds.count, 3)
        model.selectedScript = script
        let scriptRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(scriptRequest, contentRoute: host.route, detailPath: host.path)
        var expectedPath = NavigationPath()
        expectedPath.append(script)
        await gate.release()
        try await operation.value
        fixture.realm.refresh()
        XCTAssertEqual(model.detailSelectionRequest, scriptRequest)
        XCTAssertNil(model.selectedFeed)
        XCTAssertEqual(model.selectedScript?.id, script.id)
        XCTAssertEqual(host.contentRoute, .userScripts)
        XCTAssertEqual(host.detailPath, expectedPath)
        XCTAssertEqual(snapshot(fixture.realm), committedSnapshot)
    }

    func testDirectTypedNavigationPushOrPopRetiresCommittedDuplicatePublication() async throws {
        for pushesDetail in [true, false] {
            let fixture = try await makeFixture()
            let model = manager(fixture.realm.configuration)
            let host = TypedLibraryHostBindings()
            let feed = try source(fixture)
            let route = ContentPaneRoute.contentCategory(try XCTUnwrap(feed.categoryID))
            host.contentRoute = route
            if !pushesDetail {
                model.selectedFeed = feed
                model.applyDetailSelectionRequest(
                    model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path
                )
            }
            let priorRequest = model.detailSelectionRequest
            let feedReference = ThreadSafeReference(to: feed)
            let categoryReference = ThreadSafeReference(to: try category(fixture))
            let gate = FeedDuplicationGate()
            let committed = expectation(description: "Duplicate committed before direct typed navigation")
            let operation = Task { @RealmBackgroundActor in
                try await model.duplicate(
                    feed: feedReference, inCategory: categoryReference, overwriteExisting: false,
                    beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) }
                )
            }
            addTeardownBlock { operation.cancel(); await gate.release(); _ = await operation.result }
            await fulfillment(of: [committed], timeout: 5)
            fixture.realm.refresh()
            let committedSnapshot = snapshot(fixture.realm)
            XCTAssertEqual(committedSnapshot.feeds.count, 3)
            var userPath = NavigationPath()
            if pushesDetail { userPath.append(feed) }
            model.selectDetailPath(userPath, detailPath: host.path)
            let userRequest = model.detailSelectionRequest
            XCTAssertNotEqual(userRequest.id, priorRequest.id)
            model.applyDetailSelectionRequest(priorRequest, contentRoute: host.route, detailPath: host.path)
            model.applyDetailSelectionRequest(userRequest, contentRoute: host.route, detailPath: host.path)
            await gate.release()
            try await operation.value
            fixture.realm.refresh()
            XCTAssertEqual(model.detailSelectionRequest, userRequest)
            XCTAssertNil(model.selectedFeed)
            XCTAssertNil(model.selectedScript)
            XCTAssertEqual(host.contentRoute, route, "Detail navigation must not write the category route")
            XCTAssertEqual(host.detailPath, userPath)
            XCTAssertEqual(snapshot(fixture.realm), committedSnapshot)
        }
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
        let host = TypedLibraryHostBindings()
        model.selectedFeed = try source(fixture)
        let originalSelection = try source(fixture).id
        let originalRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(originalRequest, contentRoute: host.route, detailPath: host.path)
        let originalPath = host.detailPath
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
        XCTAssertEqual(model.detailSelectionRequest, originalRequest)
        XCTAssertEqual(host.detailPath, originalPath)
    }

    func testRecreatedDuplicatedFeedBeforePublicationDoesNotReplaceCurrentSelection() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        model.selectedFeed = try source(fixture)
        let originalRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(originalRequest, contentRoute: host.route, detailPath: host.path)
        let originalPath = host.detailPath
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
        XCTAssertEqual(model.detailSelectionRequest, originalRequest)
        XCTAssertEqual(host.detailPath, originalPath)
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
        let host = TypedLibraryHostBindings()
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
        let newerRequest = model.detailSelectionRequest
        model.applyDetailSelectionRequest(newerRequest, contentRoute: host.route, detailPath: host.path)
        let newerPath = host.detailPath
        await gate.release()
        try await first.value
        fixture.realm.refresh()
        XCTAssertEqual(model.selectedFeed?.id, newerSelection)
        XCTAssertEqual(model.detailSelectionRequest, newerRequest)
        XCTAssertEqual(host.contentRoute, .contentCategory(fixture.categoryID))
        XCTAssertEqual(host.detailPath, newerPath)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 4, "Both committed copies survive")
    }

    func testAlreadyCancelledNewcomerDoesNotRetireCommittedPublication() async throws {
        let fixture = try await makeFixture()
        let model = manager(fixture.realm.configuration)
        let host = TypedLibraryHostBindings()
        model.selectedFeed = try source(fixture)
        let initialSelection = model.detailSelectionRequest
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
        model.applyDetailSelectionRequest(initialSelection, contentRoute: host.route, detailPath: host.path)
        XCTAssertEqual(model.detailSelectionRequest, initialSelection, "Inactive peer cleanup preserves the newer pending duplicate")
        await gate.release()
        try await first.value
        fixture.realm.refresh()
        let selected = try XCTUnwrap(model.selectedFeed)
        XCTAssertNotEqual(selected.id, fixture.sourceID)
        XCTAssertNotEqual(selected.id, fixture.existingID)
        XCTAssertEqual(selected.categoryID, fixture.categoryID)
        model.applyDetailSelectionRequest(model.detailSelectionRequest, contentRoute: host.route, detailPath: host.path)
        var expectedPath = NavigationPath()
        expectedPath.append(selected)
        XCTAssertEqual(host.contentRoute, .contentCategory(fixture.categoryID))
        XCTAssertEqual(host.detailPath, expectedPath)
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
