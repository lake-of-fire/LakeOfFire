import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor CategoryFeedDeletionGate {
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

private struct CategoryFeedDeletionFeedState: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let categoryID: UUID?
    let title: String
    let isDeleted: Bool
    let modifiedAt: Date
    let explicitlyModifiedAt: Date?
}

private struct CategoryFeedDeletionCategoryState: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let title: String
    let isDeleted: Bool
    let opmlURL: URL?
    let modifiedAt: Date
    let explicitlyModifiedAt: Date?
}

private struct CategoryFeedDeletionSnapshot: Equatable, Sendable {
    let feeds: [CategoryFeedDeletionFeedState]
    let categories: [CategoryFeedDeletionCategoryState]
    let generations: [String: String]
}

private struct CategoryFeedDeletionDiskFixture: Sendable {
    let configuration: Realm.Configuration
    let replacementConfiguration: Realm.Configuration
    let retiredConfiguration: Realm.Configuration
    let command: LibraryCategoryFeedDeleteCommand
    let original: CategoryFeedDeletionSnapshot
    let replacement: CategoryFeedDeletionSnapshot
}

@MainActor
final class LibraryCategoryEditorPresentationTests: XCTestCase, @unchecked Sendable {
    private enum InjectedFailure: Error { case unexpectedWriteHook }

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

    private func makeFixture(titles: [String] = ["A", "B"]) async throws -> Fixture {
        let configuration = configured(Realm.Configuration(inMemoryIdentifier: UUID().uuidString))
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let categoryID = UUID()
        let libraryID = UUID()
        try await Self.write(configuration) { writer in
            let category = FeedCategory()
            category.id = categoryID
            category.createdAt = Date(timeIntervalSinceReferenceDate: 100)
            category.title = "Category"
            category.backgroundImageUrl = URL(string: "https://example.com/category.png")!
            writer.add(category)
            category.refreshChangeMetadata(explicitlyModified: true)
            let library = LibraryConfiguration()
            library.id = libraryID
            library.categoryIDs.append(categoryID)
            writer.add(library)
            library.refreshChangeMetadata(explicitlyModified: true)
            for (index, title) in titles.enumerated() {
                let feed = Feed()
                feed.createdAt = Date(timeIntervalSinceReferenceDate: Double(200 + index))
                feed.title = title
                feed.categoryID = categoryID
                feed.rssUrl = URL(string: "https://example.com/\(feed.id).xml")!
                feed.iconUrl = URL(string: "about:blank")!
                writer.add(feed)
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
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

    private func model(_ fixture: Fixture) -> LibraryCategoryViewModel {
        LibraryCategoryViewModel(
            category: fixture.category, libraryConfiguration: fixture.library,
            selectedFeed: .constant(nil), observesRealm: false
        )
    }

    private func feed(_ fixture: Fixture, title: String = "A") throws -> Feed {
        try XCTUnwrap(fixture.realm.objects(Feed.self).first(where: { $0.title == title }))
    }

    private func snapshot(_ realm: Realm) -> CategoryFeedDeletionSnapshot {
        CategoryFeedDeletionSnapshot(
            feeds: realm.objects(Feed.self).map {
                CategoryFeedDeletionFeedState(
                    id: $0.id, createdAt: $0.createdAt, categoryID: $0.categoryID,
                    title: $0.title, isDeleted: $0.isDeleted, modifiedAt: $0.modifiedAt,
                    explicitlyModifiedAt: $0.explicitlyModifiedAt
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            categories: realm.objects(FeedCategory.self).map {
                CategoryFeedDeletionCategoryState(
                    id: $0.id, createdAt: $0.createdAt, title: $0.title,
                    isDeleted: $0.isDeleted, opmlURL: $0.opmlURL,
                    modifiedAt: $0.modifiedAt, explicitlyModifiedAt: $0.explicitlyModifiedAt
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            generations: Dictionary(uniqueKeysWithValues:
                realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
            )
        )
    }

    func testRetiredEditorKeepsStableIdentityAndAvoidsManagedPresentationReads() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let categoryID = fixture.category.id
        let libraryID = fixture.library.id
        try await Self.write(fixture.realm.configuration) { writer in
            writer.delete(try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)))
            writer.delete(try XCTUnwrap(writer.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID)))
        }
        fixture.realm.refresh()
        XCTAssertTrue(fixture.category.isInvalidated)
        XCTAssertTrue(fixture.library.isInvalidated)

        XCTAssertEqual(editor.categoryID, categoryID)
        XCTAssertFalse(editor.isUserEditable)
        XCTAssertFalse(editor.showDeleteButton)
        XCTAssertFalse(editor.showRestoreButton)
        XCTAssertFalse(editor.showMoreOptions)
        XCTAssertEqual(editor.deleteButtonTitle, "Archive")
        XCTAssertEqual(editor.deleteButtonImageName, "archivebox")
        XCTAssertNil(editor.managedOPMLURL)
        XCTAssertTrue(editor.visibleFeeds.isEmpty)
        XCTAssertTrue(editor.visibleFeedRows.isEmpty)
        XCTAssertTrue(editor.duplicationCategories.isEmpty)
        XCTAssertEqual(editor.categoryImageURL.absoluteString, "about:blank")
        editor.categoryTitle = "Retained draft"
        editor.refresh()
        XCTAssertEqual(editor.categoryTitle, "Retained draft")
    }

    func testRetiredCategoryCannotDeleteItsCapturedFeed() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: feed(fixture)))
        let owner = try XCTUnwrap(LibraryCategoryFieldOwner(category: fixture.category))
        let command = LibraryCategoryFeedDeleteCommand(owner: owner, selections: [selection])
        let categoryID = fixture.category.id
        try await Self.write(fixture.realm.configuration) { writer in
            writer.delete(try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)))
        }
        fixture.realm.refresh()
        let afterRetirement = snapshot(fixture.realm)

        try await command.write()
        try await editor.deleteFeeds([selection]).value
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), afterRetirement)
        XCTAssertFalse(try feed(fixture).isDeleted)
    }

    func testDisplayedFeedDeletionUsesCapturedSelectionsAfterRename() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let displayed = editor.visibleFeedRows.map(\.id)
        let first = try feed(fixture)
        let second = try feed(fixture, title: "B")
        let firstID = first.id
        let secondID = second.id
        XCTAssertEqual(displayed.map(\.id), [firstID, secondID])
        try await Self.write(fixture.realm.configuration) { writer in
            let current = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: firstID))
            current.title = "Z"
            current.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        XCTAssertEqual(editor.visibleFeedRows.map(\.id.id), [secondID, firstID])
        let beforeDelete = snapshot(fixture.realm)

        // Include an obsolete out-of-bounds offset: the rendered first row must
        // still select A, and the missing row must not select a different feed.
        try await editor.deleteFeed(at: IndexSet([0, 99]), displayedFeeds: displayed).value
        fixture.realm.refresh()
        XCTAssertTrue(first.isDeleted)
        XCTAssertFalse(second.isDeleted)
        let afterDelete = snapshot(fixture.realm)
        XCTAssertEqual(afterDelete.categories, beforeDelete.categories)
        XCTAssertEqual(
            afterDelete.feeds.first(where: { $0.id == secondID }),
            beforeDelete.feeds.first(where: { $0.id == secondID })
        )
        XCTAssertEqual(afterDelete.generations.keys.filter {
            afterDelete.generations[$0] != beforeDelete.generations[$0]
        }.count, 1)
    }

    func testDisplayedFeedDeletionRejectsFeedMovedAfterCapture() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let item = try feed(fixture)
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: item))
        let otherID = UUID()
        let gate = CategoryFeedDeletionGate()
        let started = expectation(description: "Captured feed deletion opened its owner store")
        let deletion = editor.deleteFeeds([selection], beforeWrite: {
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { deletion.cancel(); await gate.release(); _ = await deletion.result }
        await fulfillment(of: [started], timeout: 5)
        try await Self.write(fixture.realm.configuration) { writer in
            let other = FeedCategory()
            other.id = otherID
            other.createdAt = Date(timeIntervalSinceReferenceDate: 400)
            other.title = "New owner"
            other.backgroundImageUrl = URL(string: "about:blank")!
            writer.add(other)
            other.refreshChangeMetadata(explicitlyModified: true)
            let current = try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: selection.id))
            current.categoryID = otherID
            current.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let afterMove = snapshot(fixture.realm)
        await gate.release()
        try await deletion.value
        fixture.realm.refresh()
        XCTAssertFalse(item.isDeleted)
        XCTAssertEqual(item.categoryID, otherID)
        XCTAssertEqual(snapshot(fixture.realm), afterMove)
    }

    func testCapturedContextSelectionAvoidsReadingInvalidatedFeedIdentity() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let item = try feed(fixture)
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: item))
        try await Self.write(fixture.realm.configuration) { writer in
            writer.delete(try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: selection.id)))
        }
        fixture.realm.refresh()
        XCTAssertTrue(item.isInvalidated)
        XCTAssertNil(LibraryCategoryFeedSelection(feed: item))
        let afterRemoval = snapshot(fixture.realm)

        // The displayed context menu already captured its value before the
        // managed row disappeared. Invoking it must not read item.id again.
        try await editor.deleteFeeds([selection]).value
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), afterRemoval)
    }

    func testCapturedFeedSelectionRejectsSameIDNewIncarnation() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: feed(fixture)))
        let categoryID = fixture.category.id
        let gate = CategoryFeedDeletionGate()
        let started = expectation(description: "Old feed selection suspended before mutation")
        let deletion = editor.deleteFeeds([selection], beforeWrite: {
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { deletion.cancel(); await gate.release(); _ = await deletion.result }
        await fulfillment(of: [started], timeout: 5)
        try await Self.write(fixture.realm.configuration) { writer in
            writer.delete(try XCTUnwrap(writer.object(ofType: Feed.self, forPrimaryKey: selection.id)))
            let successor = Feed()
            successor.id = selection.id
            successor.createdAt = selection.createdAt.addingTimeInterval(1)
            successor.categoryID = categoryID
            successor.title = "Successor feed"
            successor.rssUrl = URL(string: "https://example.com/successor.xml")!
            successor.iconUrl = URL(string: "about:blank")!
            writer.add(successor)
            successor.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let afterReplacement = snapshot(fixture.realm)
        await gate.release()
        try await deletion.value
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), afterReplacement)
        XCTAssertFalse(try XCTUnwrap(fixture.realm.object(ofType: Feed.self, forPrimaryKey: selection.id)).isDeleted)
    }

    func testCapturedCategoryOwnerRejectsSameIDNewIncarnation() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: feed(fixture)))
        let categoryID = fixture.category.id
        let createdAt = fixture.category.createdAt
        let gate = CategoryFeedDeletionGate()
        let started = expectation(description: "Old category owner suspended before mutation")
        let deletion = editor.deleteFeeds([selection], beforeWrite: {
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { deletion.cancel(); await gate.release(); _ = await deletion.result }
        await fulfillment(of: [started], timeout: 5)
        try await Self.write(fixture.realm.configuration) { writer in
            writer.delete(try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)))
            let successor = FeedCategory()
            successor.id = categoryID
            successor.createdAt = createdAt.addingTimeInterval(1)
            successor.title = "Successor category"
            successor.backgroundImageUrl = URL(string: "about:blank")!
            writer.add(successor)
            successor.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let afterReplacement = snapshot(fixture.realm)
        await gate.release()
        try await deletion.value
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), afterReplacement)
        XCTAssertFalse(try feed(fixture).isDeleted)
    }

    func testDeletionRechecksManagedCategoryEligibilityBeforeMutation() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: feed(fixture)))
        let categoryID = fixture.category.id
        let gate = CategoryFeedDeletionGate()
        let started = expectation(description: "Deletion captured the initially editable category")
        let deletion = editor.deleteFeeds([selection], beforeWrite: {
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { deletion.cancel(); await gate.release(); _ = await deletion.result }
        await fulfillment(of: [started], timeout: 5)
        try await Self.write(fixture.realm.configuration) { writer in
            let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            category.opmlURL = URL(string: "https://example.com/managed.opml")!
            category.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let afterEligibilityChange = snapshot(fixture.realm)
        await gate.release()
        try await deletion.value
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), afterEligibilityChange)
        XCTAssertFalse(try feed(fixture).isDeleted)
    }

    func testDeletionCannotMutateFeedThroughJournaledCategoryTombstone() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: feed(fixture)))
        let categoryID = fixture.category.id
        let gate = CategoryFeedDeletionGate()
        let started = expectation(description: "Deletion suspended before category tombstone")
        let deletion = editor.deleteFeeds([selection], beforeWrite: {
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { deletion.cancel(); await gate.release(); _ = await deletion.result }
        await fulfillment(of: [started], timeout: 5)
        try await Self.write(fixture.realm.configuration) { writer in
            let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            category.isDeleted = true
            category.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.realm.refresh()
        let afterTombstone = snapshot(fixture.realm)
        await gate.release()
        try await deletion.value
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), afterTombstone)
        XCTAssertFalse(try feed(fixture).isDeleted)
    }

    func testRepeatedAndDuplicateDeletionRetainsTombstoneWithoutRejournaling() async throws {
        let fixture = try await makeFixture()
        let editor = model(fixture)
        let item = try feed(fixture)
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: item))
        let beforeDelete = snapshot(fixture.realm)
        try await editor.deleteFeeds([selection, selection]).value
        fixture.realm.refresh()
        XCTAssertFalse(item.isInvalidated, "Deletion must retain a synchronized tombstone")
        XCTAssertTrue(item.isDeleted)
        let afterDelete = snapshot(fixture.realm)
        XCTAssertNotEqual(afterDelete.generations, beforeDelete.generations)
        XCTAssertEqual(afterDelete.categories, beforeDelete.categories)

        try await editor.deleteFeeds([selection, selection]).value
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), afterDelete)
    }

    func testEmptySelectionDoesNotReachWriteHookOrChangeJournal() async throws {
        let fixture = try await makeFixture()
        let owner = try XCTUnwrap(LibraryCategoryFieldOwner(category: fixture.category))
        let command = LibraryCategoryFeedDeleteCommand(owner: owner, selections: [])
        let before = snapshot(fixture.realm)
        try await command.write(beforeWrite: { throw InjectedFailure.unexpectedWriteHook })
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), before)
    }

    func testCancellationBeforeAdmissionPreservesFeedForExplicitRetry() async throws {
        let fixture = try await makeFixture()
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: feed(fixture)))
        let owner = try XCTUnwrap(LibraryCategoryFieldOwner(category: fixture.category))
        let command = LibraryCategoryFeedDeleteCommand(owner: owner, selections: [selection])
        let before = snapshot(fixture.realm)
        let gate = CategoryFeedDeletionGate()
        let started = expectation(description: "Deletion awaits final admission")
        let deletion = Task { @RealmBackgroundActor in
            try await command.write(beforeWrite: {
                await gate.wait(onSuspension: { started.fulfill() })
            })
        }
        addTeardownBlock { deletion.cancel(); await gate.release(); _ = await deletion.result }
        await fulfillment(of: [started], timeout: 5)
        deletion.cancel()
        await gate.release()
        do {
            try await deletion.value
            XCTFail("Cancelled uncommitted deletion must not report success")
        } catch is CancellationError {}
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), before)

        try await command.write()
        fixture.realm.refresh()
        XCTAssertTrue(try feed(fixture).isDeleted)
        XCTAssertNotEqual(snapshot(fixture.realm).generations, before.generations)
    }

    func testCancellationAfterCommitSubmissionSettlesTombstoneWithoutRejournaling() async throws {
        let fixture = try await makeFixture()
        let selection = try XCTUnwrap(LibraryCategoryFeedSelection(feed: feed(fixture)))
        let owner = try XCTUnwrap(LibraryCategoryFieldOwner(category: fixture.category))
        let command = LibraryCategoryFeedDeleteCommand(owner: owner, selections: [selection])
        let deletion = RealmWriteCommitObservation.$didSubmit.withValue({
            withUnsafeCurrentTask { $0?.cancel() }
        }) {
            Task { @RealmBackgroundActor in try await command.write() }
        }
        try await deletion.value
        XCTAssertTrue(deletion.isCancelled)
        fixture.realm.refresh()
        XCTAssertTrue(try feed(fixture).isDeleted)
        let afterCommit = snapshot(fixture.realm)

        try await command.write()
        fixture.realm.refresh()
        XCTAssertEqual(snapshot(fixture.realm), afterCommit)
    }

    // Reuse #274's physical-store boundary: capture real production identities,
    // close fixture accessors, then preserve UUIDs/creation dates while replacing
    // the file at the captured path. Both old and replacement journals are checked.
    private func diskCommand(_ configuration: Realm.Configuration) throws -> LibraryCategoryFeedDeleteCommand {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            defer { realm.invalidate() }
            let category = try XCTUnwrap(realm.objects(FeedCategory.self).first)
            let feed = try XCTUnwrap(realm.objects(Feed.self).first)
            return LibraryCategoryFeedDeleteCommand(
                owner: try XCTUnwrap(LibraryCategoryFieldOwner(category: category)),
                selections: [try XCTUnwrap(LibraryCategoryFeedSelection(feed: feed))]
            )
        }
    }

    private func diskSnapshot(_ configuration: Realm.Configuration) throws -> CategoryFeedDeletionSnapshot {
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

    private func diskFixture() throws -> CategoryFeedDeletionDiskFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-feed-deletion-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = configured(Realm.Configuration(
            fileURL: directory.appendingPathComponent("current.realm")
        ))
        var replacementConfiguration = configuration
        replacementConfiguration.fileURL = directory.appendingPathComponent("replacement.realm")
        var retiredConfiguration = configuration
        retiredConfiguration.fileURL = directory.appendingPathComponent("retired.realm")
        let captured = configuration
        addTeardownBlock {
            await Self.releaseDiskCache(captured)
            try? FileManager.default.removeItem(at: directory)
        }
        let categoryID = UUID()
        let libraryID = UUID()
        let feedID = UUID()
        for (store, title) in [(configuration, "Original"), (replacementConfiguration, "Replacement")] {
            try autoreleasepool {
                let realm = try Realm(configuration: store)
                defer { realm.invalidate() }
                try realm.write {
                    let category = FeedCategory()
                    category.id = categoryID
                    category.createdAt = Date(timeIntervalSinceReferenceDate: 100)
                    category.title = title
                    category.backgroundImageUrl = URL(string: "about:blank")!
                    realm.add(category)
                    category.refreshChangeMetadata(explicitlyModified: true)
                    let library = LibraryConfiguration()
                    library.id = libraryID
                    library.categoryIDs.append(categoryID)
                    realm.add(library)
                    library.refreshChangeMetadata(explicitlyModified: true)
                    let feed = Feed()
                    feed.id = feedID
                    feed.createdAt = Date(timeIntervalSinceReferenceDate: 200)
                    feed.title = title
                    feed.categoryID = categoryID
                    feed.rssUrl = URL(string: "https://example.com/feed.xml")!
                    feed.iconUrl = URL(string: "about:blank")!
                    realm.add(feed)
                    feed.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
        let original = try diskSnapshot(configuration)
        let replacement = try diskSnapshot(replacementConfiguration)
        XCTAssertEqual(original.feeds.map(\.id), replacement.feeds.map(\.id))
        XCTAssertEqual(original.feeds.map(\.createdAt), replacement.feeds.map(\.createdAt))
        XCTAssertEqual(original.categories.map(\.id), replacement.categories.map(\.id))
        XCTAssertEqual(original.categories.map(\.createdAt), replacement.categories.map(\.createdAt))
        return CategoryFeedDeletionDiskFixture(
            configuration: configuration, replacementConfiguration: replacementConfiguration,
            retiredConfiguration: retiredConfiguration, command: try diskCommand(configuration),
            original: original, replacement: replacement
        )
    }

    private func replaceDiskFile(_ fixture: CategoryFeedDeletionDiskFixture) throws {
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

    func testCapturedDeletionRejectsSamePathReplacementBeforeOpening() async throws {
        let fixture = try diskFixture()
        try replaceDiskFile(fixture)
        do {
            try await fixture.command.write()
            XCTFail("A captured deletion must not adopt the replacement store")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
    }

    func testCapturedDeletionRevalidatesSamePathReplacementAfterOpening() async throws {
        let fixture = try diskFixture()
        let command = fixture.command
        let gate = CategoryFeedDeletionGate()
        let opened = expectation(description: "Original physical store opened before deletion")
        let deletion = Task { @RealmBackgroundActor in
            try await command.write(beforeWrite: {
                await gate.wait(onSuspension: { opened.fulfill() })
            })
        }
        addTeardownBlock { deletion.cancel(); await gate.release(); _ = await deletion.result }
        await fulfillment(of: [opened], timeout: 5)
        try replaceDiskFile(fixture)
        await gate.release()
        do {
            try await deletion.value
            XCTFail("Deletion must revalidate the physical store inside its owned transaction")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
    }
}
