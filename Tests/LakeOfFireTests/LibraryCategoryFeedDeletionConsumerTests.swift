import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

final class LibraryCategoryFeedDeletionConsumerTests: XCTestCase {
    @MainActor
    func testRenderedOffsetsDeleteTheCapturedFeedAfterTheLiveListReorders() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertLibrary(in: configuration)
        let realm = try await Realm.open(configuration: configuration)
        let selection = FeedSelection()
        selection.feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: identifiers.first.feedID))
        let model = try makeModel(in: realm, identifiers: identifiers, selectedFeed: selection.binding)
        let renderedTargets = [identifiers.first, identifiers.second]
        try await Self.reverseTitles(in: configuration, identifiers: identifiers)
        await realm.asyncRefresh()
        XCTAssertEqual(model.category.getFeeds()?.first?.id, identifiers.second.feedID)

        let task = try XCTUnwrap(model.deleteFeed(at: IndexSet(integer: 0), from: renderedTargets))
        await task.value

        XCTAssertNil(model.feedDeletionErrorMessage)
        XCTAssertEqual(model.lastFeedDeletionReceipt?.deletedFeedIDs, [identifiers.first.feedID])
        XCTAssertNil(selection.feed)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertTrue(try XCTUnwrap(realm.object(ofType: Feed.self,
                                                     forPrimaryKey: identifiers.first.feedID)).isDeleted)
            XCTAssertFalse(try XCTUnwrap(realm.object(ofType: Feed.self,
                                                      forPrimaryKey: identifiers.second.feedID)).isDeleted)
        }()
    }

    @MainActor
    func testRetryKeepsTheFailedTargetsAndOwningStoreAfterReordering() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let identifiers = try await Self.insertLibrary(in: configurationA)
        try await Self.insertLibrary(in: configurationB, identifiers: identifiers)
        let realm = try await Realm.open(configuration: configurationA)
        let attempts = DeletionAttempts()
        let model = try makeModel(in: realm, identifiers: identifiers, operation: { categoryID, createdAt, targets, configuration in
            if await attempts.record(targets: targets, configuration: configuration) == 1 {
                throw DeletionFailure.rejected
            }
            return try await LibraryFeedDeletionCommand.perform(
                categoryID: categoryID, categoryCreatedAt: createdAt, targets: targets,
                configuration: configuration
            )
        })
        let firstAttempt = try XCTUnwrap(model.deleteFeed(at: IndexSet(integer: 0),
                                                         from: [identifiers.first, identifiers.second]))
        await firstAttempt.value
        XCTAssertNotNil(model.feedDeletionErrorMessage)
        XCTAssertTrue(model.canRetryFeedDeletion)
        try await Self.reverseTitles(in: configurationA, identifiers: identifiers)
        let originalConfiguration = LibraryDataManager.realmConfiguration
        LibraryDataManager.realmConfiguration = configurationB
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }

        let retry = try XCTUnwrap(model.retryFeedDeletion())
        await retry.value

        XCTAssertNil(model.feedDeletionErrorMessage)
        XCTAssertFalse(model.canRetryFeedDeletion)
        let recordedTargets = await attempts.targets
        let recordedStores = await attempts.storeIdentifiers
        XCTAssertEqual(recordedTargets, [[identifiers.first], [identifiers.first]])
        XCTAssertEqual(recordedStores, [configurationA.inMemoryIdentifier, configurationA.inMemoryIdentifier])
        try await { @RealmBackgroundActor in
            let realmA = try await RealmBackgroundActor.shared.cachedRealm(for: configurationA)
            let realmB = try await RealmBackgroundActor.shared.cachedRealm(for: configurationB)
            XCTAssertTrue(try XCTUnwrap(realmA.object(ofType: Feed.self,
                                                      forPrimaryKey: identifiers.first.feedID)).isDeleted)
            XCTAssertFalse(try XCTUnwrap(realmA.object(ofType: Feed.self,
                                                       forPrimaryKey: identifiers.second.feedID)).isDeleted)
            XCTAssertFalse(try XCTUnwrap(realmB.object(ofType: Feed.self,
                                                       forPrimaryKey: identifiers.first.feedID)).isDeleted)
        }()
    }

    @MainActor
    func testSameIDReplacementIsReportedUnavailableWithoutDeletingIt() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertLibrary(in: configuration)
        let realm = try await Realm.open(configuration: configuration)
        let model = try makeModel(in: realm, identifiers: identifiers)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let original = try XCTUnwrap(realm.object(ofType: Feed.self,
                                                       forPrimaryKey: identifiers.first.feedID))
            let replacement = Feed()
            replacement.id = original.id
            replacement.categoryID = identifiers.categoryID
            replacement.createdAt = identifiers.first.createdAt.addingTimeInterval(1)
            replacement.rssUrl = URL(string: "https://example.com/replacement.xml")!
            try await realm.asyncWrite {
                realm.delete(original)
                realm.add(replacement)
            }
        }()

        let task = try XCTUnwrap(model.deleteFeed(at: IndexSet(integer: 0), from: [identifiers.first]))
        await task.value

        XCTAssertEqual(model.lastFeedDeletionReceipt?.unavailableFeedIDs, [identifiers.first.feedID])
        XCTAssertNotNil(model.feedDeletionErrorMessage)
        XCTAssertFalse(model.canRetryFeedDeletion)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertFalse(try XCTUnwrap(realm.object(ofType: Feed.self,
                                                      forPrimaryKey: identifiers.first.feedID)).isDeleted)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }()
    }

    @MainActor
    func testSingleFlightAndDismissalFenceSuppressAnObsoleteFailure() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertLibrary(in: configuration)
        let realm = try await Realm.open(configuration: configuration)
        let entered = expectation(description: "Deletion was admitted")
        let gate = DeletionGate()
        defer { Task { await gate.release() } }
        let model = try makeModel(in: realm, identifiers: identifiers, operation: { _, _, _, _ in
            entered.fulfill()
            await gate.wait()
            throw DeletionFailure.rejected
        })
        let task = try XCTUnwrap(model.deleteFeed(at: IndexSet(integer: 0), from: [identifiers.first]))
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(model.isDeletingFeeds)
        XCTAssertNil(model.deleteFeed(at: IndexSet(integer: 0), from: [identifiers.second]))
        model.dismissFeedDeletionFailure()
        await gate.release()

        await task.value

        XCTAssertFalse(model.isDeletingFeeds)
        XCTAssertNil(model.feedDeletionErrorMessage)
        XCTAssertFalse(model.canRetryFeedDeletion)
    }

    @MainActor
    func testDeletionSurvivesEditorRetirementWithoutClearingAnotherStoreSelection() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let identifiers = try await Self.insertLibrary(in: configurationA)
        try await Self.insertLibrary(in: configurationB, identifiers: identifiers)
        let realmA = try await Realm.open(configuration: configurationA)
        let realmB = try await Realm.open(configuration: configurationB)
        let entered = expectation(description: "Deletion was admitted")
        let gate = DeletionGate()
        defer { Task { await gate.release() } }
        let selection = FeedSelection()
        selection.feed = try XCTUnwrap(realmA.object(ofType: Feed.self,
                                                     forPrimaryKey: identifiers.first.feedID))
        let model = try makeModel(in: realmA, identifiers: identifiers, selectedFeed: selection.binding,
                                  operation: { categoryID, createdAt, targets, configuration in
            entered.fulfill()
            await gate.wait()
            return try await LibraryFeedDeletionCommand.perform(
                categoryID: categoryID, categoryCreatedAt: createdAt, targets: targets,
                configuration: configuration
            )
        })
        let task = try XCTUnwrap(model.deleteFeed(at: IndexSet(integer: 0), from: [identifiers.first]))
        await fulfillment(of: [entered], timeout: 5)
        await model.finishEditing()
        selection.feed = try XCTUnwrap(realmB.object(ofType: Feed.self,
                                                     forPrimaryKey: identifiers.first.feedID))
        await gate.release()

        await task.value

        XCTAssertEqual(selection.feed?.id, identifiers.first.feedID)
        XCTAssertEqual(selection.feed?.realm?.configuration.inMemoryIdentifier, configurationB.inMemoryIdentifier)
        XCTAssertEqual(model.lastFeedDeletionReceipt?.deletedFeedIDs, [identifiers.first.feedID])
    }

    func testBatchDeletionJournalsOneTimestampAndReplayDoesNotAdvanceGenerations() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertLibrary(in: configuration)
        let timestamp = Date(timeIntervalSinceReferenceDate: 101_000)
        let targets = [identifiers.first, identifiers.second]
        let receipt = try await LibraryFeedDeletionCommand.perform(
            categoryID: identifiers.categoryID, categoryCreatedAt: identifiers.createdAt,
            targets: targets, configuration: configuration, deletedAt: timestamp
        )
        XCTAssertEqual(Set(receipt.deletedFeedIDs), Set(targets.map(\.feedID)))
        let generations = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            return try targets.map { target in
                let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: target.feedID))
                let journal = try XCTUnwrap(Self.journal(for: feed, in: realm))
                XCTAssertEqual(journal.changedAt, timestamp)
                return journal.generation
            }
        }()
        let replay = try await LibraryFeedDeletionCommand.perform(
            categoryID: identifiers.categoryID, categoryCreatedAt: identifiers.createdAt,
            targets: targets, configuration: configuration, deletedAt: timestamp.addingTimeInterval(1)
        )
        XCTAssertTrue(replay.deletedFeedIDs.isEmpty)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            for (index, target) in targets.enumerated() {
                let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: target.feedID))
                XCTAssertEqual(Self.journal(for: feed, in: realm)?.generation, generations[index])
            }
        }()
    }

    func testConflictingLifetimesRejectTheWholeBatchBeforeMutation() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertLibrary(in: configuration)
        do {
            _ = try await LibraryFeedDeletionCommand.perform(
                categoryID: identifiers.categoryID, categoryCreatedAt: identifiers.createdAt,
                targets: [identifiers.first, LibraryFeedDeletionTarget(
                    feedID: identifiers.first.feedID,
                    createdAt: identifiers.first.createdAt.addingTimeInterval(1)
                ), identifiers.second],
                configuration: configuration
            )
            XCTFail("Conflicting selected lifetimes must reject the batch")
        } catch LibraryFeedDeletionCommandError.conflictingTargetIdentity {
        }
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            for target in [identifiers.first, identifiers.second] {
                XCTAssertFalse(try XCTUnwrap(realm.object(ofType: Feed.self,
                                                          forPrimaryKey: target.feedID)).isDeleted)
            }
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }()
    }

    @MainActor
    private func makeModel(
        in realm: Realm,
        identifiers: Identifiers,
        selectedFeed: Binding<Feed?> = .constant(nil),
        operation: LibraryCategoryFeedDeletionOperation? = nil
    ) throws -> LibraryCategoryViewModel {
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: identifiers.categoryID))
        let library = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: identifiers.libraryID))
        if let operation {
            return LibraryCategoryViewModel(category: category, libraryConfiguration: library,
                                             selectedFeed: selectedFeed, feedDeletionOperation: operation)
        }
        return LibraryCategoryViewModel(category: category, libraryConfiguration: library, selectedFeed: selectedFeed)
    }

    private struct Identifiers: Sendable {
        let categoryID: UUID
        let libraryID: UUID
        let createdAt: Date
        let first: LibraryFeedDeletionTarget
        let second: LibraryFeedDeletionTarget
    }

    @RealmBackgroundActor
    @discardableResult
    private static func insertLibrary(
        in configuration: Realm.Configuration,
        identifiers: Identifiers? = nil
    ) async throws -> Identifiers {
        let timestamp = Date()
        let identifiers = identifiers ?? Identifiers(
            categoryID: UUID(), libraryID: UUID(), createdAt: timestamp,
            first: LibraryFeedDeletionTarget(feedID: UUID(), createdAt: timestamp),
            second: LibraryFeedDeletionTarget(feedID: UUID(), createdAt: timestamp)
        )
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let category = FeedCategory()
        category.id = identifiers.categoryID
        category.createdAt = identifiers.createdAt
        category.title = "Category"
        let library = LibraryConfiguration()
        library.id = identifiers.libraryID
        library.categoryIDs.append(category.id)
        let first = Feed()
        first.id = identifiers.first.feedID
        first.createdAt = identifiers.first.createdAt
        first.categoryID = category.id
        first.title = "Alpha"
        first.rssUrl = URL(string: "https://example.com/alpha.xml")!
        let second = Feed()
        second.id = identifiers.second.feedID
        second.createdAt = identifiers.second.createdAt
        second.categoryID = category.id
        second.title = "Beta"
        second.rssUrl = URL(string: "https://example.com/beta.xml")!
        try await realm.asyncWrite { realm.add([category, library, first, second]) }
        return identifiers
    }

    @RealmBackgroundActor
    private static func reverseTitles(in configuration: Realm.Configuration, identifiers: Identifiers) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let first = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: identifiers.first.feedID))
        let second = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: identifiers.second.feedID))
        try await realm.asyncWrite {
            first.title = "Zulu"
            second.title = "Alpha"
        }
    }

    @RealmBackgroundActor
    private static func journal(for object: Object, in realm: Realm) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let identifier = String(describing: object[primaryKey]!)
        return realm.object(ofType: BigSyncPendingMutation.self,
                            forPrimaryKey: object.objectSchema.className + "." + identifier)
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self,
                                     Feed.self, UserScript.self, UserScriptAllowedDomain.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    @MainActor
    private final class FeedSelection {
        var feed: Feed?
        var binding: Binding<Feed?> {
            Binding(get: { self.feed }, set: { self.feed = $0 })
        }
    }

    private enum DeletionFailure: Error { case rejected }

    private actor DeletionAttempts {
        private(set) var targets = [[LibraryFeedDeletionTarget]]()
        private(set) var storeIdentifiers = [String?]()
        func record(targets: [LibraryFeedDeletionTarget], configuration: Realm.Configuration) -> Int {
            self.targets.append(targets)
            storeIdentifiers.append(configuration.inMemoryIdentifier)
            return self.targets.count
        }
    }

    private actor DeletionGate {
        private var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }
}
