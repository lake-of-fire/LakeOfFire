#if os(macOS)
import AppKit
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
