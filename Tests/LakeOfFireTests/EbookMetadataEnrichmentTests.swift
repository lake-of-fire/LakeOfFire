import Foundation
import XCTest
import ZIPFoundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
import SwiftCloudDrive
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class EbookMetadataEnrichmentTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let manager: ReaderFileManager
        let configuration: Realm.Configuration
        let realm: Realm
    }

    @RealmBackgroundActor
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [ContentFile.self, ContentPackageFile.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        let realm = try await Realm(configuration: configuration, actor: RealmBackgroundActor.shared)
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: root))
        let oldManager = ReaderFileManager.shared
        let oldDestinations = ReaderFileManager.fileDestinationProcessors
        let oldURLs = ReaderFileManager.readerFileURLProcessors
        let oldProcessors = ReaderFileManager.fileProcessors
        let oldEnrichment = ReaderFileManager.fileEnrichmentProcessors
        ReaderFileManager.shared = manager
        ReaderFileManager.fileDestinationProcessors = []
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        ReaderFileManager.fileEnrichmentProcessors = [:]
        defer {
            ReaderFileManager.shared = oldManager
            ReaderFileManager.fileDestinationProcessors = oldDestinations
            ReaderFileManager.readerFileURLProcessors = oldURLs
            ReaderFileManager.fileProcessors = oldProcessors
            ReaderFileManager.fileEnrichmentProcessors = oldEnrichment
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = Fixture(root: root, manager: manager, configuration: configuration, realm: realm)
        do {
            try await body(fixture)
        } catch {
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            throw error
        }
        await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
    }

    @RealmBackgroundActor
    private func seed(_ name: String, in realm: Realm) async throws -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "ebook://ebook/load/local/\(name).epub")!
        file.title = "Before"
        file.mimeType = "application/epub+zip"
        file.updateCompoundKey()
        try await realm.asyncWrite { realm.add(file) }
        return file
    }

    @RealmBackgroundActor
    private func generation(_ file: ContentFile, in realm: Realm) -> String? {
        realm.objects(BigSyncPendingMutation.self).first(where: { $0.objectIdentifier == file.compoundKey })?.generation
    }

    @RealmBackgroundActor
    func testPreparedUpdateDoesNotOverwriteAnInterveningUserEdit() async throws {
        try await withFixture { f in
            let file = try await self.seed("edit", in: f.realm)
            var update = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
            update.desired.title = "Obsolete parsed title"
            update.desired.author = "Obsolete parsed author"
            update.desired.isPhysicalMedia = true
            try await f.realm.asyncWrite {
                file.title = "User edited title"
                file.author = "User edited author"
                file.refreshChangeMetadata(explicitlyModified: true)
            }
            let before = self.generation(file, in: f.realm)
            let deferred = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertEqual(deferred, [file.compoundKey])
            XCTAssertEqual(file.title, "User edited title")
            XCTAssertEqual(file.author, "User edited author")
            XCTAssertFalse(file.isPhysicalMedia)
            XCTAssertEqual(self.generation(file, in: f.realm), before)
        }
    }

    @RealmBackgroundActor
    func testSameClockChangedValueStillRejectsPreparedUpdate() async throws {
        try await withFixture { f in
            let file = try await self.seed("clock", in: f.realm)
            var update = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
            update.desired.title = "Obsolete"
            let timestamp = file.modifiedAt
            // Simulate an inbound value retaining the source clock, not a user
            // write that bypasses journaling. Clock equality is not value equality.
            try await f.realm.asyncWrite {
                file.author = "Incoming author"
                file.refreshChangeMetadata(explicitlyModified: false, at: timestamp)
            }
            let deferred = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertEqual(deferred, [file.compoundKey])
            XCTAssertEqual(file.title, "Before")
            XCTAssertEqual(file.author, "Incoming author")
            XCTAssertNil(self.generation(file, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testDeletionKeepsItsJournalGenerationAndRejectsOldMetadata() async throws {
        try await withFixture { f in
            let file = try await self.seed("deleted", in: f.realm)
            var update = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
            update.desired.title = "Obsolete"
            try await f.realm.asyncWrite {
                file.isDeleted = true
                file.refreshChangeMetadata(explicitlyModified: true)
            }
            let deletion = self.generation(file, in: f.realm)
            let deferred = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertEqual(deferred, [file.compoundKey])
            XCTAssertTrue(file.isDeleted)
            XCTAssertEqual(file.title, "Before")
            XCTAssertEqual(self.generation(file, in: f.realm), deletion)
        }
    }

    @RealmBackgroundActor
    func testHardDeletionAndRecreationCannotInheritPreparedMetadata() async throws {
        try await withFixture { f in
            let file = try await self.seed("recreated", in: f.realm)
            var update = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
            update.desired.title = "Obsolete"
            // Test-only simulation of reset/recreation; production deletion
            // remains a journaled soft delete.
            try await f.realm.asyncWrite { f.realm.delete(file) }
            let replacement = try await self.seed("recreated", in: f.realm)
            let deferred = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertEqual(deferred, [replacement.compoundKey])
            XCTAssertEqual(replacement.title, "Before")
            XCTAssertNil(self.generation(replacement, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testMixedRealmBatchWritesEachOwningRealm() async throws {
        try await withFixture { f in
            let first = try await self.seed("same", in: f.realm)
            var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
            configuration.objectTypes = [ContentFile.self, BigSyncPendingMutation.self]
            BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
            let otherRealm = try await Realm(configuration: configuration, actor: RealmBackgroundActor.shared)
            let second = try await self.seed("same", in: otherRealm)
            let timestamp = Date(timeIntervalSince1970: 1_000)
            try await EbookFileManager.applyMetadataUpdates(
                images: [], titles: [(first, "One"), (second, "Two")], authors: [],
                publicationDates: [], physicalMedia: [first, second], at: timestamp
            )
            XCTAssertEqual(first.title, "One")
            XCTAssertEqual(second.title, "Two")
            XCTAssertEqual(first.modifiedAt, timestamp)
            XCTAssertEqual(second.modifiedAt, timestamp)
            XCTAssertNotNil(self.generation(first, in: f.realm))
            XCTAssertNotNil(self.generation(second, in: otherRealm))
        }
    }

    @RealmBackgroundActor
    func testDifferentManagedWrappersMergeFieldsForTheSameRow() async throws {
        try await withFixture { f in
            let file = try await self.seed("wrappers", in: f.realm)
            let otherWrapper = try XCTUnwrap(f.realm.objects(ContentFile.self).first)
            try await EbookFileManager.applyMetadataUpdates(
                images: [], titles: [(file, "Title")], authors: [(otherWrapper, "Author")],
                publicationDates: [], physicalMedia: []
            )
            XCTAssertEqual(file.title, "Title")
            XCTAssertEqual(file.author, "Author")
            XCTAssertEqual(f.realm.objects(BigSyncPendingMutation.self).count, 1)
        }
    }

    @RealmBackgroundActor
    func testNoOpDoesNotCreateAJournalGeneration() async throws {
        try await withFixture { f in
            let file = try await self.seed("noop", in: f.realm)
            let update = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
            let deferred = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertTrue(deferred.isEmpty)
            XCTAssertNil(self.generation(file, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testCancelledBatchDoesNotCommitMetadataOrJournal() async throws {
        try await withFixture { f in
            let file = try await self.seed("cancelled", in: f.realm)
            var prepared = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
            prepared.desired.title = "Must not commit"
            let update = prepared
            let task = Task { @RealmBackgroundActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await EbookFileManager.applyPreparedMetadataUpdates([update])
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(file.title, "Before")
            XCTAssertNil(self.generation(file, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testAvailabilityCancellationPropagatesWithoutWriting() async throws {
        try await withFixture { f in
            let file = try await self.seed("availability", in: f.realm)
            do {
                _ = try await EbookFileManager.enrichMetadata([file], status: { _ in throw CancellationError() })
                XCTFail("Cancellation must not become a deferred/successful batch")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(file.title, "Before")
            XCTAssertNil(self.generation(file, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testLaterAvailabilityAwaitCannotOverwriteEarlierEditedBook() async throws {
        try await withFixture { f in
            try self.writeEPUB(at: f.root.appendingPathComponent("first.epub"))
            try self.writeEPUB(at: f.root.appendingPathComponent("second.epub"))
            let first = try await self.seed("first", in: f.realm)
            let second = try await self.seed("second", in: f.realm)
            let configuration = f.configuration
            let firstID = first.compoundKey
            let deferred = try await EbookFileManager.enrichMetadata([first, second], status: { url in
                if url.lastPathComponent == "second.epub" {
                    try await { @RealmBackgroundActor in
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                        let book = try XCTUnwrap(realm.object(ofType: ContentFile.self, forPrimaryKey: firstID))
                        try await realm.asyncWrite {
                            book.title = "Newer edit during later await"
                            book.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }()
                }
                return .localOnly
            })
            XCTAssertEqual(deferred, [firstID])
            XCTAssertEqual(first.title, "Newer edit during later await")
            XCTAssertFalse(first.isPhysicalMedia)
            XCTAssertEqual(second.title, "Coverless title")
            XCTAssertTrue(second.isPhysicalMedia)
        }
    }

    @RealmBackgroundActor
    func testCoverlessInventoryFinishesEnrichmentInsteadOfRetryingForever() async throws {
        try await withFixture { f in
            try self.writeEPUB(at: f.root.appendingPathComponent("coverless.epub"))
            EbookFileManager.configure()
            try await f.manager.refreshAllFilesMetadata(force: true)
            await f.realm.asyncRefresh()
            let file = try XCTUnwrap(f.realm.objects(ContentFile.self).first)
            XCTAssertEqual(file.title, "Coverless title")
            XCTAssertEqual(file.author, "Author")
            XCTAssertTrue(file.isPhysicalMedia)
            XCTAssertNil(file.imageUrl)
            XCTAssertNotNil(file.fileMetadataRefreshedAt)
            XCTAssertNotNil(self.generation(file, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testZIPAndDirectoryCoverRevisionTracksCompleteBytesAndPreservesIdenticalBytes() async throws {
        for packed in [false, true] {
            try await withFixture { f in
                let path = f.root.appendingPathComponent("cover.epub")
                // Equal-sized payloads differ only beyond the first read chunk.
                // The entry reader admits bytes; image decoding is a separate boundary.
                var firstBytes = Data(repeating: 0x41, count: 70_000)
                firstBytes.append(0x01)
                var secondBytes = firstBytes
                secondBytes[secondBytes.count - 1] = 0x02
                try self.writeCoveredEPUB(at: path, packed: packed, cover: firstBytes)
                let file = try await self.seed("cover", in: f.realm)
                let firstDeferred = try await EbookFileManager.enrichMetadata([file], status: { _ in .localOnly })
                XCTAssertTrue(firstDeferred.isEmpty)
                let firstURL = try XCTUnwrap(file.imageUrl)
                let firstComponents = try XCTUnwrap(URLComponents(url: firstURL, resolvingAgainstBaseURL: false))
                XCTAssertEqual(firstComponents.queryItems?.first(where: { $0.name == "subpath" })?.value, "Images/cover.jpg")
                XCTAssertEqual(firstComponents.queryItems?.first(where: { $0.name == "cover-revision" })?.value?.count, 64)

                try self.writeCoveredEPUB(at: path, packed: packed, cover: secondBytes)
                let secondDeferred = try await EbookFileManager.enrichMetadata([file], status: { _ in .localOnly })
                XCTAssertTrue(secondDeferred.isEmpty)
                let secondURL = try XCTUnwrap(file.imageUrl)
                XCTAssertNotEqual(firstURL, secondURL, "Changed cover bytes must change ReaderImage's request URL")
                XCTAssertEqual(firstURL.path, secondURL.path)
                let secondComponents = try XCTUnwrap(URLComponents(url: secondURL, resolvingAgainstBaseURL: false))
                XCTAssertEqual(secondComponents.queryItems?.first(where: { $0.name == "subpath" })?.value, "Images/cover.jpg")

                let generation = self.generation(file, in: f.realm)
                let modifiedAt = file.modifiedAt
                try self.writeCoveredEPUB(at: path, packed: packed, cover: secondBytes)
                let unchangedDeferred = try await EbookFileManager.enrichMetadata([file], status: { _ in .localOnly })
                XCTAssertTrue(unchangedDeferred.isEmpty)
                XCTAssertEqual(file.imageUrl, secondURL)
                XCTAssertEqual(file.modifiedAt, modifiedAt)
                XCTAssertEqual(self.generation(file, in: f.realm), generation)
            }
        }
    }

    @RealmBackgroundActor
    func testZIPAndDirectoryUnreadableOptionalCoverPreservesImageAndEnrichesMetadata() async throws {
        for packed in [false, true] {
            try await withFixture { f in
                try self.writeCoveredEPUB(at: f.root.appendingPathComponent("missing.epub"), packed: packed, cover: nil)
                let file = try await self.seed("missing", in: f.realm)
                let previousImage = URL(string: "reader-file://file/load/local/missing.epub?subpath=old.jpg")!
                try await EbookFileManager.applyMetadataUpdates(
                    images: [(file, previousImage)], titles: [], authors: [], publicationDates: [], physicalMedia: []
                )
                let deferred = try await EbookFileManager.enrichMetadata([file], status: { _ in .localOnly })
                XCTAssertTrue(deferred.isEmpty)
                XCTAssertEqual(file.title, "Covered title")
                XCTAssertEqual(file.author, "Cover author")
                XCTAssertTrue(file.isPhysicalMedia)
                XCTAssertEqual(file.imageUrl, previousImage)
            }
        }
    }

    @RealmBackgroundActor
    func testZIPAndDirectoryCancellationAfterCoverPreparationDoesNotPublishPartialMetadata() async throws {
        for packed in [false, true] {
            try await withFixture { f in
                try self.writeCoveredEPUB(at: f.root.appendingPathComponent("first.epub"), packed: packed, cover: Data([1, 2, 3]))
                try self.writeCoveredEPUB(at: f.root.appendingPathComponent("second.epub"), packed: packed, cover: Data([4, 5, 6]))
                let first = try await self.seed("first", in: f.realm)
                let second = try await self.seed("second", in: f.realm)
                let before = self.generation(first, in: f.realm)
                do {
                    _ = try await EbookFileManager.enrichMetadata([first, second], status: { url in
                        if url.lastPathComponent == "second.epub" { throw CancellationError() }
                        return .localOnly
                    })
                    XCTFail("Cancellation must not publish the earlier prepared cover or metadata")
                } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(first.title, "Before")
                XCTAssertEqual(first.author, "")
                XCTAssertNil(first.imageUrl)
                XCTAssertFalse(first.isPhysicalMedia)
                XCTAssertEqual(self.generation(first, in: f.realm), before)
                XCTAssertEqual(second.title, "Before")
                XCTAssertNil(second.imageUrl)
            }
        }
    }

    private func writeCoveredEPUB(at target: URL, packed: Bool, cover: Data?) throws {
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        let directory = packed
            ? target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            : target
        defer { if packed { try? FileManager.default.removeItem(at: directory) } }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8).write(to: directory.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0"><metadata><dc:title>Covered title</dc:title><dc:creator>Cover author</dc:creator></metadata><manifest><item id="cover" href="Images/cover.jpg" properties="cover-image" media-type="image/jpeg"/></manifest></package>
        """.utf8).write(to: directory.appendingPathComponent("book.opf"))
        if let cover { try cover.write(to: directory.appendingPathComponent("Images/cover.jpg")) }
        if packed {
            try FileManager.default.zipItem(at: directory, to: target, shouldKeepParent: false, compressionMethod: .deflate)
        }
    }

    private func writeEPUB(at root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0"><metadata><dc:title>Coverless title</dc:title><dc:creator>Author</dc:creator></metadata><manifest/></package>
        """.utf8).write(to: root.appendingPathComponent("book.opf"))
    }
}
