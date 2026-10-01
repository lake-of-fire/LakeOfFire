import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

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

        try await model.deleteCategory(at: IndexSet(integer: 0), from: model.userLibraryCategories).value
        realm.refresh()
        XCTAssertTrue(second.isArchived)
        XCTAssertFalse(first.isArchived)
        XCTAssertEqual(Array(configuration.categoryIDs), [first.id])
        XCTAssertNotNil(journal(for: second, in: realm))
        XCTAssertNotNil(journal(for: configuration, in: realm))

        try await model.deleteCategory(at: IndexSet(integer: 0), from: model.archivedCategories).value
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

    func testCategoryCommandsAndRefreshStayInCapturedRealmAfterGlobalReplacement() async throws {
        let previousConfiguration = LibraryDataManager.realmConfiguration
        let capturedConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        defer { LibraryDataManager.realmConfiguration = previousConfiguration }
        let capturedRealm = try Realm(configuration: capturedConfiguration)
        let replacementRealm = try Realm(configuration: replacementConfiguration)

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
        let capturedRealm = try Realm(configuration: capturedConfiguration)
        let replacementRealm = try Realm(configuration: replacementConfiguration)

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
        let capturedRealm = try Realm(configuration: capturedConfiguration)
        let replacementRealm = try Realm(configuration: replacementConfiguration)

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
        let capturedRealm = try Realm(configuration: capturedConfiguration)
        let replacementRealm = try Realm(configuration: replacementConfiguration)

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
        LibraryDataManager.realmConfiguration = replacementConfiguration

        let move = try XCTUnwrap(model.moveScripts(
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0
        ))
        try await move.value
        capturedRealm.refresh()
        replacementRealm.refresh()
        XCTAssertEqual(
            Array(capturedLibrary.userScriptIDs),
            [secondID, hiddenID, firstID, lockedID]
        )
        XCTAssertEqual(Array(replacementLibrary.userScriptIDs), originalIDs)
        XCTAssertNotNil(journal(for: capturedLibrary, in: capturedRealm))
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)

        model.userScripts = [capturedSecond, capturedFirst, capturedLocked]
        let beforeNoOps = journalGenerations(in: capturedRealm)
        XCTAssertNil(model.moveScripts(fromOffsets: IndexSet(integer: 0), toOffset: 0))
        model.userScripts = [capturedLocked, capturedSecond, capturedFirst]
        try await model.deleteScript(at: IndexSet(integer: 0)).value
        capturedRealm.refresh()
        XCTAssertEqual(journalGenerations(in: capturedRealm), beforeNoOps)
        XCTAssertFalse(capturedLocked.isArchived)

        model.userScripts = [capturedSecond, capturedFirst, capturedLocked]
        let deletion = model.deleteScript(at: IndexSet(integer: 1))
        model.userScripts = [capturedLocked, capturedSecond]
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
            FeedDirectory.self, UserScript.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
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
