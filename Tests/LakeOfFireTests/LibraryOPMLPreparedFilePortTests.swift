import Foundation
import OPML
import XCTest
@testable import LakeOfFireLibrary

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LibraryOPMLPreparedFilePortTests: XCTestCase {
    func testFailedFileWriteNeverPublishesShareableStateAndRequiresExplicitRetry() async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "Prepared after retry")])
        }
        var writeAttempts = 0
        manager.writeOPMLFile = { data, url in
            writeAttempts += 1
            if writeAttempts == 1 {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: [.atomic])
        }

        let first = UUID()
        let second = UUID()
        manager.registerOPMLExportUI(first)
        defer {
            manager.unregisterOPMLExportUI(first)
            manager.unregisterOPMLExportUI(second)
        }

        XCTAssertTrue(await waitUntil { manager.opmlExportFailed })
        XCTAssertNil(manager.exportedOPML)
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertEqual(writeAttempts, 1)

        // Merely adding another visible consumer cannot turn a failed file into
        // a shareable placeholder or silently retry it.
        manager.registerOPMLExportUI(second)
        manager.ensureOPMLExportPrepared()
        await Task.yield()
        XCTAssertEqual(writeAttempts, 1)
        XCTAssertTrue(manager.opmlExportFailed)

        manager.refreshOPMLExport()
        XCTAssertTrue(await waitUntil {
            manager.exportedOPMLFileURL != nil && !manager.opmlExportFailed
        })
        let url = try XCTUnwrap(manager.exportedOPMLFileURL)
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.pathExtension, "opml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try String(contentsOf: url, encoding: .utf8)
                .contains("Prepared after retry")
        )
    }

    func testVisibleInvalidationPublishesNewImmutableFileWithoutMutatingOldConsumer() async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        let exporter = SequencedOPMLExporter([
            "First immutable export",
            "Second immutable export",
        ])
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: await exporter.next())])
        }

        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer { manager.unregisterOPMLExportUI(registration) }

        XCTAssertTrue(await waitUntil { manager.exportedOPMLFileURL != nil })
        let firstURL = try XCTUnwrap(manager.exportedOPMLFileURL)
        let firstBytes = try Data(contentsOf: firstURL)

        manager.invalidateOPMLExport()
        XCTAssertTrue(await waitUntil {
            guard let current = manager.exportedOPMLFileURL else { return false }
            return current != firstURL
        })
        let secondURL = try XCTUnwrap(manager.exportedOPMLFileURL)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertTrue(
            try String(contentsOf: secondURL, encoding: .utf8)
                .contains("Second immutable export")
        )
    }

    func testRetiredExportRemainsReadableUntilLastVisibleOwnerLeaves() async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        let exporter = SequencedOPMLExporter([
            "Retained first export",
            "Fresh second export",
        ])
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: await exporter.next())])
        }

        let registration = UUID()
        manager.registerOPMLExportUI(registration)

        XCTAssertTrue(await waitUntil { manager.exportedOPMLFileURL != nil })
        let firstURL = try XCTUnwrap(manager.exportedOPMLFileURL)
        let firstBytes = try Data(contentsOf: firstURL)

        manager.invalidateOPMLExport()
        XCTAssertTrue(await waitUntil {
            guard let current = manager.exportedOPMLFileURL else { return false }
            return current != firstURL
        })
        let secondURL = try XCTUnwrap(manager.exportedOPMLFileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))

        manager.unregisterOPMLExportUI(registration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))

        manager.invalidateOPMLExport()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertNil(manager.exportedOPMLFileURL)
    }

    func testFailedWriteCleanupOwnershipSurvivesRemovalFailureUntilRetry() async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "Cleanup retry")])
        }

        var writeAttempts = 0
        var partialURL: URL?
        manager.writeOPMLFile = { data, url in
            writeAttempts += 1
            if writeAttempts == 1 {
                try Data("partial".utf8).write(to: url, options: [.atomic])
                partialURL = url
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: [.atomic])
        }

        var removalAttempts = 0
        manager.removeOPMLFile = { url in
            removalAttempts += 1
            guard removalAttempts > 1 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        }

        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer { manager.unregisterOPMLExportUI(registration) }

        XCTAssertTrue(await waitUntil { manager.opmlExportFailed })
        let failedURL = try XCTUnwrap(partialURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertEqual(removalAttempts, 1)

        manager.refreshOPMLExport()
        XCTAssertTrue(await waitUntil {
            manager.exportedOPMLFileURL != nil && !manager.opmlExportFailed
        })

        XCTAssertEqual(removalAttempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertEqual(writeAttempts, 2)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private actor SequencedOPMLExporter {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        values.isEmpty ? "fallback" : values.removeFirst()
    }
}
