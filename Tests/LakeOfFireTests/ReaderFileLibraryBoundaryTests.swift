import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import SwiftUIDownloads
import UniformTypeIdentifiers
import XCTest
@testable import LakeOfFireContent

private actor LibraryBoundaryGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor LibraryBoundaryEnumeration {
    let entered = LibraryBoundaryGate()
    let release = LibraryBoundaryGate()
    private var first = true
    func read(_ directory: URL) async throws -> [URL] {
        let snapshot = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .producesRelativePathURLs]
        )
        if first {
            first = false
            await entered.open()
            await release.wait()
        }
        return snapshot
    }
}

/// Exercises the production manager, local filesystem, Realm index and journal.
/// Only clock/scheduling and a held enumeration are injected. No network or
/// production account is used. These tests require the native package graph.
@MainActor
final class ReaderFileLibraryBoundaryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let library: URL
        let manager: ReaderFileManager
        let configuration: Realm.Configuration
        let realm: Realm
    }

    private func withFixture(
        manager: ReaderFileManager = ReaderFileManager(),
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderLibraryBoundary-" + UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [ContentFile.self, ContentPackageFile.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        manager.historyRealmConfigurationOverride = configuration
        manager.inventoryRefreshQueue = ReaderFileRefreshQueue(interval: 0)
        manager.readerContentMimeTypes.append(.epub)
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: library))
        let oldShared = ReaderFileManager.shared
        let oldDestinations = ReaderFileManager.fileDestinationProcessors
        let oldURLProcessors = ReaderFileManager.readerFileURLProcessors
        let oldProcessors = ReaderFileManager.fileProcessors
        let oldEnrichment = ReaderFileManager.fileEnrichmentProcessors
        ReaderFileManager.shared = manager
        ReaderFileManager.fileDestinationProcessors = []
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        ReaderFileManager.fileEnrichmentProcessors = [:]
        defer {
            ReaderFileManager.shared = oldShared
            ReaderFileManager.fileDestinationProcessors = oldDestinations
            ReaderFileManager.readerFileURLProcessors = oldURLProcessors
            ReaderFileManager.fileProcessors = oldProcessors
            ReaderFileManager.fileEnrichmentProcessors = oldEnrichment
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = Fixture(root: root, library: library, manager: manager,
                              configuration: configuration, realm: realm)
        do {
            try await body(fixture)
        } catch {
            await manager.inventoryRefreshQueue?.waitForIdle()
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            throw error
        }
        await manager.inventoryRefreshQueue?.waitForIdle()
        await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
    }

    private func download(_ raw: String, manager: ReaderFileManager) async throws -> Downloadable {
        let url = try XCTUnwrap(URL(string: raw))
        let result = try await manager.downloadable(url: url, name: "Book")
        return try XCTUnwrap(result)
    }

    private func write(_ text: String, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: destination)
    }

    func testCatalogBasenameCollisionCannotClaimAnotherDownloadsBytes() async throws {
        try await withFixture { f in
            let legacy = f.library.appendingPathComponent("book.txt")
            try self.write("user-owned legacy book", to: legacy)
            try await f.manager.refreshAllFilesMetadata()
            let legacyRecord = try XCTUnwrap(f.manager.files?.first)
            let legacyKey = legacyRecord.compoundKey
            let first = try await self.download("https://a.example/book.txt", manager: f.manager)
            let second = try await self.download("https://b.example/book.txt", manager: f.manager)
            let queryVariant = try await self.download("https://a.example/book.txt?id=2", manager: f.manager)
            XCTAssertNotEqual(first.localDestination, legacy)
            XCTAssertNotEqual(first.localDestination, second.localDestination)
            XCTAssertNotEqual(first.localDestination, queryVariant.localDestination)
            try self.write("download A", to: first.localDestination)
            let firstExists = await first.existsLocally()
            let secondExists = await second.existsLocally()
            let queryExists = await queryVariant.existsLocally()
            XCTAssertTrue(firstExists)
            XCTAssertFalse(secondExists)
            XCTAssertFalse(queryExists)
            XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "user-owned legacy book")
            let secondImport = try await f.manager.ensureImported(downloadable: second)
            XCTAssertNil(secondImport)
            XCTAssertEqual(legacyRecord.compoundKey, legacyKey)
            XCTAssertFalse(legacyRecord.isDeleted)
        }
    }

    func testImportedCatalogResourcesKeepSeparateURLsAndPayloads() async throws {
        try await withFixture { f in
            let first = try await self.download("https://example.com/book.txt?id=1", manager: f.manager)
            let second = try await self.download("https://example.com/book.txt?id=2", manager: f.manager)
            try self.write("first book", to: first.localDestination)
            try self.write("second book", to: second.localDestination)
            let firstResult = try await f.manager.ensureImported(downloadable: first)
            let secondResult = try await f.manager.ensureImported(downloadable: second)
            let firstURL = try XCTUnwrap(firstResult)
            let secondURL = try XCTUnwrap(secondResult)
            XCTAssertNotEqual(firstURL, secondURL)
            let firstBytes = try await f.manager.read(fileURL: firstURL)
            let secondBytes = try await f.manager.read(fileURL: secondURL)
            XCTAssertEqual(firstBytes, Data("first book".utf8))
            XCTAssertEqual(secondBytes, Data("second book".utf8))
            f.realm.refresh()
            let indexed = Array(f.realm.objects(ContentFile.self).where { !$0.isDeleted })
            XCTAssertEqual(Set(indexed.map(\.url)), Set([firstURL, secondURL]))
            XCTAssertEqual(Set(f.manager.files?.map(\.url) ?? []), Set([firstURL, secondURL]))
        }
    }

    func testSourceSlotIsStableAcrossManagerRecreationAndFragmentChanges() async throws {
        try await withFixture { f in
            let first = try await self.download("https://example.com/book.txt?token=a%2Fb#one", manager: f.manager)
            let replacement = ReaderFileManager()
            replacement.localDrive = f.manager.localDrive
            let second = try await self.download("https://example.com/book.txt?token=a%2Fb#two", manager: replacement)
            XCTAssertEqual(first.localDestination, second.localDestination)
            XCTAssertEqual(first.localDestination.lastPathComponent, "book.txt")
            XCTAssertEqual(first.localDestination.deletingLastPathComponent().lastPathComponent.count, 64)
        }
    }

    func testDownloadNamespaceCannotEscapeThroughExistingSymlink() async throws {
        try await withFixture { f in
            let outside = f.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: f.library.appendingPathComponent(ReaderFileStoragePaths.downloadsDirectory),
                withDestinationURL: outside
            )
            do {
                _ = try await self.download("https://example.com/book.txt", manager: f.manager)
                XCTFail("Download destination must stay inside the selected drive")
            } catch ReaderFileManagerError.invalidFileURL {
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    func testDownloadSlotCannotEscapeThroughExistingSymlink() async throws {
        try await withFixture { f in
            let source = "https://example.com/book.txt"
            let first = try await self.download(source, manager: f.manager)
            let destination = first.localDestination
            let slot = destination.deletingLastPathComponent()
            let outside = f.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: slot.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: slot, withDestinationURL: outside)
            do {
                _ = try await self.download(source, manager: f.manager)
                XCTFail("An existing download slot symlink must not escape the selected drive")
            } catch ReaderFileManagerError.invalidFileURL {
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    func testInventorySkipsStagingPayloadButKeepsOrdinarySimilarlyNamedBook() async throws {
        try await withFixture { f in
            let id = "01234567-89AB-CDEF-0123-456789ABCDEF"
            let stagingName = "book.downloading.\(id).epub"
            let ordinaryName = "book.downloading.notes.epub"
            try self.write("incomplete transfer", to: f.library.appendingPathComponent(stagingName))
            try self.write("ordinary user file", to: f.library.appendingPathComponent(ordinaryName))
            try await f.manager.refreshAllFilesMetadata()
            f.realm.refresh()
            let records = Array(f.realm.objects(ContentFile.self))
            XCTAssertEqual(records.map { $0.url.lastPathComponent }, [ordinaryName])
            XCTAssertEqual(f.manager.files?.map { $0.url.lastPathComponent }, [ordinaryName])
            let stagingReaderURL = try await f.manager.readerFileURL(
                for: f.library.appendingPathComponent(stagingName)
            )
            let staging = ContentFile()
            staging.url = try XCTUnwrap(stagingReaderURL)
            staging.updateCompoundKey()
            let stagingRecordName = ContentFile.className() + "." + staging.compoundKey
            XCTAssertNil(f.realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: stagingRecordName))
            // A later complete scan must not have invented a tombstone for a
            // transient item: it must never have acquired a ContentFile at all.
            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            XCTAssertEqual(f.realm.objects(ContentFile.self).count, 1)
            XCTAssertFalse(try XCTUnwrap(records.first).isDeleted)
        }
    }

    func testOrdinaryInvalidationDuringHeldEnumerationFindsLateFile() async throws {
        let enumeration = LibraryBoundaryEnumeration()
        let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
                                        directoryContentsProvider: { try await enumeration.read($0) })
        try await withFixture(manager: manager) { f in
            let first = Task { @MainActor in try await manager.refreshAllFilesMetadata() }
            await enumeration.entered.wait()
            do {
                try self.write("arrived after snapshot", to: f.library.appendingPathComponent("late.txt"))
            } catch {
                await enumeration.release.open()
                _ = try? await first.value
                throw error
            }
            let admitted = self.expectation(description: "ordinary refresh caller admitted")
            let late = Task { @MainActor in
                admitted.fulfill()
                try await manager.refreshAllFilesMetadata()
            }
            let outcome = await XCTWaiter.fulfillment(of: [admitted], timeout: 5)
            XCTAssertEqual(outcome, .completed)
            await enumeration.release.open()
            try await first.value
            try await late.value
            XCTAssertEqual(manager.files?.map { $0.url.lastPathComponent }, ["late.txt"])
        }
    }

    func testOrdinaryRefreshAfterCompletedScanObservesDeletion() async throws {
        try await withFixture { f in
            let url = f.library.appendingPathComponent("removed.txt")
            try self.write("book", to: url)
            try await f.manager.refreshAllFilesMetadata()
            let record = try XCTUnwrap(f.manager.files?.first)
            try FileManager.default.removeItem(at: url)
            // No forced refresh and no second external event to rescue this.
            try await f.manager.refreshAllFilesMetadata()
            f.realm.refresh()
            XCTAssertTrue(record.isDeleted)
            XCTAssertTrue(f.manager.files?.isEmpty == true)
            XCTAssertFalse(f.realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }
}


@MainActor
extension ReaderFileLibraryBoundaryTests {
    private func indexedDeletionRecord(_ f: Fixture, name: String = "delete.txt") throws -> ContentFile {
        let record = ContentFile()
        record.url = try XCTUnwrap(URL(string: "reader-file://file/load/local/" + name))
        record.updateCompoundKey()
        try f.realm.write {
            f.realm.add(record)
            record.refreshChangeMetadata(explicitlyModified: true)
        }
        f.manager.files = [record]
        return record
    }

    private func journalGeneration(_ f: Fixture, record: ContentFile) throws -> String {
        try XCTUnwrap(f.realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: ContentFile.className() + "." + record.compoundKey)).generation
    }

    func testDeleteCannotRetargetAReplacementDriveAfterAvailability() async throws {
        try await withFixture { f in
            let originalURL = f.library.appendingPathComponent("delete.txt")
            try self.write("original bytes", to: originalURL)
            let replacementRoot = f.root.appendingPathComponent("replacement", isDirectory: true)
            let replacement = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
            let replacementURL = replacementRoot.appendingPathComponent("delete.txt")
            try self.write("replacement bytes", to: replacementURL)
            let record = try self.indexedDeletionRecord(f)
            let generation = try self.journalGeneration(f, record: record)
            do {
                try await f.manager.delete(readerFileURL: record.url, statusLoader: { url in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    f.manager.localDrive = replacement
                    return status
                })
                XCTFail("A stale deletion must not follow the replacement drive")
            } catch ReaderFileDeleteError.removeFailed { }
            f.realm.refresh()
            XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "original bytes")
            XCTAssertEqual(try String(contentsOf: replacementURL, encoding: .utf8), "replacement bytes")
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(try self.journalGeneration(f, record: record), generation)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [record.compoundKey])
        }
    }

    func testMissingFileOutcomeCannotDeleteReplacementDriveIndex() async throws {
        try await withFixture { f in
            let replacementRoot = f.root.appendingPathComponent("replacement", isDirectory: true)
            let replacement = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
            let replacementURL = replacementRoot.appendingPathComponent("delete.txt")
            try self.write("replacement bytes", to: replacementURL)
            let record = try self.indexedDeletionRecord(f)
            let generation = try self.journalGeneration(f, record: record)
            do {
                try await f.manager.delete(readerFileURL: record.url, statusLoader: { url in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    XCTAssertEqual(status, .fileMissing)
                    f.manager.localDrive = replacement
                    return status
                })
                XCTFail("Old-root absence cannot authorize a new-root tombstone")
            } catch ReaderFileDeleteError.removeFailed { }
            f.realm.refresh()
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(try self.journalGeneration(f, record: record), generation)
            XCTAssertEqual(try String(contentsOf: replacementURL, encoding: .utf8), "replacement bytes")
        }
    }

    func testMissingFileOutcomeCannotTombstoneAReappearedPayload() async throws {
        try await withFixture { f in
            let url = f.library.appendingPathComponent("delete.txt")
            let record = try self.indexedDeletionRecord(f)
            let generation = try self.journalGeneration(f, record: record)
            do {
                try await f.manager.delete(readerFileURL: record.url, statusLoader: { backing in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                    XCTAssertEqual(status, .fileMissing)
                    try self.write("newly imported bytes", to: url)
                    return status
                })
                XCTFail("Absence must still hold when the index write is admitted")
            } catch ReaderFileDeleteError.removeFailed { }
            f.realm.refresh()
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(try self.journalGeneration(f, record: record), generation)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "newly imported bytes")
        }
    }

    func testCancelledAvailabilityCannotDeleteOrJournalAFile() async throws {
        try await withFixture { f in
            let url = f.library.appendingPathComponent("delete.txt")
            try self.write("original bytes", to: url)
            let record = try self.indexedDeletionRecord(f)
            let generation = try self.journalGeneration(f, record: record)
            let deletion = Task { @MainActor in
                try await f.manager.delete(readerFileURL: record.url, statusLoader: { backing in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return status
                })
            }
            do { try await deletion.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            f.realm.refresh()
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(try self.journalGeneration(f, record: record), generation)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original bytes")
        }
    }

    func testCurrentFileDeletionAndRepeatedMissingDeleteKeepTruthfulJournals() async throws {
        try await withFixture { f in
            let url = f.library.appendingPathComponent("delete.txt")
            try self.write("original bytes", to: url)
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let initial = try self.journalGeneration(f, record: record)
            let package = ContentPackageFile()
            package.url = try XCTUnwrap(URL(string: "reader-file://file/load/local/delete.txt?entry=1"))
            package.packageContentFileID = record.compoundKey
            package.updateCompoundKey()
            try f.realm.write {
                f.realm.add(package)
                package.refreshChangeMetadata(explicitlyModified: true)
            }
            try await f.manager.delete(readerFileURL: backing)
            await f.manager.inventoryRefreshQueue?.waitForIdle()
            f.realm.refresh()
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(record.isDeleted)
            XCTAssertTrue(package.isDeleted)
            XCTAssertEqual(record.modifiedAt, package.modifiedAt)
            let committed = try self.journalGeneration(f, record: record)
            XCTAssertNotEqual(committed, initial)
            try await f.manager.delete(readerFileURL: backing)
            await f.manager.inventoryRefreshQueue?.waitForIdle()
            f.realm.refresh()
            XCTAssertEqual(try self.journalGeneration(f, record: record), committed)
        }
    }

    private struct RefreshRecordSnapshot: Equatable {
        let url: URL
        let title: String
        let isDeleted: Bool
        let modifiedAt: Date
        let fileMetadataRefreshedAt: Date?
    }

    private struct RefreshStorageSnapshot: Equatable {
        let records: [String: RefreshRecordSnapshot]
        let journals: [String: String]
    }

    private func refreshStorageSnapshot(_ realm: Realm) -> RefreshStorageSnapshot {
        realm.refresh()
        return RefreshStorageSnapshot(
            records: Dictionary(uniqueKeysWithValues: realm.objects(ContentFile.self).map {
                ($0.compoundKey, RefreshRecordSnapshot(url: $0.url, title: $0.title,
                    isDeleted: $0.isDeleted, modifiedAt: $0.modifiedAt,
                    fileMetadataRefreshedAt: $0.fileMetadataRefreshedAt))
            }),
            journals: Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
                ($0.recordName, $0.generation)
            })
        )
    }

    private func seedRefreshRecord(_ name: String, in realm: Realm) async throws -> ContentFile {
        let file = ContentFile()
        file.url = try XCTUnwrap(URL(string: "reader-file://file/load/local/\(name).txt"))
        file.title = name
        file.updateCompoundKey()
        try await realm.asyncWritePreservingOwnership {
            realm.add(file)
            file.refreshChangeMetadata(explicitlyModified: true)
        }
        return file
    }

    private func requireStaleRefreshCancellation(_ task: Task<Void, Swift.Error>) async throws {
        do {
            try await task.value
            XCTFail("The stale inventory producer must fail instead of publishing replacement storage")
        } catch is CancellationError {
        }
    }

    func testSuspendedInventoryScanCannotMutateOrPublishAfterDriveReplacement() async throws {
        let enumeration = LibraryBoundaryEnumeration()
        let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
            directoryContentsProvider: { try await enumeration.read($0) })
        try await withFixture(manager: manager) { f in
            try self.write("stale discovered bytes", to: f.library.appendingPathComponent("discovered.txt"))
            let orphan = try await self.seedRefreshRecord("old-orphan", in: f.realm)
            let replacement = try await self.seedRefreshRecord("replacement", in: f.realm)
            f.manager.files = [replacement]
            let before = self.refreshStorageSnapshot(f.realm)
            let old = Task { @MainActor in try await f.manager.refreshAllFilesMetadata(force: true) }
            await enumeration.entered.wait()
            let replacementRoot = f.root.appendingPathComponent("replacement-library", isDirectory: true)
            do {
                f.manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
            } catch {
                await enumeration.release.open()
                _ = try? await old.value
                throw error
            }
            await enumeration.release.open()
            try await self.requireStaleRefreshCancellation(old)
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before,
                           "Neither discovered metadata nor old orphan tombstones may commit")
            XCTAssertFalse(orphan.isDeleted)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [replacement.compoundKey])
        }
    }

    func testSuspendedInventoryScanCannotMutateEitherRealmAfterConfigurationReplacement() async throws {
        let enumeration = LibraryBoundaryEnumeration()
        let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
            directoryContentsProvider: { try await enumeration.read($0) })
        try await withFixture(manager: manager) { f in
            try self.write("stale discovered bytes", to: f.library.appendingPathComponent("discovered.txt"))
            _ = try await self.seedRefreshRecord("old-orphan", in: f.realm)
            var configuration = f.configuration
            configuration.inMemoryIdentifier = "replacement-" + UUID().uuidString
            BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
            let replacementRealm = try await Realm(configuration: configuration, actor: MainActor.shared)
            let replacement = try await self.seedRefreshRecord("replacement", in: replacementRealm)
            let oldBefore = self.refreshStorageSnapshot(f.realm)
            let replacementBefore = self.refreshStorageSnapshot(replacementRealm)
            let old = Task { @MainActor in try await f.manager.refreshAllFilesMetadata(force: true) }
            await enumeration.entered.wait()
            f.manager.historyRealmConfigurationOverride = configuration
            f.manager.files = [replacement]
            await enumeration.release.open()
            do {
                try await self.requireStaleRefreshCancellation(old)
                XCTAssertEqual(self.refreshStorageSnapshot(f.realm), oldBefore)
                XCTAssertEqual(self.refreshStorageSnapshot(replacementRealm), replacementBefore)
                XCTAssertEqual(f.manager.files?.map(\.compoundKey), [replacement.compoundKey])
            } catch {
                await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
                throw error
            }
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
    }

    func testNewInitializationRevokesSuspendedScanEvenWhenPreparationFails() async throws {
        let enumeration = LibraryBoundaryEnumeration()
        let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
            directoryContentsProvider: { try await enumeration.read($0) },
            cloudDriveFactory: { _ in throw ReaderFileManagerError.driveMissing },
            localDriveFactory: { throw ReaderFileManagerError.driveMissing })
        try await withFixture(manager: manager) { f in
            let installedDrive = f.manager.localDrive
            try self.write("stale discovered bytes", to: f.library.appendingPathComponent("discovered.txt"))
            let replacement = try await self.seedRefreshRecord("replacement", in: f.realm)
            f.manager.files = [replacement]
            let before = self.refreshStorageSnapshot(f.realm)
            let old = Task { @MainActor in try await f.manager.refreshAllFilesMetadata(force: true) }
            await enumeration.entered.wait()
            do {
                try await f.manager.initialize(ubiquityContainerIdentifier: "new-failed")
                XCTFail("Expected factory failure after the newer initializer acquired its identity")
            } catch ReaderFileManagerError.driveMissing {
            } catch {
                await enumeration.release.open()
                _ = try? await old.value
                throw error
            }
            await enumeration.release.open()
            try await self.requireStaleRefreshCancellation(old)
            XCTAssertTrue(f.manager.localDrive === installedDrive)
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [replacement.compoundKey])
            try await f.manager.refreshAllFilesMetadata(force: true)
            XCTAssertTrue(f.manager.files?.contains { $0.url.lastPathComponent == "discovered.txt" } == true,
                          "A fresh request under the current identity remains usable")
        }
    }


}
