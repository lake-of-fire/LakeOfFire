import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import XCTest
@testable import LakeOfFireContent

private actor InventoryAdmissionGate {
    private var released = false
    private var mappingClaims = 0
    func isFirstMapping() -> Bool {
        mappingClaims += 1
        return mappingClaims == 1
    }
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

private actor MigrationMetadataRetirementProbe {
    private var observation: ([String], [String: String])?
    func capture(ids: [String], journal: [String: String]) { observation = (ids, journal) }
    func snapshot() -> ([String], [String: String])? { observation }
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

    private func withFixture(
        libraryName: String = "library",
        directoryContentsProvider: (@Sendable (URL) async throws -> [URL])? = nil,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InventoryAdmission-" + UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent(libraryName, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [ContentFile.self, ContentPackageFile.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let manager: ReaderFileManager
        if let directoryContentsProvider {
            manager = ReaderFileManager(payloadStateProvider: { _ in .current },
                                        directoryContentsProvider: directoryContentsProvider)
        } else {
            manager = ReaderFileManager()
        }
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

    func testMigratedMetadataRejectsMissingOrRetiredScannedRecordsWithoutPartialPublication() async throws {
        for removesIndex in [false, true] {
            try await withFixture(libraryName: "Documents") { f in
                // A local-directory drive emits local backing URLs even when
                // assigned as the migration cloud root. Keep their resolver
                // pointed at the same disposable directory.
                f.manager.localDrive = f.drive
                f.manager.cloudDrive = f.drive
                try Data("Migration metadata".utf8).write(to: f.library.appendingPathComponent("book.txt"))
                let retained = try seed("retained", in: f)
                f.manager.files = [retained]
                let beforePublished = f.manager.files?.map { $0.compoundKey }
                let probe = MigrationMetadataRetirementProbe()
                ReaderFileManager.fileProcessors = [{ files in
                    XCTAssertEqual(files.count, 1, "The real scan must discover and persist the payload")
                    let realm = try XCTUnwrap(files.first?.realm)
                    let ids = files.map { $0.compoundKey }
                    // Simulate retirement after scanned IDs were captured. The
                    // second variant additionally simulates fixture-only index loss.
                    try realm.write {
                        for file in files {
                            file.isDeleted = true
                            file.refreshChangeMetadata(explicitlyModified: true)
                            if removesIndex {
                                // Fixture-only loss of the index after its durable
                                // retirement; exercise unresolved scanned IDs too.
                                realm.delete(file)
                            }
                        }
                    }
                    let journal = Dictionary(uniqueKeysWithValues:
                        realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) })
                    await probe.capture(ids: ids, journal: journal)
                }]
                do {
                    try await f.manager.refreshMigratedCloudDocumentsMetadata(containerURL: f.root)
                    XCTFail("A filesystem scan cannot complete migration with a retired index row")
                } catch ReaderFileManagerError.incompleteMetadataScan { }
                let observed = await probe.snapshot()
                let (ids, journal) = try XCTUnwrap(observed)
                f.realm.refresh()
                XCTAssertEqual(f.manager.files?.map { $0.compoundKey }, beforePublished)
                XCTAssertEqual(Dictionary(uniqueKeysWithValues:
                    f.realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }), journal)
                for id in ids {
                    let row = f.realm.object(ofType: ContentFile.self, forPrimaryKey: id)
                    if removesIndex { XCTAssertNil(row) }
                    else { XCTAssertTrue(try XCTUnwrap(row).isDeleted) }
                }
                XCTAssertEqual(try Data(contentsOf: f.library.appendingPathComponent("book.txt")),
                    Data("Migration metadata".utf8))
            }
        }
    }

    func testMigratedMetadataPublishesCompleteScannedRecords() async throws {
        try await withFixture(libraryName: "Documents") { f in
            f.manager.localDrive = f.drive
            f.manager.cloudDrive = f.drive
            try Data("Complete metadata".utf8).write(to: f.library.appendingPathComponent("book.txt"))
            try await f.manager.refreshMigratedCloudDocumentsMetadata(containerURL: f.root)
            let published = try XCTUnwrap(f.manager.files)
            XCTAssertEqual(published.count, 1)
            XCTAssertEqual(published.first?.url.lastPathComponent, "book.txt")
            XCTAssertFalse(try XCTUnwrap(published.first).isDeleted)
            f.realm.refresh()
            XCTAssertEqual(f.realm.objects(ContentFile.self).filter("isDeleted == false").count, 1)
            XCTAssertFalse(f.realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testMigratedMetadataRetirementDuringPublicationPreservesPriorListAndJournal() async throws {
        try await withFixture(libraryName: "Documents") { f in
            f.manager.localDrive = f.drive
            f.manager.cloudDrive = f.drive
            for name in ["first.txt", "second.txt"] {
                try Data(name.utf8).write(to: f.library.appendingPathComponent(name))
            }
            let retained = try seed("retained", in: f)
            f.manager.files = [retained]
            let beforePublished = f.manager.files?.map { $0.compoundKey }
            var reachedPublication = false
            var retirementJournal = [String: String]()
            do {
                try await f.manager.refreshMigratedCloudDocumentsMetadata(containerURL: f.root,
                    openRealm: { configuration in
                        // This opening occurs after the actual scan and complete
                        // reference transfer, at the MainActor publisher boundary.
                        let realm = try await Realm.open(configuration: configuration)
                        reachedPublication = true
                        let discovered = Array(realm.objects(ContentFile.self)).filter {
                            ["first.txt", "second.txt"].contains($0.url.lastPathComponent)
                        }
                        XCTAssertEqual(discovered.count, 2)
                        let retiring = try XCTUnwrap(discovered.first {
                            $0.url.lastPathComponent == "second.txt"
                        })
                        try realm.write {
                            retiring.isDeleted = true
                            retiring.refreshChangeMetadata(explicitlyModified: true)
                        }
                        retirementJournal = Dictionary(uniqueKeysWithValues:
                            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) })
                        return realm
                    })
                XCTFail("Retirement after transfer must prevent partial migration publication")
            } catch ReaderFileManagerError.incompleteMetadataScan { }
            XCTAssertTrue(reachedPublication, "The reference-completeness guard must have succeeded first")
            f.realm.refresh()
            XCTAssertEqual(f.manager.files?.map { $0.compoundKey }, beforePublished)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:
                f.realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }), retirementJournal)
            let valid = f.realm.objects(ContentFile.self).filter {
                $0.url.lastPathComponent == "first.txt" && !$0.isDeleted
            }
            XCTAssertEqual(valid.count, 1)
            for name in ["first.txt", "second.txt"] {
                XCTAssertEqual(try Data(contentsOf: f.library.appendingPathComponent(name)), Data(name.utf8))
            }
        }
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

    func testMigratedCloudDocumentsRequireAnInstalledMatchingDrive() async throws {
        try await withFixture(libraryName: "Documents") { f in
            try self.write("preserved", named: "book", in: f)
            do {
                try await f.manager.refreshMigratedCloudDocumentsMetadata(containerURL: f.root)
                XCTFail("A local-only manager cannot certify a captured cloud container")
            } catch { XCTAssertTrue(error is ReaderFileManagerError) }
            f.manager.cloudDrive = f.drive
            do {
                try await f.manager.refreshMigratedCloudDocumentsMetadata(
                    containerURL: f.root.appendingPathComponent("other-account"))
                XCTFail("A different container cannot certify this drive")
            } catch { XCTAssertTrue(error is ReaderFileManagerError) }
            XCTAssertTrue(f.realm.objects(ContentFile.self).isEmpty)
            XCTAssertTrue(self.journals(f).isEmpty)
            XCTAssertEqual(try String(contentsOf: f.library.appendingPathComponent("book.txt"),
                                      encoding: .utf8), "preserved")
        }
    }

    func testMigratedCloudDocumentsCompleteScanIndexesAndPublishesFiles() async throws {
        try await withFixture(libraryName: "Documents") { f in
            f.manager.cloudDrive = f.drive
            f.manager.localDrive = nil
            try self.write("migrated", named: "book", in: f)
            try await f.manager.refreshMigratedCloudDocumentsMetadata(containerURL: f.root)
            f.realm.refresh()
            XCTAssertEqual(f.realm.objects(ContentFile.self).map { $0.url.lastPathComponent }, ["book.txt"])
            XCTAssertEqual(f.manager.files?.map { $0.url.lastPathComponent }, ["book.txt"])
            XCTAssertFalse(self.journals(f).isEmpty)
        }
    }

    func testMigratedCloudDocumentsDoNotJoinAnOlderCompleteRootScan() async throws {
        try await assertMigrationStartsFreshScan(nested: false)
    }

    func testMigratedCloudDocumentsDoNotJoinAnOlderCompleteChildScan() async throws {
        try await assertMigrationStartsFreshScan(nested: true)
    }

    private func assertMigrationStartsFreshScan(nested: Bool) async throws {
        try await withFixture(libraryName: "Documents") { f in
            f.manager.cloudDrive = f.drive
            f.manager.localDrive = nil
            let folder = nested ? f.library.appendingPathComponent("Books", isDirectory: true) : f.library
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("predecessor inventory".utf8).write(to: folder.appendingPathComponent("existing.txt"))
            let predecessorMapped = self.expectation(description: "Predecessor has enumerated its old inventory")
            let freshMapped = self.expectation(description: "Migration independently enumerates after relocation")
            let gate = InventoryAdmissionGate()
            ReaderFileManager.readerFileURLProcessors = [{ fileURL, _ in
                if fileURL.lastPathComponent == "existing.txt" {
                    if await gate.isFirstMapping() {
                        predecessorMapped.fulfill()
                        await gate.wait()
                    } else {
                        freshMapped.fulfill()
                    }
                }
                return nil
            }]
            let predecessor = Task { @MainActor in
                _ = try await f.manager.refreshFilesMetadata(
                    drive: f.drive,
                    relativePath: nested ? RootRelativePath(path: "Books") : nil,
                    realmConfiguration: f.configuration
                )
            }
            let initialWait = await XCTWaiter.fulfillment(of: [predecessorMapped], timeout: 5)
            guard initialWait == .completed else {
                predecessor.cancel()
                await gate.open()
                _ = try? await predecessor.value
                throw InventoryAdmissionFixtureError.mappingDidNotStart
            }
            // A real storage relocation happens after the old scan's inventory
            // was captured, while that scan remains suspended in URL mapping.
            let source = f.root.appendingPathComponent("legacy-book.txt")
            let relocated = folder.appendingPathComponent("book.txt")
            do {
                try Data("newly relocated".utf8).write(to: source)
                try FileManager.default.moveItem(at: source, to: relocated)
            } catch {
                predecessor.cancel()
                await gate.open()
                _ = try? await predecessor.value
                throw error
            }
            let migrationScan = Task { @MainActor in
                try await f.manager.refreshMigratedCloudDocumentsMetadata(containerURL: f.root)
            }
            do {
                let freshWait = await XCTWaiter.fulfillment(of: [freshMapped], timeout: 5)
                guard freshWait == .completed else {
                    throw InventoryAdmissionFixtureError.mappingDidNotStart
                }
                // The migration scan must finish without releasing or borrowing
                // its predecessor, and index the item absent from that inventory.
                try await migrationScan.value
                f.realm.refresh()
                XCTAssertEqual(Set(f.realm.objects(ContentFile.self).map { $0.url.lastPathComponent }),
                               Set(["existing.txt", "book.txt"]))
                XCTAssertEqual(Set(f.manager.files?.map { $0.url.lastPathComponent } ?? []),
                               Set(["existing.txt", "book.txt"]))
                XCTAssertEqual(try String(contentsOf: relocated, encoding: .utf8), "newly relocated")
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            } catch {
                predecessor.cancel()
                migrationScan.cancel()
                await gate.open()
                _ = try? await predecessor.value
                _ = try? await migrationScan.value
                throw error
            }
            await gate.open()
            try await predecessor.value
            await f.manager.inventoryRefreshQueue?.waitForIdle()
        }
    }

    func testMigratedCloudDocumentsPropagateEnumerationFailure() async throws {
        try await withFixture(libraryName: "Documents", directoryContentsProvider: { _ in
            throw InventoryAdmissionFixtureError.mappingDidNotStart
        }) { f in
            f.manager.cloudDrive = f.drive
            f.manager.localDrive = nil
            try self.write("preserved", named: "book", in: f)
            do {
                try await f.manager.refreshMigratedCloudDocumentsMetadata(containerURL: f.root)
                XCTFail("Migration completion must propagate the captured-root scan failure")
            } catch { XCTAssertTrue(error is InventoryAdmissionFixtureError) }
            XCTAssertTrue(f.realm.objects(ContentFile.self).isEmpty)
            XCTAssertTrue(self.journals(f).isEmpty)
            XCTAssertNil(f.manager.files)
        }
    }

    func testMigratedCloudDocumentsRejectIncompleteScanWithoutPublishing() async throws {
        try await withFixture(libraryName: "Documents") { f in
            f.manager.cloudDrive = f.drive
            f.manager.localDrive = nil
            try self.write("disappears during mapping", named: "gone", in: f)
            let entered = self.expectation(description: "Migration scan reached URL mapping")
            entered.assertForOverFulfill = false
            let gate = InventoryAdmissionGate()
            ReaderFileManager.readerFileURLProcessors = [{ _, _ in
                entered.fulfill()
                await gate.wait()
                return nil
            }]
            let scan = Task { @MainActor in
                try await f.manager.refreshMigratedCloudDocumentsMetadata(containerURL: f.root)
            }
            let wait = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            guard wait == .completed else {
                scan.cancel()
                await gate.open()
                _ = try? await scan.value
                throw InventoryAdmissionFixtureError.mappingDidNotStart
            }
            do {
                try FileManager.default.removeItem(at: f.library.appendingPathComponent("gone.txt"))
            } catch {
                scan.cancel()
                await gate.open()
                _ = try? await scan.value
                throw error
            }
            await gate.open()
            do {
                try await scan.value
                XCTFail("A missing admitted payload makes the migration scan incomplete")
            } catch {
                guard let migrationError = error as? ReaderFileManagerError,
                      case .incompleteMetadataScan = migrationError else {
                    XCTFail("Expected incomplete scan, received \(error)")
                    return
                }
            }
            f.realm.refresh()
            XCTAssertTrue(f.realm.objects(ContentFile.self).isEmpty)
            XCTAssertTrue(self.journals(f).isEmpty)
            XCTAssertNil(f.manager.files)
        }
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
