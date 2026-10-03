import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class LibraryCategoryPresentationTests: XCTestCase {
    func testDisplayedUserAndArchiveDeletionSelectsTheirOwnRows() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let first = category("First")
        let second = category("Second")
        let archived = category("Archived")
        archived.isArchived = true
        let configuration = LibraryConfiguration()
        configuration.categoryIDs.append(objectsIn: [first.id, second.id])
        try realm.write { realm.add([first, second, archived]); realm.add(configuration) }

        let model = LibraryCategoriesViewModel(observesRealm: false)
        model.libraryConfiguration = configuration
        model.userLibraryCategories = [second, first]
        model.archivedCategories = [archived]
        let displayedUserCategoryIDs = model.userLibraryCategories!.map(\.id)
        let displayedArchivedCategoryIDs = model.archivedCategories!.map(\.id)
        model.userLibraryCategories = [first, second]
        model.archivedCategories = []

        try await model.deleteCategory(
            at: IndexSet(integer: 0), fromCategoryIDs: displayedUserCategoryIDs
        ).value
        realm.refresh()
        XCTAssertTrue(second.isArchived)
        XCTAssertFalse(first.isArchived)
        XCTAssertEqual(Array(configuration.categoryIDs), [first.id])
        XCTAssertNotNil(journal(for: second, in: realm))
        XCTAssertNotNil(journal(for: configuration, in: realm))

        try await model.deleteCategory(
            at: IndexSet(integer: 0), fromCategoryIDs: displayedArchivedCategoryIDs
        ).value
        realm.refresh()
        XCTAssertTrue(archived.isDeleted)
        XCTAssertNotNil(journal(for: archived, in: realm))
        XCTAssertFalse(first.isDeleted)
    }

    func testReorderPreservesHiddenIDsAndStaleOrNoOpCommandsDoNotJournal() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let first = category("First")
        let hidden = category("Managed")
        hidden.opmlURL = URL(string: "https://example.com/managed.opml")
        let second = category("Second")
        let late = category("Late")
        let configuration = LibraryConfiguration()
        configuration.categoryIDs.append(objectsIn: [first.id, hidden.id, second.id])
        try realm.write { realm.add([first, hidden, second, late]); realm.add(configuration) }

        let model = LibraryCategoriesViewModel(observesRealm: false)
        model.libraryConfiguration = configuration
        model.userLibraryCategories = [first, second]
        let before = journalGenerations(in: realm)
        XCTAssertNil(model.moveCategories(fromOffsets: IndexSet(integer: 0), toOffset: 0))
        XCTAssertEqual(journalGenerations(in: realm), before)

        let moved = try XCTUnwrap(model.moveCategories(fromOffsets: IndexSet(integer: 1), toOffset: 0))
        try await moved.value
        realm.refresh()
        XCTAssertEqual(Array(configuration.categoryIDs), [second.id, hidden.id, first.id])
        XCTAssertNotNil(journal(for: configuration, in: realm))

        model.userLibraryCategories = [second, first]
        let stale = try XCTUnwrap(model.moveCategories(fromOffsets: IndexSet(integer: 1), toOffset: 0))
        try realm.write {
            configuration.categoryIDs.append(late.id)
            configuration.refreshChangeMetadata(explicitlyModified: true)
        }
        let afterNewerWrite = journalGenerations(in: realm)
        try await stale.value
        realm.refresh()
        XCTAssertEqual(Array(configuration.categoryIDs), [second.id, hidden.id, first.id, late.id])
        XCTAssertEqual(journalGenerations(in: realm), afterNewerWrite)
    }

    func testRetainedDisplayedCategoryMoveUsesItsIDsAndRejectsNewerStoredOrdering() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let first = category("First")
        let hidden = category("Managed")
        hidden.opmlURL = URL(string: "https://example.com/managed.opml")
        let second = category("Second")
        let configuration = libraryConfiguration(
            id: UUID(), categoryIDs: [first.id, hidden.id, second.id]
        )
        try realm.write { realm.add([first, hidden, second]); realm.add(configuration) }

        let model = LibraryCategoriesViewModel(observesRealm: false)
        model.libraryConfiguration = configuration
        model.userLibraryCategories = [first, second]
        let displayedCategoryIDs = model.userLibraryCategories!.map(\.id)
        // The retained row callback still refers to First, even after a newer
        // presentation has published a different row order.
        model.userLibraryCategories = [second, first]
        let move = try XCTUnwrap(model.moveCategories(
            fromOffsets: IndexSet(integer: 0), toOffset: 2,
            displayedCategoryIDs: displayedCategoryIDs
        ))
        try await move.value
        realm.refresh()
        XCTAssertEqual(Array(configuration.categoryIDs), [second.id, hidden.id, first.id])
        XCTAssertNotNil(journal(for: configuration, in: realm))
        XCTAssertFalse(first.isDeleted)
        XCTAssertFalse(second.isDeleted)
        XCTAssertNil(journal(for: hidden, in: realm))

        // A callback from the earlier rendered order may not overwrite the
        // newer stored ordering, even though its indices remain valid.
        let beforeStaleMove = journalGenerations(in: realm)
        let staleMove = try XCTUnwrap(model.moveCategories(
            fromOffsets: IndexSet(integer: 0), toOffset: 2,
            displayedCategoryIDs: displayedCategoryIDs
        ))
        try await staleMove.value
        realm.refresh()
        XCTAssertEqual(Array(configuration.categoryIDs), [second.id, hidden.id, first.id])
        XCTAssertEqual(journalGenerations(in: realm), beforeStaleMove)
    }

    func testRetainedDisplayedFeedDeletionSurvivesRenameWithoutDeletingNewFirstRow() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let parent = category("Feeds")
        let first = feed("Alpha", id: UUID(), categoryID: parent.id)
        let second = feed("Beta", id: UUID(), categoryID: parent.id)
        let configuration = libraryConfiguration(id: UUID(), categoryIDs: [parent.id])
        try realm.write { realm.add([parent, first, second]); realm.add(configuration) }
        let model = LibraryCategoryViewModel(
            category: parent, libraryConfiguration: configuration,
            selectedFeed: .constant(nil)
        )
        let displayedFeedIDs = try XCTUnwrap(parent.getFeeds()).map(\.id)
        XCTAssertEqual(displayedFeedIDs, [first.id, second.id])
        try realm.write {
            first.title = "Zulu"
            first.refreshChangeMetadata(explicitlyModified: true)
        }
        XCTAssertEqual(parent.getFeeds()?.map(\.id), [second.id, first.id])
        let beforeDeletion = journalGenerations(in: realm)

        try await model.deleteFeed(
            at: IndexSet(integer: 0), fromFeedIDs: displayedFeedIDs
        ).value
        realm.refresh()
        XCTAssertTrue(first.isDeleted)
        XCTAssertFalse(second.isDeleted)
        XCTAssertNotEqual(journalGenerations(in: realm), beforeDeletion)
        XCTAssertNotNil(journal(for: first, in: realm))
        XCTAssertNil(journal(for: second, in: realm))
        XCTAssertNil(journal(for: parent, in: realm))
        XCTAssertNil(journal(for: configuration, in: realm))

        let afterDeletion = journalGenerations(in: realm)
        try await model.deleteFeed(
            at: IndexSet(integer: 0), fromFeedIDs: displayedFeedIDs
        ).value
        realm.refresh()
        XCTAssertFalse(second.isDeleted)
        XCTAssertEqual(journalGenerations(in: realm), afterDeletion)
    }

    func testDisplayedFeedDeletionRejectsNewlyManagedCategoryWithoutChangingJournals() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let parent = category("Feeds")
        let target = feed("Target", id: UUID(), categoryID: parent.id)
        let configuration = libraryConfiguration(id: UUID(), categoryIDs: [parent.id])
        try realm.write { realm.add([parent, target]); realm.add(configuration) }
        let model = LibraryCategoryViewModel(
            category: parent, libraryConfiguration: configuration,
            selectedFeed: .constant(nil)
        )
        let displayedFeedIDs = try XCTUnwrap(parent.getFeeds()).map(\.id)
        let deletion = model.deleteFeed(at: IndexSet(integer: 0), fromFeedIDs: displayedFeedIDs)
        // The command is queued on MainActor; editability changes before its
        // background write turn, while the displayed row remains the same.
        try realm.write {
            parent.opmlURL = URL(string: "https://example.com/managed.opml")
            parent.refreshChangeMetadata(explicitlyModified: true)
        }
        let beforeRejectedDeletion = journalGenerations(in: realm)
        try await deletion.value
        realm.refresh()
        XCTAssertFalse(target.isDeleted)
        XCTAssertNil(journal(for: target, in: realm))
        XCTAssertEqual(journalGenerations(in: realm), beforeRejectedDeletion)
    }

    func testCategoryCommandsAndRefreshStayInCapturedRealmAfterGlobalReplacement() async throws {
        let previousConfiguration = LibraryDataManager.realmConfiguration
        let capturedConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        defer { LibraryDataManager.realmConfiguration = previousConfiguration }
        let capturedRealm = try await Realm.open(configuration: capturedConfiguration)
        let replacementRealm = try await Realm.open(configuration: replacementConfiguration)

        let configurationID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let capturedLibrary = libraryConfiguration(id: configurationID, categoryIDs: [firstID, secondID])
        let replacementLibrary = libraryConfiguration(id: configurationID, categoryIDs: [firstID, secondID])
        let capturedFirst = category("Captured first", id: firstID)
        let capturedSecond = category("Captured second", id: secondID)
        let replacementFirst = category("Replacement first", id: firstID)
        let replacementSecond = category("Replacement second", id: secondID)
        try capturedRealm.write {
            capturedRealm.add([capturedFirst, capturedSecond])
            capturedRealm.add(capturedLibrary)
        }
        try replacementRealm.write {
            replacementRealm.add([replacementFirst, replacementSecond])
            replacementRealm.add(replacementLibrary)
        }

        LibraryDataManager.realmConfiguration = capturedConfiguration
        let model = LibraryCategoriesViewModel(
            observesRealm: false,
            realmConfiguration: capturedConfiguration
        )
        LibraryDataManager.realmConfiguration = replacementConfiguration

        try await model.refreshData().value
        XCTAssertEqual(model.userLibraryCategories?.map(\.title), ["Captured first", "Captured second"])

        model.userLibraryCategories = [capturedFirst, capturedSecond]
        let move = try XCTUnwrap(model.moveCategories(
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        ))
        try await move.value
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertEqual(Array(capturedLibrary.categoryIDs), [secondID, firstID])
        XCTAssertEqual(Array(replacementLibrary.categoryIDs), [firstID, secondID])

        try await model.deleteCategory(capturedFirst)
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertTrue(capturedFirst.isArchived)
        XCTAssertFalse(replacementFirst.isArchived)
        XCTAssertFalse(Array(capturedLibrary.categoryIDs).contains(firstID))
        XCTAssertTrue(Array(replacementLibrary.categoryIDs).contains(firstID))
        XCTAssertNotNil(journal(for: capturedFirst, in: capturedRealm))
        XCTAssertNotNil(journal(for: capturedLibrary, in: capturedRealm))
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)

        try await model.restoreCategory(capturedFirst)
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertFalse(capturedFirst.isArchived)
        XCTAssertTrue(Array(capturedLibrary.categoryIDs).contains(firstID))
        XCTAssertFalse(replacementFirst.isArchived)
        XCTAssertEqual(Array(replacementLibrary.categoryIDs), [firstID, secondID])
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)

        let createdCategoryID = try await model.createCategory()
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertNotNil(capturedRealm.object(
            ofType: FeedCategory.self,
            forPrimaryKey: createdCategoryID
        ))
        XCTAssertNil(replacementRealm.object(
            ofType: FeedCategory.self,
            forPrimaryKey: createdCategoryID
        ))
        XCTAssertTrue(Array(capturedLibrary.categoryIDs).contains(createdCategoryID))
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testCategoryEditorWritesFeedsAndDataManagerWrapperStayInCapturedRealm() async throws {
        let previousLibraryConfiguration = LibraryDataManager.realmConfiguration
        let previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let capturedConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        defer {
            LibraryDataManager.realmConfiguration = previousLibraryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
        }
        let capturedRealm = try await Realm.open(configuration: capturedConfiguration)
        let replacementRealm = try await Realm.open(configuration: replacementConfiguration)

        let configurationID = UUID()
        let categoryID = UUID()
        let feedID = UUID()
        let capturedLibrary = libraryConfiguration(id: configurationID, categoryIDs: [categoryID])
        let replacementLibrary = libraryConfiguration(id: configurationID, categoryIDs: [categoryID])
        let capturedCategory = category("Captured category", id: categoryID)
        let replacementCategory = category("Replacement category", id: categoryID)
        let capturedFeed = feed("Captured feed", id: feedID, categoryID: categoryID)
        let replacementFeed = feed("Replacement feed", id: feedID, categoryID: categoryID)
        try capturedRealm.write {
            capturedRealm.add([capturedCategory, capturedFeed])
            capturedRealm.add(capturedLibrary)
        }
        try replacementRealm.write {
            replacementRealm.add([replacementCategory, replacementFeed])
            replacementRealm.add(replacementLibrary)
        }

        LibraryDataManager.realmConfiguration = capturedConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = capturedConfiguration
        var selectedFeed: Feed?
        let model = LibraryCategoryViewModel(
            category: capturedCategory,
            libraryConfiguration: capturedLibrary,
            selectedFeed: Binding(get: { selectedFeed }, set: { selectedFeed = $0 })
        )
        LibraryDataManager.realmConfiguration = replacementConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacementConfiguration

        model.categoryTitle = "Edited captured category"
        model.categoryBackgroundImageURL = "https://example.com/edited.png"
        let fieldsUpdated = await waitUntil {
            capturedRealm.refresh()
            return capturedCategory.title == "Edited captured category"
                && capturedCategory.backgroundImageUrl.absoluteString == "https://example.com/edited.png"
        }
        XCTAssertTrue(fieldsUpdated)
        replacementRealm.refresh()
        XCTAssertEqual(replacementCategory.title, "Replacement category")
        XCTAssertEqual(
            replacementCategory.backgroundImageUrl.absoluteString,
            "https://example.com/category.png"
        )

        try await Task.sleep(for: .milliseconds(450))
        try capturedRealm.write {
            capturedCategory.title = "Captured notification"
            capturedCategory.refreshChangeMetadata(explicitlyModified: true)
        }
        let notificationPublished = await waitUntil {
            model.categoryTitle == "Captured notification"
        }
        XCTAssertTrue(notificationPublished)
        XCTAssertEqual(replacementCategory.title, "Replacement category")

        try await model.deleteFeed(capturedFeed)
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertTrue(capturedFeed.isDeleted)
        XCTAssertFalse(replacementFeed.isDeleted)
        XCTAssertNotNil(journal(for: capturedFeed, in: capturedRealm))

        let optionalCreatedFeedID = try await model.createFeed()
        let createdFeedID = try XCTUnwrap(optionalCreatedFeedID)
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertNotNil(capturedRealm.object(ofType: Feed.self, forPrimaryKey: createdFeedID))
        XCTAssertNil(replacementRealm.object(ofType: Feed.self, forPrimaryKey: createdFeedID))
        XCTAssertEqual(selectedFeed?.id, createdFeedID)

        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: capturedConfiguration)
            let category = try XCTUnwrap(realm.object(
                ofType: FeedCategory.self,
                forPrimaryKey: categoryID
            ))
            try await LibraryDataManager.shared.deleteCategory(category)
        }.value
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertTrue(capturedCategory.isArchived)
        XCTAssertFalse(replacementCategory.isArchived)
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)

        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: capturedConfiguration)
            let category = try XCTUnwrap(realm.object(
                ofType: FeedCategory.self,
                forPrimaryKey: categoryID
            ))
            try await LibraryDataManager.shared.restoreCategory(category)
        }.value
        capturedRealm.refresh()
        XCTAssertFalse(capturedCategory.isArchived)
        XCTAssertTrue(Array(capturedLibrary.categoryIDs).contains(categoryID))
    }

    func testListObserversKeepPublishingCapturedRealmAfterGlobalReplacement() async throws {
        let previousConfiguration = LibraryDataManager.realmConfiguration
        let capturedConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        defer { LibraryDataManager.realmConfiguration = previousConfiguration }
        let capturedRealm = try await Realm.open(configuration: capturedConfiguration)
        let replacementRealm = try await Realm.open(configuration: replacementConfiguration)

        let configurationID = UUID()
        let categoryID = UUID()
        let scriptID = UUID()
        let capturedLibrary = libraryConfiguration(
            id: configurationID,
            categoryIDs: [categoryID],
            scriptIDs: [scriptID]
        )
        let replacementLibrary = libraryConfiguration(
            id: configurationID,
            categoryIDs: [categoryID],
            scriptIDs: [scriptID]
        )
        let capturedCategory = category("Captured initial category", id: categoryID)
        let replacementCategory = category("Replacement initial category", id: categoryID)
        let capturedScript = script("Captured initial script", id: scriptID)
        let replacementScript = script("Replacement initial script", id: scriptID)
        try capturedRealm.write {
            capturedRealm.add([capturedCategory, capturedScript])
            capturedRealm.add(capturedLibrary)
        }
        try replacementRealm.write {
            replacementRealm.add([replacementCategory, replacementScript])
            replacementRealm.add(replacementLibrary)
        }

        LibraryDataManager.realmConfiguration = capturedConfiguration
        let categoriesModel = LibraryCategoriesViewModel(
            realmConfiguration: capturedConfiguration
        )
        let scriptsModel = LibraryScriptsListViewModel(
            realmConfiguration: capturedConfiguration
        )
        let initialPublished = await waitUntil {
            categoriesModel.userLibraryCategories?.map(\.title) == ["Captured initial category"]
                && scriptsModel.userScripts?.map(\.title) == ["Captured initial script"]
        }
        XCTAssertTrue(initialPublished)
        LibraryDataManager.realmConfiguration = replacementConfiguration

        let nextCategoryID = UUID()
        let nextScriptID = UUID()
        let capturedNextCategory = category("Captured next category", id: nextCategoryID)
        let capturedNextScript = script("Captured next script", id: nextScriptID)
        let replacementNextCategory = category("Replacement next category", id: nextCategoryID)
        let replacementNextScript = script("Replacement next script", id: nextScriptID)
        try replacementRealm.write {
            replacementRealm.add([replacementNextCategory, replacementNextScript])
            replacementLibrary.categoryIDs.append(nextCategoryID)
            replacementLibrary.userScriptIDs.append(nextScriptID)
        }
        try capturedRealm.write {
            capturedRealm.add([capturedNextCategory, capturedNextScript])
            capturedLibrary.categoryIDs.append(nextCategoryID)
            capturedLibrary.userScriptIDs.append(nextScriptID)
            capturedLibrary.refreshChangeMetadata(explicitlyModified: true)
        }

        let capturedUpdatePublished = await waitUntil {
            categoriesModel.userLibraryCategories?.map(\.title) == [
                "Captured initial category", "Captured next category",
            ] && scriptsModel.userScripts?.map(\.title) == [
                "Captured initial script", "Captured next script",
            ]
        }
        XCTAssertTrue(capturedUpdatePublished)
        XCTAssertFalse(categoriesModel.userLibraryCategories?.contains(where: {
            $0.title.hasPrefix("Replacement")
        }) ?? true)
        XCTAssertFalse(scriptsModel.userScripts?.contains(where: {
            $0.title.hasPrefix("Replacement")
        }) ?? true)
    }

    func testScriptRowCommandsUseCapturedSnapshotAndRealm() async throws {
        let previousConfiguration = LibraryDataManager.realmConfiguration
        let capturedConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        defer { LibraryDataManager.realmConfiguration = previousConfiguration }
        let capturedRealm = try await Realm.open(configuration: capturedConfiguration)
        let replacementRealm = try await Realm.open(configuration: replacementConfiguration)

        let configurationID = UUID()
        let firstID = UUID()
        let hiddenID = UUID()
        let lockedID = UUID()
        let secondID = UUID()
        let originalIDs = [firstID, hiddenID, lockedID, secondID]
        let capturedLibrary = libraryConfiguration(id: configurationID, scriptIDs: originalIDs)
        let replacementLibrary = libraryConfiguration(id: configurationID, scriptIDs: originalIDs)
        let capturedFirst = script("Captured first", id: firstID)
        let capturedLocked = script(
            "Captured locked",
            id: lockedID,
            opmlURL: URL(string: "https://example.com/system.opml")
        )
        let capturedSecond = script("Captured second", id: secondID)
        let replacementFirst = script("Replacement first", id: firstID)
        let replacementLocked = script(
            "Replacement locked",
            id: lockedID,
            opmlURL: URL(string: "https://example.com/system.opml")
        )
        let replacementSecond = script("Replacement second", id: secondID)
        try capturedRealm.write {
            capturedRealm.add([capturedFirst, capturedLocked, capturedSecond])
            capturedRealm.add(capturedLibrary)
        }
        try replacementRealm.write {
            replacementRealm.add([replacementFirst, replacementLocked, replacementSecond])
            replacementRealm.add(replacementLibrary)
        }

        LibraryDataManager.realmConfiguration = capturedConfiguration
        let model = LibraryScriptsListViewModel(
            observesRealm: false,
            realmConfiguration: capturedConfiguration
        )
        model.libraryConfiguration = capturedLibrary
        model.userScripts = [capturedFirst, capturedLocked, capturedSecond]
        let displayedScriptIDs = model.userScripts!.map(\.id)
        let displayedEditableScriptIDs = Set(model.userScripts!.filter(\.isUserEditable).map(\.id))
        model.userScripts = [capturedSecond, capturedLocked, capturedFirst]
        LibraryDataManager.realmConfiguration = replacementConfiguration

        let move = try XCTUnwrap(model.moveScripts(
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0,
            displayedScriptIDs: displayedScriptIDs,
            displayedEditableScriptIDs: displayedEditableScriptIDs
        ))
        try await move.value
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertEqual(
            Array(capturedLibrary.userScriptIDs),
            [secondID, hiddenID, lockedID, firstID]
        )
        XCTAssertEqual(Array(replacementLibrary.userScriptIDs), originalIDs)
        XCTAssertNotNil(journal(for: capturedLibrary, in: capturedRealm))
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)

        let beforeStaleMove = journalGenerations(in: capturedRealm)
        let staleMove = try XCTUnwrap(model.moveScripts(
            fromOffsets: IndexSet(integer: 2), toOffset: 0,
            displayedScriptIDs: displayedScriptIDs,
            displayedEditableScriptIDs: displayedEditableScriptIDs
        ))
        try await staleMove.value
        capturedRealm.refresh()
        XCTAssertEqual(Array(capturedLibrary.userScriptIDs), [secondID, hiddenID, lockedID, firstID])
        XCTAssertEqual(journalGenerations(in: capturedRealm), beforeStaleMove)

        model.userScripts = [capturedSecond, capturedLocked, capturedFirst]
        let beforeNoOps = journalGenerations(in: capturedRealm)
        XCTAssertNil(model.moveScripts(fromOffsets: IndexSet(integer: 0), toOffset: 0))
        model.userScripts = [capturedLocked, capturedSecond, capturedFirst]
        try await model.deleteScript(at: IndexSet(integer: 0)).value
        capturedRealm.refresh()
        XCTAssertEqual(journalGenerations(in: capturedRealm), beforeNoOps)
        XCTAssertFalse(capturedLocked.isArchived)

        model.userScripts = [capturedSecond, capturedLocked, capturedFirst]
        let displayedDeletionIDs = model.userScripts!.map(\.id)
        model.userScripts = [capturedLocked, capturedSecond]
        let deletion = model.deleteScript(
            at: IndexSet(integer: 2), displayedScriptIDs: displayedDeletionIDs
        )
        try await deletion.value
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertTrue(capturedFirst.isArchived)
        XCTAssertFalse(capturedSecond.isArchived)
        XCTAssertFalse(capturedLocked.isArchived)
        XCTAssertFalse(Array(capturedLibrary.userScriptIDs).contains(firstID))
        XCTAssertEqual(Array(replacementLibrary.userScriptIDs), originalIDs)
        XCTAssertFalse(replacementFirst.isArchived)
        XCTAssertNotNil(journal(for: capturedFirst, in: capturedRealm))
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)

        let createdScriptID = try await model.createScript()
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertNotNil(capturedRealm.object(ofType: UserScript.self, forPrimaryKey: createdScriptID))
        XCTAssertNil(replacementRealm.object(ofType: UserScript.self, forPrimaryKey: createdScriptID))
        XCTAssertTrue(Array(capturedLibrary.userScriptIDs).contains(createdScriptID))

        try await model.refreshData().value
        XCTAssertEqual(
            model.userScripts?.map(\.id),
            [secondID, lockedID, createdScriptID]
        )
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testScriptMoveAndDeleteRejectStaleConfigurationWithoutChangingJournals() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let first = script("First", id: UUID())
        let second = script("Second", id: UUID())
        let library = libraryConfiguration(id: UUID(), scriptIDs: [first.id, second.id])
        try realm.write {
            realm.add([first, second])
            realm.add(library)
        }
        let model = LibraryScriptsListViewModel(observesRealm: false)
        model.libraryConfiguration = library
        model.userScripts = [first, second]

        let move = try XCTUnwrap(model.moveScripts(fromOffsets: IndexSet(integer: 0), toOffset: 2))
        // The caller remains on MainActor, so the queued command cannot begin
        // before this external configuration edit has completed.
        try realm.write {
            library.createdAt = library.createdAt.addingTimeInterval(1)
            library.refreshChangeMetadata(explicitlyModified: true)
        }
        let beforeRejectedMove = journalGenerations(in: realm)
        try await move.value
        realm.refresh()
        XCTAssertEqual(Array(library.userScriptIDs), [first.id, second.id])
        XCTAssertEqual(journalGenerations(in: realm), beforeRejectedMove)

        let deletion = model.deleteScript(at: IndexSet(integer: 0))
        try realm.write {
            library.createdAt = library.createdAt.addingTimeInterval(1)
            library.refreshChangeMetadata(explicitlyModified: true)
        }
        let beforeRejectedDeletion = journalGenerations(in: realm)
        try await deletion.value
        realm.refresh()
        XCTAssertFalse(first.isArchived)
        XCTAssertFalse(first.isDeleted)
        XCTAssertEqual(Array(library.userScriptIDs), [first.id, second.id])
        XCTAssertEqual(journalGenerations(in: realm), beforeRejectedDeletion)

        let changedEditabilityMove = try XCTUnwrap(model.moveScripts(
            fromOffsets: IndexSet(integer: 0), toOffset: 2
        ))
        try realm.write {
            first.opmlURL = URL(string: "https://example.org/locked.opml")
            first.refreshChangeMetadata(explicitlyModified: true)
        }
        let beforeRejectedEditabilityChange = journalGenerations(in: realm)
        try await changedEditabilityMove.value
        realm.refresh()
        XCTAssertEqual(Array(library.userScriptIDs), [first.id, second.id])
        XCTAssertEqual(journalGenerations(in: realm), beforeRejectedEditabilityChange)
    }

    func testDelayedScriptFieldPublicationsKeepTheirOriginatingOwnerAfterReplacement() async throws {
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        let capturedConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        let capturedRealm = try await Realm(configuration: capturedConfiguration)
        let replacementRealm = try await Realm(configuration: replacementConfiguration)
        let first = script("First", id: UUID())
        first.script = "first source"
        first.previewURL = URL(string: "https://first.example")
        let second = script("Second", id: UUID())
        second.script = "second source"
        second.previewURL = URL(string: "https://second.example")
        let replacementFirst = script("Replacement first", id: first.id)
        let replacementSecond = script("Replacement second", id: second.id)
        try capturedRealm.write { capturedRealm.add([first, second]) }
        try replacementRealm.write { replacementRealm.add([replacementFirst, replacementSecond]) }
        LibraryDataManager.realmConfiguration = capturedConfiguration
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: capturedConfiguration, observesRealm: false
        )
        model.script = first
        XCTAssertEqual(model.scriptTitle, "First")
        model.scriptTitle = "Leading title"
        model.scriptText = "leading source"
        model.scriptPreviewURL = "https://leading.example"
        // The second publications must traverse the real trailing debounce.
        // Reassignment and hydration happen synchronously before that can fire.
        model.scriptTitle = "Trailing title"
        model.scriptText = "trailing source"
        model.scriptPreviewURL = "https://trailing.example"
        model.scriptEnabled = false
        model.scriptInjectAtStart = false
        model.scriptMainFrameOnly = false
        model.scriptSandboxed = true
        model.script = second
        LibraryDataManager.realmConfiguration = replacementConfiguration
        XCTAssertEqual(model.scriptTitle, "Second")
        XCTAssertEqual(model.scriptText, "second source")
        let editsCompleted = await waitUntil {
            capturedRealm.refresh()
            return first.title == "Trailing title" && first.script == "trailing source"
                && first.previewURL == URL(string: "https://trailing.example")
                && first.isArchived && !first.injectAtStart && !first.mainFrameOnly && first.sandboxed
        }
        XCTAssertTrue(editsCompleted)
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertEqual(second.title, "Second")
        XCTAssertEqual(second.script, "second source")
        XCTAssertEqual(second.previewURL, URL(string: "https://second.example"))
        XCTAssertFalse(second.isArchived)
        XCTAssertTrue(second.injectAtStart)
        XCTAssertTrue(second.mainFrameOnly)
        XCTAssertFalse(second.sandboxed)
        XCTAssertNil(journal(for: second, in: capturedRealm))
        XCTAssertNotNil(journal(for: first, in: capturedRealm))
        XCTAssertEqual(replacementFirst.title, "Replacement first")
        XCTAssertEqual(replacementSecond.title, "Replacement second")
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testScriptFieldHydrationAndNoOpPublicationsDoNotJournal() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let owner = script("Hydrated title", id: UUID())
        owner.script = "hydrated source"
        owner.isArchived = true
        owner.injectAtStart = false
        owner.mainFrameOnly = false
        owner.sandboxed = true
        owner.previewURL = URL(string: "https://hydrated.example")
        try realm.write { realm.add(owner) }
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        let before = journalGenerations(in: realm)
        model.script = owner
        model.refresh()
        // Let every production debounce expire: model hydration must never
        // become a delayed user edit or manufacture a journal generation.
        try await Task.sleep(for: .milliseconds(450))
        realm.refresh()
        XCTAssertEqual(journalGenerations(in: realm), before)
        XCTAssertEqual(model.scriptTitle, "Hydrated title")
        XCTAssertEqual(model.scriptText, "hydrated source")
        XCTAssertFalse(model.scriptEnabled)
        XCTAssertFalse(model.scriptInjectAtStart)
        XCTAssertFalse(model.scriptMainFrameOnly)
        XCTAssertTrue(model.scriptSandboxed)
        XCTAssertEqual(model.scriptPreviewURL, "https://hydrated.example")
        model.scriptTitle = owner.title
        model.scriptText = owner.script
        model.scriptEnabled = !owner.isArchived
        model.scriptInjectAtStart = owner.injectAtStart
        model.scriptMainFrameOnly = owner.mainFrameOnly
        model.scriptSandboxed = owner.sandboxed
        model.scriptPreviewURL = owner.previewURL!.absoluteString
        try await Task.sleep(for: .milliseconds(450))
        realm.refresh()
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testDelayedScriptFieldEditRechecksManagedEligibilityBeforeWriting() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let owner = script("Original", id: UUID())
        try realm.write { realm.add(owner) }
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        model.script = owner
        model.scriptTitle = "Leading edit"
        model.scriptTitle = "Rejected trailing edit"
        try realm.write { owner.opmlURL = URL(string: "https://example.com/managed.opml") }
        let titleBeforeDelay = owner.title
        let before = journalGenerations(in: realm)
        try await Task.sleep(for: .milliseconds(450))
        realm.refresh()
        XCTAssertEqual(owner.title, titleBeforeDelay)
        XCTAssertNotEqual(owner.title, "Rejected trailing edit")
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testAllowedDomainDeletionCapturesDisplayedIDsAndOriginatingScript() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let first = UserScriptAllowedDomain()
        first.domain = "first.example"
        let second = UserScriptAllowedDomain()
        let hiddenID = UUID()
        let owner = script("Owner", id: UUID())
        owner.allowedDomainIDs.append(objectsIn: [first.id, hiddenID, second.id])
        let replacement = script("Replacement", id: UUID())
        replacement.allowedDomainIDs.append(first.id)
        try realm.write { realm.add([first, second]); realm.add([owner, replacement]) }
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        model.script = owner
        let deletion = model.onDeleteOfAllowedDomains(
            at: IndexSet(integer: 0), displayedDomainIDs: [first.id, second.id]
        )
        model.script = replacement
        try realm.write {
            owner.allowedDomainIDs.removeAll()
            owner.allowedDomainIDs.append(objectsIn: [second.id, hiddenID, first.id])
        }
        try await deletion.value
        realm.refresh()
        XCTAssertTrue(first.isDeleted)
        XCTAssertFalse(second.isDeleted)
        XCTAssertEqual(Array(owner.allowedDomainIDs), [second.id, hiddenID])
        XCTAssertEqual(Array(replacement.allowedDomainIDs), [first.id])
        XCTAssertNotNil(journal(for: first, in: realm))
        XCTAssertNotNil(journal(for: owner, in: realm))
        XCTAssertNil(journal(for: replacement, in: realm))
        XCTAssertNil(journal(for: second, in: realm))

        let before = journalGenerations(in: realm)
        // A retained callback with invalid offsets and IDs absent from the live
        // list is harmless, even though the list has shrunk since rendering.
        try await model.onDeleteOfAllowedDomains(
            at: IndexSet([0, 8]), displayedDomainIDs: [first.id, second.id], scriptID: owner.id
        ).value
        realm.refresh()
        XCTAssertEqual(Array(owner.allowedDomainIDs), [second.id, hiddenID])
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testAllowedDomainCommandsRecheckLivePermissionsWithoutJournaling() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let domain = UserScriptAllowedDomain()
        let owner = script("Owner", id: UUID())
        owner.allowedDomainIDs.append(domain.id)
        try realm.write { realm.add(domain); realm.add(owner) }
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        model.script = owner
        let deletion = model.onDeleteOfAllowedDomains(
            at: IndexSet(integer: 0), displayedDomainIDs: [domain.id]
        )
        try realm.write { owner.opmlURL = URL(string: "https://example.com/managed.opml") }
        let before = journalGenerations(in: realm)
        try await deletion.value
        try await model.addEmptyDomain().value
        try await UserScriptAllowedDomainEditor(
            domainID: domain.id, scriptID: owner.id, realmConfiguration: realm.configuration
        ).write("blocked.example")
        realm.refresh()
        XCTAssertEqual(Array(owner.allowedDomainIDs), [domain.id])
        XCTAssertFalse(domain.isDeleted)
        XCTAssertEqual(domain.domain, "")
        XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testDomainCellEditorReadWriteAndAddStayInOriginatingRealmWithIdenticalIDs() async throws {
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        let capturedConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        let capturedRealm = try await Realm(configuration: capturedConfiguration)
        let replacementRealm = try await Realm(configuration: replacementConfiguration)
        let domainID = UUID()
        let scriptID = UUID()
        let capturedDomain = UserScriptAllowedDomain()
        capturedDomain.id = domainID
        capturedDomain.domain = "captured.example"
        let replacementDomain = UserScriptAllowedDomain()
        replacementDomain.id = domainID
        replacementDomain.domain = "replacement.example"
        let capturedScript = script("Captured", id: scriptID)
        let replacementScript = script("Replacement", id: scriptID)
        capturedScript.allowedDomainIDs.append(domainID)
        replacementScript.allowedDomainIDs.append(domainID)
        try capturedRealm.write { capturedRealm.add(capturedDomain); capturedRealm.add(capturedScript) }
        try replacementRealm.write { replacementRealm.add(replacementDomain); replacementRealm.add(replacementScript) }
        LibraryDataManager.realmConfiguration = capturedConfiguration
        // Use the actual cell's immutable editor, the same value captured by
        // both its load task and its debounced callback.
        let cell = UserScriptAllowedDomainCell(
            domainID: domainID, scriptID: scriptID, realmConfiguration: capturedConfiguration
        )
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: capturedConfiguration, observesRealm: false
        )
        model.script = capturedScript
        LibraryDataManager.realmConfiguration = replacementConfiguration
        let loadedText = try await cell.editor.read()
        XCTAssertEqual(loadedText, "captured.example")
        try await cell.editor.write("edited.example")
        try await model.addEmptyDomain().value
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertEqual(capturedDomain.domain, "edited.example")
        XCTAssertEqual(capturedScript.allowedDomainIDs.count, 2)
        XCTAssertEqual(replacementDomain.domain, "replacement.example")
        XCTAssertEqual(Array(replacementScript.allowedDomainIDs), [domainID])
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertNotNil(journal(for: capturedDomain, in: capturedRealm))
        let before = journalGenerations(in: capturedRealm)
        try await cell.editor.write("edited.example")
        capturedRealm.refresh()
        XCTAssertEqual(journalGenerations(in: capturedRealm), before)
        try capturedRealm.write { capturedScript.allowedDomainIDs.removeAll() }
        try await cell.editor.write("detached.example")
        capturedRealm.refresh()
        XCTAssertEqual(capturedDomain.domain, "edited.example")
        XCTAssertEqual(journalGenerations(in: capturedRealm), before)
        try capturedRealm.write { capturedScript.allowedDomainIDs.append(domainID) }
        try await model.deleteAllowedDomains([domainID]).value
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertTrue(capturedDomain.isDeleted)
        XCTAssertFalse(replacementDomain.isDeleted)
        XCTAssertEqual(Array(replacementScript.allowedDomainIDs), [domainID])
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testMountedCategoryContainerReplacesOwnerForSelectionAndRealmChanges() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let first = category("First")
        let second = category("Second")
        let library = libraryConfiguration(id: UUID(), categoryIDs: [first.id, second.id])
        try realm.write { realm.add([first, second]); realm.add(library) }
        let replacementRealm = try await Realm(configuration: makeConfiguration())
        let replacementCategory = category("Replacement second", id: second.id)
        let replacementLibrary = libraryConfiguration(id: library.id, categoryIDs: [second.id])
        try replacementRealm.write { replacementRealm.add(replacementCategory); replacementRealm.add(replacementLibrary) }
        let manager = LibraryManagerViewModel()
        var appearedModels: [LibraryCategoryViewModel] = []
        func root(_ category: FeedCategory, _ library: LibraryConfiguration) -> some View {
            NavigationStack {
                LibraryCategoryViewContainer(
                    category: category, libraryConfiguration: library, selectedFeed: .constant(nil),
                    onEditorAppear: { appearedModels.append($0) }
                )
                .environmentObject(manager)
            }
        }
#if os(macOS)
        let host = NSHostingView(rootView: root(first, library))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
#elseif os(iOS)
        let host = UIHostingController(rootView: root(first, library))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        defer { window.rootViewController = nil; window.isHidden = true }
#endif
        let firstAppeared = await waitUntil { appearedModels.last?.category.id == first.id }
        XCTAssertTrue(firstAppeared)
        host.rootView = root(second, library)
        let secondAppeared = await waitUntil { appearedModels.last?.category.id == second.id }
        XCTAssertTrue(secondAppeared)
        let secondModel = try XCTUnwrap(appearedModels.last)
        XCTAssertEqual(secondModel.categoryTitle, "Second")
        XCTAssertFalse(secondModel === appearedModels.first)
        secondModel.categoryTitle = "Edited second"
        let secondEdited = await waitUntil { realm.refresh(); return second.title == "Edited second" }
        XCTAssertTrue(secondEdited)
        XCTAssertEqual(first.title, "First")
        host.rootView = root(replacementCategory, replacementLibrary)
        let replacementAppeared = await waitUntil { appearedModels.last?.categoryTitle == "Replacement second" }
        XCTAssertTrue(replacementAppeared)
        let replacementModel = try XCTUnwrap(appearedModels.last)
        XCTAssertFalse(replacementModel === secondModel)
        replacementModel.categoryTitle = "Edited replacement"
        let replacementEdited = await waitUntil {
            replacementRealm.refresh(); return replacementCategory.title == "Edited replacement"
        }
        XCTAssertTrue(replacementEdited)
        realm.refresh()
        XCTAssertEqual(second.title, "Edited second")
    }

    func testScriptUserValueCanReturnAfterHydrationWithoutPublisherDeduplicationLoss() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let owner = script("Original", id: UUID())
        try realm.write { realm.add(owner) }
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        model.script = owner
        model.scriptTitle = "User value"
        let first = await waitUntil { realm.refresh(); return owner.title == "User value" }
        XCTAssertTrue(first)
        try realm.write { owner.title = "Hydrated value" }
        model.refresh()
        model.scriptTitle = "User value"
        let second = await waitUntil { realm.refresh(); return owner.title == "User value" }
        XCTAssertTrue(second)
    }

    func testScriptPasteReplacesBufferedPreviewURLAndKeepsItsJournalStable() async throws {
        let (realm, restoreConfiguration) = try makeRealm()
        defer { restoreConfiguration() }
        let owner = script("Original", id: UUID())
        try realm.write { realm.add(owner) }
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: realm.configuration, observesRealm: false
        )
        model.script = owner
        model.scriptPreviewURL = "https://example.com/leading"
        model.scriptPreviewURL = "https://example.com/buffered"
        try await model.pastePreviewURL(strings: ["https://example.com/pasted"]).value
        realm.refresh()
        XCTAssertEqual(owner.previewURL?.absoluteString, "https://example.com/pasted")
        let before = journalGenerations(in: realm)
        try await Task.sleep(for: .milliseconds(500))
        let settled = await waitUntil {
            realm.refresh()
            return owner.previewURL?.absoluteString == "https://example.com/pasted"
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.scriptPreviewURL, "https://example.com/pasted")
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    private func makeRealm() throws -> (Realm, () -> Void) {
        let previous = LibraryDataManager.realmConfiguration
        let configuration = makeConfiguration()
        LibraryDataManager.realmConfiguration = configuration
        return (try Realm(configuration: configuration), {
            LibraryDataManager.realmConfiguration = previous
        })
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let fixtureConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: fixtureConfiguration)
        }
        return configuration
    }

    private func libraryConfiguration(
        id: UUID,
        categoryIDs: [UUID] = [],
        scriptIDs: [UUID] = []
    ) -> LibraryConfiguration {
        let result = LibraryConfiguration()
        result.id = id
        result.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        result.categoryIDs.append(objectsIn: categoryIDs)
        result.userScriptIDs.append(objectsIn: scriptIDs)
        return result
    }

    private func category(_ title: String, id: UUID = UUID()) -> FeedCategory {
        let result = FeedCategory()
        result.id = id
        result.title = title
        result.backgroundImageUrl = URL(string: "https://example.com/category.png")!
        return result
    }

    private func feed(_ title: String, id: UUID, categoryID: UUID) -> Feed {
        let result = Feed()
        result.id = id
        result.title = title
        result.rssUrl = URL(string: "https://example.com/\(id).xml")!
        result.categoryID = categoryID
        return result
    }

    private func script(
        _ title: String,
        id: UUID,
        opmlURL: URL? = nil
    ) -> UserScript {
        let result = UserScript()
        result.id = id
        result.title = title
        result.opmlURL = opmlURL
        return result
    }

    private func journal(for object: Object, in realm: Realm) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let identifier = String(describing: object[primaryKey]!)
        return realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + identifier
        )
    }

    private func journalGenerations(in realm: Realm) -> [String: String] {
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
