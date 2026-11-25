import Foundation
import XCTest
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
    private func seed(
        _ name: String, in realm: Realm, publicationDate: Date? = nil
    ) async throws -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "ebook://ebook/load/local/\(name).epub")!
        file.title = "Before"
        file.mimeType = "application/epub+zip"
        if let publicationDate { file.publicationDate = publicationDate }
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
    func testPublicationDateEnrichmentReplacesFileDateOnlyForValidMetadata() async throws {
        try await withFixture { f in
            let fileDate = Date(timeIntervalSince1970: 1_700_000_000)
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            let cases: [(name: String, opfDate: String?, expected: Date)] = [
                ("reduced", "1997-07", Date(timeIntervalSince1970: 867_715_200)),
                ("invalid", "2019-02-29T03:04:05Z", fileDate),
                ("absent", nil, fileDate),
            ]
            for (name, opfDate, expected) in cases {
                try self.writeEPUB(
                    at: f.root.appendingPathComponent("\(name).epub"), publicationDate: opfDate
                )
                let file = try await self.seed(name, in: f.realm, publicationDate: fileDate)
                let deferred = try await EbookFileManager.enrichMetadata([file])
                XCTAssertTrue(deferred.isEmpty, name)
                XCTAssertEqual(file.publicationDate, expected, name)
                XCTAssertEqual(file.humanReadablePublicationDate, displayFormatter.string(from: expected), name)
                XCTAssertEqual(file.title, "Coverless title", name)
                XCTAssertEqual(file.author, "Author", name)
                let generation = try XCTUnwrap(self.generation(file, in: f.realm), name)

                let deferredAgain = try await EbookFileManager.enrichMetadata([file])
                XCTAssertTrue(deferredAgain.isEmpty, name)
                XCTAssertEqual(self.generation(file, in: f.realm), generation, name)
            }
        }
    }

    func testAbsoluteEPUBPublicationDateUsesUTCAcrossDeviceTimeZones() throws {
        let locale = Locale(identifier: "en_US_POSIX")
        let startOf1997 = Date(timeIntervalSince1970: 852_076_800)
        let cases: [(zone: String, instant: Date, ebookText: String, deviceText: String)] = [
            ("America/Toronto", startOf1997, "Jan 1, 1997", "Dec 31, 1996"),
            ("Asia/Tokyo", startOf1997.addingTimeInterval(-3_600), "Dec 31, 1996", "Jan 1, 1997"),
        ]
        for (identifier, instant, ebookText, deviceText) in cases {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier))
            for storage in ["local", "icloud"] {
                let url = try XCTUnwrap(URL(string: "ebook://ebook/load/\(storage)/book.epub"))
                let format = ReaderAbsolutePublicationDateFormat(url: url, isPhysicalMedia: true)
                let formatter = format.makeFormatter(locale: locale, deviceTimeZone: zone)
                XCTAssertEqual(formatter.string(from: instant), ebookText, "\(identifier), \(storage)")
            }

            let otherItems = [
                ("https://example.test/feed-entry", false),
                ("https://example.test/remote.epub", true),
                ("reader-file://file/load/local/comic.zip", true),
                ("ebook://ebook/load/local/comic.zip", true),
                ("ebook://ebook/load/local/book.epub", false),
                ("ebook://ebook/view/local/book.epub", true),
            ]
            for (address, isPhysicalMedia) in otherItems {
                let url = try XCTUnwrap(URL(string: address))
                let format = ReaderAbsolutePublicationDateFormat(url: url, isPhysicalMedia: isPhysicalMedia)
                let formatter = format.makeFormatter(locale: locale, deviceTimeZone: zone)
                XCTAssertEqual(formatter.string(from: instant), deviceText, "\(identifier), \(address)")
            }
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

    private func writeEPUB(at root: URL, publicationDate: String? = nil) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        let date = publicationDate.map { "<dc:date>\($0)</dc:date>" } ?? ""
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0"><metadata><dc:title>Coverless title</dc:title><dc:creator>Author</dc:creator>\(date)</metadata><manifest/></package>
        """.utf8).write(to: root.appendingPathComponent("book.opf"))
    }
}
