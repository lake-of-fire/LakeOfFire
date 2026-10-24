import Foundation
import OPML
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
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
            manager.invalidateOPMLExport()
        }

        let didReportWriteFailure = await waitUntil { manager.opmlExportFailed }
        XCTAssertTrue(didReportWriteFailure)
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
        let didPrepareRetry = await waitUntil {
            manager.exportedOPMLFileURL != nil && !manager.opmlExportFailed
        }
        XCTAssertTrue(didPrepareRetry)
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
        defer {
            manager.unregisterOPMLExportUI(registration)
            manager.invalidateOPMLExport()
        }

        let didPrepareFirstExport = await waitUntil { manager.exportedOPMLFileURL != nil }
        XCTAssertTrue(didPrepareFirstExport)
        let firstURL = try XCTUnwrap(manager.exportedOPMLFileURL)
        let firstBytes = try Data(contentsOf: firstURL)

        manager.invalidateOPMLExport()
        let didPrepareReplacementExport = await waitUntil {
            guard let current = manager.exportedOPMLFileURL else { return false }
            return current != firstURL
        }
        XCTAssertTrue(didPrepareReplacementExport)
        let secondURL = try XCTUnwrap(manager.exportedOPMLFileURL)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertTrue(
            try String(contentsOf: secondURL, encoding: .utf8)
                .contains("Second immutable export")
        )
    }

    func testCapturedExporterKeepsOriginalRealmAfterGlobalReplacement() async throws {
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }

        func makeConfiguration(_ name: String) -> Realm.Configuration {
            var configuration = Realm.Configuration(inMemoryIdentifier: name)
            configuration.objectTypes = [
                LibraryConfiguration.self, FeedCategory.self, Feed.self,
                FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
            ]
            configureLakeOfFireMutationTrackingForTesting(&configuration)
            return configuration
        }

        let observed = makeConfiguration("opml-observed-\(UUID().uuidString)")
        let replacement = makeConfiguration("opml-replacement-\(UUID().uuidString)")
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: observed)
            await RealmBackgroundActor.shared.removeCachedRealm(for: replacement)
        }
        LibraryDataManager.realmConfiguration = observed

        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: observed)
            let library = LibraryConfiguration()
            let script = UserScript()
            script.title = "Observed export script"
            script.script = "console.log('observed')"
            library.userScriptIDs.append(script.id)
            try await realm.asyncWrite {
                realm.add([library, script])
            }
        }.value

        // Use the selected non-observing construction seam without initializing
        // the process singleton or leaving its download flag changed.
        let dataManager: LibraryDataManager = {
            let previousObservation = LibraryDataManager.observesDownloadController
            LibraryDataManager.observesDownloadController = false
            defer { LibraryDataManager.observesDownloadController = previousObservation }
            return LibraryDataManager()
        }()
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            try await dataManager.exportUserOPML(realmConfiguration: observed)
        }

        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: replacement)
            let library = LibraryConfiguration()
            let script = UserScript()
            script.title = "Replacement export script"
            script.script = "console.log('replacement')"
            library.userScriptIDs.append(script.id)
            try await realm.asyncWrite {
                realm.add([library, script])
            }
        }.value
        LibraryDataManager.realmConfiguration = replacement

        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer {
            manager.unregisterOPMLExportUI(registration)
            manager.invalidateOPMLExport()
        }

        let didPrepareCapturedRealmExport = await waitUntil { manager.exportedOPMLFileURL != nil }
        XCTAssertTrue(didPrepareCapturedRealmExport)
        let url = try XCTUnwrap(manager.exportedOPMLFileURL)
        let xml = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(xml.contains("Observed export script"))
        XCTAssertFalse(xml.contains("Replacement export script"))
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
        let secondRegistration = UUID()
        manager.registerOPMLExportUI(registration)
        manager.registerOPMLExportUI(secondRegistration)
        defer {
            manager.unregisterOPMLExportUI(registration)
            manager.unregisterOPMLExportUI(secondRegistration)
            manager.invalidateOPMLExport()
        }

        let didPrepareFirstExport = await waitUntil { manager.exportedOPMLFileURL != nil }
        XCTAssertTrue(didPrepareFirstExport)
        let firstURL = try XCTUnwrap(manager.exportedOPMLFileURL)
        let firstBytes = try Data(contentsOf: firstURL)

        manager.invalidateOPMLExport()
        let didPrepareReplacementExport = await waitUntil {
            guard let current = manager.exportedOPMLFileURL else { return false }
            return current != firstURL
        }
        XCTAssertTrue(didPrepareReplacementExport)
        let secondURL = try XCTUnwrap(manager.exportedOPMLFileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))

        manager.unregisterOPMLExportUI(registration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        manager.unregisterOPMLExportUI(secondRegistration)
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
        defer {
            manager.unregisterOPMLExportUI(registration)
            manager.invalidateOPMLExport()
        }

        let didReportWriteFailure = await waitUntil { manager.opmlExportFailed }
        XCTAssertTrue(didReportWriteFailure)
        let failedURL = try XCTUnwrap(partialURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertEqual(removalAttempts, 1)

        manager.refreshOPMLExport()
        let didPrepareRetry = await waitUntil {
            manager.exportedOPMLFileURL != nil && !manager.opmlExportFailed
        }
        XCTAssertTrue(didPrepareRetry)

        XCTAssertEqual(removalAttempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertEqual(writeAttempts, 2)
    }


    func testWriterReturningWithoutAFileCannotPublishShareableState() async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: "Never written")])
        }
        manager.writeOPMLFile = { _, _ in }
        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer {
            manager.unregisterOPMLExportUI(registration)
            manager.invalidateOPMLExport()
        }

        let failed = await waitUntil { manager.opmlExportFailed }
        XCTAssertTrue(failed)
        XCTAssertNil(manager.exportedOPML)
        XCTAssertNil(manager.exportedOPMLFileURL)
        XCTAssertNil(manager.exportedOPMLShareItem)
    }

    func testShareSnapshotSurvivesReplacementAndFileCleanup() async throws {
        let manager = LibraryManagerViewModel(observesRealm: false)
        let exporter = SequencedOPMLExporter(["Original share bytes", "Replacement share bytes"])
        manager.exportUserOPML = {
            OPML(entries: [OPMLEntry(text: await exporter.next())])
        }
        let registration = UUID()
        manager.registerOPMLExportUI(registration)
        defer {
            manager.unregisterOPMLExportUI(registration)
            manager.invalidateOPMLExport()
        }

        let prepared = await waitUntil { manager.exportedOPMLFileURL != nil }
        XCTAssertTrue(prepared)
        let originalURL = try XCTUnwrap(manager.exportedOPMLFileURL)
        let originalShare = try XCTUnwrap(manager.exportedOPMLShareItem)
        XCTAssertEqual(originalShare.data, try Data(contentsOf: originalURL))

        manager.invalidateOPMLExport()
        let replaced = await waitUntil {
            guard let current = manager.exportedOPMLFileURL else { return false }
            return current != originalURL
        }
        XCTAssertTrue(replaced)
        let replacementShare = try XCTUnwrap(manager.exportedOPMLShareItem)
        manager.unregisterOPMLExportUI(registration)
        manager.invalidateOPMLExport()

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertNil(manager.exportedOPMLShareItem)
        XCTAssertTrue(try XCTUnwrap(String(data: originalShare.data, encoding: .utf8)).contains("Original share bytes"))
        XCTAssertFalse(try XCTUnwrap(String(data: originalShare.data, encoding: .utf8)).contains("Replacement share bytes"))
        XCTAssertTrue(try XCTUnwrap(String(data: replacementShare.data, encoding: .utf8)).contains("Replacement share bytes"))
    }

    func testStaleExporterSuccessOrFailureCannotReplaceNewerPreparedShare() async throws {
        for staleFails in [false, true] {
            let entered = expectation(description: "Original export is suspended")
            let gate = HeldOPMLExporter(
                entered: entered,
                staleFails: staleFails
            )
            let manager = LibraryManagerViewModel(observesRealm: false)
            manager.exportUserOPML = { try await gate.export() }
            var staleWrites = 0
            manager.writeOPMLFile = { data, url in
                if String(data: data, encoding: .utf8)?.contains("stale export") == true {
                    staleWrites += 1
                }
                try data.write(to: url, options: [.atomic])
            }

            let staleTask = manager.refreshOPMLExport()
            addTeardownBlock {
                staleTask.cancel()
                await MainActor.run { manager.invalidateOPMLExport() }
                await gate.release()
                await staleTask.value
            }
            await fulfillment(of: [entered], timeout: 2)
            let firstIsWaiting = await gate.firstIsWaiting()
            guard firstIsWaiting else {
                XCTFail("The original export did not reach its controlled suspension")
                return
            }

            let freshTask = manager.refreshOPMLExport()
            addTeardownBlock {
                freshTask.cancel()
                await MainActor.run { manager.invalidateOPMLExport() }
                await gate.release()
                await freshTask.value
            }
            await freshTask.value
            let freshURL = try XCTUnwrap(manager.exportedOPMLFileURL)
            let freshBytes = try XCTUnwrap(manager.exportedOPMLShareItem).data
            XCTAssertTrue(manager.exportedOPML?.xml.contains("fresh export") == true)

            await gate.release()
            await staleTask.value
            XCTAssertEqual(staleWrites, 0)
            XCTAssertEqual(manager.exportedOPMLFileURL, freshURL)
            XCTAssertEqual(manager.exportedOPMLShareItem?.data, freshBytes)
            XCTAssertFalse(manager.opmlExportFailed)
        }
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

private actor HeldOPMLExporter {
    private let entered: XCTestExpectation
    private let staleFails: Bool
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var callCount = 0
    private var released = false

    init(
        entered: XCTestExpectation,
        staleFails: Bool
    ) {
        self.entered = entered
        self.staleFails = staleFails
    }

    func firstIsWaiting() -> Bool { firstContinuation != nil }

    func release() {
        released = true
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume()
    }

    func export() async throws -> OPML {
        callCount += 1
        guard callCount == 1 else {
            return OPML(entries: [OPMLEntry(text: "fresh export")])
        }
        if released {
            entered.fulfill()
        } else {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
                entered.fulfill()
            }
        }
        if staleFails { throw CocoaError(.fileReadUnknown) }
        return OPML(entries: [OPMLEntry(text: "stale export")])
    }
}
