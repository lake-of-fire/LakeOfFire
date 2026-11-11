import BigSyncKit
import SwiftUIDownloads
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryRegressionTests: XCTestCase, @unchecked Sendable {
    @RealmBackgroundActor
    func testDuplicateAndOverwritePreserveFeedContentAndImageSettings() async throws {
        let configuration = makeConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        let sourceCategory = FeedCategory()
        sourceCategory.title = "Source"
        let destinationCategory = FeedCategory()
        destinationCategory.title = "Destination"
        let source = makeFeed(title: "Configured source")
        source.categoryID = sourceCategory.id
        source.iconUrl = URL(string: "https://example.com/source-icon.png")!
        source.rssContainsFullContent = true
        source.extractImageFromContent = false
        source.isArchived = true
        try realm.write {
            realm.add(sourceCategory)
            realm.add(destinationCategory)
            realm.add(source)
            source.refreshChangeMetadata(explicitlyModified: true)
        }

        let duplicatedID = try await LibraryDataManager.shared.duplicateFeed(
            ThreadSafeReference(to: source),
            inCategory: ThreadSafeReference(to: destinationCategory),
            overwriteExisting: false,
            realmConfiguration: configuration
        )
        let firstID = try XCTUnwrap(duplicatedID)
        let copy = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: firstID))
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.categoryID, destinationCategory.id)
        XCTAssertFalse(copy.isArchived)
        XCTAssertFalse(copy.isDeleted)
        XCTAssertEqual(copy.iconUrl, source.iconUrl)
        XCTAssertTrue(copy.rssContainsFullContent)
        XCTAssertFalse(copy.extractImageFromContent)
        let recordName = "Feed.\(copy.id)"
        let firstGeneration = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
        )?.generation)

        try realm.write {
            source.iconUrl = URL(string: "https://example.com/revised-icon.png")!
            source.rssContainsFullContent = false
            source.extractImageFromContent = true
            source.refreshChangeMetadata(explicitlyModified: true)
        }
        let overwriteID = try await LibraryDataManager.shared.duplicateFeed(
            ThreadSafeReference(to: source),
            inCategory: ThreadSafeReference(to: destinationCategory),
            overwriteExisting: true,
            realmConfiguration: configuration
        )
        XCTAssertEqual(overwriteID, firstID)
        XCTAssertEqual(copy.iconUrl, source.iconUrl)
        XCTAssertFalse(copy.rssContainsFullContent)
        XCTAssertTrue(copy.extractImageFromContent)
        XCTAssertEqual(copy.categoryID, destinationCategory.id)
        XCTAssertFalse(copy.isArchived)
        XCTAssertTrue(source.isArchived)
        XCTAssertEqual(source.categoryID, sourceCategory.id)
        XCTAssertEqual(realm.objects(Feed.self).count, 2)
        XCTAssertNotEqual(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
        )?.generation, firstGeneration)
    }

    @MainActor
    func testConfiguredCatalogDownloadRespectsTheInjectedDataRoot() throws {
        let key = "JVIDS_MANABI_DATA_ROOT"
        let previousRoot = ProcessInfo.processInfo.environment[key]
        let previousGroup = LibraryConfiguration.securityApplicationGroupIdentifier
        let previousDirectory = LibraryConfiguration.downloadstDirectoryName
        let previousURLs = LibraryConfiguration.opmlURLs
        defer {
            if let previousRoot { setenv(key, previousRoot, 1) } else { unsetenv(key) }
            LibraryConfiguration.securityApplicationGroupIdentifier = previousGroup
            LibraryConfiguration.downloadstDirectoryName = previousDirectory
            LibraryConfiguration.opmlURLs = previousURLs
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv(key, root.path, 1)
        LibraryConfiguration.securityApplicationGroupIdentifier = "group.manabi.fixture-only"
        LibraryConfiguration.downloadstDirectoryName = "catalog-fixture"
        let source = URL(string: "https://example.invalid/\(UUID().uuidString).opml")!
        LibraryConfiguration.opmlURLs = [source]
        let downloadable = try XCTUnwrap(LibraryConfiguration.configuredDownloadables.first)
        XCTAssertEqual(downloadable.url, source)
        XCTAssertEqual(downloadable.localDestination,
                       root.appendingPathComponent("catalog-fixture", isDirectory: true)
                           .appendingPathComponent(source.lastPathComponent))
    }

    @RealmBackgroundActor
    func testAppFeedCreatesAfterForeignProvisionalMatchRollsBack() async throws {
        try await verifyAppFeedSelectionAfterForeignRollback(provisionalCreation: true)
    }

    @RealmBackgroundActor
    func testAppFeedRetainsCanonicalAfterForeignDeletionRollsBack() async throws {
        try await verifyAppFeedSelectionAfterForeignRollback(provisionalCreation: false)
    }

    @RealmBackgroundActor
    func testAppFeedUnarchivesAlreadyConfiguredCanonicalWithoutCreatingDuplicate() async throws {
        let configuration = makeConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        let feed = makeFeed(title: "Application feed")
        let feedID = feed.id
        feed.deleteOrphans = true
        feed.meaningfulContentMinLength = 0
        feed.isReaderModeByDefault = true
        feed.rssContainsFullContent = true
        feed.isArchived = true
        try realm.write {
            realm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        let originalGeneration = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: "Feed.\(feedID)"
        )?.generation)

        let result = try await LibraryDataManager.shared.getOrCreateAppFeed(
            rssURL: feed.rssUrl,
            isReaderModeByDefault: true,
            rssContainsFullContent: true,
            title: "Application feed",
            realmConfiguration: configuration
        )

        XCTAssertEqual(result?.id, feedID)
        XCTAssertFalse(feed.isArchived)
        XCTAssertEqual(realm.objects(Feed.self).count, 1)
        XCTAssertNotEqual(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: "Feed.\(feedID)"
        )?.generation, originalGeneration)
    }

    @RealmBackgroundActor
    private func verifyAppFeedSelectionAfterForeignRollback(provisionalCreation: Bool) async throws {
        let configuration = makeConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        let feed = makeFeed(title: "Application feed")
        let originalID = feed.id
        let rssURL = feed.rssUrl
        feed.deleteOrphans = true
        feed.meaningfulContentMinLength = 0
        feed.isReaderModeByDefault = true
        feed.rssContainsFullContent = true
        var originalGeneration: String?
        if !provisionalCreation {
            try realm.write {
                realm.add(feed)
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
            originalGeneration = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: "Feed.\(originalID)"
            )?.generation)
        }
        try realm.beginWrite()
        if provisionalCreation { realm.add(feed) } else { feed.isDeleted = true }
        defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
        let submitted = expectation(description: "Application feed selection acquires its own writer")
        let publication = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({
                Task { @RealmBackgroundActor in submitted.fulfill() }
            }) {
                let resolved = try await LibraryDataManager.shared.getOrCreateAppFeed(
                    rssURL: rssURL,
                    isReaderModeByDefault: true,
                    rssContainsFullContent: true,
                    title: "Application feed",
                    realmConfiguration: configuration
                )
                return resolved?.id
            }
        }
        defer { publication.cancel() }
        await fulfillment(of: [submitted], timeout: 5)
        XCTAssertTrue(realm.isInWriteTransaction)
        realm.cancelWrite()
        let resultID = try await publication.value
        let publishedID = try XCTUnwrap(resultID)
        let published = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: publishedID))

        XCTAssertFalse(published.isDeleted)
        XCTAssertFalse(published.isArchived)
        XCTAssertEqual(published.title, "Application feed")
        XCTAssertTrue(published.isReaderModeByDefault)
        XCTAssertTrue(published.rssContainsFullContent)
        XCTAssertEqual(realm.objects(Feed.self).count, 1)
        let mutation = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: "Feed.\(publishedID)"
        ))
        if provisionalCreation {
            XCTAssertNotEqual(publishedID, originalID)
            XCTAssertNil(realm.object(ofType: BigSyncPendingMutation.self,
                                     forPrimaryKey: "Feed.\(originalID)"))
        } else {
            XCTAssertEqual(publishedID, originalID)
            XCTAssertEqual(mutation.generation, originalGeneration)
        }
    }

    func test_scriptPublisherKeepsObservedRealmAfterConfigurationReplacement() async throws {
        try await verifyScriptPublisherKeepsObservedRealmAfterConfigurationReplacement()
    }

    @RealmBackgroundActor
    private func verifyScriptPublisherKeepsObservedRealmAfterConfigurationReplacement() async throws {
        let observedConfiguration = makeScriptConfiguration()
        let replacementConfiguration = makeScriptConfiguration()
        let originalConfiguration = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }

        let observedRealm = try await Realm(
            configuration: observedConfiguration, actor: RealmBackgroundActor.shared
        )
        let observedLibrary = LibraryConfiguration()
        let initialScript = UserScript()
        try await observedRealm.asyncWrite {
            observedRealm.add(observedLibrary)
            observedRealm.add(initialScript)
        }

        LibraryDataManager.realmConfiguration = observedConfiguration
        let manager = LibraryDataManager()
        defer { manager.realmCancellables.forEach { $0.cancel() } }

        // The initial collection publication proves both the real subscription
        // and its debounced callback have run before replacing the global Realm.
        let initialDelivery = try await eventually {
            observedLibrary.userScriptIDs.contains(initialScript.id)
        }
        XCTAssertTrue(initialDelivery)
        guard initialDelivery else { return }
        let recordName = "LibraryConfiguration.\(observedLibrary.id)"
        let initialGeneration = try XCTUnwrap(observedRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
        )?.generation)

        let replacementRealm = try await Realm(
            configuration: replacementConfiguration, actor: RealmBackgroundActor.shared
        )
        // An orphan in the replacement Realm exposes a misrouted callback as
        // a changed library row and a durable journal entry there.
        let replacementLibrary = LibraryConfiguration()
        let replacementOrphan = UserScript()
        try await replacementRealm.asyncWrite {
            replacementRealm.add(replacementLibrary)
            replacementRealm.add(replacementOrphan)
        }
        let replacementRecordName = "LibraryConfiguration.\(replacementLibrary.id)"
        XCTAssertNil(replacementRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: replacementRecordName
        ))

        LibraryDataManager.realmConfiguration = replacementConfiguration
        let nextObservedScript = UserScript()
        try await observedRealm.asyncWrite { observedRealm.add(nextObservedScript) }

        let nextDelivery = try await eventually {
            observedLibrary.userScriptIDs.contains(nextObservedScript.id)
        }
        XCTAssertTrue(nextDelivery)
        XCTAssertEqual(Array(observedLibrary.userScriptIDs), [initialScript.id, nextObservedScript.id])
        let nextMutation = try XCTUnwrap(observedRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
        ))
        XCTAssertNotEqual(nextMutation.generation, initialGeneration)
        XCTAssertEqual(Array(replacementLibrary.userScriptIDs), [])
        XCTAssertNil(replacementRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: replacementRecordName
        ))
    }

    @RealmBackgroundActor
    func testDuplicateFeedOverwritesDestinationAndConsumesReferencesOnce() async throws {
        let configuration = makeConfiguration()
        let originalConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = originalConfiguration }
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let realm = try await Realm(configuration: configuration, actor: RealmBackgroundActor.shared)

        let sourceCategory = FeedCategory()
        let destinationCategory = FeedCategory()
        let source = makeFeed(title: "source")
        source.categoryID = sourceCategory.id
        let existing = makeFeed(title: "old destination")
        existing.categoryID = destinationCategory.id
        try await realm.asyncWrite {
            realm.add([sourceCategory, destinationCategory, source, existing])
        }

        let resultID = try await LibraryDataManager.shared.duplicateFeed(
            ThreadSafeReference(to: source),
            inCategory: ThreadSafeReference(to: destinationCategory),
            overwriteExisting: true
        )
        XCTAssertEqual(resultID, existing.id)
        XCTAssertEqual(destinationCategory.getFeeds()?.map(\.id), [existing.id])
        XCTAssertEqual(destinationCategory.getFeeds()?.first?.title, "source")

        let createdID = try await LibraryDataManager.shared.duplicateFeed(
            ThreadSafeReference(to: source),
            inCategory: ThreadSafeReference(to: destinationCategory),
            overwriteExisting: false
        )
        let created = try XCTUnwrap(createdID.flatMap { realm.object(ofType: Feed.self, forPrimaryKey: $0) })
        XCTAssertNotEqual(created.id, existing.id)
        XCTAssertEqual(created.categoryID, destinationCategory.id)
        XCTAssertEqual(created.title, source.title)
        XCTAssertEqual(created.rssUrl, source.rssUrl)
        XCTAssertEqual(destinationCategory.getFeeds()?.count, 2)
    }

    @RealmBackgroundActor
    func testMultiFileOPMLImportKeepsCapturedRealmAfterGlobalReplacement() async throws {
        var capturedConfiguration = DefaultRealmConfiguration.configuration
        capturedConfiguration.fileURL = nil
        capturedConfiguration.inMemoryIdentifier = UUID().uuidString
        configureLakeOfFireMutationTrackingForTesting(&capturedConfiguration)
        var replacementConfiguration = capturedConfiguration
        replacementConfiguration.inMemoryIdentifier = UUID().uuidString
        let originalConfiguration = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }
        let capturedRealm = try await Realm(
            configuration: capturedConfiguration, actor: RealmBackgroundActor.shared
        )
        let replacementRealm = try await Realm(
            configuration: replacementConfiguration, actor: RealmBackgroundActor.shared
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let firstCategoryID = UUID()
        let secondCategoryID = UUID()
        let firstFeedID = UUID()
        let secondFeedID = UUID()
        let firstURL = directory.appendingPathComponent("first.opml")
        let secondURL = directory.appendingPathComponent("second.opml")
        for (fileURL, categoryID, feedID, title) in [
            (firstURL, firstCategoryID, firstFeedID, "First"),
            (secondURL, secondCategoryID, secondFeedID, "Second"),
        ] {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0"><head/><body>
              <outline text="\(title)" uuid="\(categoryID.uuidString)">
                <outline text="\(title) feed" uuid="\(feedID.uuidString)" xmlUrl="https://example.com/\(title).xml"/>
              </outline>
            </body></opml>
            """
            try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let cleanupConfiguration = capturedConfiguration
        let cleanupReplacementConfiguration = replacementConfiguration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: cleanupConfiguration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: cleanupReplacementConfiguration)
            let trash = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: directory, to: trash.appendingPathComponent("opml-import-test-\(directory.lastPathComponent)")
            )
        }

        LibraryDataManager.realmConfiguration = replacementConfiguration
        let manager = LibraryDataManager()
        defer { manager.realmCancellables.forEach { $0.cancel() } }
        await manager.importOPML(
            fileURLs: [firstURL, secondURL], realmConfiguration: capturedConfiguration
        )

        for categoryID in [firstCategoryID, secondCategoryID] {
            XCTAssertNotNil(capturedRealm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            XCTAssertNil(replacementRealm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        }
        for feedID in [firstFeedID, secondFeedID] {
            XCTAssertNotNil(capturedRealm.object(ofType: Feed.self, forPrimaryKey: feedID))
            XCTAssertNil(replacementRealm.object(ofType: Feed.self, forPrimaryKey: feedID))
        }
        XCTAssertFalse(capturedRealm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testMultiFileOPMLCancellationBetweenFilesPreservesCommittedJournalAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var capturedConfiguration = DefaultRealmConfiguration.configuration
        capturedConfiguration.inMemoryIdentifier = nil
        capturedConfiguration.fileURL = directory.appendingPathComponent("captured.realm")
        configureLakeOfFireMutationTrackingForTesting(&capturedConfiguration)
        var replacementConfiguration = capturedConfiguration
        replacementConfiguration.fileURL = directory.appendingPathComponent("replacement.realm")
        let originalConfiguration = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }
        let cleanupConfiguration = capturedConfiguration
        let cleanupReplacementConfiguration = replacementConfiguration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: cleanupConfiguration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: cleanupReplacementConfiguration)
            let trash = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: directory,
                to: trash.appendingPathComponent("opml-cancellation-test-\(directory.lastPathComponent)")
            )
        }

        let firstCategoryID = UUID()
        let secondCategoryID = UUID()
        let firstFeedID = UUID()
        let secondFeedID = UUID()
        let firstURL = directory.appendingPathComponent("first.opml")
        let secondURL = directory.appendingPathComponent("second.opml")
        for (fileURL, categoryID, feedID, title) in [
            (firstURL, firstCategoryID, firstFeedID, "First"),
            (secondURL, secondCategoryID, secondFeedID, "Second"),
        ] {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0"><head/><body>
              <outline text="\(title)" uuid="\(categoryID.uuidString)">
                <outline text="\(title) feed" uuid="\(feedID.uuidString)" xmlUrl="https://example.com/\(title).xml"/>
              </outline>
            </body></opml>
            """
            try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        LibraryDataManager.realmConfiguration = capturedConfiguration
        let manager = LibraryDataManager()
        defer { manager.realmCancellables.forEach { $0.cancel() } }
        let firstFileCommitted = expectation(description: "First OPML file committed")
        let boundary = OPMLImportFileBoundary()
        let importConfiguration = capturedConfiguration
        let importTask = Task {
            await manager.importOPML(
                fileURLs: [firstURL, secondURL],
                realmConfiguration: importConfiguration,
                afterImportingFile: { fileURL in
                    await boundary.pause(after: fileURL, reached: firstFileCommitted)
                }
            )
        }
        defer {
            importTask.cancel()
            Task { await boundary.resume() }
        }
        await fulfillment(of: [firstFileCommitted], timeout: 8)

        // The boundary is reached only after the complete production importer
        // returns, including category admission and its metadata refresh.
        let capturedRealm = try await Realm(
            configuration: capturedConfiguration, actor: RealmBackgroundActor.shared
        )
        let library = try XCTUnwrap(capturedRealm.objects(LibraryConfiguration.self).first)
        let libraryID = library.id
        XCTAssertEqual(Array(library.categoryIDs), [firstCategoryID])
        let firstRecordNames = [
            "FeedCategory.\(firstCategoryID)",
            "Feed.\(firstFeedID)",
            "LibraryConfiguration.\(libraryID)",
        ]
        let committedGenerations = try firstRecordNames.map { recordName in
            try XCTUnwrap(capturedRealm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
            )?.generation)
        }

        // Cancellation and global configuration replacement happen while the
        // old task is suspended. Its late return must not admit the next file.
        importTask.cancel()
        LibraryDataManager.realmConfiguration = replacementConfiguration
        await boundary.resume()
        await importTask.value
        XCTAssertTrue(importTask.isCancelled)
        let completedFileURLs = await boundary.completedFileURLs
        XCTAssertEqual(completedFileURLs, [firstURL])

        await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        let reopenedRealm = try await Realm(
            configuration: capturedConfiguration, actor: RealmBackgroundActor.shared
        )
        let replacementRealm = try await Realm(
            configuration: replacementConfiguration, actor: RealmBackgroundActor.shared
        )
        XCTAssertEqual(reopenedRealm.object(
            ofType: FeedCategory.self, forPrimaryKey: firstCategoryID
        )?.title, "First")
        XCTAssertEqual(reopenedRealm.object(
            ofType: Feed.self, forPrimaryKey: firstFeedID
        )?.categoryID, firstCategoryID)
        XCTAssertEqual(Array(try XCTUnwrap(reopenedRealm.object(
            ofType: LibraryConfiguration.self, forPrimaryKey: libraryID
        )).categoryIDs), [firstCategoryID])
        for (recordName, generation) in zip(firstRecordNames, committedGenerations) {
            XCTAssertEqual(reopenedRealm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
            )?.generation, generation)
        }
        XCTAssertNil(reopenedRealm.object(ofType: FeedCategory.self, forPrimaryKey: secondCategoryID))
        XCTAssertNil(reopenedRealm.object(ofType: Feed.self, forPrimaryKey: secondFeedID))
        XCTAssertNil(reopenedRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: "FeedCategory.\(secondCategoryID)"
        ))
        XCTAssertNil(reopenedRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: "Feed.\(secondFeedID)"
        ))
        XCTAssertTrue(replacementRealm.objects(LibraryConfiguration.self).isEmpty)
        XCTAssertTrue(replacementRealm.objects(FeedCategory.self).isEmpty)
        XCTAssertTrue(replacementRealm.objects(Feed.self).isEmpty)
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)

        // The canceled operation has fully returned. A new operation on the same
        // manager can finish the remaining file using the captured Realm.
        await manager.importOPML(fileURLs: [secondURL], realmConfiguration: capturedConfiguration)
        XCTAssertNotNil(reopenedRealm.object(ofType: FeedCategory.self, forPrimaryKey: secondCategoryID))
        XCTAssertNotNil(reopenedRealm.object(ofType: Feed.self, forPrimaryKey: secondFeedID))
        XCTAssertNotNil(reopenedRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: "Feed.\(secondFeedID)"
        ))
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testOPMLRoundTripPreservesEmptyCategoriesAndNestedDirectories() async throws {
        let sourceConfiguration = makeOPMLConfiguration()
        let restoredConfiguration = makeOPMLConfiguration()
        let sourceRealm = try await RealmBackgroundActor.shared.cachedRealm(for: sourceConfiguration)
        let restoredRealm = try await RealmBackgroundActor.shared.cachedRealm(for: restoredConfiguration)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: sourceConfiguration)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: restoredConfiguration)
        }
        let library = LibraryConfiguration()
        let emptyCategory = FeedCategory()
        emptyCategory.title = "Empty category"
        let category = FeedCategory()
        category.title = "Directories"
        let parent = FeedDirectory()
        parent.title = "Parent"
        parent.categoryID = category.id
        parent.ordinal = 1
        let nestedEmpty = FeedDirectory()
        nestedEmpty.title = "Nested empty directory"
        nestedEmpty.categoryID = category.id
        nestedEmpty.parentDirectoryID = parent.id
        nestedEmpty.ordinal = 0
        let empty = FeedDirectory()
        empty.title = "Empty directory"
        empty.categoryID = category.id
        empty.ordinal = 0
        library.categoryIDs.append(objectsIn: [emptyCategory.id, category.id])
        try sourceRealm.write {
            sourceRealm.add([library, emptyCategory, category, parent, nestedEmpty, empty])
        }

        let opml = try await LibraryDataManager.shared.exportUserOPML(
            realmConfiguration: sourceConfiguration
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-roundtrip-\(UUID().uuidString).opml")
        try opml.xml.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await LibraryDataManager.shared.importOPML(
            fileURL: fileURL, realmConfiguration: restoredConfiguration
        )

        let restoredLibrary = try XCTUnwrap(restoredRealm.objects(LibraryConfiguration.self).first)
        XCTAssertEqual(Array(restoredLibrary.categoryIDs), [emptyCategory.id, category.id])
        XCTAssertEqual(restoredRealm.objects(FeedCategory.self).count, 2)
        let restoredEmptyCategory = try XCTUnwrap(restoredRealm.object(
            ofType: FeedCategory.self, forPrimaryKey: emptyCategory.id
        ))
        XCTAssertEqual(restoredEmptyCategory.title, emptyCategory.title)
        XCTAssertTrue(restoredEmptyCategory.isEmpty())
        for original in [parent, nestedEmpty, empty] {
            let restored = try XCTUnwrap(restoredRealm.object(
                ofType: FeedDirectory.self, forPrimaryKey: original.id
            ))
            XCTAssertEqual(restored.title, original.title)
            XCTAssertEqual(restored.categoryID, original.categoryID)
            XCTAssertEqual(restored.parentDirectoryID, original.parentDirectoryID)
            XCTAssertEqual(restored.ordinal, original.ordinal)
            XCTAssertFalse(restored.isDeleted)
            XCTAssertNotNil(restoredRealm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: "FeedDirectory.\(original.id)"
            ))
        }
        XCTAssertEqual(restoredRealm.objects(FeedDirectory.self).count, 3)
        XCTAssertNotNil(restoredRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: "FeedCategory.\(emptyCategory.id)"
        ))
        let generations = Dictionary(uniqueKeysWithValues: restoredRealm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) })
        try await LibraryDataManager.shared.importOPML(
            fileURL: fileURL, realmConfiguration: restoredConfiguration
        )
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: restoredRealm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) }), generations)
    }

    @RealmBackgroundActor
    func testOPMLRoundTripPreservesDisabledAndEmptyScriptsWithoutRejournaling() async throws {
        let sourceConfiguration = makeOPMLConfiguration()
        let restoredConfiguration = makeOPMLConfiguration()
        let sourceRealm = try await RealmBackgroundActor.shared.cachedRealm(for: sourceConfiguration)
        let restoredRealm = try await RealmBackgroundActor.shared.cachedRealm(for: restoredConfiguration)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: sourceConfiguration)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: restoredConfiguration)
        }
        let library = LibraryConfiguration()
        let disabled = UserScript()
        disabled.title = "Disabled"
        disabled.script = "window.disabledScript = true;"
        disabled.isArchived = true
        let disabledEmpty = UserScript()
        disabledEmpty.title = "Disabled empty draft"
        disabledEmpty.isArchived = true
        let enabledEmpty = UserScript()
        enabledEmpty.title = "Enabled empty draft"
        let enabled = UserScript()
        enabled.title = "Enabled"
        enabled.script = "window.enabledScript = true;"
        let deleted = UserScript()
        deleted.title = "Deleted"
        deleted.isDeleted = true
        let scripts = [enabled, disabled, disabledEmpty, enabledEmpty]
        library.userScriptIDs.append(objectsIn: scripts.map(\.id) + [deleted.id])
        try sourceRealm.write {
            sourceRealm.add(library)
            sourceRealm.add(scripts + [deleted])
        }

        let opml = try await LibraryDataManager.shared.exportUserOPML(
            realmConfiguration: sourceConfiguration
        )
        XCTAssertEqual(Array(library.userScriptIDs), scripts.map(\.id))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scripts-roundtrip-\(UUID().uuidString).opml")
        try opml.xml.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await LibraryDataManager.shared.importOPML(
            fileURL: fileURL, realmConfiguration: restoredConfiguration
        )

        let restoredLibrary = try XCTUnwrap(restoredRealm.objects(LibraryConfiguration.self).first)
        XCTAssertEqual(Array(restoredLibrary.userScriptIDs), scripts.map(\.id))
        XCTAssertEqual(restoredRealm.objects(UserScript.self).count, scripts.count)
        XCTAssertNil(restoredRealm.object(ofType: UserScript.self, forPrimaryKey: deleted.id))
        XCTAssertTrue(restoredRealm.objects(FeedCategory.self).isEmpty)
        for original in scripts {
            let restored = try XCTUnwrap(restoredRealm.object(
                ofType: UserScript.self, forPrimaryKey: original.id
            ))
            XCTAssertEqual(restored.title, original.title)
            XCTAssertEqual(restored.script, original.script)
            XCTAssertEqual(restored.isArchived, original.isArchived)
            XCTAssertFalse(restored.isDeleted)
            XCTAssertNotNil(restoredRealm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: "UserScript.\(original.id)"
            ))
        }
        // WKContentWorld is initialized on the main thread; use an immutable
        // Realm snapshot while checking the actual WebKit script projection.
        let frozenLibrary = restoredLibrary.freeze()
        let activeScriptCount = await MainActor.run {
            frozenLibrary.getActiveWebViewUserScripts()?.count
        }
        XCTAssertEqual(activeScriptCount, 2)
        let generations = Dictionary(uniqueKeysWithValues: restoredRealm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) })
        try await LibraryDataManager.shared.importOPML(
            fileURL: fileURL, realmConfiguration: restoredConfiguration
        )
        let consolidated = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: restoredConfiguration
        )
        XCTAssertEqual(Array(consolidated.userScriptIDs), scripts.map(\.id))
        XCTAssertEqual(consolidated.getActiveWebViewUserScripts()?.count, 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: restoredRealm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) }), generations)
    }

    @RealmBackgroundActor
    func testOPMLScriptWithoutArchiveAttributeRemainsEnabledAndIdempotent() async throws {
        let configuration = makeOPMLConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        let script = UserScript()
        script.isArchived = true
        let library = LibraryConfiguration()
        library.userScriptIDs.append(script.id)
        try realm.write { realm.add([library, script]) }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head/><body>
          <outline text="User Scripts" isUserScriptList="true">
            <outline text="Legacy script" uuid="\(script.id.uuidString)" script="window.legacy = true;"/>
          </outline>
          <outline text="Script without identity" script="window.unidentified = true;"/>
        </body></opml>
        """
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-script-\(UUID().uuidString).opml")
        try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await LibraryDataManager.shared.importOPML(fileURL: fileURL, realmConfiguration: configuration)

        XCTAssertFalse(script.isArchived)
        XCTAssertEqual(script.script, "window.legacy = true;")
        XCTAssertEqual(Array(library.userScriptIDs), [script.id])
        XCTAssertEqual(realm.objects(UserScript.self).count, 1)
        XCTAssertTrue(realm.objects(FeedCategory.self).isEmpty)
        XCTAssertTrue(realm.objects(Feed.self).isEmpty)
        let generations = Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) })
        XCTAssertNotNil(generations["UserScript.\(script.id)"])
        try await LibraryDataManager.shared.importOPML(fileURL: fileURL, realmConfiguration: configuration)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) }), generations)
    }

    @RealmBackgroundActor
    func testUserScriptAdmissionRequiresCompleteLiveRestrictions() async throws {
        let realm = try await Realm(configuration: makeOPMLConfiguration(), actor: RealmBackgroundActor.shared)
        let script = UserScript()
        script.opmlURL = URL(string: "https://example.com/scripts.opml")
        script.script = "window.scoped = true;"
        let domain = UserScriptAllowedDomain()
        domain.domain = "example.com"
        try realm.write { realm.add([script, domain]) }

        await assertScriptAdmission(script, domains: [])
        try realm.write { script.allowedDomainIDs.append(domain.id) }
        await assertScriptAdmission(script, domains: ["example.com"])
        // Duplicate links do not make an otherwise complete graph incomplete.
        try realm.write { script.allowedDomainIDs.append(domain.id) }
        await assertScriptAdmission(script, domains: ["example.com"])
        let missingID = UUID()
        try realm.write { script.allowedDomainIDs.append(missingID) }
        await assertScriptAdmission(script, domains: nil)
        try realm.write {
            script.allowedDomainIDs.removeAll()
            script.allowedDomainIDs.append(missingID)
        }
        await assertScriptAdmission(script, domains: nil)
        try realm.write {
            script.allowedDomainIDs.removeAll()
            script.allowedDomainIDs.append(domain.id)
            domain.isDeleted = true
        }
        await assertScriptAdmission(script, domains: nil)
        let liveDomain = UserScriptAllowedDomain()
        liveDomain.domain = "other.example"
        try realm.write {
            realm.add(liveDomain)
            script.allowedDomainIDs.append(liveDomain.id)
        }
        await assertScriptAdmission(script, domains: nil)
        try realm.write {
            domain.isDeleted = false
            script.isDeleted = true
        }
        await assertScriptAdmission(script, domains: nil)
        try realm.write { script.allowedDomainIDs.removeAll() }
        await assertScriptAdmission(script, domains: nil)
    }

    @RealmBackgroundActor
    func testOPMLMalformedScriptDomainsLeaveStoredGraphAndJournalUnchanged() async throws {
        let configuration = makeOPMLConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let manager = LibraryDataManager(observesChanges: false)
        let library = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
        let realm = try XCTUnwrap(library.realm)
        let script = UserScript()
        script.title = "Original"
        script.script = "original"
        script.previewURL = URL(string: "about:blank")
        let domain = UserScriptAllowedDomain()
        domain.domain = "example.com"
        script.allowedDomainIDs.append(domain.id)
        try realm.write {
            realm.add([script, domain])
            library.userScriptIDs.append(script.id)
            script.refreshChangeMetadata(explicitlyModified: true)
            domain.refreshChangeMetadata(explicitlyModified: true)
            library.refreshChangeMetadata(explicitlyModified: true)
        }
        let generations = Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) })
        let scriptModifiedAt = script.modifiedAt
        let domainModifiedAt = domain.modifiedAt
        let libraryModifiedAt = library.modifiedAt

        for encoded in ["%", "%GG", "%FF", "example.com,%GG", "other.example,%"] {
            // Exercise existing (including an otherwise unchanged entry) and new imports.
            for id in [script.id, UUID()] {
                for title in ["Original", "Changed"] {
                    let fileURL = try writeScriptOPML(id: id, title: title, domains: encoded)
                    defer { try? FileManager.default.removeItem(at: fileURL) }
                    do {
                        try await manager.importOPML(
                            fileURL: fileURL, realmConfiguration: configuration
                        )
                        XCTFail("Malformed domains must reject the import: \(encoded)")
                    } catch {
                        XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
                        XCTAssertEqual((error as NSError).code, CocoaError.fileReadCorruptFile.rawValue)
                    }
                    XCTAssertEqual(script.title, "Original")
                    XCTAssertEqual(script.script, "original")
                    XCTAssertEqual(Array(script.allowedDomainIDs), [domain.id])
                    XCTAssertFalse(script.isDeleted)
                    XCTAssertFalse(domain.isDeleted)
                    XCTAssertEqual(domain.domain, "example.com")
                    XCTAssertEqual(script.modifiedAt, scriptModifiedAt)
                    XCTAssertEqual(domain.modifiedAt, domainModifiedAt)
                    XCTAssertEqual(library.modifiedAt, libraryModifiedAt)
                    XCTAssertEqual(Array(library.userScriptIDs), [script.id])
                    XCTAssertEqual(realm.objects(UserScript.self).count, 1)
                    XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
                    XCTAssertEqual(Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
                        .map { ($0.recordName, $0.generation) }), generations)
                }
            }
        }
    }

    @RealmBackgroundActor
    func testOPMLValidScriptDomainsAndGlobalRestrictionsRemainSupported() async throws {
        let configuration = makeOPMLConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let manager = LibraryDataManager(observesChanges: false)
        let library = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
        let realm = try XCTUnwrap(library.realm)
        let id = UUID()
        let policies: [(String?, Set<String>)] = [
            ("example%2Ecom,other.example", ["example.com", "other.example"]),
            ("", []), (nil, []),
        ]
        for (encoded, expected) in policies {
            let fileURL = try writeScriptOPML(id: id, title: "Original", domains: encoded)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            try await manager.importOPML(fileURL: fileURL, realmConfiguration: configuration)
            let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: id))
            await assertScriptAdmission(script, domains: expected)
            let generations = Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
                .map { ($0.recordName, $0.generation) })
            try await manager.importOPML(fileURL: fileURL, realmConfiguration: configuration)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
                .map { ($0.recordName, $0.generation) }), generations)
        }
    }

    @RealmBackgroundActor
    func testOPMLValidImportRepairsIncompleteScriptRestrictionGraph() async throws {
        let configuration = makeOPMLConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let manager = LibraryDataManager(observesChanges: false)
        let library = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
        let realm = try XCTUnwrap(library.realm)
        let script = UserScript()
        let domain = UserScriptAllowedDomain()
        domain.domain = "example.com"
        domain.isDeleted = true
        script.allowedDomainIDs.append(objectsIn: [domain.id, UUID()])
        try realm.write {
            realm.add([script, domain])
            library.userScriptIDs.append(script.id)
        }
        await assertScriptAdmission(script, domains: nil)
        let fileURL = try writeScriptOPML(id: script.id, title: "Original", domains: "example.com")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: configuration)
        XCTAssertFalse(domain.isDeleted)
        XCTAssertEqual(Array(script.allowedDomainIDs), [domain.id])
        await assertScriptAdmission(script, domains: ["example.com"])
        XCTAssertNotNil(realm.object(ofType: BigSyncPendingMutation.self,
                                    forPrimaryKey: "UserScript.\(script.id)"))
        XCTAssertNotNil(realm.object(ofType: BigSyncPendingMutation.self,
                                    forPrimaryKey: "UserScriptAllowedDomain.\(domain.id)"))
        // With all attributes and surviving domain values unchanged, a missing
        // relationship still requires repair rather than taking the no-op path.
        try realm.write { script.allowedDomainIDs.append(UUID()) }
        await assertScriptAdmission(script, domains: nil)
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: configuration)
        XCTAssertEqual(Array(script.allowedDomainIDs), [domain.id])
        await assertScriptAdmission(script, domains: ["example.com"])
    }

    @RealmBackgroundActor
    private func assertScriptAdmission(
        _ script: UserScript, domains: Set<String>?, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let frozen = script.freeze()
        let actual = await MainActor.run { frozen.getWebViewUserScript()?.allowedDomains }
        XCTAssertEqual(actual, domains, file: file, line: line)
    }

    private func writeScriptOPML(id: UUID, title: String, domains: String?) throws -> URL {
        let domainAttribute = domains.map { " allowedDomains=\"\($0)\"" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head/><body>
          <outline text="\(title)" uuid="\(id.uuidString)" script="original" injectAtStart="true" mainFrameOnly="true" previewURL="about:blank"\(domainAttribute)/>
        </body></opml>
        """
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-domains-\(UUID().uuidString).opml")
        try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }


    @RealmBackgroundActor
    func testOPMLImportPreservesUTF16LittleEndianBytes() async throws {
        try await verifyEncodedOPMLImport(encoding: .utf16LittleEndian, declaration: "UTF-16",
                                         byteOrderMark: Data([0xff, 0xfe]))
    }

    @RealmBackgroundActor
    func testOPMLImportPreservesUTF16BigEndianBytes() async throws {
        try await verifyEncodedOPMLImport(encoding: .utf16BigEndian, declaration: "UTF-16",
                                         byteOrderMark: Data([0xfe, 0xff]))
    }

    @RealmBackgroundActor
    func testOPMLImportPreservesDeclaredLatin1Characters() async throws {
        try await verifyEncodedOPMLImport(encoding: .isoLatin1, declaration: "ISO-8859-1",
                                         title: "Café et français")
    }

    @RealmBackgroundActor
    func testOPMLImportPreservesUTF8Characters() async throws {
        try await verifyEncodedOPMLImport(encoding: .utf8, declaration: "UTF-8")
    }

    @RealmBackgroundActor
    private func verifyEncodedOPMLImport(
        encoding: String.Encoding,
        declaration: String,
        byteOrderMark: Data = Data(),
        title: String = "日本語と café"
    ) async throws {
        let configuration = makeOPMLConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        let categoryID = UUID()
        let feedID = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/café/feed.xml"))
        let xml = """
        <?xml version="1.0" encoding="\(declaration)"?>
        <opml version="2.0"><head/><body>
          <outline text="\(title)" uuid="\(categoryID.uuidString)">
            <outline text="\(title) feed" uuid="\(feedID.uuidString)" xmlUrl="https://example.com/café/feed.xml"/>
          </outline>
        </body></opml>
        """
        var bytes = byteOrderMark
        bytes.append(try XCTUnwrap(xml.data(using: encoding, allowLossyConversion: false)))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("encoded-opml-\(UUID().uuidString).opml")
        try bytes.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let manager = LibraryDataManager(observesChanges: false)
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: configuration)

        await realm.asyncRefresh()
        let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
        XCTAssertEqual(category.title, title)
        XCTAssertEqual(feed.title, title + " feed")
        XCTAssertEqual(feed.rssUrl, sourceURL)
        XCTAssertEqual(feed.categoryID, categoryID)
        XCTAssertEqual(Array(library.categoryIDs), [categoryID])
        XCTAssertEqual(realm.objects(FeedCategory.self).count, 1)
        XCTAssertEqual(realm.objects(Feed.self).count, 1)
        XCTAssertFalse(category.isDeleted)
        XCTAssertFalse(feed.isDeleted)
        for recordName in ["FeedCategory.\(categoryID)", "Feed.\(feedID)",
                           "LibraryConfiguration.\(library.id)"] {
            XCTAssertNotNil(realm.object(ofType: BigSyncPendingMutation.self,
                                        forPrimaryKey: recordName)?.generation)
        }
        // Reimporting the same encoded file retains identity and no-op journaling.
        let generations = Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) })
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: configuration)
        await realm.asyncRefresh()
        XCTAssertEqual(realm.objects(FeedCategory.self).count, 1)
        XCTAssertEqual(realm.objects(Feed.self).count, 1)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) }), generations)
    }


    @RealmBackgroundActor
    func testStandardOPMLImportsNestedFoldersAndKeepsSameURLInDifferentFolders() async throws {
        try await withStandardOPMLFixture { realm, configuration, directory, manager in
            let file = try self.writeStandardOPML("""
            <outline text="Courses">
              <outline text="First"><outline text="News" xmlUrl="https://example.com/news.xml"/></outline>
              <outline text="Second"><outline text="News" xmlUrl="https://example.com/news.xml"/></outline>
            </outline>
            """, in: directory)
            try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            await realm.asyncRefresh()
            let category = try XCTUnwrap(realm.objects(FeedCategory.self).first)
            let folders = Array(realm.objects(FeedDirectory.self))
            let feeds = Array(realm.objects(Feed.self))
            XCTAssertEqual(category.title, "Courses")
            XCTAssertEqual(Set(folders.map(\.title)), ["First", "Second"])
            XCTAssertEqual(feeds.count, 2)
            XCTAssertEqual(Set(feeds.compactMap(\.directoryID)), Set(folders.map(\.id)))
            XCTAssertTrue(feeds.allSatisfy { $0.categoryID == category.id })
            XCTAssertTrue(feeds.allSatisfy { $0.rssUrl == URL(string: "https://example.com/news.xml")! })
            let identities = Set(feeds.map(\.id))
            let generations = self.standardOPMLGenerations(in: realm)
            try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(FeedCategory.self).count, 1)
            XCTAssertEqual(realm.objects(FeedDirectory.self).count, 2)
            XCTAssertEqual(Set(realm.objects(Feed.self).map(\.id)), identities)
            XCTAssertEqual(self.standardOPMLGenerations(in: realm), generations)
        }
    }

    @RealmBackgroundActor
    func testStandardFlatOPMLUsesMyLibraryAndReimportsWithoutDuplicates() async throws {
        try await withStandardOPMLFixture { realm, configuration, directory, manager in
            let file = try self.writeStandardOPML("""
            <outline text="日本語 News" type="rss" xmlUrl="https://example.com/news.xml"/>
            <outline text="Podcast" type="rss" xmlUrl="https://example.com/podcast.xml"/>
            """, in: directory)
            try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            await realm.asyncRefresh()
            let category = try XCTUnwrap(realm.objects(FeedCategory.self).first)
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            XCTAssertEqual(category.title, "My Library")
            XCTAssertEqual(Array(library.categoryIDs), [category.id])
            XCTAssertEqual(realm.objects(Feed.self).count, 2)
            XCTAssertTrue(realm.objects(Feed.self).allSatisfy { $0.categoryID == category.id && $0.directoryID == nil })
            let generations = self.standardOPMLGenerations(in: realm)
            try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(FeedCategory.self).count, 1)
            XCTAssertEqual(realm.objects(Feed.self).count, 2)
            XCTAssertEqual(self.standardOPMLGenerations(in: realm), generations)
        }
    }

    @RealmBackgroundActor
    func testStandardOPMLPreservesCustomizedRowsAndExistingCategoryOrder() async throws {
        try await withStandardOPMLFixture { realm, configuration, directory, manager in
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            let category = FeedCategory()
            category.title = "Courses"
            category.isArchived = true
            let other = FeedCategory()
            other.title = "Other"
            let folder = FeedDirectory()
            folder.title = "First"
            folder.categoryID = category.id
            folder.ordinal = 91
            folder.isArchived = true
            let feed = Feed()
            feed.categoryID = category.id
            feed.directoryID = folder.id
            feed.rssUrl = URL(string: "https://example.com/news.xml")!
            feed.title = "My edited title"
            feed.ordinal = 73
            feed.isArchived = true
            feed.rssContainsFullContent = true
            feed.isReaderModeByDefault = false
            feed.extractImageFromContent = false
            feed.meaningfulContentMinLength = 321
            try realm.write {
                realm.add([category, other, folder, feed])
                library.categoryIDs.append(objectsIn: [category.id, other.id])
                category.refreshChangeMetadata(explicitlyModified: true)
                other.refreshChangeMetadata(explicitlyModified: true)
                folder.refreshChangeMetadata(explicitlyModified: true)
                feed.refreshChangeMetadata(explicitlyModified: true)
                library.refreshChangeMetadata(explicitlyModified: true)
            }
            let generations = self.standardOPMLGenerations(in: realm)
            let file = try self.writeStandardOPML("""
            <outline text="Other"/>
            <outline text="Courses"><outline text="First">
              <outline text="Publisher title" xmlUrl="https://example.com/news.xml"/>
            </outline></outline>
            """, in: directory)
            try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            await realm.asyncRefresh()
            XCTAssertEqual(Array(library.categoryIDs), [category.id, other.id])
            XCTAssertEqual(feed.title, "My edited title")
            XCTAssertEqual(feed.ordinal, 73)
            XCTAssertTrue(feed.isArchived)
            XCTAssertTrue(feed.rssContainsFullContent)
            XCTAssertFalse(feed.isReaderModeByDefault)
            XCTAssertFalse(feed.extractImageFromContent)
            XCTAssertEqual(feed.meaningfulContentMinLength, 321)
            XCTAssertTrue(category.isArchived)
            XCTAssertTrue(folder.isArchived)
            XCTAssertEqual(folder.ordinal, 91)
            XCTAssertEqual(feed.directoryID, folder.id)
            XCTAssertEqual(realm.objects(FeedCategory.self).count, 2)
            XCTAssertEqual(realm.objects(FeedDirectory.self).count, 1)
            XCTAssertEqual(realm.objects(Feed.self).count, 1)
            XCTAssertEqual(self.standardOPMLGenerations(in: realm), generations)
        }
    }


    @RealmBackgroundActor
    func testStandardOPMLAppliesCategoryAttributesOnlyAtFirstCreation() async throws {
        try await withStandardOPMLFixture { realm, configuration, directory, manager in
            let file = try self.writeStandardOPML("""
            <outline text="Courses" isCommented="true" backgroundImageUrl="https://example.com/original.jpg"/>
            """, head: "<ownerName>Original publisher</ownerName>", in: directory)
            try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            await realm.asyncRefresh()
            let category = try XCTUnwrap(realm.objects(FeedCategory.self).first)
            XCTAssertEqual(category.title, "Courses")
            XCTAssertEqual(category.opmlOwnerName, "Original publisher")
            XCTAssertEqual(category.backgroundImageUrl, URL(string: "https://example.com/original.jpg")!)
            XCTAssertTrue(category.isArchived)
            XCTAssertNil(category.opmlURL)
            let generations = self.standardOPMLGenerations(in: realm)
            let changed = try self.writeStandardOPML("""
            <outline text="Courses" isCommented="false" backgroundImageUrl="https://example.com/changed.jpg"/>
            """, head: "<ownerName>Changed publisher</ownerName>", in: directory)
            try await manager.importOPML(fileURL: changed, realmConfiguration: configuration)
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(FeedCategory.self).count, 1)
            XCTAssertEqual(category.opmlOwnerName, "Original publisher")
            XCTAssertEqual(category.backgroundImageUrl, URL(string: "https://example.com/original.jpg")!)
            XCTAssertTrue(category.isArchived)
            XCTAssertEqual(self.standardOPMLGenerations(in: realm), generations)
        }
    }

    @RealmBackgroundActor
    func testStandardOPMLRejectsAmbiguousLocalCategoryWithoutChoosingARow() async throws {
        try await withStandardOPMLFixture { realm, configuration, directory, manager in
            let first = FeedCategory()
            first.title = "Courses"
            let second = FeedCategory()
            second.title = "Courses"
            try realm.write { realm.add([first, second]) }
            let generations = self.standardOPMLGenerations(in: realm)
            let file = try self.writeStandardOPML("""
            <outline text="Courses"><outline text="News" xmlUrl="https://example.com/news.xml"/></outline>
            """, in: directory)
            do {
                try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
                XCTFail("Ambiguous local identities must not choose a category")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual((error as NSError).code, CocoaError.fileReadCorruptFile.rawValue)
            }
            XCTAssertEqual(realm.objects(FeedCategory.self).count, 2)
            XCTAssertTrue(realm.objects(Feed.self).isEmpty)
            XCTAssertEqual(self.standardOPMLGenerations(in: realm), generations)
        }
    }

    @RealmBackgroundActor
    func testConcurrentStandardOPMLImportsShareTheOwnedIdentityLookup() async throws {
        try await withStandardOPMLFixture { realm, configuration, directory, manager in
            let file = try self.writeStandardOPML("""
            <outline text="Courses"><outline text="News" xmlUrl="https://example.com/news.xml"/></outline>
            """, in: directory)
            let first = Task { @RealmBackgroundActor in
                try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            }
            let second = Task { @RealmBackgroundActor in
                try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            }
            let firstResult = await first.result
            let secondResult = await second.result
            try firstResult.get()
            try secondResult.get()
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(FeedCategory.self).count, 1)
            XCTAssertEqual(realm.objects(Feed.self).count, 1)
        }
    }

    @RealmBackgroundActor
    func testStandardOPMLDoesNotAdoptManagedCategoriesOrMalformedUUIDs() async throws {
        try await withStandardOPMLFixture { realm, configuration, directory, manager in
            let managed = FeedCategory()
            managed.title = "Courses"
            managed.opmlURL = URL(string: "https://example.com/managed.opml")!
            try realm.write { realm.add(managed) }
            let file = try self.writeStandardOPML("""
            <outline text="Courses"><outline text="News" xmlUrl="https://example.com/news.xml"/></outline>
            <outline text="Ignored" uuid="not-a-uuid"><outline text="Ignored child" xmlUrl="https://example.com/ignored.xml"/></outline>
            """, in: directory)
            try await manager.importOPML(fileURL: file, realmConfiguration: configuration)
            await realm.asyncRefresh()
            let local = try XCTUnwrap(realm.objects(FeedCategory.self).first { $0.opmlURL == nil })
            XCTAssertNotEqual(local.id, managed.id)
            XCTAssertEqual(local.title, "Courses")
            XCTAssertEqual(realm.objects(FeedCategory.self).count, 2)
            XCTAssertEqual(realm.objects(Feed.self).count, 1)
            XCTAssertEqual(realm.objects(Feed.self).first?.categoryID, local.id)
            XCTAssertFalse(managed.isDeleted)
        }
    }

    @RealmBackgroundActor
    func testStandardOPMLKeepsSuppliedUUIDAndManagedDownloadContracts() async throws {
        try await withStandardOPMLFixture { realm, configuration, directory, manager in
            let categoryID = UUID()
            let feedID = UUID()
            let file = try self.writeStandardOPML("""
            <outline text="Managed" uuid="\(categoryID)">
              <outline text="Managed news" uuid="\(feedID)" xmlUrl="https://example.com/news.xml"/>
            </outline>
            """, in: directory)
            let download = await MainActor.run {
                Downloadable(url: URL(string: "https://example.com/managed.opml")!,
                             name: "Managed", localDestination: file)
            }
            try await manager.importOPML(fileURL: file, fromDownload: download, realmConfiguration: configuration)
            await realm.asyncRefresh()
            let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
            XCTAssertEqual(category.opmlURL, download.url)
            XCTAssertEqual(feed.categoryID, categoryID)
            let generations = self.standardOPMLGenerations(in: realm)
            try await manager.importOPML(fileURL: file, fromDownload: download, realmConfiguration: configuration)
            await realm.asyncRefresh()
            XCTAssertEqual(self.standardOPMLGenerations(in: realm), generations)

            let ordinary = try self.writeStandardOPML("""
            <outline text="Ignored"><outline text="Ignored" xmlUrl="https://example.com/ordinary.xml"/></outline>
            """, in: directory)
            try await manager.importOPML(fileURL: ordinary, fromDownload: download, realmConfiguration: configuration)
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(FeedCategory.self).count, 1)
            XCTAssertEqual(realm.objects(Feed.self).count, 1)
            XCTAssertTrue(category.isDeleted, "Managed orphan reconciliation retains its existing contract")
            XCTAssertTrue(feed.isDeleted)
        }
    }

    @RealmBackgroundActor
    private func withStandardOPMLFixture(
        _ body: @RealmBackgroundActor (Realm, Realm.Configuration, URL, LibraryDataManager) async throws -> Void
    ) async throws {
        let configuration = makeOPMLConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        _ = try await LibraryConfiguration.getConsolidatedOrCreate(realmConfiguration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        try await body(realm, configuration, directory, LibraryDataManager(observesChanges: false))
    }

    private func writeStandardOPML(_ body: String, head: String = "", in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString + ".opml")
        try Data(("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head>\(head)</head><body>\(body)</body></opml>
        """).utf8).write(to: file)
        return file
    }

    @RealmBackgroundActor
    private func standardOPMLGenerations(in realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self)
            .map { ($0.recordName, $0.generation) })
    }

    private func makeOPMLConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self, Feed.self,
            UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            FeedCategory.self,
            Feed.self,
            LibraryConfiguration.self,
            BigSyncPendingMutation.self,
        ]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        return configuration
    }

    private func makeScriptConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    @RealmBackgroundActor
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeFeed(title: String) -> Feed {
        let feed = Feed()
        feed.title = title
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        return feed
    }
}

private actor OPMLImportFileBoundary {
    private(set) var completedFileURLs = [URL]()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func pause(after fileURL: URL, reached expectation: XCTestExpectation) async {
        completedFileURLs.append(fileURL)
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            expectation.fulfill()
        }
    }

    func resume() {
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}
