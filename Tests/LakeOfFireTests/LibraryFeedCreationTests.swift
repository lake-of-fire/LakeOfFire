import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor FeedCreationGate {
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

private struct FeedCreationSnapshot: Equatable, Sendable {
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

    let feeds: [FeedState]
    let categories: [CategoryState]
    let generations: [String: String]
}

@MainActor
private final class FeedCreationPresentation {
    var selected: Feed?
    var published: [UUID] = []
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LibraryFeedCreationTests: XCTestCase, @unchecked Sendable {
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

    private func snapshot(_ realm: Realm) -> FeedCreationSnapshot {
        FeedCreationSnapshot(
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

    private func create(
        _ fixture: Fixture,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> LibraryFeedCreationResult? {
        try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
            inCategory: ThreadSafeReference(to: fixture.category),
            realmConfiguration: fixture.realm.configuration,
            beforeWrite: beforeWrite
        )
    }

    private func model(_ fixture: Fixture, selection: Binding<Feed?>) -> LibraryCategoryViewModel {
        LibraryCategoryViewModel(
            category: fixture.category, libraryConfiguration: fixture.library,
            selectedFeed: selection, observesRealm: false
        )
    }

    func testEqualFieldsCategoryReplacementBeforeWriteMakesNoFeedOrJournalChangeAndCanRetry() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let categoryID = fixture.category.id
        let createdAt = fixture.category.createdAt
        let reference = ThreadSafeReference(to: fixture.category)
        let gate = FeedCreationGate()
        let entered = expectation(description: "Original category resolved before replacement")
        let task = Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
                inCategory: reference, realmConfiguration: configuration,
                beforeWrite: { await gate.wait(onSuspension: { entered.fulfill() }) }
            )
        }
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [entered], timeout: 5)
        try await Self.write(configuration) { writer in
            let old = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            let replacement = FeedCategory(value: old)
            writer.delete(old)
            writer.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let replacement = try XCTUnwrap(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        XCTAssertTrue(fixture.category.isInvalidated)
        XCTAssertEqual(replacement.createdAt, createdAt)
        let authoritativeReplacement = snapshot(fixture.realm)
        await gate.release()
        let rejected = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(rejected)
        XCTAssertEqual(snapshot(fixture.realm), authoritativeReplacement)
        XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)

        let retry = try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
            inCategory: ThreadSafeReference(to: replacement), realmConfiguration: configuration
        )
        fixture.realm.refresh()
        XCTAssertNotNil(retry)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 3)
    }

    func testEqualFieldsCategoryReplacementBehindQueuedAdmissionPreservesTheOtherWrite() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let categoryID = fixture.category.id
        let reference = ThreadSafeReference(to: fixture.category)
        let creationGate = FeedCreationGate()
        let peerGate = FeedCreationGate()
        let resolved = expectation(description: "Creator retains its original actor-owned category")
        let peerEntered = expectation(description: "Peer owns the replacement transaction")
        let submitted = expectation(description: "Creator queues its separate owned admission")
        let task = RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
            Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
                    inCategory: reference, realmConfiguration: configuration,
                    beforeWrite: { await creationGate.wait(onSuspension: { resolved.fulfill() }) }
                )
            }
        }
        addTeardownBlock {
            task.cancel()
            await creationGate.release()
            await peerGate.release()
            _ = await task.result
        }
        await fulfillment(of: [resolved], timeout: 5)
        let peer = Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try writer.beginWrite()
            do {
                let original = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                let replacement = FeedCategory(value: original)
                writer.delete(original)
                writer.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
                await peerGate.wait(onSuspension: { peerEntered.fulfill() })
                XCTAssertTrue(writer.isInWriteTransaction)
                XCTAssertFalse(replacement.isInvalidated)
                try writer.commitWrite()
            } catch {
                if writer.isInWriteTransaction { writer.cancelWrite() }
                throw error
            }
            return Dictionary(uniqueKeysWithValues: writer.objects(BigSyncPendingMutation.self).map {
                ($0.recordName, $0.generation)
            })
        }
        addTeardownBlock { await peerGate.release(); _ = await peer.result }
        await fulfillment(of: [peerEntered], timeout: 5)
        await creationGate.release()
        await fulfillment(of: [submitted], timeout: 5)
        await peerGate.release()
        let peerGenerations = try await peer.value
        let rejected = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(rejected)
        XCTAssertTrue(fixture.category.isInvalidated)
        XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)
        XCTAssertEqual(snapshot(fixture.realm).generations, peerGenerations)
        XCTAssertEqual(peerGenerations.count, 2)
    }

    func testEqualFieldsCommittedFeedReplacementDoesNotSelectOrScroll() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(
            get: { presentation.selected }, set: { presentation.selected = $0 }
        ))
        let gate = FeedCreationGate()
        let committed = expectation(description: "Feed committed before presentation")
        let task = try XCTUnwrap(model.createFeed(
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [committed], timeout: 5)
        fixture.realm.refresh()
        let original = try XCTUnwrap(fixture.realm.objects(Feed.self).first)
        let feedID = original.id
        let createdAt = original.createdAt
        try await Self.write(configuration) { writer in
            let old = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: feedID))
            let replacement = Feed(value: old)
            replacement.title = "Equal-identity replacement"
            writer.delete(old)
            writer.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let authoritativeReplacement = snapshot(fixture.realm)
        XCTAssertTrue(original.isInvalidated)
        XCTAssertEqual(fixture.realm.objects(Feed.self).first?.createdAt, createdAt)
        await gate.release()
        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertNil(presentation.selected)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertEqual(snapshot(fixture.realm), authoritativeReplacement)
    }

    func testEqualFieldsCategoryReplacementAfterCommitKeepsFeedWithoutPublishing() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let categoryID = fixture.category.id
        let createdAt = fixture.category.createdAt
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(
            get: { presentation.selected }, set: { presentation.selected = $0 }
        ))
        let gate = FeedCreationGate()
        let committed = expectation(description: "Accepted feed awaits editor publication")
        let task = try XCTUnwrap(model.createFeed(
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [committed], timeout: 5)
        fixture.realm.refresh()
        let feedID = try XCTUnwrap(fixture.realm.objects(Feed.self).first).id
        try await Self.write(configuration) { writer in
            let old = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            let replacement = FeedCategory(value: old)
            replacement.title = "Equal-identity category replacement"
            writer.delete(old)
            writer.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let authoritativeReplacement = snapshot(fixture.realm)
        XCTAssertTrue(fixture.category.isInvalidated)
        XCTAssertEqual(fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)?.createdAt, createdAt)
        await gate.release()
        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertNil(presentation.selected)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertEqual(fixture.realm.objects(Feed.self).first?.id, feedID)
        XCTAssertEqual(snapshot(fixture.realm), authoritativeReplacement)
    }

    func testEqualFieldsReplacementDuringSelectionSetterCannotPublishStaleScroll() async throws {
        let fixture = try await makeFixture()
        let presentation = FeedCreationPresentation()
        var replacedFeedID: UUID?
        var replacedCreatedAt: Date?
        let model = model(fixture, selection: .init(
            get: { presentation.selected },
            set: { value in
                guard let value else { presentation.selected = nil; return }
                do {
                    let realm = try XCTUnwrap(value.realm)
                    replacedFeedID = value.id
                    replacedCreatedAt = value.createdAt
                    try realm.write {
                        let replacement = Feed(value: value)
                        replacement.title = "Synchronous successor"
                        realm.delete(value)
                        realm.add(replacement)
                        replacement.refreshChangeMetadata(explicitlyModified: true)
                        presentation.selected = replacement
                    }
                } catch { XCTFail("Selection fixture failed: \(error)") }
            }
        ))
        let task = try XCTUnwrap(model.createFeed(didPublish: { presentation.published.append($0) }))
        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertNotNil(replacedFeedID)
        XCTAssertEqual(presentation.selected?.id, replacedFeedID)
        XCTAssertEqual(presentation.selected?.createdAt, replacedCreatedAt)
        XCTAssertEqual(presentation.selected?.title, "Synchronous successor")
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
    }

    func testEqualFieldsPreviousSelectionReplacementSurvivesDelayedCreation() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let firstCreation = try await create(fixture)
        let first = try XCTUnwrap(firstCreation)
        fixture.realm.refresh()
        let original = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: first.feedID))
        let presentation = FeedCreationPresentation()
        presentation.selected = original
        let model = model(fixture, selection: .init(
            get: { presentation.selected }, set: { presentation.selected = $0 }
        ))
        let gate = FeedCreationGate()
        let committed = expectation(description: "Second feed committed with original selection captured")
        let task = try XCTUnwrap(model.createFeed(
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [committed], timeout: 5)
        try await Self.write(configuration) { writer in
            let old = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: first.feedID))
            let replacement = Feed(value: old)
            replacement.title = "New selected incarnation"
            writer.delete(old)
            writer.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let successor = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: first.feedID))
        presentation.selected = successor
        let authoritativeReplacement = snapshot(fixture.realm)
        await gate.release()
        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertTrue(original.isInvalidated)
        XCTAssertTrue(presentation.selected?.isSameObject(as: successor) == true)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 2)
        XCTAssertEqual(snapshot(fixture.realm), authoritativeReplacement)
    }

    func testCommittedPhysicalReferencesResolveOnceWithoutChangingResultEquality() async throws {
        let fixture = try await makeFixture()
        let creation = try await create(fixture)
        let result = try XCTUnwrap(creation)
        let copy = result
        fixture.realm.refresh()
        XCTAssertEqual(result, copy)
        let resolved = try XCTUnwrap(result.resolveCommittedRows(in: fixture.realm))
        XCTAssertTrue(resolved.category.isSameObject(as: fixture.category))
        XCTAssertTrue(resolved.feed.isSameObject(as:
            fixture.realm.object(ofType: Feed.self, forPrimaryKey: result.feedID)
        ))
        XCTAssertEqual(result, copy)
        XCTAssertNil(copy.resolveCommittedRows(in: fixture.realm))
    }

    func testWrongStoreAndActiveWriteDoNotConsumeCommittedPublicationReferences() async throws {
        let fixture = try await makeFixture()
        let other = try await makeFixture()
        let otherBefore = snapshot(other.realm)
        let creation = try await create(fixture)
        let result = try XCTUnwrap(creation)
        fixture.realm.refresh()
        XCTAssertNil(result.resolveCommittedRows(in: other.realm))
        try fixture.realm.write {
            XCTAssertNil(result.resolveCommittedRows(in: fixture.realm))
            XCTAssertTrue(fixture.realm.isInWriteTransaction)
        }
        XCTAssertNotNil(result.resolveCommittedRows(in: fixture.realm))
        XCTAssertEqual(snapshot(other.realm), otherBefore)
    }

    func testSamePhysicalRowsCanChangeMetadataBeforeCreationPublication() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let categoryID = fixture.category.id
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(
            get: { presentation.selected }, set: { presentation.selected = $0 }
        ))
        let gate = FeedCreationGate()
        let committed = expectation(description: "Committed physical rows await an ordinary edit")
        let task = try XCTUnwrap(model.createFeed(
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [committed], timeout: 5)
        try await Self.write(configuration) { writer in
            let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            let feed = try XCTUnwrap(writer.objects(Feed.self).first)
            category.title = "Edited original category"
            feed.title = "Edited committed feed"
            category.refreshChangeMetadata(explicitlyModified: true)
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let authoritativeEdits = snapshot(fixture.realm)
        await gate.release()
        let publishedID = try await task.value
        let feedID = try XCTUnwrap(publishedID)
        fixture.realm.refresh()
        XCTAssertEqual(presentation.selected?.id, feedID)
        XCTAssertEqual(presentation.selected?.title, "Edited committed feed")
        XCTAssertEqual(presentation.published, [feedID])
        XCTAssertEqual(snapshot(fixture.realm), authoritativeEdits)
    }

    func testCreationPreservesDefaultsAndJournalsOnlyTheNewFeed() async throws {
        let fixture = try await makeFixture()
        let before = snapshot(fixture.realm)
        let creation = try await create(fixture)
        let result = try XCTUnwrap(creation)
        fixture.realm.refresh()
        let feed = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: result.feedID))
        let after = snapshot(fixture.realm)
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertEqual(after.feeds.count, 1)
        XCTAssertEqual(feed.createdAt, result.feedCreatedAt)
        XCTAssertEqual(feed.categoryID, result.categoryID)
        XCTAssertEqual(result.categoryCreatedAt, fixture.category.createdAt)
        XCTAssertEqual(feed.meaningfulContentMinLength, 0)
        XCTAssertEqual(feed.rssUrl, Feed().rssUrl)
        XCTAssertFalse(feed.isDeleted)
        XCTAssertNotNil(feed.explicitlyModifiedAt)
        XCTAssertEqual(after.generations.count, before.generations.count + 1)
        for (id, generation) in before.generations {
            XCTAssertEqual(after.generations[id], generation)
        }
    }

    func testManagedCategoryAtEntryMakesNoFeedOrJournalChange() async throws {
        let fixture = try await makeFixture()
        let categoryID = fixture.category.id
        try await Self.write(fixture.realm.configuration) { writer in
            let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            category.opmlURL = URL(string: "https://example.com/managed.opml")
            category.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let before = snapshot(fixture.realm)
        let result = try await create(fixture)
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertEqual(snapshot(fixture.realm), before)
    }

    func testDeletedCategoryAtWriteAdmissionMakesNoFeedOrJournalChange() async throws {
        let fixture = try await makeFixture()
        let categoryID = fixture.category.id
        let configuration = fixture.realm.configuration
        let result = try await create(fixture, beforeWrite: {
            try await Self.write(configuration) { writer in
                let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                category.isDeleted = true
                category.refreshChangeMetadata(explicitlyModified: true)
            }
        })
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)
        XCTAssertTrue(fixture.category.isDeleted)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 2)
    }

    func testManagedCategoryAtWriteAdmissionMakesNoFeed() async throws {
        let fixture = try await makeFixture()
        let categoryID = fixture.category.id
        let configuration = fixture.realm.configuration
        let result = try await create(fixture, beforeWrite: {
            try await Self.write(configuration) { writer in
                let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                category.opmlURL = URL(string: "https://example.com/managed.opml")
                category.refreshChangeMetadata(explicitlyModified: true)
            }
        })
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 2)
    }

    func testRecreatedCategoryAtWriteAdmissionIsNotRetargeted() async throws {
        let fixture = try await makeFixture()
        let categoryID = fixture.category.id
        let originalCreatedAt = fixture.category.createdAt
        let configuration = fixture.realm.configuration
        let result = try await create(fixture, beforeWrite: {
            try await Self.write(configuration) { writer in
                let old = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                let replacement = FeedCategory(value: old)
                replacement.createdAt = originalCreatedAt.addingTimeInterval(1)
                writer.delete(old)
                writer.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
            }
        })
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)
        XCTAssertEqual(
            fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)?.createdAt,
            originalCreatedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 2)
    }

    func testArchivedEditableCategoryRetainsItsExistingCreationPolicy() async throws {
        let fixture = try await makeFixture()
        let categoryID = fixture.category.id
        try await Self.write(fixture.realm.configuration) { writer in
            let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            category.isArchived = true
            category.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let result = try await create(fixture)
        fixture.realm.refresh()
        XCTAssertEqual(result?.categoryID, categoryID)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
    }

    func testCancellationBeforeAdmissionMakesNoFeedAndCanRetry() async throws {
        let fixture = try await makeFixture()
        let before = snapshot(fixture.realm)
        let configuration = fixture.realm.configuration
        let reference = ThreadSafeReference(to: fixture.category)
        let gate = FeedCreationGate()
        let entered = expectation(description: "Create is held before admission")
        let task = Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
                inCategory: reference, realmConfiguration: configuration,
                beforeWrite: { await gate.wait(onSuspension: { entered.fulfill() }) }
            )
        }
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("A cancelled uncommitted creation cannot succeed")
        } catch is CancellationError {}
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), before)
        let retried = try await create(fixture)
        fixture.realm.refresh()
        XCTAssertNotNil(retried)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
    }

    func testCancellationAfterCommitSubmissionReturnsTheDurableIdentity() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let reference = ThreadSafeReference(to: fixture.category)
        let task = RealmWriteCommitObservation.$didSubmit.withValue({
            withUnsafeCurrentTask { $0?.cancel() }
        }) {
            Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
                    inCategory: reference, realmConfiguration: configuration
                )
            }
        }
        let creation = try await task.value
        let result = try XCTUnwrap(creation)
        fixture.realm.refresh()
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
        XCTAssertEqual(
            fixture.realm.object(ofType: Feed.self, forPrimaryKey: result.feedID)?.createdAt,
            result.feedCreatedAt
        )
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 3)
    }

    func testCancelledQueuedCreationDoesNotRollBackAnotherOwnersWrite() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let categoryID = fixture.category.id
        let reference = ThreadSafeReference(to: fixture.category)
        let gate = FeedCreationGate()
        let peerEntered = expectation(description: "Peer owns the Realm transaction")
        let submitted = expectation(description: "Creation submits its independent SDK ticket")
        let peer = Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try writer.beginWrite()
            let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            category.title = "Peer's uncommitted title"
            category.refreshChangeMetadata(explicitlyModified: true)
            await gate.wait(onSuspension: { peerEntered.fulfill() })
            XCTAssertTrue(writer.isInWriteTransaction)
            XCTAssertEqual(category.title, "Peer's uncommitted title")
            try writer.commitWrite()
        }
        addTeardownBlock { await gate.release(); _ = await peer.result }
        await fulfillment(of: [peerEntered], timeout: 5)
        let task = RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
            Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
                    inCategory: reference, realmConfiguration: configuration
                )
            }
        }
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [submitted], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Only the queued creation is cancelled")
        } catch is CancellationError {}
        await gate.release()
        try await peer.value
        fixture.realm.refresh()
        XCTAssertEqual(fixture.category.title, "Peer's uncommitted title")
        XCTAssertTrue(fixture.realm.objects(Feed.self).isEmpty)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 2)
    }

    func testCategoryCommandUsesCapturedStoreAndPublishesTheCommittedFeed() async throws {
        let fixture = try await makeFixture()
        let replacement = try await makeFixture()
        let replacementBefore = snapshot(replacement.realm)
        let originalLibrary = LibraryDataManager.realmConfiguration
        let originalFeeds = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            LibraryDataManager.realmConfiguration = originalLibrary
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeeds
        }
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(get: { presentation.selected }, set: { presentation.selected = $0 }))
        LibraryDataManager.realmConfiguration = replacement.realm.configuration
        ReaderContentLoader.feedEntryRealmConfiguration = replacement.realm.configuration
        let task = try XCTUnwrap(model.createFeed(didPublish: { presentation.published.append($0) }))
        let creation = try await task.value
        let feedID = try XCTUnwrap(creation)
        fixture.realm.refresh()
        replacement.realm.refresh()
        XCTAssertEqual(snapshot(replacement.realm), replacementBefore)
        XCTAssertEqual(presentation.selected?.id, feedID)
        XCTAssertEqual(presentation.selected?.categoryID, fixture.category.id)
        XCTAssertEqual(presentation.selected?.realm?.configuration.inMemoryIdentifier, fixture.realm.configuration.inMemoryIdentifier)
        XCTAssertEqual(presentation.published, [feedID])
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
    }

    func testRetirementKeepsTheCommitButDoesNotPublishOrScroll() async throws {
        let fixture = try await makeFixture()
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(get: { presentation.selected }, set: { presentation.selected = $0 }))
        let gate = FeedCreationGate()
        let committed = expectation(description: "Creation committed before presentation")
        let task = try XCTUnwrap(model.createFeed(
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [committed], timeout: 5)
        model.retireFeedCreation()
        await gate.release()
        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertNil(presentation.selected)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 3)
    }

    func testNewerCreationPublishesWhileOlderCommittedResultIsHeld() async throws {
        let fixture = try await makeFixture()
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(get: { presentation.selected }, set: { presentation.selected = $0 }))
        let gate = FeedCreationGate()
        let committed = expectation(description: "Older creation is committed")
        let first = try XCTUnwrap(model.createFeed(
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { first.cancel(); await gate.release(); _ = await first.result }
        await fulfillment(of: [committed], timeout: 5)
        let second = try XCTUnwrap(model.createFeed(didPublish: { presentation.published.append($0) }))
        let nextResult = try await second.value
        let nextID = try XCTUnwrap(nextResult)
        await gate.release()
        let oldResult = try await first.value
        fixture.realm.refresh()
        XCTAssertNil(oldResult)
        XCTAssertEqual(presentation.selected?.id, nextID)
        XCTAssertEqual(presentation.published, [nextID])
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 2)
    }

    func testNewerSelectionSurvivesDelayedCreationPublication() async throws {
        let fixture = try await makeFixture()
        let otherCreation = try await create(fixture)
        let otherID = try XCTUnwrap(otherCreation?.feedID)
        fixture.realm.refresh()
        let other = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: otherID))
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(get: { presentation.selected }, set: { presentation.selected = $0 }))
        let task = try XCTUnwrap(model.createFeed(
            beforePublication: { presentation.selected = other },
            didPublish: { presentation.published.append($0) }
        ))
        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertEqual(presentation.selected?.id, otherID)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 2)
    }

    func testRecreatedFeedBeforePublicationIsNotSelected() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(get: { presentation.selected }, set: { presentation.selected = $0 }))
        let task = try XCTUnwrap(model.createFeed(beforePublication: {
            try await Self.write(configuration) { writer in
                let old = try XCTUnwrap(writer.objects(Feed.self).first)
                let replacement = Feed(value: old)
                replacement.createdAt = old.createdAt.addingTimeInterval(1)
                replacement.title = "Replacement"
                writer.delete(old)
                writer.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
            }
        }))
        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertNil(presentation.selected)
        XCTAssertEqual(fixture.realm.objects(Feed.self).first?.title, "Replacement")
    }



    func testAlreadyCancelledNewcomerDoesNotRetireAcceptedPresentation() async throws {
        let fixture = try await makeFixture()
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(
            get: { presentation.selected }, set: { presentation.selected = $0 }
        ))
        let gate = FeedCreationGate()
        let committed = expectation(description: "Accepted creation awaits presentation")
        let first = try XCTUnwrap(model.createFeed(
            beforePublication: { await gate.wait(onSuspension: { committed.fulfill() }) },
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { first.cancel(); await gate.release(); _ = await first.result }
        await fulfillment(of: [committed], timeout: 5)
        let newcomer = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return model.createFeed()
        }
        let rejected = await newcomer.value
        XCTAssertNil(rejected)
        await gate.release()
        let creation = try await first.value
        let feedID = try XCTUnwrap(creation)
        fixture.realm.refresh()
        XCTAssertEqual(presentation.selected?.id, feedID)
        XCTAssertEqual(presentation.published, [feedID])
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
    }

    func testRecreatedCategoryBeforePublicationKeepsTheCommitWithoutOpeningAnEditor() async throws {
        let fixture = try await makeFixture()
        let configuration = fixture.realm.configuration
        let categoryID = fixture.category.id
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(
            get: { presentation.selected }, set: { presentation.selected = $0 }
        ))
        let task = try XCTUnwrap(model.createFeed(
            beforePublication: {
                try await Self.write(configuration) { writer in
                    let old = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                    let replacement = FeedCategory(value: old)
                    replacement.createdAt = old.createdAt.addingTimeInterval(1)
                    replacement.title = "Replacement category"
                    writer.delete(old)
                    writer.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                }
            },
            didPublish: { presentation.published.append($0) }
        ))
        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertNil(presentation.selected)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertEqual(fixture.realm.objects(Feed.self).count, 1)
        XCTAssertEqual(
            fixture.realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)?.title,
            "Replacement category"
        )
    }


    private struct DiskFixture {
        let configuration: Realm.Configuration
        let replacementConfiguration: Realm.Configuration
        let retiredConfiguration: Realm.Configuration
        let categoryID: UUID
        let original: FeedCreationSnapshot
        let replacement: FeedCreationSnapshot
    }

    private func diskReference(_ fixture: DiskFixture) throws -> ThreadSafeReference<FeedCategory> {
        try autoreleasepool {
            let realm = try Realm(configuration: fixture.configuration)
            defer { realm.invalidate() }
            return ThreadSafeReference(to: try XCTUnwrap(
                realm.object(ofType: FeedCategory.self, forPrimaryKey: fixture.categoryID)
            ))
        }
    }

    private func diskSnapshot(_ configuration: Realm.Configuration) throws -> FeedCreationSnapshot {
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
            .appendingPathComponent("feed-creation-\(UUID())", isDirectory: true)
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
        XCTAssertEqual(original.generations.count, 1)
        XCTAssertEqual(Set(replacement.generations.keys), Set(original.generations.keys))
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

    private func createAfterReplacingDiskFile(_ fixture: DiskFixture) async throws {
        let reference = try diskReference(fixture)
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: fixture.configuration)
        try replaceDiskFile(fixture)
        _ = try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
            inCategory: reference, realmConfiguration: fixture.configuration,
            storageAdmission: admission
        )
    }

    func testCreationRejectsSamePathReplacementBeforeOpening() async throws {
        let fixture = try makeDiskFixture()
        do {
            try await createAfterReplacingDiskFile(fixture)
            XCTFail("Creation must not adopt a replacement physical store")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
    }

    func testCreationRevalidatesSamePathReplacementAfterOpening() async throws {
        let fixture = try makeDiskFixture()
        let reference = try diskReference(fixture)
        let configuration = fixture.configuration
        let gate = FeedCreationGate()
        let opened = expectation(description: "Original category resolved before the file replacement")
        let task = Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
                inCategory: reference, realmConfiguration: configuration,
                beforeWrite: { await gate.wait(onSuspension: { opened.fulfill() }) }
            )
        }
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [opened], timeout: 5)
        try replaceDiskFile(fixture)
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Owned creation must reject the retired physical store")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
    }


    func testSynchronousSelectionReplacementPreventsStaleScrollPublication() async throws {
        let fixture = try await makeFixture()
        let otherCreation = try await create(fixture)
        let otherID = try XCTUnwrap(otherCreation?.feedID)
        fixture.realm.refresh()
        let other = try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: otherID))
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(
            get: { presentation.selected },
            set: { _ in presentation.selected = other }
        ))
        let task = try XCTUnwrap(model.createFeed(didPublish: { presentation.published.append($0) }))
        let result = try await task.value
        XCTAssertNil(result)
        XCTAssertEqual(presentation.selected?.id, otherID)
        XCTAssertTrue(presentation.published.isEmpty)
    }

    func testCategoryCreationIdentityIsCapturedBeforeSchedulingTheCommand() async throws {
        let fixture = try await makeFixture()
        let presentation = FeedCreationPresentation()
        let model = model(fixture, selection: .init(
            get: { presentation.selected }, set: { presentation.selected = $0 }
        ))
        // A fresh background open must observe the new authoritative value,
        // rather than accidentally retaining the fixture writer's older version.
        await RealmBackgroundActor.shared.removeCachedRealm(for: fixture.realm.configuration)
        let replacementCreatedAt = fixture.category.createdAt.addingTimeInterval(1)
        let task = try XCTUnwrap(model.createFeed(
            didPublish: { presentation.published.append($0) }
        ))
        addTeardownBlock { task.cancel(); _ = await task.result }
        // No await occurs between command capture and this real Realm commit.
        // The command's MainActor task therefore cannot recapture the category
        // until after its creation identity has changed on the same live row.
        try fixture.realm.write {
            fixture.category.createdAt = replacementCreatedAt
            fixture.category.refreshChangeMetadata(explicitlyModified: true)
        }
        let authoritativeReplacement = snapshot(fixture.realm)

        let result = try await task.value
        fixture.realm.refresh()
        XCTAssertNil(result)
        XCTAssertNil(presentation.selected)
        XCTAssertTrue(presentation.published.isEmpty)
        XCTAssertEqual(fixture.category.createdAt, replacementCreatedAt)
        XCTAssertEqual(snapshot(fixture.realm), authoritativeReplacement)
    }
}
