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
        XCTAssertTrue(try String(contentsOf: preparedURL, encoding: .utf8).contains("Explicit retry export"))
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
            return (script.id, domain.id)
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
            return (
                realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: "UserScript.\(identifiers.0)") != nil,
                realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: "UserScriptAllowedDomain.\(identifiers.1)") != nil
            )
        }.value
        XCTAssertTrue(journaledEdits.0)
        XCTAssertTrue(journaledEdits.1)
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
