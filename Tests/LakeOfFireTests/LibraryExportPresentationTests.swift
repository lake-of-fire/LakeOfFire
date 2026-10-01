#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import BigSyncKit
import OPML
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@available(iOS 16.0, macOS 15.0, *)
@MainActor
final class LibraryExportPresentationTests: XCTestCase {
#if os(macOS)
    func testFailedFileWriteExposesRetryAndOnlySharesPreparedOPML() async throws {
        let previous = LibraryDataManager.realmConfiguration
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self,
            Feed.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = previous }
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "Retry export entry")])
        }
        var writeAttempts = 0
        manager.writeOPMLFile = { data, url in
            writeAttempts += 1
            if writeAttempts == 1 {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: [.atomic])
        }

        let exportWindow = window(for: manager)
        defer { exportWindow.contentView = nil; exportWindow.close() }
        let failed = await waitUntil { manager.opmlExportFailed }
        XCTAssertTrue(failed)
        XCTAssertNil(manager.exportedOPML)
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertNil(manager.exportedOPMLShareItem)
        XCTAssertEqual(writeAttempts, 1)

        // A second registration and ordinary preparation request must not retry a failed write.
        let secondWindow = window(for: manager)
        defer { secondWindow.contentView = nil; secondWindow.close() }
        let bothViewsRegistered = await waitUntil { manager.opmlExportUIRegistrationCount == 2 }
        XCTAssertTrue(bothViewsRegistered)
        manager.ensureOPMLExportPrepared()
        await Task.yield()
        XCTAssertEqual(writeAttempts, 1)

        let retryVisible = await waitUntil {
            accessibilityElement(in: exportWindow.contentView, identifier: "library-opml-retry") != nil
        }
        if !retryVisible, exportWindow.contentView?.accessibilityChildren()?.isEmpty != false {
            throw XCTSkip(
                "The hidden AppKit XCTest host exposes no SwiftUI accessibility descendants; " +
                "the real Retry press and ShareLink assertions require Mac UI acceptance."
            )
        }
        XCTAssertTrue(retryVisible)
        XCTAssertNil(accessibilityElement(in: exportWindow.contentView, identifier: "library-opml-share"))
        let retry = try XCTUnwrap(accessibilityElement(in: exportWindow.contentView, identifier: "library-opml-retry"))
        XCTAssertTrue(retry.accessibilityPerformPress())

        let preparedResult = await waitForExport(manager, containing: "Retry export entry")
        let preparedURL = try XCTUnwrap(preparedResult)
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertFalse(manager.opmlExportFailed)
        XCTAssertEqual(preparedURL.pathExtension, "opml")
        XCTAssertTrue(preparedURL.isFileURL)
        XCTAssertNotEqual(preparedURL.absoluteString, "about:blank")
        XCTAssertTrue(try String(contentsOf: preparedURL, encoding: .utf8).contains("Retry export entry"))
        let shareVisible = await waitUntil {
            accessibilityElement(in: exportWindow.contentView, identifier: "library-opml-share") != nil
        }
        XCTAssertTrue(shareVisible)
        XCTAssertNil(accessibilityElement(in: exportWindow.contentView, identifier: "library-opml-retry"))
    }

#endif

    func testFailedFileWriteKeepsExportUnpreparedUntilExplicitRetry() async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = { OPML(entries: [OPMLEntry(text: "Explicit retry export")]) }
        var writeAttempts = 0
        manager.writeOPMLFile = { data, url in
            writeAttempts += 1
            if writeAttempts == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: [.atomic])
        }
        let firstRegistration = UUID()
        let secondRegistration = UUID()
        manager.registerOPMLExportUI(firstRegistration)
        defer {
            manager.unregisterOPMLExportUI(firstRegistration)
            manager.unregisterOPMLExportUI(secondRegistration)
        }
        let failed = await waitUntil { manager.opmlExportFailed }
        XCTAssertTrue(failed)
        XCTAssertNil(manager.exportedOPML)
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertEqual(writeAttempts, 1)

        manager.registerOPMLExportUI(secondRegistration)
        manager.ensureOPMLExportPrepared()
        await Task.yield()
        XCTAssertEqual(writeAttempts, 1)
        XCTAssertTrue(manager.opmlExportFailed)

        manager.refreshOPMLExport()
        let preparedResult = await waitForExport(manager, containing: "Explicit retry export")
        let preparedURL = try XCTUnwrap(preparedResult)
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertFalse(manager.opmlExportFailed)
        XCTAssertNotNil(manager.exportedOPML)
        XCTAssertTrue(preparedURL.isFileURL)
        XCTAssertEqual(preparedURL.pathExtension, "opml")
        XCTAssertEqual(manager.exportedOPMLShareItem?.data, try Data(contentsOf: preparedURL))
        XCTAssertTrue(try String(contentsOf: preparedURL, encoding: .utf8).contains("Explicit retry export"))
    }

    func testFailedWriteCleanupRemainsOwnedUntilLaterRemovalSucceeds()
    async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "failed write cleanup owner")])
        }

        var writeAttempts = 0
        var failedURL: URL?
        manager.writeOPMLFile = { data, url in
            writeAttempts += 1
            if writeAttempts == 1 {
                // Reproduce a writer that created bytes before reporting a
                // terminal failure. The export must never publish this path.
                try Data("partial-opml".utf8).write(to: url, options: [.atomic])
                failedURL = url
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: [.atomic])
        }

        var removalAttempts = 0
        manager.removeOPMLFile = { url in
            removalAttempts += 1
            XCTAssertEqual(url, failedURL)
            throw CocoaError(.fileWriteNoPermission)
        }

        let registration = UUID()
        manager.registerOPMLExportUI(registration)

        let failed = await waitUntil { manager.opmlExportFailed }
        XCTAssertTrue(failed)
        let orphan = try XCTUnwrap(failedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(removalAttempts, 1)
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertNil(manager.exportedOPMLShareItem)

        manager.removeOPMLFile = { url in
            removalAttempts += 1
            try FileManager.default.removeItem(at: url)
        }
        manager.refreshOPMLExport()

        let preparedResult = await waitForExport(
            manager,
            containing: "failed write cleanup owner"
        )
        let prepared = try XCTUnwrap(preparedResult)
        XCTAssertEqual(removalAttempts, 2)
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertNotEqual(prepared, orphan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path))
        XCTAssertFalse(manager.opmlExportFailed)
        XCTAssertEqual(
            manager.exportedOPMLShareItem?.data,
            try Data(contentsOf: prepared)
        )

        manager.unregisterOPMLExportUI(registration)
        manager.invalidateOPMLExport()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
    }

    func testVisibleExportRepreparesAfterScriptAndIndependentDomainEdits() async throws {
        let previous = LibraryDataManager.realmConfiguration
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self,
            Feed.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = previous }
        let identifiers = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            let library = LibraryConfiguration()
            let script = UserScript()
            script.title = "Original script export"
            script.script = "console.log('original');"
            let domain = UserScriptAllowedDomain()
            domain.domain = "original.example.org"
            script.allowedDomainIDs.append(domain.id)
            library.userScriptIDs.append(script.id)
            try await realm.asyncWrite {
                realm.add([library, script, domain])
                library.refreshChangeMetadata(explicitlyModified: true)
                script.refreshChangeMetadata(explicitlyModified: true)
                domain.refreshChangeMetadata(explicitlyModified: true)
            }
            let scriptJournal = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: "UserScript.\(script.id)"
            ))
            let domainJournal = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: "UserScriptAllowedDomain.\(domain.id)"
            ))
            return (script.id, domain.id, scriptJournal.generation, domainJournal.generation)
        }.value
        let manager = LibraryManagerViewModel()
        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer { manager.unregisterOPMLExportUI(registration) }
        let initialResult = await waitForExport(manager, containing: "Original script export")
        let initialURL = try XCTUnwrap(initialResult)
        let initialBytes = try Data(contentsOf: initialURL)

        // Each edit writes its own exported record, without touching the library configuration.
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: identifiers.0))
            try await realm.asyncWrite {
                script.title = "Changed script export"
                script.script = "console.log('changed');"
                script.mainFrameOnly = false
                script.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        let scriptResult = await waitForExport(manager, after: initialURL, containing: "Changed script export")
        let scriptURL = try XCTUnwrap(scriptResult)
        let scriptBytes = try Data(contentsOf: scriptURL)
        XCTAssertEqual(try Data(contentsOf: initialURL), initialBytes)

        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            let domain = try XCTUnwrap(realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: identifiers.1))
            try await realm.asyncWrite {
                domain.domain = "changed.example.org"
                domain.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        let domainResult = await waitForExport(manager, after: scriptURL, containing: "changed.example.org")
        let domainURL = try XCTUnwrap(domainResult)
        let domainXML = try String(contentsOf: domainURL, encoding: .utf8)
        XCTAssertTrue(domainXML.contains("Changed script export"))
        XCTAssertFalse(domainXML.contains("original.example.org"))
        XCTAssertEqual(try Data(contentsOf: initialURL), initialBytes)
        XCTAssertEqual(try Data(contentsOf: scriptURL), scriptBytes)
        let journaledEdits = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            let scriptJournal = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: "UserScript.\(identifiers.0)"
            ))
            let domainJournal = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: "UserScriptAllowedDomain.\(identifiers.1)"
            ))
            return (scriptJournal.generation, domainJournal.generation)
        }.value
        XCTAssertNotEqual(journaledEdits.0, identifiers.2)
        XCTAssertNotEqual(journaledEdits.1, identifiers.3)
    }

    func testLibraryAddAndDuplicateKeepCapturedRealmAfterGlobalReplacement() async throws {
        let previousLibraryConfiguration = LibraryDataManager.realmConfiguration
        let previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let capturedConfiguration = makeLibraryRealmConfiguration()
        let replacementConfiguration = makeLibraryRealmConfiguration()
        LibraryDataManager.realmConfiguration = capturedConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = capturedConfiguration
        let manager = LibraryManagerViewModel(observesRealm: false)
        LibraryDataManager.realmConfiguration = replacementConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacementConfiguration
        defer {
            LibraryDataManager.realmConfiguration = previousLibraryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
        }

        let rssURL = URL(string: "https://example.org/captured-feed.xml")!
        try await manager.add(rssURL: rssURL, title: "Captured feed")
        let feed = try XCTUnwrap(manager.selectedFeed)
        XCTAssertEqual(feed.rssUrl, rssURL)
        XCTAssertEqual(feed.title, "Captured feed")
        let categoryID = try XCTUnwrap(feed.categoryID)
        let mainRealm = try await Realm.open(configuration: capturedConfiguration)
        let category = try XCTUnwrap(mainRealm.object(
            ofType: FeedCategory.self, forPrimaryKey: categoryID
        ))
        let originalFeedID = feed.id
        try await manager.duplicate(
            feed: ThreadSafeReference(to: feed),
            inCategory: ThreadSafeReference(to: category),
            overwriteExisting: false
        )
        let duplicate = try XCTUnwrap(manager.selectedFeed)
        XCTAssertNotEqual(duplicate.id, originalFeedID)
        XCTAssertEqual(duplicate.categoryID, categoryID)
        XCTAssertEqual(duplicate.rssUrl, rssURL)

        let duplicateFeedID = duplicate.id

        // Script creation uses the same explicit configuration contract as the
        // category/feed helpers, including its post-write consolidation hop.
        let scriptID = try await LibraryDataManager.shared.createEmptyScript(
            addToLibrary: true, realmConfiguration: capturedConfiguration
        )
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: capturedConfiguration
            )
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            XCTAssertTrue(library.categoryIDs.contains(categoryID))
            XCTAssertTrue(library.userScriptIDs.contains(scriptID))
            XCTAssertEqual(realm.objects(Feed.self).count, 2)
            for key in [
                "FeedCategory.\(categoryID)", "Feed.\(originalFeedID)",
                "Feed.\(duplicateFeedID)", "UserScript.\(scriptID)",
                "LibraryConfiguration.\(library.id)",
            ] {
                XCTAssertNotNil(realm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: key
                ))
            }
            let replacement = try await RealmBackgroundActor.shared.cachedRealm(
                for: replacementConfiguration
            )
            XCTAssertTrue(replacement.objects(LibraryConfiguration.self).isEmpty)
            XCTAssertTrue(replacement.objects(FeedCategory.self).isEmpty)
            XCTAssertTrue(replacement.objects(Feed.self).isEmpty)
            XCTAssertTrue(replacement.objects(UserScript.self).isEmpty)
            XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
        }()
    }

    func testObservedRealmPublisherKeepsReconciliationAndExportInCapturedConfiguration()
    async throws {
        let previousConfiguration = LibraryDataManager.realmConfiguration
        let observedConfiguration = makeLibraryRealmConfiguration()
        let replacementConfiguration = makeLibraryRealmConfiguration()
        LibraryDataManager.realmConfiguration = observedConfiguration
        defer { LibraryDataManager.realmConfiguration = previousConfiguration }

        let observedIDs = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: observedConfiguration
            )
            let primary = LibraryConfiguration()
            primary.createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
            try await realm.asyncWrite {
                realm.add(primary)
            }
            return primary.id
        }.value

        // The default export closure uses the shared data manager. Initializing
        // it while A is active keeps its own retained subscription out of B.
        _ = LibraryDataManager.shared
        let manager = LibraryManagerViewModel()
        let initiallyReconciled = await waitUntil {
            manager.libraryConfiguration?.id == observedIDs
        }
        XCTAssertTrue(initiallyReconciled)

        let replacementIDs = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: replacementConfiguration
            )
            let configuration = LibraryConfiguration()
            let orphanScript = UserScript()
            orphanScript.title = "Replacement orphan script"
            try await realm.asyncWrite {
                realm.add([configuration, orphanScript])
            }
            return (configuration.id, orphanScript.id)
        }.value

        LibraryDataManager.realmConfiguration = replacementConfiguration
        let observedDuplicateIDs = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: observedConfiguration
            )
            let duplicate = LibraryConfiguration()
            duplicate.createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
            let script = UserScript()
            script.title = "Observed second script"
            duplicate.userScriptIDs.append(script.id)
            try await realm.asyncWrite {
                realm.add([duplicate, script])
            }
            return (duplicate.id, script.id)
        }.value

        let observedUpdatePublished = await waitUntil {
            manager.libraryConfiguration?.id == observedIDs &&
                manager.libraryConfiguration?.userScriptIDs.contains(observedDuplicateIDs.1) == true
        }
        XCTAssertTrue(observedUpdatePublished)

        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer { manager.unregisterOPMLExportUI(registration) }
        let exportedResult = await waitForExport(
            manager,
            containing: "Observed second script"
        )
        let exportedURL = try XCTUnwrap(exportedResult)
        let exportedXML = try String(contentsOf: exportedURL, encoding: .utf8)
        XCTAssertTrue(exportedXML.contains("Observed second script"))
        XCTAssertFalse(exportedXML.contains("Replacement orphan script"))

        let result = try await Task { @RealmBackgroundActor in
            let observedRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: observedConfiguration
            )
            let replacementRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: replacementConfiguration
            )
            let observedPrimary = try XCTUnwrap(observedRealm.object(
                ofType: LibraryConfiguration.self, forPrimaryKey: observedIDs
            ))
            let observedDuplicate = try XCTUnwrap(observedRealm.object(
                ofType: LibraryConfiguration.self, forPrimaryKey: observedDuplicateIDs.0
            ))
            let observedJournal = try XCTUnwrap(observedRealm.object(
                ofType: BigSyncPendingMutation.self,
                forPrimaryKey: "LibraryConfiguration.\(observedIDs)"
            ))
            let replacementLibrary = try XCTUnwrap(replacementRealm.object(
                ofType: LibraryConfiguration.self, forPrimaryKey: replacementIDs.0
            ))
            return (
                Array(observedPrimary.userScriptIDs),
                observedDuplicate.isDeleted,
                observedJournal.recordName,
                observedRealm.object(
                    ofType: BigSyncPendingMutation.self,
                    forPrimaryKey: "LibraryConfiguration.\(observedDuplicateIDs.0)"
                ) != nil,
                Array(replacementLibrary.userScriptIDs),
                replacementRealm.object(
                    ofType: BigSyncPendingMutation.self,
                    forPrimaryKey: "LibraryConfiguration.\(replacementIDs.0)"
                ) != nil,
                replacementRealm.object(
                    ofType: BigSyncPendingMutation.self,
                    forPrimaryKey: "UserScript.\(replacementIDs.1)"
                ) != nil
            )
        }.value

        XCTAssertEqual(result.0, [observedDuplicateIDs.1])
        XCTAssertTrue(result.1)
        XCTAssertEqual(result.2, "LibraryConfiguration.\(observedIDs)")
        XCTAssertTrue(result.3)
        XCTAssertEqual(result.4, [])
        XCTAssertFalse(result.5)
        XCTAssertFalse(result.6)
    }

    func testVisibleInvalidationRepreparesAfterFailedFileWrite() async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "Updated after failure")])
        }
        var writeAttempts = 0
        manager.writeOPMLFile = { data, url in
            writeAttempts += 1
            if writeAttempts == 1 {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: [.atomic])
        }

        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer { manager.unregisterOPMLExportUI(registration) }
        let failed = await waitUntil { manager.opmlExportFailed }
        XCTAssertTrue(failed)
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertEqual(writeAttempts, 1)

        // This is the same invalidation entry point used by library changes.
        manager.invalidateOPMLExport()
        let preparedResult = await waitForExport(manager, containing: "Updated after failure")
        let preparedURL = try XCTUnwrap(preparedResult)
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertFalse(manager.opmlExportFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedURL.path))
    }

    func testInvalidationClearsFailureWithoutRestartAfterLastViewDisappears() async {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = { OPML(entries: []) }
        var writeAttempts = 0
        manager.writeOPMLFile = { _, _ in
            writeAttempts += 1
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        let failed = await waitUntil { manager.opmlExportFailed }
        XCTAssertTrue(failed)
        XCTAssertEqual(writeAttempts, 1)

        manager.unregisterOPMLExportUI(registration)
        XCTAssertEqual(manager.opmlExportUIRegistrationCount, 0)
        manager.invalidateOPMLExport()
        XCTAssertFalse(manager.opmlExportFailed)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(writeAttempts, 1)
        XCTAssertNil(manager.exportedOPMLFileURL)
    }

    func testRetiredExportFilesStayReadableUntilLastExportViewUnregisters()
    async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "retained immutable export")])
        }
        let registration = UUID()
        manager.registerOPMLExportUI(registration)

        let firstResult = await waitForExport(manager, containing: "retained immutable export")
        let firstURL = try XCTUnwrap(firstResult)
        manager.invalidateOPMLExport()
        let secondResult = await waitForExport(
            manager,
            after: firstURL,
            containing: "retained immutable export"
        )
        let secondURL = try XCTUnwrap(secondResult)
        manager.invalidateOPMLExport()
        let thirdResult = await waitForExport(
            manager,
            after: secondURL,
            containing: "retained immutable export"
        )
        let thirdURL = try XCTUnwrap(thirdResult)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertNotEqual(secondURL, thirdURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thirdURL.path))

        manager.unregisterOPMLExportUI(registration)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstURL.path),
            "A retired generation should be deleted after the final UI owner leaves"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: secondURL.path),
            "All retired generations should drain together"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: thirdURL.path),
            "The current prepared export remains reusable after UI dismissal"
        )
        XCTAssertEqual(manager.exportedOPMLFileURL, thirdURL)

        manager.invalidateOPMLExport()
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: thirdURL.path),
            "Without a registered export UI, invalidating the current generation can delete it"
        )
    }

    func testShareSnapshotRemainsReadableAfterItsPreparedFileIsRemoved()
    async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "original share snapshot")])
        }
        let registration = UUID()
        manager.registerOPMLExportUI(registration)

        let firstResult = await waitForExport(manager, containing: "original share snapshot")
        let firstURL = try XCTUnwrap(firstResult)
        let firstShareItem = try XCTUnwrap(manager.exportedOPMLShareItem)
        XCTAssertEqual(firstShareItem.data, try Data(contentsOf: firstURL))

        manager.invalidateOPMLExport()
        let secondResult = await waitForExport(manager, after: firstURL)
        _ = try XCTUnwrap(secondResult)
        manager.unregisterOPMLExportUI(registration)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(
            try XCTUnwrap(String(data: firstShareItem.data, encoding: .utf8))
                .contains("original share snapshot"),
            "An already-created share item must own its bytes after file cleanup"
        )
    }

    func testFailedRetiredFileRemovalRemainsOwnedForLaterCleanupRetry()
    async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "retry retired cleanup")])
        }
        let firstRegistration = UUID()
        manager.registerOPMLExportUI(firstRegistration)

        let firstResult = await waitForExport(manager, containing: "retry retired cleanup")
        let firstURL = try XCTUnwrap(firstResult)
        manager.invalidateOPMLExport()
        let secondResult = await waitForExport(
            manager,
            after: firstURL,
            containing: "retry retired cleanup"
        )
        let secondURL = try XCTUnwrap(secondResult)

        var removeAttempts = 0
        manager.removeOPMLFile = { url in
            removeAttempts += 1
            XCTAssertEqual(url, firstURL)
            throw CocoaError(.fileWriteNoPermission)
        }
        manager.unregisterOPMLExportUI(firstRegistration)

        XCTAssertEqual(removeAttempts, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: firstURL.path),
            "A failed deletion must leave the retired generation owned"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))

        let secondRegistration = UUID()
        manager.registerOPMLExportUI(secondRegistration)
        manager.removeOPMLFile = { url in
            removeAttempts += 1
            try FileManager.default.removeItem(at: url)
        }
        manager.unregisterOPMLExportUI(secondRegistration)

        XCTAssertEqual(removeAttempts, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstURL.path),
            "The next final-owner cleanup must retry the retained deletion"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: secondURL.path),
            "The current prepared generation remains reusable"
        )
    }

    func testPermissionFailureRetainsCleanupOwnershipEvenWhenPathIsAbsent()
    async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "explicit removal error")])
        }
        let registration = UUID()
        manager.registerOPMLExportUI(registration)

        let firstResult = await waitForExport(manager, containing: "explicit removal error")
        let firstURL = try XCTUnwrap(firstResult)
        manager.invalidateOPMLExport()
        let secondResult = await waitForExport(manager, after: firstURL)
        _ = try XCTUnwrap(secondResult)
        try FileManager.default.removeItem(at: firstURL)

        var attempts = 0
        manager.removeOPMLFile = { url in
            XCTAssertEqual(url, firstURL)
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        manager.unregisterOPMLExportUI(registration)
        XCTAssertEqual(attempts, 1)

        manager.removeOPMLFile = { url in
            XCTAssertEqual(url, firstURL)
            attempts += 1
            throw CocoaError(.fileNoSuchFile)
        }
        manager.registerOPMLExportUI(registration)
        manager.unregisterOPMLExportUI(registration)
        XCTAssertEqual(attempts, 2, "Permission failure must retain the URL for retry")

        manager.registerOPMLExportUI(registration)
        manager.unregisterOPMLExportUI(registration)
        XCTAssertEqual(attempts, 2, "A confirmed missing file needs no further retry")
    }

    func testSecondExportViewKeepsRetiredFilesAliveUntilItAlsoUnregisters()
    async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "two-owner export")])
        }
        let firstRegistration = UUID()
        let secondRegistration = UUID()
        manager.registerOPMLExportUI(firstRegistration)
        manager.registerOPMLExportUI(secondRegistration)

        let firstResult = await waitForExport(manager, containing: "two-owner export")
        let firstURL = try XCTUnwrap(firstResult)
        manager.invalidateOPMLExport()
        let secondResult = await waitForExport(
            manager,
            after: firstURL,
            containing: "two-owner export"
        )
        _ = try XCTUnwrap(secondResult)

        manager.unregisterOPMLExportUI(firstRegistration)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: firstURL.path),
            "One remaining export view still owns retired generations"
        )

        manager.unregisterOPMLExportUI(secondRegistration)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstURL.path)
        )
    }

    func testStaleAsynchronousExportCannotReplaceNewerPreparedFile() async throws {
        let gate = DelayedOPMLExporter()
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = { await gate.export() }
        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer { manager.unregisterOPMLExportUI(registration) }

        var firstWaiting = false
        for _ in 0..<150 {
            if await gate.firstIsWaiting() { firstWaiting = true; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(firstWaiting)
        manager.invalidateOPMLExport()
        let preparedURL = await waitForExport(manager, containing: "fresh")
        let freshURL = try XCTUnwrap(preparedURL)
        await gate.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.exportedOPMLFileURL, freshURL)
        let xml = try String(contentsOf: freshURL, encoding: .utf8)
        XCTAssertTrue(xml.contains("fresh"))
        XCTAssertFalse(xml.contains("stale"))
    }

#if os(macOS)
    func testVisibleViewsReprepareAfterMutationAndKeepEarlierSharedFile() async throws {
        let previous = LibraryDataManager.realmConfiguration
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self,
            Feed.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = previous }
        let realm = try await Realm(configuration: configuration)
        let manager = LibraryManagerViewModel()

        let firstWindow = window(for: manager)
        let secondWindow = window(for: manager)
        defer { firstWindow.contentView = nil; secondWindow.contentView = nil
            firstWindow.close(); secondWindow.close() }
        let bothViewsRegistered = await waitUntil { manager.opmlExportUIRegistrationCount == 2 }
        XCTAssertTrue(bothViewsRegistered)
        let preparedFirstURL = await waitForExport(manager)
        let firstURL = try XCTUnwrap(preparedFirstURL)
        let originalBytes = try Data(contentsOf: firstURL)

        let categoryID = try await Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
        }.value
        realm.refresh()
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        try realm.write {
            category.title = "Visible export mutation"
            category.refreshChangeMetadata(explicitlyModified: true)
        }
        let preparedUpdatedURL = await waitForExport(manager, after: firstURL, containing: "Visible export mutation")
        let updatedURL = try XCTUnwrap(preparedUpdatedURL)
        XCTAssertNotEqual(updatedURL, firstURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        let updatedXML = try String(contentsOf: updatedURL, encoding: .utf8)
        XCTAssertTrue(updatedXML.contains("Visible export mutation"))

        firstWindow.contentView = nil
        let oneViewRegistered = await waitUntil { manager.opmlExportUIRegistrationCount == 1 }
        XCTAssertTrue(oneViewRegistered)
        manager.invalidateOPMLExport()
        manager.invalidateOPMLExport()
        let preparedRapidURL = await waitForExport(manager, after: updatedURL)
        let rapidURL = try XCTUnwrap(preparedRapidURL)
        XCTAssertNotEqual(rapidURL, updatedURL)

        secondWindow.contentView = nil
        let noViewsRegistered = await waitUntil { manager.opmlExportUIRegistrationCount == 0 }
        XCTAssertTrue(noViewsRegistered)
        manager.invalidateOPMLExport()
        XCTAssertNil(manager.exportedOPMLFileURL)
        await Task.yield()
        XCTAssertNil(manager.exportedOPMLFileURL)
    }

    private func window(for manager: LibraryManagerViewModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            NavigationStack { LibraryCategoriesView().environmentObject(manager) }
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

#endif

#if os(iOS)
    func testVisibleViewsReprepareAfterMutationAndKeepEarlierSharedFile() async throws {
        let previous = LibraryDataManager.realmConfiguration
        let configuration = makeLibraryRealmConfiguration()
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = previous }
        let realm = try await Realm(configuration: configuration)
        let manager = LibraryManagerViewModel()

        func mountedExportWindow() -> UIWindow {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            window.rootViewController = UIHostingController(rootView:
                NavigationStack { LibraryCategoriesView().environmentObject(manager) }
            )
            window.isHidden = false
            window.rootViewController?.view.layoutIfNeeded()
            return window
        }
        let firstWindow = mountedExportWindow()
        let secondWindow = mountedExportWindow()
        defer {
            firstWindow.rootViewController = nil
            secondWindow.rootViewController = nil
            firstWindow.isHidden = true
            secondWindow.isHidden = true
        }
        let bothViewsRegistered = await waitUntil { manager.opmlExportUIRegistrationCount == 2 }
        XCTAssertTrue(bothViewsRegistered)
        let preparedFirstURL = await waitForExport(manager)
        let firstURL = try XCTUnwrap(preparedFirstURL)
        let originalBytes = try Data(contentsOf: firstURL)

        let categoryID = try await Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
        }.value
        realm.refresh()
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        try realm.write {
            category.title = "Visible export mutation"
            category.refreshChangeMetadata(explicitlyModified: true)
        }
        let preparedUpdatedURL = await waitForExport(manager, after: firstURL, containing: "Visible export mutation")
        let updatedURL = try XCTUnwrap(preparedUpdatedURL)
        XCTAssertNotEqual(updatedURL, firstURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(try String(contentsOf: updatedURL, encoding: .utf8).contains("Visible export mutation"))

        firstWindow.rootViewController = nil
        let oneViewRegistered = await waitUntil { manager.opmlExportUIRegistrationCount == 1 }
        XCTAssertTrue(oneViewRegistered)
        manager.invalidateOPMLExport()
        manager.invalidateOPMLExport()
        let preparedRapidURL = await waitForExport(manager, after: updatedURL)
        let rapidURL = try XCTUnwrap(preparedRapidURL)
        XCTAssertNotEqual(rapidURL, updatedURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), originalBytes)

        secondWindow.rootViewController = nil
        let noViewsRegistered = await waitUntil { manager.opmlExportUIRegistrationCount == 0 }
        XCTAssertTrue(noViewsRegistered)
        manager.invalidateOPMLExport()
        XCTAssertNil(manager.exportedOPMLFileURL)
        await Task.yield()
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    }
#endif

    private func waitForExport(
        _ manager: LibraryManagerViewModel,
        after previousURL: URL? = nil,
        containing expectedText: String? = nil
    ) async -> URL? {
        for _ in 0..<150 {
            if let url = manager.exportedOPMLFileURL,
               url != previousURL,
               FileManager.default.fileExists(atPath: url.path),
               expectedText.map({ (try? String(contentsOf: url, encoding: .utf8).contains($0)) == true }) ?? true {
                return url
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeLibraryRealmConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self,
            FeedCategory.self,
            FeedDirectory.self,
            Feed.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

#if os(macOS)
    private func accessibilityElement(in root: NSView?, identifier: String) -> NSAccessibilityProtocol? {
        guard let root else { return nil }
        root.layoutSubtreeIfNeeded()
        return accessibilityElement(in: root as NSAccessibilityProtocol, identifier: identifier)
    }

    private func accessibilityElement(in element: NSAccessibilityProtocol, identifier: String) -> NSAccessibilityProtocol? {
        if element.accessibilityIdentifier() == identifier { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let child = child as? NSAccessibilityProtocol,
               let match = accessibilityElement(in: child, identifier: identifier) {
                return match
            }
        }
        return nil
    }

#endif
}

private actor DelayedOPMLExporter {
    private var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func firstIsWaiting() -> Bool { firstContinuation != nil }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func export() async -> OPML {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
            return OPML(entries: [OPMLEntry(text: "stale")])
        }
        return OPML(entries: [OPMLEntry(text: "fresh")])
    }
}
