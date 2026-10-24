import BigSyncKit
import Foundation
import OPML
import RealmSwift
import SwiftUIDownloads
import XCTest
@testable import LakeOfFireContent
@testable import RealmSwiftGaps

final class LibraryOPMLRoundTripTests: XCTestCase, @unchecked Sendable {
    private struct JournalState: Equatable {
        let generation: String
        let changedAt: Date
    }

    private enum ImportFailure: Error {
        case beforeCommit
    }

    @RealmBackgroundActor
    func testXMLRoundTripPreservesEmptyCategoriesAndNestedCollections() async throws {
        let source = try await makeRealm()
        let destination = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let library = LibraryConfiguration()
        let emptyCategory = FeedCategory()
        emptyCategory.title = "Empty category"
        let category = FeedCategory()
        category.title = "Directories"
        let emptyDirectory = FeedDirectory()
        emptyDirectory.title = "Empty directory"
        emptyDirectory.categoryID = category.id
        emptyDirectory.ordinal = 0
        let parent = FeedDirectory()
        parent.title = "Parent"
        parent.categoryID = category.id
        parent.ordinal = 1
        let nestedEmpty = FeedDirectory()
        nestedEmpty.title = "Nested empty directory"
        nestedEmpty.categoryID = category.id
        nestedEmpty.parentDirectoryID = parent.id
        nestedEmpty.ordinal = 0
        let feed = Feed()
        feed.title = "Nested feed"
        feed.rssUrl = URL(string: "https://example.org/nested.xml")!
        feed.categoryID = category.id
        feed.directoryID = parent.id
        feed.ordinal = 1
        feed.markdownDescription = "A nested subscription"
        feed.rssContainsFullContent = true
        let archived = FeedDirectory()
        archived.title = "Archived directory"
        archived.categoryID = category.id
        archived.isArchived = true
        let deleted = Feed()
        deleted.title = "Deleted feed"
        deleted.categoryID = category.id
        deleted.isDeleted = true
        library.categoryIDs.append(objectsIn: [emptyCategory.id, category.id])
        try source.write {
            source.add([library, emptyCategory, category, emptyDirectory, parent,
                        nestedEmpty, feed, archived, deleted])
        }

        let exported = try await manager.exportUserOPML(realmConfiguration: source.configuration)
        let parsed = try OPML(Data(exported.xml.utf8))
        XCTAssertEqual(parsed.entries.count, 3) // Script wrapper plus two categories.
        let fileURL = try writeXML(exported.xml)
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: destination.configuration)

        let restoredLibrary = try XCTUnwrap(destination.objects(LibraryConfiguration.self).first)
        XCTAssertEqual(Array(restoredLibrary.categoryIDs), [emptyCategory.id, category.id])
        let restoredCategory = try XCTUnwrap(destination.object(ofType: FeedCategory.self, forPrimaryKey: category.id))
        XCTAssertEqual(restoredCategory.getCollectionChildren()?.map(\.id), [emptyDirectory.id, parent.id])
        let restoredEmpty = try XCTUnwrap(destination.object(ofType: FeedCategory.self, forPrimaryKey: emptyCategory.id))
        XCTAssertTrue(restoredEmpty.isEmpty())
        for original in [emptyDirectory, parent, nestedEmpty] {
            let restored = try XCTUnwrap(destination.object(ofType: FeedDirectory.self, forPrimaryKey: original.id))
            XCTAssertEqual(restored.title, original.title)
            XCTAssertEqual(restored.categoryID, original.categoryID)
            XCTAssertEqual(restored.parentDirectoryID, original.parentDirectoryID)
            XCTAssertEqual(restored.ordinal, original.ordinal)
            XCTAssertFalse(restored.isDeleted)
            XCTAssertNotNil(destination.object(ofType: BigSyncPendingMutation.self,
                                               forPrimaryKey: "FeedDirectory.\(original.id)"))
        }
        let restoredParent = try XCTUnwrap(destination.object(ofType: FeedDirectory.self, forPrimaryKey: parent.id))
        XCTAssertEqual(restoredParent.getCollectionChildren()?.map(\.id), [nestedEmpty.id, feed.id])
        let restoredFeed = try XCTUnwrap(destination.object(ofType: Feed.self, forPrimaryKey: feed.id))
        XCTAssertEqual(restoredFeed.directoryID, parent.id)
        XCTAssertEqual(restoredFeed.categoryID, category.id)
        XCTAssertEqual(restoredFeed.rssUrl, feed.rssUrl)
        XCTAssertEqual(restoredFeed.markdownDescription, feed.markdownDescription)
        XCTAssertTrue(restoredFeed.rssContainsFullContent)
        XCTAssertNil(destination.object(ofType: FeedDirectory.self, forPrimaryKey: archived.id))
        XCTAssertNil(destination.object(ofType: Feed.self, forPrimaryKey: deleted.id))
        let journal = journalState(in: destination)
        XCTAssertNotNil(journal["FeedCategory.\(emptyCategory.id)"])
        XCTAssertNotNil(journal["Feed.\(feed.id)"])
        XCTAssertTrue(journal.values.allSatisfy { $0.changedAt == restoredLibrary.modifiedAt })

        try await manager.importOPML(fileURL: fileURL, realmConfiguration: destination.configuration)
        XCTAssertEqual(journalState(in: destination), journal)
    }

    @RealmBackgroundActor
    func testXMLRoundTripPreservesDisabledAndEmptyScriptsWithoutRejournaling() async throws {
        let source = try await makeRealm()
        let destination = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let library = LibraryConfiguration()
        let enabled = UserScript()
        enabled.title = "Enabled"
        enabled.script = "window.enabledScript = true;"
        let disabled = UserScript()
        disabled.title = "Disabled"
        disabled.script = "window.disabledScript = true;"
        disabled.isArchived = true
        let disabledEmpty = UserScript()
        disabledEmpty.title = "Disabled empty draft"
        disabledEmpty.isArchived = true
        let enabledEmpty = UserScript()
        enabledEmpty.title = "Enabled empty draft"
        let deleted = UserScript()
        deleted.title = "Deleted"
        deleted.isDeleted = true
        let domain = UserScriptAllowedDomain()
        domain.domain = "example.org"
        enabled.allowedDomainIDs.append(domain.id)
        let scripts = [enabled, disabled, disabledEmpty, enabledEmpty]
        library.userScriptIDs.append(objectsIn: scripts.map(\.id) + [deleted.id])
        try source.write {
            source.add([library, domain])
            source.add(scripts + [deleted])
        }

        let exported = try await manager.exportUserOPML(realmConfiguration: source.configuration)
        XCTAssertEqual(Array(library.userScriptIDs), scripts.map(\.id))
        let fileURL = try writeXML(exported.xml)
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: destination.configuration)

        let restoredLibrary = try XCTUnwrap(destination.objects(LibraryConfiguration.self).first)
        XCTAssertEqual(Array(restoredLibrary.userScriptIDs), scripts.map(\.id))
        XCTAssertEqual(destination.objects(UserScript.self).count, scripts.count)
        XCTAssertNil(destination.object(ofType: UserScript.self, forPrimaryKey: deleted.id))
        XCTAssertTrue(destination.objects(FeedCategory.self).isEmpty)
        for original in scripts {
            let restored = try XCTUnwrap(destination.object(ofType: UserScript.self, forPrimaryKey: original.id))
            XCTAssertEqual(restored.title, original.title)
            XCTAssertEqual(restored.script, original.script)
            XCTAssertEqual(restored.isArchived, original.isArchived)
            XCTAssertFalse(restored.isDeleted)
            XCTAssertNotNil(destination.object(ofType: BigSyncPendingMutation.self,
                                               forPrimaryKey: "UserScript.\(original.id)"))
        }
        let restoredEnabled = try XCTUnwrap(destination.object(ofType: UserScript.self, forPrimaryKey: enabled.id))
        XCTAssertEqual(restoredEnabled.getAllowedDomains()?.map(\.domain), [domain.domain])
        XCTAssertEqual(restoredLibrary.getActiveWebViewUserScriptDescriptors()?.count, 2)
        let journal = journalState(in: destination)
        XCTAssertTrue(journal.keys.contains { $0.hasPrefix("UserScriptAllowedDomain.") })
        XCTAssertTrue(journal.values.allSatisfy { $0.changedAt == restoredLibrary.modifiedAt })

        try await manager.importOPML(fileURL: fileURL, realmConfiguration: destination.configuration)
        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: destination.configuration)
        XCTAssertEqual(Array(consolidated.userScriptIDs), scripts.map(\.id))
        XCTAssertEqual(consolidated.getActiveWebViewUserScriptDescriptors()?.count, 2)
        XCTAssertEqual(journalState(in: destination), journal)
    }

    @RealmBackgroundActor
    func testMissingArchiveAttributeKeepsLegacyScriptEnabledAndReplayIsANoOp() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let script = UserScript()
        script.isArchived = true
        let library = LibraryConfiguration()
        library.userScriptIDs.append(script.id)
        try realm.write { realm.add([library, script]) }
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="User Scripts" isUserScriptList="true">
            <outline text="Legacy script" uuid="\(script.id)" script="window.legacy = true;"/>
          </outline>
        </body></opml>
        """)
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertFalse(script.isArchived)
        XCTAssertEqual(script.script, "window.legacy = true;")
        XCTAssertEqual(Array(library.userScriptIDs), [script.id])
        let journal = journalState(in: realm)
        XCTAssertNotNil(journal["UserScript.\(script.id)"])
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    @RealmBackgroundActor
    func testManagedImportPreservesLocalPositionsAndPrunesOrphanMembershipOnce() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let sourceURL = URL(string: "https://example.org/library.opml")!
        let library = LibraryConfiguration()
        let orphan = UserScript()
        orphan.title = "Removed source script"
        orphan.opmlURL = sourceURL
        let local = UserScript()
        local.title = "Local script"
        let first = UserScript()
        first.title = "Source A"
        first.opmlURL = sourceURL
        let second = UserScript()
        second.title = "Source B"
        second.opmlURL = sourceURL
        let thirdID = UUID()
        let unresolvedScriptID = UUID()
        let orphanCategory = FeedCategory()
        orphanCategory.opmlURL = sourceURL
        let localCategory = FeedCategory()
        localCategory.title = "Local category"
        let sourceCategory = FeedCategory()
        sourceCategory.title = "Source category"
        sourceCategory.opmlURL = sourceURL
        let newCategoryID = UUID()
        let unresolvedCategoryID = UUID()
        library.userScriptIDs.append(objectsIn: [orphan.id, local.id, first.id, second.id, unresolvedScriptID])
        library.categoryIDs.append(objectsIn: [orphanCategory.id, localCategory.id, sourceCategory.id, unresolvedCategoryID])
        try realm.write {
            realm.add([library, orphan, local, first, second, orphanCategory, localCategory, sourceCategory])
        }
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="User Scripts" isUserScriptList="true">
            <outline text="Source A" uuid="\(first.id)" script=""/>
            <outline text="Source B" uuid="\(second.id)" script=""/>
            <outline text="Source C" uuid="\(thirdID)" script=""/>
          </outline>
          <outline text="Source category" uuid="\(sourceCategory.id)"/>
          <outline text="New category" uuid="\(newCategoryID)"/>
        </body></opml>
        """)
        let download = Downloadable(url: sourceURL, name: "Defaults", localDestination: fileURL)
        try await manager.importOPML(fileURL: fileURL, fromDownload: download, realmConfiguration: realm.configuration)
        XCTAssertEqual(Array(library.userScriptIDs), [local.id, first.id, second.id, thirdID, unresolvedScriptID])
        XCTAssertEqual(Array(library.categoryIDs), [localCategory.id, sourceCategory.id, newCategoryID, unresolvedCategoryID])
        XCTAssertTrue(orphan.isDeleted)
        XCTAssertTrue(orphanCategory.isDeleted)
        XCTAssertFalse(local.isDeleted)
        XCTAssertNil(local.opmlURL)
        let journal = journalState(in: realm)
        XCTAssertNotNil(journal["UserScript.\(orphan.id)"])
        XCTAssertNotNil(journal["FeedCategory.\(orphanCategory.id)"])
        XCTAssertNotNil(journal["LibraryConfiguration.\(library.id)"])

        try await manager.importOPML(fileURL: fileURL, fromDownload: download, realmConfiguration: realm.configuration)
        XCTAssertEqual(journalState(in: realm), journal)
        XCTAssertEqual(Array(library.userScriptIDs), [local.id, first.id, second.id, thirdID, unresolvedScriptID])
        XCTAssertEqual(Array(library.categoryIDs), [localCategory.id, sourceCategory.id, newCategoryID, unresolvedCategoryID])
    }

    @RealmBackgroundActor
    func testArchivedCategoryStaysOutsideMembershipAndReplayDoesNotRejournal() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let archivedID = UUID()
        let activeID = UUID()
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="Archived category" uuid="\(archivedID)" isCommented="true"/>
          <outline text="Active empty category" uuid="\(activeID)"/>
        </body></opml>
        """)
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
        let archived = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: archivedID))
        XCTAssertTrue(archived.isArchived)
        XCTAssertFalse(archived.isDeleted)
        XCTAssertEqual(Array(library.categoryIDs), [activeID])
        let journal = journalState(in: realm)
        XCTAssertNotNil(journal["FeedCategory.\(archivedID)"])
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertEqual(Array(library.categoryIDs), [activeID])
        XCTAssertEqual(journalState(in: realm), journal)
    }

    @RealmBackgroundActor
    func testFailureBeforeCommitRollsBackConsolidationImportAndJournalThenRetries() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let sourceURL = URL(string: "https://example.org/rollback.opml")!
        let primary = LibraryConfiguration()
        primary.createdAt = Date(timeIntervalSince1970: 10)
        let duplicate = LibraryConfiguration()
        duplicate.createdAt = Date(timeIntervalSince1970: 20)
        let local = UserScript()
        local.title = "Local"
        duplicate.userScriptIDs.append(local.id)
        let orphan = UserScript()
        orphan.opmlURL = sourceURL
        primary.userScriptIDs.append(orphan.id)
        try realm.write { realm.add([primary, duplicate, local, orphan]) }
        let categoryID = UUID()
        let directoryID = UUID()
        let scriptID = UUID()
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="User Scripts" isUserScriptList="true">
            <outline text="New empty script" uuid="\(scriptID)" script=""/>
          </outline>
          <outline text="New category" uuid="\(categoryID)">
            <outline text="Empty child" uuid="\(directoryID)"/>
          </outline>
        </body></opml>
        """)
        let download = Downloadable(url: sourceURL, name: "Defaults", localDestination: fileURL)
        let before = journalState(in: realm)
        do {
            try await LibraryOPMLImportObservation.$beforeCommit.withValue({ @RealmBackgroundActor in
                XCTAssertTrue(duplicate.isDeleted)
                XCTAssertTrue(orphan.isDeleted)
                XCTAssertNotNil(realm.object(ofType: FeedDirectory.self, forPrimaryKey: directoryID))
                XCTAssertTrue(primary.userScriptIDs.contains(scriptID))
                XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
                throw ImportFailure.beforeCommit
            }) {
                try await manager.importOPML(fileURL: fileURL, fromDownload: download, realmConfiguration: realm.configuration)
            }
            XCTFail("Expected the actual import transaction to roll back")
        } catch ImportFailure.beforeCommit { }

        XCTAssertFalse(duplicate.isDeleted)
        XCTAssertFalse(orphan.isDeleted)
        XCTAssertEqual(Array(primary.userScriptIDs), [orphan.id])
        XCTAssertEqual(Array(duplicate.userScriptIDs), [local.id])
        XCTAssertTrue(primary.categoryIDs.isEmpty)
        XCTAssertNil(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        XCTAssertNil(realm.object(ofType: FeedDirectory.self, forPrimaryKey: directoryID))
        XCTAssertNil(realm.object(ofType: UserScript.self, forPrimaryKey: scriptID))
        XCTAssertEqual(journalState(in: realm), before)

        try await manager.importOPML(fileURL: fileURL, fromDownload: download, realmConfiguration: realm.configuration)
        XCTAssertTrue(duplicate.isDeleted)
        XCTAssertTrue(orphan.isDeleted)
        XCTAssertEqual(Array(primary.userScriptIDs), [local.id, scriptID])
        XCTAssertEqual(Array(primary.categoryIDs), [categoryID])
        let journal = journalState(in: realm)
        XCTAssertNotNil(journal["LibraryConfiguration.\(duplicate.id)"])
        XCTAssertNotNil(journal["UserScript.\(orphan.id)"])
        XCTAssertNotNil(journal["FeedDirectory.\(directoryID)"])
        XCTAssertTrue(journal.values.allSatisfy { $0.changedAt == primary.modifiedAt })
    }

    @RealmBackgroundActor
    func testCancellingAQueuedImportPreservesTheOtherWriteAndCanRetry() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let library = LibraryConfiguration()
        try realm.write { realm.add(library) }
        let categoryID = UUID()
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="Imported category" uuid="\(categoryID)"/>
        </body></opml>
        """)
        let marker = Date(timeIntervalSince1970: 123)
        try realm.beginWrite()
        library.opmlLastImportedAt = marker
        let submitted = XCTestExpectation(description: "Import ticket submitted behind another write")
        let settled = XCTestExpectation(description: "Cancelled import ticket settled")
        let importTask = Task { @RealmBackgroundActor in
            defer { settled.fulfill() }
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
            }
        }
        addTeardownBlock { @RealmBackgroundActor in
            importTask.cancel()
            if realm.isInWriteTransaction { realm.cancelWrite() }
            _ = await importTask.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        importTask.cancel()
        await fulfillment(of: [settled], timeout: 5)
        do {
            try await importTask.value
            XCTFail("Expected queued import cancellation")
        } catch is CancellationError { }
        XCTAssertTrue(realm.isInWriteTransaction)
        XCTAssertEqual(library.opmlLastImportedAt, marker)
        XCTAssertNil(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        realm.cancelWrite()
        XCTAssertNil(library.opmlLastImportedAt)

        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertEqual(Array(library.categoryIDs), [categoryID])
        XCTAssertNotNil(realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: "FeedCategory.\(categoryID)"))
    }

    @RealmBackgroundActor
    func testQueuedImportUsesCurrentConfigurationCreationAndMembership() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let original = LibraryConfiguration()
        original.createdAt = Date(timeIntervalSince1970: 100)
        let configurationID = original.id
        try realm.write { realm.add(original) }
        let importedID = UUID()
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="Imported category" uuid="\(importedID)"/>
        </body></opml>
        """)
        try realm.beginWrite()
        let submitted = XCTestExpectation(description: "Import admitted its source before waiting for the write")
        let importTask = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
            }
        }
        addTeardownBlock { @RealmBackgroundActor in
            importTask.cancel()
            if realm.isInWriteTransaction { realm.cancelWrite() }
            _ = await importTask.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        realm.delete(original)
        let replacement = LibraryConfiguration()
        replacement.id = configurationID
        replacement.createdAt = Date(timeIntervalSince1970: 200)
        let local = FeedCategory()
        local.title = "New local category"
        let unresolvedID = UUID()
        replacement.categoryIDs.append(objectsIn: [local.id, unresolvedID])
        realm.add([replacement, local])
        try realm.commitWrite()
        try await importTask.value

        XCTAssertEqual(replacement.createdAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(Array(replacement.categoryIDs), [local.id, unresolvedID, importedID])
        XCTAssertEqual(realm.objects(LibraryConfiguration.self).count, 1)
        XCTAssertNotNil(realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: "FeedCategory.\(importedID)"))
    }

    @RealmBackgroundActor
    func testCancellationAfterCommitSubmissionReturnsDurableSuccess() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let categoryID = UUID()
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="Durable category" uuid="\(categoryID)"/>
        </body></opml>
        """)
        let submitted = XCTestExpectation(description: "Actual import commit submitted")
        let importTask = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                submitted.fulfill()
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
            }
            return Task.isCancelled
        }
        addTeardownBlock { _ = await importTask.result }
        let wasCancelled = try await importTask.value
        await fulfillment(of: [submitted], timeout: 5)
        XCTAssertTrue(wasCancelled)
        let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
        XCTAssertEqual(Array(library.categoryIDs), [categoryID])
        let journal = journalState(in: realm)
        XCTAssertNotNil(journal["FeedCategory.\(categoryID)"])
        XCTAssertNotNil(journal["LibraryConfiguration.\(library.id)"])
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    @RealmBackgroundActor
    func testImportedFeedURLReplacementClearsOldMetadataButReplayPreservesNewMetadata() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let library = LibraryConfiguration()
        let category = FeedCategory()
        category.title = "Feeds"
        let feed = Feed()
        feed.title = "Subscription"
        feed.categoryID = category.id
        feed.rssUrl = URL(string: "https://example.org/old.xml")!
        feed.lastFetchedETag = "old-tag"
        feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 10)
        feed.lastRefreshedEntriesAt = Date(timeIntervalSince1970: 20)
        library.categoryIDs.append(category.id)
        try realm.write { realm.add([library, category, feed]) }
        let replacementURL = URL(string: "https://example.org/new.xml")!
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="Feeds" uuid="\(category.id)">
            <outline text="Subscription" uuid="\(feed.id)" type="rss" xmlUrl="\(replacementURL.absoluteString)"/>
          </outline>
        </body></opml>
        """)
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertEqual(feed.rssUrl, replacementURL)
        XCTAssertNil(feed.lastFetchedETag)
        XCTAssertNil(feed.lastFetchedModifiedAt)
        XCTAssertNil(feed.lastRefreshedEntriesAt)
        let refreshedAt = Date(timeIntervalSince1970: 30)
        try realm.write {
            feed.lastFetchedETag = "new-tag"
            feed.lastFetchedModifiedAt = refreshedAt
            feed.lastRefreshedEntriesAt = refreshedAt
        }
        let journal = journalState(in: realm)
        XCTAssertNotNil(journal["Feed.\(feed.id)"])
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertEqual(feed.lastFetchedETag, "new-tag")
        XCTAssertEqual(feed.lastFetchedModifiedAt, refreshedAt)
        XCTAssertEqual(feed.lastRefreshedEntriesAt, refreshedAt)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    @RealmBackgroundActor
    func testUnchangedDirectoryMovesToTheCurrentCatalogBeforeOldSourceCleanup() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let oldSource = URL(string: "https://example.org/library-v1.opml")!
        let currentSource = URL(string: "https://example.org/library-v2.opml")!
        let categoryID = UUID()
        let directoryID = UUID()
        let feedID = UUID()
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="Category" uuid="\(categoryID)">
            <outline text="Directory" uuid="\(directoryID)" markdownDescription="Keep this description">
              <outline text="Feed" uuid="\(feedID)" type="rss" xmlUrl="https://example.org/feed.xml"/>
            </outline>
          </outline>
        </body></opml>
        """)
        let oldDownload = Downloadable(url: oldSource, name: "Original", localDestination: fileURL)
        let currentDownload = Downloadable(url: currentSource, name: "Current", localDestination: fileURL)
        try await manager.importOPML(fileURL: fileURL, fromDownload: oldDownload, realmConfiguration: realm.configuration)
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        let directory = try XCTUnwrap(realm.object(ofType: FeedDirectory.self, forPrimaryKey: directoryID))
        let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
        let createdAt = directory.createdAt
        let originalJournal = journalState(in: realm)
        XCTAssertEqual(directory.opmlURL, oldSource)

        // Only the source changes. The XML, UUIDs, placement and attributes stay identical.
        try await manager.importOPML(fileURL: fileURL, fromDownload: currentDownload, realmConfiguration: realm.configuration)
        XCTAssertEqual(category.opmlURL, currentSource)
        XCTAssertEqual(directory.opmlURL, currentSource)
        XCTAssertEqual(directory.createdAt, createdAt)
        XCTAssertEqual(directory.markdownDescription, "Keep this description")
        XCTAssertEqual(directory.modifiedAt, category.modifiedAt)
        XCTAssertEqual(directory.explicitlyModifiedAt, directory.modifiedAt)
        let currentJournal = journalState(in: realm)
        XCTAssertNotEqual(currentJournal["FeedDirectory.\(directoryID)"], originalJournal["FeedDirectory.\(directoryID)"])
        XCTAssertEqual(currentJournal["Feed.\(feedID)"], originalJournal["Feed.\(feedID)"])

        try await manager.importOPML(fileURL: fileURL, fromDownload: currentDownload, realmConfiguration: realm.configuration)
        XCTAssertEqual(journalState(in: realm), currentJournal)

        let emptyFileURL = try writeXML("<opml version=\"2.0\"><head/><body/></opml>")
        let retiredDownload = Downloadable(url: oldSource, name: "Original", localDestination: emptyFileURL)
        try await manager.importOPML(fileURL: emptyFileURL, fromDownload: retiredDownload, realmConfiguration: realm.configuration)
        XCTAssertFalse(category.isDeleted)
        XCTAssertFalse(directory.isDeleted)
        XCTAssertFalse(feed.isDeleted)
        XCTAssertEqual(category.getCollectionChildren()?.map(\.id), [directoryID])
        XCTAssertEqual(directory.getCollectionChildren()?.map(\.id), [feedID])
        XCTAssertEqual(journalState(in: realm), currentJournal)

        // The current source still owns ordinary orphan deletion and its tombstones.
        let removedTreeURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="Category" uuid="\(categoryID)"/>
        </body></opml>
        """)
        let currentRemoval = Downloadable(url: currentSource, name: "Current", localDestination: removedTreeURL)
        try await manager.importOPML(fileURL: removedTreeURL, fromDownload: currentRemoval, realmConfiguration: realm.configuration)
        XCTAssertFalse(category.isDeleted)
        XCTAssertTrue(directory.isDeleted)
        XCTAssertTrue(feed.isDeleted)
        XCTAssertTrue(try XCTUnwrap(category.getCollectionChildren()).isEmpty)
        let removedJournal = journalState(in: realm)
        XCTAssertNotEqual(removedJournal["FeedDirectory.\(directoryID)"], currentJournal["FeedDirectory.\(directoryID)"])
        XCTAssertNotEqual(removedJournal["Feed.\(feedID)"], currentJournal["Feed.\(feedID)"])
        try await manager.importOPML(fileURL: removedTreeURL, fromDownload: currentRemoval, realmConfiguration: realm.configuration)
        XCTAssertEqual(journalState(in: realm), removedJournal)
    }

    @RealmBackgroundActor
    func testLocalDirectoryImportUsesTheExistingNilSourcePolicyWithoutOtherEdits() async throws {
        let realm = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let source = URL(string: "https://example.org/library.opml")!
        let categoryID = UUID()
        let directoryID = UUID()
        let fileURL = try writeXML("""
        <opml version="2.0"><head/><body>
          <outline text="Category" uuid="\(categoryID)">
            <outline text="Directory" uuid="\(directoryID)"/>
          </outline>
        </body></opml>
        """)
        let download = Downloadable(url: source, name: "Catalog", localDestination: fileURL)
        try await manager.importOPML(fileURL: fileURL, fromDownload: download, realmConfiguration: realm.configuration)
        let directory = try XCTUnwrap(realm.object(ofType: FeedDirectory.self, forPrimaryKey: directoryID))
        XCTAssertEqual(directory.opmlURL, source)
        let originalJournal = journalState(in: realm)

        // Directory applyAttributes already treats the optional source as authoritative.
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertNil(directory.opmlURL)
        XCTAssertEqual(directory.title, "Directory")
        XCTAssertEqual(directory.categoryID, categoryID)
        XCTAssertFalse(directory.isDeleted)
        let localJournal = journalState(in: realm)
        XCTAssertNotEqual(localJournal["FeedDirectory.\(directoryID)"], originalJournal["FeedDirectory.\(directoryID)"])
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: realm.configuration)
        XCTAssertEqual(journalState(in: realm), localJournal)
    }

    @RealmBackgroundActor
    private func makeRealm() async throws -> Realm {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self, Feed.self,
            UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        return realm
    }

    private func writeXML(_ xml: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-import-\(UUID().uuidString).opml")
        try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        return fileURL
    }

    @RealmBackgroundActor
    private func journalState(in realm: Realm) -> [String: JournalState] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, JournalState(generation: $0.generation, changedAt: $0.changedAt))
        })
    }
}
