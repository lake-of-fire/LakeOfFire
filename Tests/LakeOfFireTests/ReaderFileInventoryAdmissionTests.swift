import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import XCTest
@testable import LakeOfFireContent

private actor InventoryAdmissionGate {
    private var released = false
    private var waiters = [CheckedContinuation<Void, Never>]()
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private enum InventoryAdmissionFixtureError: Swift.Error { case mappingDidNotStart }

/// Real manager, filesystem, Realm and mutation journal. Only URL-mapping
/// scheduling is held; the metadata writer and deletion command are unchanged.
@MainActor
final class ReaderFileInventoryAdmissionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let library: URL
        let manager: ReaderFileManager
        let realm: Realm
        let configuration: Realm.Configuration
        let drive: CloudDrive
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InventoryAdmission-" + UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [ContentFile.self, ContentPackageFile.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration
        manager.inventoryRefreshQueue = ReaderFileRefreshQueue(interval: 0)
        let drive = try await CloudDrive(storage: .localDirectory(rootURL: library))
        manager.localDrive = drive
        let oldShared = ReaderFileManager.shared
        let oldMapping = ReaderFileManager.readerFileURLProcessors
        let oldProcessors = ReaderFileManager.fileProcessors
        let oldEnrichment = ReaderFileManager.fileEnrichmentProcessors
        ReaderFileManager.shared = manager
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        ReaderFileManager.fileEnrichmentProcessors = [:]
        defer {
            ReaderFileManager.shared = oldShared
            ReaderFileManager.readerFileURLProcessors = oldMapping
            ReaderFileManager.fileProcessors = oldProcessors
            ReaderFileManager.fileEnrichmentProcessors = oldEnrichment
        }
        do {
            try await body(Fixture(root: root, library: library, manager: manager,
                realm: realm, configuration: configuration, drive: drive))
        } catch {
            await manager.inventoryRefreshQueue?.waitForIdle()
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            throw error
        }
        await manager.inventoryRefreshQueue?.waitForIdle()
        await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
    }

    private func seed(_ name: String, in f: Fixture) throws -> ContentFile {
        let row = ContentFile()
        row.url = try XCTUnwrap(URL(string: "reader-file://file/load/local/\(name).txt"))
        row.title = name
        row.updateCompoundKey()
        try f.realm.write {
            f.realm.add(row)
            row.refreshChangeMetadata(explicitlyModified: true)
        }
        return row
    }

    private func write(_ text: String, named name: String, in f: Fixture) throws {
        try Data(text.utf8).write(to: f.library.appendingPathComponent(name + ".txt"))
    }

    private func journals(_ f: Fixture) -> [String: String] {
        f.realm.refresh()
        return Dictionary(uniqueKeysWithValues: f.realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }

    private func duringMappedScan(
        _ f: Fixture,
        fullInventory: Bool = false,
        beforeResume: () async throws -> Void
    ) async throws {
        let entered = expectation(description: "mapped existing file before metadata admission")
        entered.assertForOverFulfill = false
        let gate = InventoryAdmissionGate()
        ReaderFileManager.readerFileURLProcessors = [{ fileURL, _ in
            if fileURL.lastPathComponent == "gone.txt" {
                entered.fulfill()
                await gate.wait()
            }
            return nil
        }]
        let scan = Task { @MainActor in
            if fullInventory {
                try await f.manager.refreshAllFilesMetadata(force: true)
            } else {
                _ = try await f.manager.refreshFilesMetadata(drive: f.drive,
                    realmConfiguration: f.configuration)
            }
        }
        let waiting = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        guard waiting == .completed else {
            scan.cancel()
            await gate.open()
            _ = try? await scan.value
            throw InventoryAdmissionFixtureError.mappingDidNotStart
        }
        do {
            try await beforeResume()
        } catch {
            scan.cancel()
            await gate.open()
            _ = try? await scan.value
            throw error
        }
        await gate.open()
        try await scan.value
        await f.manager.inventoryRefreshQueue?.waitForIdle()
        f.realm.refresh()
    }

    func testMappedFileDeletedBeforeMetadataAdmissionKeepsTombstoneAndJournal() async throws {
        try await withFixture { f in
            try self.write("original", named: "gone", in: f)
            let row = try self.seed("gone", in: f)
            let key = row.compoundKey
            let url = row.url
            var deletionJournals = [String: String]()
            try await self.duringMappedScan(f) {
                try await f.manager.delete(readerFileURL: url)
                deletionJournals = self.journals(f)
                XCTAssertTrue(row.isDeleted)
            }
            let retained = try XCTUnwrap(f.realm.object(ofType: ContentFile.self, forPrimaryKey: key))
            XCTAssertTrue(retained.isDeleted, "A stale mapped URL must not revive an acknowledged local deletion")
            XCTAssertEqual(self.journals(f), deletionJournals)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.library.appendingPathComponent("gone.txt").path))
        }
    }

    func testMappedUnindexedFileDisappearingBeforeAdmissionCreatesNoRecordOrJournal() async throws {
        try await withFixture { f in
            try self.write("never indexed", named: "gone", in: f)
            try await self.duringMappedScan(f) {
                try FileManager.default.removeItem(at: f.library.appendingPathComponent("gone.txt"))
            }
            XCTAssertTrue(f.realm.objects(ContentFile.self).isEmpty)
            XCTAssertTrue(self.journals(f).isEmpty)
        }
    }

    func testIncompleteMetadataAdmissionRetainsOrphansUntilANewCompleteScan() async throws {
        try await withFixture { f in
            try self.write("disappears after mapping", named: "gone", in: f)
            let gone = try self.seed("gone", in: f)
            let orphan = try self.seed("orphan", in: f)
            let initialJournals = self.journals(f)
            try await self.duringMappedScan(f, fullInventory: true) {
                try FileManager.default.removeItem(at: f.library.appendingPathComponent("gone.txt"))
            }
            XCTAssertFalse(gone.isDeleted)
            XCTAssertFalse(orphan.isDeleted, "A partial metadata pass is not a complete-root absence proof")
            XCTAssertEqual(self.journals(f), initialJournals)
            ReaderFileManager.readerFileURLProcessors = []
            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            XCTAssertTrue(gone.isDeleted)
            XCTAssertTrue(orphan.isDeleted)
            XCTAssertNotEqual(self.journals(f), initialJournals)
        }
    }

    func testMissingMappedFileDoesNotSuppressHealthySiblingIndexing() async throws {
        try await withFixture { f in
            try self.write("will disappear", named: "gone", in: f)
            try self.write("healthy", named: "healthy", in: f)
            try await self.duringMappedScan(f, fullInventory: true) {
                try FileManager.default.removeItem(at: f.library.appendingPathComponent("gone.txt"))
            }
            let files = Array(f.realm.objects(ContentFile.self))
            XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["healthy.txt"])
            XCTAssertEqual(f.manager.files?.map { $0.url.lastPathComponent }, ["healthy.txt"])
            XCTAssertFalse(self.journals(f).isEmpty)
        }
    }

    func testReimportBeforeMetadataAdmissionCanReviveTheOriginalRecord() async throws {
        try await withFixture { f in
            try self.write("old payload", named: "gone", in: f)
            let row = try self.seed("gone", in: f)
            let key = row.compoundKey
            let url = row.url
            var deletionJournals = [String: String]()
            try await self.duringMappedScan(f) {
                try await f.manager.delete(readerFileURL: url)
                deletionJournals = self.journals(f)
                XCTAssertTrue(row.isDeleted)
                try self.write("new legitimate payload", named: "gone", in: f)
            }
            let revived = try XCTUnwrap(f.realm.object(ofType: ContentFile.self, forPrimaryKey: key))
            XCTAssertFalse(revived.isDeleted)
            XCTAssertEqual(f.realm.objects(ContentFile.self).count, 1)
            XCTAssertNotEqual(self.journals(f), deletionJournals)
            XCTAssertEqual(try Data(contentsOf: f.library.appendingPathComponent("gone.txt")),
                Data("new legitimate payload".utf8))
        }
    }

    func testAlreadyDeletedAbsentMappedFileDoesNotRenewItsDeletionGeneration() async throws {
        try await withFixture { f in
            try self.write("old local payload", named: "gone", in: f)
            let row = try self.seed("gone", in: f)
            try f.realm.write {
                row.isDeleted = true
                row.refreshChangeMetadata(explicitlyModified: true)
            }
            let before = self.journals(f)
            try await self.duringMappedScan(f) {
                try FileManager.default.removeItem(at: f.library.appendingPathComponent("gone.txt"))
            }
            XCTAssertTrue(row.isDeleted)
            XCTAssertEqual(self.journals(f), before)
        }
    }
}
