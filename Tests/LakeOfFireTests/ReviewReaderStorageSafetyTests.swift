import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

/// Real temporary roots and Realm writes; only filesystem observations are injected.
/// No production iCloud account, network transfer, or wall-clock sleep is required.
@MainActor
final class ReviewReaderStorageSafetyTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let local: URL
        let cloud: URL
        let manager: ReaderFileManager
        let configuration: Realm.Configuration
        let realm: Realm
    }

    private func withFixture(
        manager: ReaderFileManager = ReaderFileManager(),
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderStorageSafety-" + UUID().uuidString, isDirectory: true)
        let local = root.appendingPathComponent("local", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [ContentFile.self, ContentPackageFile.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: local))
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
        let fixture = Fixture(root: root, local: local, cloud: cloud,
                              manager: manager, configuration: configuration, realm: realm)
        do {
            try await body(fixture)
        } catch {
            // A delete may have queued its ordinary inventory refresh. Drain it
            // before removing roots or changing shared configuration.
            try? await manager.refreshAllFilesMetadata(force: true)
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            throw error
        }
        try await manager.refreshAllFilesMetadata(force: true)
        await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
    }

    private func backing(_ storage: String, _ path: String) -> URL {
        URL(string: "reader-file://file/load/\(storage)/\(path)")!
    }

    private func seed(_ url: URL, in realm: Realm) throws -> ContentFile {
        let file = ContentFile()
        file.url = url
        file.mimeType = "text/plain"
        file.title = "Retained title"
        file.updateCompoundKey()
        try realm.write { realm.add(file) }
        return file
    }

    func testMissingCloudReadNeverUsesSameNamedLocalPayload() async throws {
        try await withFixture { f in
            let local = f.local.appendingPathComponent("same.txt")
            try Data("unrelated local document".utf8).write(to: local)
            // Two local CloudDrive instances stand in for mounted roots. The URL
            // still selects the cloud root; no simulated iCloud identity is used.
            f.manager.cloudDrive = try await CloudDrive(storage: .localDirectory(rootURL: f.cloud))
            let cloudURL = self.backing("icloud", "same.txt")
            do {
                _ = try await f.manager.resolveReadableLocalURL(forReaderBackingURL: cloudURL)
                XCTFail("A missing cloud identity must not read an unrelated local file")
            } catch is ReaderFileAccessError { }
            XCTAssertEqual(try Data(contentsOf: local), Data("unrelated local document".utf8))
        }
    }

    func testDeletingMissingCloudRecordPreservesSameNamedLocalBytesAndRecord() async throws {
        try await withFixture { f in
            let local = f.local.appendingPathComponent("same.txt")
            let bytes = Data("local A is not cloud B".utf8)
            try bytes.write(to: local)
            f.manager.cloudDrive = try await CloudDrive(storage: .localDirectory(rootURL: f.cloud))
            let localRecord = try self.seed(self.backing("local", "same.txt"), in: f.realm)
            let cloudRecord = try self.seed(self.backing("icloud", "same.txt"), in: f.realm)
            try await f.manager.delete(readerFileURL: cloudRecord.url)
            f.realm.refresh()
            XCTAssertEqual(try Data(contentsOf: local), bytes)
            XCTAssertFalse(localRecord.isDeleted)
            XCTAssertTrue(cloudRecord.isDeleted)
        }
    }

    func testLocalOnlyInventoryRetainsUnknownCloudRecordsButPrunesRemovedLocalFile() async throws {
        try await withFixture { f in
            let cloud = try self.seed(self.backing("icloud", "retained.txt"), in: f.realm)
            let local = try self.seed(self.backing("local", "removed.txt"), in: f.realm)
            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            XCTAssertFalse(cloud.isDeleted)
            XCTAssertTrue(local.isDeleted)
            XCTAssertTrue(f.manager.files?.contains(where: { $0.compoundKey == cloud.compoundKey }) == true)
            XCTAssertFalse(f.realm.objects(BigSyncPendingMutation.self).contains(where: {
                $0.objectIdentifier == cloud.compoundKey
            }))
        }
    }

    func testInventoryActorSnapshotRetainsPresentFileAndPublishesOwnedCleanup() async throws {
        try await withFixture { f in
            try Data("present".utf8).write(
                to: f.local.appendingPathComponent("present.txt")
            )
            let present = try self.seed(
                self.backing("local", "present.txt"),
                in: f.realm
            )
            let missing = try self.seed(
                self.backing("local", "missing.txt"),
                in: f.realm
            )

            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()

            XCTAssertFalse(present.isDeleted)
            XCTAssertTrue(missing.isDeleted)
            XCTAssertEqual(
                f.manager.files?.map(\.compoundKey),
                [present.compoundKey]
            )

            // Exercise the healthy same-owner path again after cleanup. The
            // published inventory must remain a detached ID snapshot rather
            // than a Realm Results iterator crossing back to MainActor.
            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            XCTAssertFalse(present.isDeleted)
            XCTAssertTrue(missing.isDeleted)
            XCTAssertEqual(
                f.manager.files?.map(\.compoundKey),
                [present.compoundKey]
            )
        }
    }

    func testIncompleteDirectoryInventoryDoesNotPublishOrphanTombstones() async throws {
        let manager = ReaderFileManager(payloadStateProvider: { _ in .current }, directoryContentsProvider: { url in
            if url.lastPathComponent == "unavailable" { throw CocoaError(.fileNoSuchFile) }
            return try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .producesRelativePathURLs]
            )
        })
        try await withFixture(manager: manager) { f in
            try FileManager.default.createDirectory(
                at: f.local.appendingPathComponent("unavailable", isDirectory: true),
                withIntermediateDirectories: true
            )
            let retained = try self.seed(self.backing("local", "unavailable/book.txt"), in: f.realm)
            try await manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            XCTAssertFalse(retained.isDeleted)
            XCTAssertTrue(f.manager.files?.contains(where: { $0.compoundKey == retained.compoundKey }) == true)
            XCTAssertTrue(f.realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testUploadingReadablePayloadIsReadableWithoutLosingTransferStatus() async throws {
        let manager = ReaderFileManager(payloadStateProvider: { _ in .uploading })
        try await withFixture(manager: manager) { f in
            manager.cloudDrive = try await CloudDrive(storage: .localDirectory(rootURL: f.cloud))
            let expected = f.cloud.appendingPathComponent("upload.txt")
            try Data("ready".utf8).write(to: expected)
            let url = self.backing("icloud", "upload.txt")
            let status = try await manager.cloudDriveSyncStatus(forReaderBackingURL: url)
            let readable = try await manager.resolveReadableLocalURL(forReaderBackingURL: url)
            XCTAssertEqual(status, .uploading)
            XCTAssertEqual(readable.standardizedFileURL, expected.standardizedFileURL)
        }
    }

    func testUploadingComponentDoesNotMakeAnIncompletePackageReadable() async throws {
        let manager = ReaderFileManager(payloadStateProvider: { url in
            url.lastPathComponent == "missing.xhtml" ? .notLocal : .uploading
        })
        try await withFixture(manager: manager) { f in
            manager.cloudDrive = try await CloudDrive(storage: .localDirectory(rootURL: f.cloud))
            let package = f.cloud.appendingPathComponent("partial.epub", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("upload".utf8).write(to: package.appendingPathComponent("ready.xhtml"))
            try Data().write(to: package.appendingPathComponent("missing.xhtml"))
            let url = URL(string: "ebook://ebook/load/icloud/partial.epub")!
            do {
                _ = try await manager.resolveReadableLocalURL(forReaderBackingURL: url)
                XCTFail("A uploading sibling cannot supply missing package bytes")
            } catch is ReaderFileAccessError { }
            let status = try await manager.cloudDriveSyncStatus(forReaderBackingURL: url)
            XCTAssertNotEqual(status, .uploading)
            XCTAssertNotEqual(status, .availableLocally)
        }
    }

    @MainActor
    private final class Availability {
        var value = CloudDriveSyncStatus.cloudOnly
    }

    func testDeferredEPUBEnrichmentRetriesWithoutAModificationTimeChange() async throws {
        try await withFixture { f in
            EbookFileManager.configure()
            let availability = Availability()
            ReaderFileManager.fileEnrichmentProcessors["epub"] = { files in
                try await EbookFileManager.enrichMetadata(files, status: { _ in availability.value })
            }
            let package = f.local.appendingPathComponent("book.epub", isDirectory: true)
            try self.writeEPUB(at: package)
            let modified = try FileManager.default.attributesOfItem(atPath: package.path)[.modificationDate] as? Date
            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            let file = try XCTUnwrap(f.realm.objects(ContentFile.self).first)
            XCTAssertNil(file.fileMetadataRefreshedAt)
            XCTAssertFalse(file.isPhysicalMedia)
            availability.value = .localOnly
            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            XCTAssertEqual(file.title, "Actual EPUB title")
            XCTAssertEqual(file.author, "Actual Author")
            XCTAssertTrue(file.isPhysicalMedia)
            XCTAssertNotNil(file.imageUrl)
            XCTAssertNotNil(file.fileMetadataRefreshedAt)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: package.path)[.modificationDate] as? Date, modified)
        }
    }

    func testFailedSpecializedProcessorDoesNotStampSuccess() async throws {
        try await withFixture { f in
            try Data("text".utf8).write(to: f.local.appendingPathComponent("book.txt"))
            ReaderFileManager.fileProcessors = [{ _ in throw CocoaError(.fileReadUnknown) }]
            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            let file = try XCTUnwrap(f.realm.objects(ContentFile.self).first)
            XCTAssertNil(file.fileMetadataRefreshedAt)
            ReaderFileManager.fileProcessors = []
            try await f.manager.refreshAllFilesMetadata(force: true)
            f.realm.refresh()
            XCTAssertNotNil(file.fileMetadataRefreshedAt)
            XCTAssertFalse(file.isDeleted)
        }
    }

    private func writeEPUB(at root: URL) throws {
        for path in ["META-INF", "OPS"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("""
        <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Actual EPUB title</dc:title><dc:creator>Actual Author</dc:creator><dc:date>2020-01-01T00:00:00Z</dc:date></metadata><manifest><item id="cover" href="cover.jpg" properties="cover-image" media-type="image/jpeg"/></manifest></package>
        """.utf8).write(to: root.appendingPathComponent("OPS/book.opf"))
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: root.appendingPathComponent("OPS/cover.jpg"))
    }
}
