#if os(macOS)
import AppKit
import OPML
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryExportPresentationTests: XCTestCase {
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

    func testVisibleViewsReprepareAfterMutationAndKeepEarlierSharedFile() async throws {
        let previous = LibraryDataManager.realmConfiguration
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self,
            Feed.self, UserScript.self,
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
#endif
