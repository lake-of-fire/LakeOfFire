import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryEditorRetirementTests: XCTestCase {
    func testCategoryReleaseFlushesLatestDraftsToCapturedStorage() async throws {
        let original = try await Realm(configuration: configuration())
        let replacement = try await Realm(configuration: configuration())
        let category = FeedCategory()
        category.title = "Original"
        let library = LibraryConfiguration()
        let replacementCategory = FeedCategory()
        replacementCategory.id = category.id
        replacementCategory.title = "Replacement"
        try original.write { original.add(category); original.add(library) }
        try replacement.write { replacement.add(replacementCategory) }
        var model: LibraryCategoryViewModel? = LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil)
        )
        weak var retired = model
        model?.categoryTitle = "Leading"
        model?.categoryTitle = "Final"
        model?.categoryBackgroundImageURL = "https://example.com/leading.png"
        model?.categoryBackgroundImageURL = "https://example.com/final.png"
        model?.refresh()
        XCTAssertEqual(model?.categoryTitle, "Final")
        XCTAssertEqual(model?.categoryBackgroundImageURL, "https://example.com/final.png")
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = replacement.configuration
        model = nil
        let persisted = await waitUntil {
            original.refresh()
            return retired == nil && category.title == "Final"
                && category.backgroundImageUrl.absoluteString == "https://example.com/final.png"
        }
        XCTAssertTrue(persisted)
        replacement.refresh()
        XCTAssertEqual(replacementCategory.title, "Replacement")
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertEqual(generations(original).count, 1)
    }

    func testFeedReleaseFlushesAllBufferedFieldsAfterRefreshAndStorageReplacement() async throws {
        let original = try await Realm(configuration: configuration())
        let replacement = try await Realm(configuration: configuration())
        let feed = try installFeed(in: original)
        let replacementFeed = try installFeed(in: replacement, id: feed.id)
        var model: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(feed: feed)
        let initialized = await waitUntil { model?.hasInitializedValues == true }
        XCTAssertTrue(initialized)
        weak var retired = model
        model?.isEditing = true
        model?.feedTitle = "Leading"
        model?.feedTitle = "Final title"
        model?.feedDescription = "Leading description"
        model?.feedDescription = "Final description"
        model?.feedURL = "https://example.com/leading.xml"
        model?.feedURL = "https://example.com/final.xml"
        model?.feedIconURL = "https://example.com/leading.png"
        model?.feedIconURL = "https://example.com/final.png"
        model?.refresh()
        XCTAssertEqual(model?.feedTitle, "Final title")
        XCTAssertEqual(model?.feedDescription, "Final description")
        XCTAssertEqual(model?.feedURL, "https://example.com/final.xml")
        XCTAssertEqual(model?.feedIconURL, "https://example.com/final.png")
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = replacement.configuration
        model = nil
        let persisted = await waitUntil {
            original.refresh()
            return retired == nil && feed.title == "Final title"
                && feed.markdownDescription == "Final description"
                && feed.rssUrl.absoluteString == "https://example.com/final.xml"
                && feed.iconUrl.absoluteString == "https://example.com/final.png"
        }
        XCTAssertTrue(persisted)
        replacement.refresh()
        XCTAssertEqual(replacementFeed.title, "Original")
        XCTAssertEqual(replacementFeed.rssUrl.absoluteString, "https://example.com/original.xml")
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertEqual(generations(original).count, 1)
    }

    func testScriptReplacementAndReleaseFlushCommandsForTheirOriginatingIdentity() async throws {
        let realm = try await Realm(configuration: configuration())
        let first = UserScript()
        first.title = "First"
        let second = UserScript()
        second.title = "Second"
        try realm.write { realm.add(first); realm.add(second) }
        var model: LibraryScriptFormSectionsViewModel? = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        model?.script = first
        model?.scriptTitle = "First leading"
        model?.scriptTitle = "First final"
        model?.scriptText = "window.first = 1;"
        model?.scriptText = "window.first = 2;"
        model?.scriptPreviewURL = "https://example.com/first-leading"
        model?.scriptPreviewURL = "https://example.com/first-final"
        model?.refresh()
        XCTAssertEqual(model?.scriptTitle, "First final")
        XCTAssertEqual(model?.scriptText, "window.first = 2;")
        model?.script = second
        XCTAssertEqual(model?.scriptTitle, "Second")
        model?.scriptTitle = "Second leading"
        model?.scriptTitle = "Second final"
        model?.scriptText = "window.second = 1;"
        model?.scriptText = "window.second = 2;"
        model?.scriptPreviewURL = "https://example.com/second-leading"
        model?.scriptPreviewURL = "https://example.com/second-final"
        model?.refresh()
        XCTAssertEqual(model?.scriptTitle, "Second final")
        weak var retired = model
        model = nil
        let persisted = await waitUntil {
            realm.refresh()
            return retired == nil && first.title == "First final" && second.title == "Second final"
                && first.script == "window.first = 2;" && second.script == "window.second = 2;"
                && first.previewURL?.absoluteString == "https://example.com/first-final"
                && second.previewURL?.absoluteString == "https://example.com/second-final"
        }
        XCTAssertTrue(persisted)
        XCTAssertEqual(generations(realm).count, 2)
    }

    func testHydrationAndRepeatedFinishLeaveJournalGenerationsStable() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: feed.categoryID))
        let library = LibraryConfiguration()
        let script = UserScript()
        script.title = "Script"
        try realm.write { realm.add(library); realm.add(script) }
        let categoryModel = LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil)
        )
        let feedModel = LibraryFeedFormSectionsViewModel(feed: feed)
        let initialized = await waitUntil { feedModel.hasInitializedValues }
        XCTAssertTrue(initialized)
        let scriptModel = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        scriptModel.script = script
        let before = generations(realm)
        categoryModel.refresh()
        feedModel.refresh()
        scriptModel.refresh()
        categoryModel.categoryTitle = category.title
        feedModel.feedTitle = feed.title
        scriptModel.scriptTitle = script.title
        for _ in 0..<2 {
            categoryModel.finishEditing()
            feedModel.finishEditing()
            scriptModel.finishEditing()
        }
        // Cover trailing duplicate delivery after the explicit flush.
        try await Task.sleep(for: .milliseconds(500))
        try await feedModel.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertEqual(generations(realm), before)
        XCTAssertEqual(categoryModel.categoryTitle, category.title)
        XCTAssertEqual(feedModel.feedTitle, feed.title)
        XCTAssertEqual(scriptModel.scriptTitle, script.title)
    }

    func testOldScriptCompletionCannotSettleNewIdentityDraft() async throws {
        let realm = try await Realm(configuration: configuration())
        let first = UserScript()
        let second = UserScript()
        second.title = "Second persisted"
        try realm.write { realm.add(first); realm.add(second) }
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        model.script = first
        model.scriptTitle = "First leading"
        model.scriptTitle = "First final"
        model.script = second
        model.scriptTitle = "Second leading"
        model.scriptTitle = "Second final"
        let oldCompleted = await waitUntil { realm.refresh(); return first.title == "First final" }
        XCTAssertTrue(oldCompleted)
        model.refresh()
        XCTAssertEqual(model.scriptTitle, "Second final")
        let newCompleted = await waitUntil { realm.refresh(); return second.title == "Second final" }
        XCTAssertTrue(newCompleted)
        XCTAssertEqual(model.scriptTitle, "Second final")
    }

    func testRetiredEditorCannotOverwriteReopenedEditorsNewerNoOp() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let entered = expectation(description: "Older editor writer suspended")
        let release = LibraryEditorRetirementBarrier()
        addTeardownBlock { await release.open() }
        var oldModel: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false
        )
        let oldWrite = try XCTUnwrap(oldModel).writeFeedAsync(field: .title, beforeWrite: {
            entered.fulfill()
            await release.wait()
        }) { feed in
            guard feed.title != "Obsolete draft" else { return false }
            feed.title = "Obsolete draft"
            return true
        }
        await fulfillment(of: [entered], timeout: 3)
        weak var retired = oldModel
        oldModel = nil
        XCTAssertNil(retired)
        let reopened = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let before = generations(realm)
        try await reopened.writeFeedAsync(field: .title) { feed in
            guard feed.title != "Original" else { return false }
            feed.title = "Original"
            return true
        }.value
        await release.open()
        try await oldWrite.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertEqual(generations(realm), before,
                       "A newer intentional no-op must fence a retired editor without journaling")
    }

    func testUnspecifiedAndMaterializedVersionLimitsShareFinalWriteAdmission() async throws {
        var captured = configuration()
        captured.maximumNumberOfActiveVersions = nil
        let realm = try await Realm(configuration: captured)
        let feed = try installFeed(in: realm)
        XCTAssertNil(captured.maximumNumberOfActiveVersions)
        XCTAssertEqual(realm.configuration.maximumNumberOfActiveVersions, 0)
        let oldOrdering = LibraryEditorWriteOrdering.shared(configuration: captured, recordKind: "feed")
        let oldSequence = oldOrdering.issueSequence()
        let reopenedOrdering = LibraryEditorWriteOrdering.shared(
            configuration: realm.configuration, recordKind: "feed"
        )
        let newSequence = reopenedOrdering.issueSequence()
        let before = generations(realm)
        let feedID = feed.id
        let writerConfiguration = captured
        // A newer intentional no-op must still consume admission. The old
        // command then runs through the real transaction boundary and may not
        // overwrite that no-op, despite the configuration round trip.
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: writerConfiguration)
            try await writer.asyncWrite {
                XCTAssertTrue(reopenedOrdering.admits(
                    recordID: feedID, field: LibraryFeedEditorField.title.rawValue, sequence: newSequence
                ))
            }
            try await writer.asyncWrite {
                guard oldOrdering.admits(
                    recordID: feedID, field: LibraryFeedEditorField.title.rawValue, sequence: oldSequence
                ), let stored = writer.object(ofType: Feed.self, forPrimaryKey: feedID) else { return }
                stored.title = "Obsolete configuration draft"
                stored.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertEqual(generations(realm), before)
    }

    private func configuration() -> Realm.Configuration {
        var result = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        result.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&result)
        let captured = result
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        return result
    }

    private func installFeed(in realm: Realm, id: UUID = UUID()) throws -> Feed {
        let category = FeedCategory()
        let feed = Feed()
        feed.id = id
        feed.categoryID = category.id
        feed.title = "Original"
        feed.rssUrl = URL(string: "https://example.com/original.xml")!
        try realm.write { realm.add(category); realm.add(feed) }
        return feed
    }

    private func generations(_ realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private actor LibraryEditorRetirementBarrier {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
