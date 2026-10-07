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

    func testDownloadAdmissionRejectsEncodedSeparatorsBeforeCreatingAResourceSlot() async throws {
        try await withFixture { f in
            for component in ["a%2Fb.epub", "a%2fb.epub", "a%5Cb.epub", "a%00b.epub", "%2e%2e"] {
                do {
                    _ = try await self.download("https://example.com/" + component, manager: f.manager)
                    XCTFail("Malformed basename must not be admitted: " + component)
                } catch let error as CocoaError {
                    XCTAssertEqual(error.code, .fileWriteInvalidFileName)
                }
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.library.path).isEmpty)
            XCTAssertTrue(f.realm.objects(ContentFile.self).isEmpty)
            XCTAssertTrue(f.realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testDownloadAdmissionPreservesUnicodeAndLiteralPercentNames() async throws {
        try await withFixture { f in
            for (component, expected) in [("吾輩は猫である.epub", "吾輩は猫である.epub"),
                                          ("a%252Fb.epub", "a%2Fb.epub"),
                                          ("100%25.epub", "100%.epub")] {
                let downloadable = try await self.download("https://example.com/books/" + component, manager: f.manager)
                XCTAssertEqual(downloadable.localDestination.lastPathComponent, expected)
                XCTAssertEqual(downloadable.localDestination.deletingLastPathComponent().deletingLastPathComponent(),
                               f.library.appendingPathComponent(ReaderFileStoragePaths.downloadsDirectory, isDirectory: true))
            }
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

// MARK: Storage delivery follow-up (2026-10-05)
// These methods extend the existing native owner file and require the actual
// Apple/Realm/SwiftCloudDrive graph. They are authored, not native-qualified.
@MainActor
private final class StorageDeliveryCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@MainActor
private final class StorageDeliveryReplacement {
    private let manager: ReaderFileManager
    private let drive: CloudDrive
    init(manager: ReaderFileManager, drive: CloudDrive) {
        self.manager = manager
        self.drive = drive
    }
    func install() { manager.localDrive = drive }
}

@MainActor
extension ReaderFileLibraryBoundaryTests {
    func testReadCannotSelectReplacementDriveAfterAvailabilityReturnsMissingPath() async throws {
        try await withFixture { f in
            let source = f.library.appendingPathComponent("read.txt")
            try self.write("original", to: source)
            let replacementRoot = f.root.appendingPathComponent("replacement", isDirectory: true)
            let replacement = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
            try self.write("replacement", to: replacementRoot.appendingPathComponent("read.txt"))
            let backing = try XCTUnwrap(URL(string: "reader-file://file/load/local/read.txt"))
            var localReads = 0
            do {
                _ = try await f.manager.read(fileURL: backing, resolveReadableURL: { url in
                    _ = try await f.manager.resolveReadableLocalURL(forReaderBackingURL: url)
                    f.manager.localDrive = replacement
                    return f.root.appendingPathComponent("missing-readable-result")
                }, readLocalFile: { _ in localReads += 1; return nil })
                XCTFail("Old availability must not select replacement bytes")
            } catch is CancellationError { }
            XCTAssertEqual(localReads, 0)
            XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
            XCTAssertEqual(try Data(contentsOf: replacementRoot.appendingPathComponent("read.txt")), Data("replacement".utf8))
        }
    }

    func testReadRejectsReplacementDuringCoordinatedPayloadDelivery() async throws {
        try await withFixture { f in
            let source = f.library.appendingPathComponent("read.txt")
            try self.write("original", to: source)
            let replacement = try await CloudDrive(storage: .localDirectory(
                rootURL: f.root.appendingPathComponent("replacement", isDirectory: true)))
            let backing = try XCTUnwrap(URL(string: "reader-file://file/load/local/read.txt"))
            do {
                _ = try await f.manager.read(fileURL: backing, resolveReadableURL: { _ in source },
                    readLocalFile: { url in
                        let bytes = try Data(contentsOf: url)
                        f.manager.localDrive = replacement
                        return bytes
                    })
                XCTFail("Read delivery must retain its original installed drive")
            } catch is CancellationError { }
        }
    }

    func testReadCancellationBeforeEntryDoesNotInvokeAvailability() async throws {
        try await withFixture { f in
            let backing = try XCTUnwrap(URL(string: "reader-file://file/load/local/read.txt"))
            var calls = 0
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.manager.read(fileURL: backing, resolveReadableURL: { _ in
                    calls += 1
                    return f.library.appendingPathComponent("read.txt")
                }, readLocalFile: { _ in XCTFail("Cancelled read cannot perform I/O"); return nil })
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            XCTAssertEqual(calls, 0)
        }
    }

    func testReadCancellationAfterAvailabilityDoesNotReadFile() async throws {
        try await withFixture { f in
            let source = f.library.appendingPathComponent("read.txt")
            try self.write("original", to: source)
            let backing = try XCTUnwrap(URL(string: "reader-file://file/load/local/read.txt"))
            var calls = 0
            let task = Task { @MainActor in
                try await f.manager.read(fileURL: backing, resolveReadableURL: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return source
                }, readLocalFile: { _ in calls += 1; return Data() })
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            XCTAssertEqual(calls, 0)
        }
    }

    func testReadRejectsNewInitializationEvenWhenInstalledDriveIsUnchanged() async throws {
        let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
            directoryContentsProvider: { _ in [] },
            cloudDriveFactory: { _ in throw ReaderFileManagerError.driveMissing },
            localDriveFactory: { throw ReaderFileManagerError.driveMissing })
        try await withFixture(manager: manager) { f in
            let source = f.library.appendingPathComponent("read.txt")
            try self.write("original", to: source)
            let installed = manager.localDrive
            let backing = try XCTUnwrap(URL(string: "reader-file://file/load/local/read.txt"))
            do {
                _ = try await manager.read(fileURL: backing, resolveReadableURL: { _ in
                    do { try await manager.initialize(ubiquityContainerIdentifier: "replacement-fails") }
                    catch ReaderFileManagerError.driveMissing { }
                    return source
                }, readLocalFile: { _ in XCTFail("Old read cannot acquire a new initialization"); return nil })
                XCTFail("Expected original initialization to expire")
            } catch is CancellationError { }
            XCTAssertTrue(manager.localDrive === installed)
        }
    }

    func testCurrentReadFallbackUsesTheOriginalDriveAndPreservesPayload() async throws {
        try await withFixture { f in
            let source = f.library.appendingPathComponent("read.txt")
            try self.write("original", to: source)
            let backing = try XCTUnwrap(URL(string: "reader-file://file/load/local/read.txt"))
            let bytes = try await f.manager.read(fileURL: backing, resolveReadableURL: { _ in
                f.root.appendingPathComponent("missing-readable-result")
            }, readLocalFile: { _ in XCTFail("Expected captured-drive fallback"); return nil })
            XCTAssertEqual(bytes, Data("original".utf8))
            let normal = try await f.manager.read(fileURL: backing)
            XCTAssertEqual(normal, bytes)
        }
    }

    func testDiscoveredPublicationRejectsDriveReplacementDuringActualRealmOpen() async throws {
        try await withFixture { f in
            let incoming = try await self.seedRefreshRecord("incoming", in: f.realm)
            let keep = try await self.seedRefreshRecord("keep", in: f.realm)
            f.manager.files = [keep]
            let before = self.refreshStorageSnapshot(f.realm)
            let reference = ThreadSafeReference(to: incoming)
            let replacement = try await CloudDrive(storage: .localDirectory(
                rootURL: f.root.appendingPathComponent("replacement", isDirectory: true)))
            do {
                try await f.manager.publishDiscoveredFiles([reference], realmConfiguration: f.configuration,
                    openRealm: { configuration in
                        let realm = try await Realm.open(configuration: configuration)
                        f.manager.localDrive = replacement
                        return realm
                    })
                XCTFail("Old publication cannot replace current list")
            } catch is CancellationError { }
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [keep.compoundKey])
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
        }
    }

    func testDiscoveredPublicationRejectsCancelledRealmOpenWithoutJournalChanges() async throws {
        try await withFixture { f in
            let row = try await self.seedRefreshRecord("incoming", in: f.realm)
            let reference = ThreadSafeReference(to: row)
            let before = self.refreshStorageSnapshot(f.realm)
            let task = Task { @MainActor in
                try await f.manager.publishDiscoveredFiles([reference], realmConfiguration: f.configuration,
                    openRealm: { configuration in
                        let realm = try await Realm.open(configuration: configuration)
                        withUnsafeCurrentTask { $0?.cancel() }
                        return realm
                    })
            }
            do { try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertNil(f.manager.files)
        }
    }

    func testDiscoveredPublicationRejectsWrongOpenedRealmBeforeReferenceResolution() async throws {
        try await withFixture { f in
            let row = try await self.seedRefreshRecord("incoming", in: f.realm)
            let reference = ThreadSafeReference(to: row)
            var configuration = f.configuration
            configuration.inMemoryIdentifier = UUID().uuidString
            let wrong = try await Realm(configuration: configuration, actor: MainActor.shared)
            do {
                try await f.manager.publishDiscoveredFiles([reference], realmConfiguration: f.configuration,
                    openRealm: { _ in wrong })
                XCTFail("A different Realm cannot consume the retained reference")
            } catch is CancellationError { }
            XCTAssertTrue(wrong.objects(ContentFile.self).isEmpty)
            XCTAssertNil(f.manager.files)
        }
    }

    func testDiscoveredPublicationDropsInvalidatedAndForeignRetainedRows() async throws {
        try await withFixture { f in
            let incoming = try await self.seedRefreshRecord("incoming", in: f.realm)
            let dead = try await self.seedRefreshRecord("dead", in: f.realm)
            var configuration = f.configuration
            configuration.inMemoryIdentifier = UUID().uuidString
            BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
            let foreignRealm = try await Realm(configuration: configuration, actor: MainActor.shared)
            let foreign = try await self.seedRefreshRecord("foreign", in: foreignRealm)
            f.manager.files = [dead, foreign]
            // This fixture deliberately invalidates an accessor; production
            // deletion remains a separately journaled soft mutation.
            try f.realm.write { f.realm.delete(dead) }
            XCTAssertTrue(dead.isInvalidated)
            let before = self.refreshStorageSnapshot(f.realm)
            let foreignBefore = self.refreshStorageSnapshot(foreignRealm)
            try await f.manager.publishDiscoveredFiles([ThreadSafeReference(to: incoming)],
                realmConfiguration: f.configuration)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [incoming.compoundKey])
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertEqual(self.refreshStorageSnapshot(foreignRealm), foreignBefore)
        }
    }

    func testCurrentDiscoveredPublicationPreservesOtherRowsAndDeduplicatesURL() async throws {
        try await withFixture { f in
            let row = try await self.seedRefreshRecord("incoming", in: f.realm)
            let keep = try await self.seedRefreshRecord("keep", in: f.realm)
            f.manager.files = [row, keep]
            let before = self.refreshStorageSnapshot(f.realm)
            try await f.manager.publishDiscoveredFiles([ThreadSafeReference(to: row)], realmConfiguration: f.configuration)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [row.compoundKey, keep.compoundKey])
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
        }
    }

    func testCancelledEmptyDiscoveredPublicationDoesNotInvokeRealmOpener() async throws {
        try await withFixture { f in
            var calls = 0
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                try await f.manager.publishDiscoveredFiles([], realmConfiguration: f.configuration,
                    openRealm: { _ in calls += 1; return f.realm })
            }
            do { try await task.value; XCTFail("Empty cancelled work is not successful publication") }
            catch is CancellationError { }
            XCTAssertEqual(calls, 0)
        }
    }

    func testEnsureImportedCannotAdoptNewDriveAfterDownloadExistenceRead() async throws {
        try await withFixture { f in
            let downloadable = try await self.download("https://example.test/book.txt", manager: f.manager)
            try self.write("original download", to: downloadable.localDestination)
            let replacementRoot = f.root.appendingPathComponent("replacement", isDirectory: true)
            let replacement = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
            let before = self.refreshStorageSnapshot(f.realm)
            do {
                _ = try await f.manager.ensureImported(downloadable: downloadable, existsLocally: { item in
                    let exists = await item.existsLocally()
                    XCTAssertTrue(exists)
                    f.manager.localDrive = replacement
                    return exists
                })
                XCTFail("A previous download cannot be adopted by new storage")
            } catch is CancellationError { }
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertEqual(try Data(contentsOf: downloadable.localDestination), Data("original download".utf8))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: replacementRoot.path).isEmpty)
        }
    }

    func testImportRevokedDuringDestinationSelectionDoesNotCreateOrCopy() async throws {
        try await withFixture { f in
            let source = f.root.appendingPathComponent("outside.txt")
            try self.write("retained", to: source)
            let replacement = try await CloudDrive(storage: .localDirectory(
                rootURL: f.root.appendingPathComponent("replacement", isDirectory: true)))
            let action = StorageDeliveryReplacement(manager: f.manager, drive: replacement)
            ReaderFileManager.fileDestinationProcessors = [{ @Sendable _ in
                await action.install()
                return RootRelativePath(path: "should-not-exist")
            }]
            let before = self.refreshStorageSnapshot(f.realm)
            do {
                _ = try await f.manager.importFile(fileURL: source, fromDownloadURL: nil)
                XCTFail("Destination lookup cannot renew the import's owner")
            } catch is CancellationError { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.library.appendingPathComponent("should-not-exist").path))
            XCTAssertEqual(try Data(contentsOf: source), Data("retained".utf8))
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
        }
    }

    func testCancelledImportDoesNotInvokeDestinationProcessorsOrCreateFiles() async throws {
        try await withFixture { f in
            let source = f.root.appendingPathComponent("outside.txt")
            try self.write("retained", to: source)
            let calls = StorageDeliveryCounter()
            ReaderFileManager.fileDestinationProcessors = [{ @Sendable _ in
                await calls.increment()
                return RootRelativePath(path: "should-not-exist")
            }]
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.manager.importFile(fileURL: source, fromDownloadURL: nil)
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            XCTAssertEqual(calls.value, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.library.appendingPathComponent("should-not-exist").path))
            XCTAssertEqual(try Data(contentsOf: source), Data("retained".utf8))
        }
    }

    func testDownloadDescriptorCannotOutliveItsDestinationSelection() async throws {
        try await withFixture { f in
            let replacement = try await CloudDrive(storage: .localDirectory(
                rootURL: f.root.appendingPathComponent("replacement", isDirectory: true)))
            let action = StorageDeliveryReplacement(manager: f.manager, drive: replacement)
            ReaderFileManager.fileDestinationProcessors = [{ @Sendable _ in
                await action.install()
                return .root
            }]
            do {
                _ = try await f.manager.downloadable(url: URL(string: "https://example.test/book.txt")!, name: "Book")
                XCTFail("Descriptor must retain the original destination owner")
            } catch is CancellationError { }
        }
    }

    func testDeniedFileInspectionCannotAuthorizeMissingFileTombstone() async throws {
        try await withFixture { f in
            let parent = f.library.appendingPathComponent("locked", isDirectory: true)
            let payload = parent.appendingPathComponent("book.txt")
            try self.write("must survive", to: payload)
            let row = ContentFile()
            row.url = URL(string: "reader-file://file/load/local/locked/book.txt")!
            row.updateCompoundKey()
            try await f.realm.asyncWritePreservingOwnership {
                f.realm.add(row)
                row.refreshChangeMetadata(explicitlyModified: true)
            }
            f.manager.files = [row]
            let before = self.refreshStorageSnapshot(f.realm)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: parent.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
            let inspectionDenied: Bool
            do { _ = try FileManager.default.attributesOfItem(atPath: payload.path); inspectionDenied = false }
            catch { inspectionDenied = true }
            guard inspectionDenied else {
                throw XCTSkip("This permission history requires a non-root test process with enforced mode000 access.")
            }
            do {
                try await f.manager.delete(readerFileURL: row.url)
                XCTFail("Uninspectable is not missing")
            } catch {
                XCTAssertFalse(error is CancellationError, "The fixture must reach filesystem admission, not task cancellation")
            }
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertFalse(row.isDeleted)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [row.compoundKey])
        }
    }

    func testLocalReadDoesNotInspectUnselectedInaccessibleCloudRoot() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try self.write("local", to: payload)
            let cloudRoot = f.root.appendingPathComponent("unselected", isDirectory: true)
            let cloud = try await CloudDrive(storage: .localDirectory(rootURL: cloudRoot))
            f.manager.cloudDrive = cloud
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloudRoot.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cloudRoot.path) }
            let value = try await f.manager.read(fileURL: URL(string: "reader-file://file/load/local/book.txt")!)
            XCTAssertEqual(value, Data("local".utf8))
        }
    }
}

// MARK: Original deletion admission (2026-10-06)
// Real manager, filesystem, Realm and mutation journal; status is the existing
// asynchronous seam. No production account or externally supplied file is used.
@MainActor
extension ReaderFileLibraryBoundaryTests {
    private func checkDeletionRealmReplacement(missing: Bool) async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            if !missing { try self.write("original bytes", to: payload) }
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let before = self.refreshStorageSnapshot(f.realm)
            var configuration = f.configuration
            configuration.inMemoryIdentifier = "delete-successor-" + UUID().uuidString
            BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
            let successorRealm = try await Realm(configuration: configuration, actor: MainActor.shared)
            let successor = try await self.seedRefreshRecord("successor", in: successorRealm)
            let successorBefore = self.refreshStorageSnapshot(successorRealm)
            let originalDrive = f.manager.localDrive
            do {
                try await f.manager.delete(readerFileURL: backing, statusLoader: { url in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    XCTAssertEqual(status, missing ? .fileMissing : .localOnly)
                    f.manager.historyRealmConfigurationOverride = configuration
                    f.manager.files = [successor]
                    return status
                })
                XCTFail("The original Realm must still own deletion before physical removal or tombstones")
            } catch ReaderFileDeleteError.removeFailed { }
            XCTAssertTrue(f.manager.localDrive === originalDrive)
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertEqual(self.refreshStorageSnapshot(successorRealm), successorBefore)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [successor.compoundKey])
            XCTAssertFalse(record.isDeleted)
            if missing {
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: payload), Data("original bytes".utf8))
            }
        }
    }

    private func checkDeletionFailedInitialization(missing: Bool) async throws {
        let manager = ReaderFileManager(
            payloadStateProvider: { _ in .current },
            directoryContentsProvider: { _ in [] },
            cloudDriveFactory: { _ in throw ReaderFileManagerError.driveMissing },
            localDriveFactory: { throw ReaderFileManagerError.driveMissing }
        )
        try await withFixture(manager: manager) { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            if !missing { try self.write("original bytes", to: payload) }
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let before = self.refreshStorageSnapshot(f.realm)
            let originalDrive = manager.localDrive
            do {
                try await manager.delete(readerFileURL: backing, statusLoader: { url in
                    let status = try await manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    XCTAssertEqual(status, missing ? .fileMissing : .localOnly)
                    do {
                        try await manager.initialize(ubiquityContainerIdentifier: "replacement-fails")
                        XCTFail("Injected replacement preparation must fail")
                    } catch ReaderFileManagerError.driveMissing { }
                    return status
                })
                XCTFail("A newer initialization revokes the original delete even when drives are unchanged")
            } catch ReaderFileDeleteError.removeFailed { }
            XCTAssertTrue(manager.localDrive === originalDrive)
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertEqual(manager.files?.map(\.compoundKey), [record.compoundKey])
            XCTAssertFalse(record.isDeleted)
            if missing {
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: payload), Data("original bytes".utf8))
            }
        }
    }

    func testDeleteRejectsRealmReplacementBeforeRemovingPayload() async throws {
        try await checkDeletionRealmReplacement(missing: false)
    }

    func testMissingDeleteRejectsRealmReplacementBeforeTombstoning() async throws {
        try await checkDeletionRealmReplacement(missing: true)
    }

    func testDeleteRejectsFailedNewInitializationBeforeRemovingPayload() async throws {
        try await checkDeletionFailedInitialization(missing: false)
    }

    func testMissingDeleteRejectsFailedNewInitializationBeforeTombstoning() async throws {
        try await checkDeletionFailedInitialization(missing: true)
    }

    func testAlreadyCancelledInitializationLeavesCurrentDeleteAdmitted() async throws {
        let manager = ReaderFileManager(
            payloadStateProvider: { _ in .current },
            cloudDriveFactory: { _ in
                XCTFail("A cancelled entrant must not invoke the cloud factory")
                throw ReaderFileManagerError.driveMissing
            },
            localDriveFactory: {
                XCTFail("A cancelled entrant must not invoke the local factory")
                throw ReaderFileManagerError.driveMissing
            }
        )
        try await withFixture(manager: manager) { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            try self.write("current bytes", to: payload)
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let before = try self.journalGeneration(f, record: record)
            try await manager.delete(readerFileURL: backing, statusLoader: { url in
                let status = try await manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                let entrant = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await manager.initialize(ubiquityContainerIdentifier: "already-cancelled")
                }
                do { try await entrant.value; XCTFail("Expected cancelled entrant") }
                catch is CancellationError { }
                return status
            })
            f.realm.refresh()
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            XCTAssertTrue(record.isDeleted)
            XCTAssertNotEqual(try self.journalGeneration(f, record: record), before)
        }
    }

    func testLocalDeleteIgnoresReplacementOfUnselectedCloudDrive() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            try self.write("current bytes", to: payload)
            let cloudRoot = f.root.appendingPathComponent("unselected-cloud", isDirectory: true)
            let replacement = try await CloudDrive(storage: .localDirectory(rootURL: cloudRoot))
            let cloudPayload = cloudRoot.appendingPathComponent("delete.txt")
            try self.write("unrelated bytes", to: cloudPayload)
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            try await f.manager.delete(readerFileURL: backing, statusLoader: { url in
                let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                f.manager.cloudDrive = replacement
                return status
            })
            f.realm.refresh()
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            XCTAssertTrue(record.isDeleted)
            XCTAssertEqual(try Data(contentsOf: cloudPayload), Data("unrelated bytes".utf8))
        }
    }
}

// MARK: Native coordinated removal admission
@MainActor
extension ReaderFileLibraryBoundaryTests {
    private func checkRealmReplacementAtRemovalAccessor(isDirectory: Bool) async throws {
        try await withFixture { f in
            let target = f.library.appendingPathComponent("delete.txt", isDirectory: isDirectory)
            let payload = isDirectory ? target.appendingPathComponent("book.txt") : target
            try self.write("original bytes", to: payload)
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let before = self.refreshStorageSnapshot(f.realm)
            var configuration = f.configuration
            configuration.inMemoryIdentifier = "accessor-successor-" + UUID().uuidString
            BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
            let successorRealm = try await Realm(configuration: configuration, actor: MainActor.shared)
            let successorBefore = self.refreshStorageSnapshot(successorRealm)
            let replacementConfiguration = configuration
            do {
                try await f.manager.delete(
                    readerFileURL: backing,
                    statusLoader: { url in
                        try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    },
                    beforeRemovalAdmission: {
                        // This runs inside the real native deletion accessor,
                        // after all earlier async inspection has completed.
                        f.manager.historyRealmConfigurationOverride = replacementConfiguration
                    }
                )
                XCTFail("Replacement at final native admission must preserve the selected payload")
            } catch ReaderFileDeleteError.removeFailed { }
            XCTAssertEqual(
                f.manager.historyRealmConfigurationOverride?.inMemoryIdentifier,
                replacementConfiguration.inMemoryIdentifier
            )
            XCTAssertEqual(try Data(contentsOf: payload), Data("original bytes".utf8))
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertEqual(self.refreshStorageSnapshot(successorRealm), successorBefore)
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [record.compoundKey])
        }
    }

    func testFileDeleteRejectsRealmReplacementInsideNativeRemovalAccessor() async throws {
        try await checkRealmReplacementAtRemovalAccessor(isDirectory: false)
    }

    func testDirectoryDeleteRejectsRealmReplacementInsideNativeRemovalAccessor() async throws {
        try await checkRealmReplacementAtRemovalAccessor(isDirectory: true)
    }

    func testDeleteCancellationInsideNativeRemovalAccessorPreservesPayloadAndJournal() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            try self.write("keep", to: payload)
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let before = self.refreshStorageSnapshot(f.realm)
            let task = Task {
                try await f.manager.delete(
                    readerFileURL: backing,
                    statusLoader: { url in
                        try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    },
                    beforeRemovalAdmission: {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                )
            }
            do { try await task.value; XCTFail("Expected final-accessor cancellation") }
            catch is CancellationError { }
            XCTAssertEqual(try Data(contentsOf: payload), Data("keep".utf8))
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertFalse(record.isDeleted)
        }
    }
}
