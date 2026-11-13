import Foundation
import XCTest
import RealmSwift
@testable import RealmSwiftGaps
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
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: root))
        let oldManager = ReaderFileManager.shared
        let oldDestinations = ReaderFileManager.fileDestinationProcessors
        let oldURLs = ReaderFileManager.readerFileURLProcessors
        let oldProcessors = ReaderFileManager.fileProcessors
        ReaderFileManager.shared = manager
        ReaderFileManager.fileDestinationProcessors = []
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        defer {
            ReaderFileManager.shared = oldManager
            ReaderFileManager.fileDestinationProcessors = oldDestinations
            ReaderFileManager.readerFileURLProcessors = oldURLs
            ReaderFileManager.fileProcessors = oldProcessors
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
            let rejected = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertEqual(rejected, [file.compoundKey])
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
            let rejected = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertEqual(rejected, [file.compoundKey])
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
            let rejected = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertEqual(rejected, [file.compoundKey])
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
            let rejected = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertEqual(rejected, [replacement.compoundKey])
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
            let rejected = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTAssertTrue(rejected.isEmpty)
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
                _ = try await EbookFileManager.enrichMetadata([file], resolveLocalURL: { _ in throw CancellationError() })
                XCTFail("Cancellation must not become a rejected/successful batch")
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
            let root = f.root
            let rejected = try await EbookFileManager.enrichMetadata([first, second], resolveLocalURL: { url in
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
                return root.appendingPathComponent(url.lastPathComponent)
            })
            XCTAssertEqual(rejected, [firstID])
            XCTAssertEqual(first.title, "Newer edit during later await")
            XCTAssertFalse(first.isPhysicalMedia)
            XCTAssertEqual(second.title, "Coverless title")
            XCTAssertTrue(second.isPhysicalMedia)
        }
    }

    @RealmBackgroundActor
    func testRegisteredProcessorEnrichesCoverlessLocalFile() async throws {
        try await withFixture { f in
            try self.writeEPUB(at: f.root.appendingPathComponent("coverless.epub"))
            let file = try await self.seed("coverless", in: f.realm)
            EbookFileManager.configure()
            let processor = try XCTUnwrap(ReaderFileManager.fileProcessors.last)
            try await processor([file])
            XCTAssertEqual(file.title, "Coverless title")
            XCTAssertEqual(file.author, "Author")
            XCTAssertTrue(file.isPhysicalMedia)
            XCTAssertNil(file.imageUrl)
            XCTAssertNotNil(self.generation(file, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testQueuedUpdateRechecksInterveningEditAtOwnedAdmission() async throws {
        try await withFixture { f in
            let file = try await self.seed("queued-edit", in: f.realm)
            var prepared = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
            prepared.desired.title = "Parsed before peer edit"
            let update = prepared
            try f.realm.beginWrite()
            let submitted = expectation(description: "Metadata submitted its real SDK begin ticket")
            let writer = Task { @RealmBackgroundActor in
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await EbookFileManager.applyPreparedMetadataUpdates([update])
                }
            }
            addTeardownBlock { @RealmBackgroundActor in
                writer.cancel()
                if f.realm.isInWriteTransaction { f.realm.cancelWrite() }
                _ = await writer.result
            }
            await fulfillment(of: [submitted], timeout: 5)
            file.title = "Peer title committed after submission"
            file.refreshChangeMetadata(explicitlyModified: true)
            try f.realm.commitWrite()
            let generation = self.generation(file, in: f.realm)
            let rejected = try await writer.value
            XCTAssertEqual(rejected, [file.compoundKey])
            XCTAssertEqual(file.title, "Peer title committed after submission")
            XCTAssertEqual(self.generation(file, in: f.realm), generation)
        }
    }

    @RealmBackgroundActor
    func testCancellingQueuedUpdateDoesNotCancelThePeerTransaction() async throws {
        try await withFixture { f in
            let file = try await self.seed("queued-cancel", in: f.realm)
            var prepared = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
            prepared.desired.title = "Cancelled parsed title"
            let update = prepared
            try f.realm.beginWrite()
            file.author = "Peer author"
            file.refreshChangeMetadata(explicitlyModified: true)
            let submitted = expectation(description: "Metadata write queued behind the peer")
            let settled = expectation(description: "Cancellation settles before peer commit")
            let writer = Task { @RealmBackgroundActor in
                defer { settled.fulfill() }
                return try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await EbookFileManager.applyPreparedMetadataUpdates([update])
                }
            }
            addTeardownBlock { @RealmBackgroundActor in
                writer.cancel()
                if f.realm.isInWriteTransaction { f.realm.cancelWrite() }
                _ = await writer.result
            }
            await fulfillment(of: [submitted], timeout: 5)
            writer.cancel()
            await fulfillment(of: [settled], timeout: 5)
            XCTAssertTrue(f.realm.isInWriteTransaction)
            XCTAssertEqual(file.author, "Peer author")
            try f.realm.commitWrite()
            let generation = self.generation(file, in: f.realm)
            do { _ = try await writer.value; XCTFail("Cancelled metadata must not succeed") }
            catch is CancellationError {}
            XCTAssertEqual(file.title, "Before")
            XCTAssertEqual(self.generation(file, in: f.realm), generation)
        }
    }

    @RealmBackgroundActor
    func testRecreationDuringResolutionCannotReceiveOriginalMetadata() async throws {
        try await withFixture { f in
            let root = f.root
            try self.writeEPUB(at: root.appendingPathComponent("replaced.epub"))
            let file = try await self.seed("replaced", in: f.realm)
            let id = file.compoundKey
            let createdAt = file.createdAt
            let configuration = f.configuration
            let rejected = try await EbookFileManager.enrichMetadata([file], resolveLocalURL: { _ in
                try await { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                    let original = try XCTUnwrap(realm.object(ofType: ContentFile.self, forPrimaryKey: id))
                    // Test-only reset/recreation, including the same creation date.
                    try await realm.asyncWrite {
                        realm.delete(original)
                        let replacement = ContentFile()
                        replacement.url = URL(string: "ebook://ebook/load/local/replaced.epub")!
                        replacement.title = "Replacement title"
                        replacement.createdAt = createdAt
                        replacement.updateCompoundKey()
                        realm.add(replacement)
                    }
                }()
                return root.appendingPathComponent("replaced.epub")
            })
            let replacement = try XCTUnwrap(f.realm.object(ofType: ContentFile.self, forPrimaryKey: id))
            XCTAssertTrue(file.isInvalidated)
            XCTAssertEqual(rejected, [id])
            XCTAssertEqual(replacement.title, "Replacement title")
            XCTAssertFalse(replacement.isPhysicalMedia)
            XCTAssertNil(self.generation(replacement, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testFailedResolutionPreservesTheRowAndAllowsAnotherBook() async throws {
        try await withFixture { f in
            let root = f.root
            try self.writeEPUB(at: root.appendingPathComponent("available.epub"))
            let failed = try await self.seed("unavailable", in: f.realm)
            let available = try await self.seed("available", in: f.realm)
            let rejected = try await EbookFileManager.enrichMetadata([failed, available], resolveLocalURL: { url in
                if url.lastPathComponent == "unavailable.epub" { throw CocoaError(.fileReadNoSuchFile) }
                return root.appendingPathComponent(url.lastPathComponent)
            })
            XCTAssertEqual(rejected, [failed.compoundKey])
            XCTAssertEqual(failed.title, "Before")
            XCTAssertNil(self.generation(failed, in: f.realm))
            XCTAssertEqual(available.title, "Coverless title")
            XCTAssertNotNil(self.generation(available, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testCancellationDuringLaterResolutionDoesNotCommitThePreparedBook() async throws {
        try await withFixture { f in
            let root = f.root
            try self.writeEPUB(at: root.appendingPathComponent("prepared.epub"))
            let prepared = try await self.seed("prepared", in: f.realm)
            let later = try await self.seed("later", in: f.realm)
            let writer = Task { @RealmBackgroundActor in
                try await EbookFileManager.enrichMetadata([prepared, later], resolveLocalURL: { url in
                    if url.lastPathComponent == "later.epub" {
                        withUnsafeCurrentTask { $0?.cancel() }
                        // A provider can report an ordinary I/O error after cancellation.
                        throw CocoaError(.fileReadNoSuchFile)
                    }
                    return root.appendingPathComponent(url.lastPathComponent)
                })
            }
            do { _ = try await writer.value; XCTFail("Cancellation must discard the prepared batch") }
            catch is CancellationError {}
            XCTAssertEqual(prepared.title, "Before")
            XCTAssertFalse(prepared.isPhysicalMedia)
            XCTAssertTrue(f.realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    @RealmBackgroundActor
    func testTombstonedFrozenAndUnmanagedInputsNeverReachResolution() async throws {
        try await withFixture { f in
            let deleted = try await self.seed("tombstone", in: f.realm)
            let valid = try await self.seed("frozen", in: f.realm)
            try await f.realm.asyncWrite {
                deleted.isDeleted = true
                deleted.refreshChangeMetadata(explicitlyModified: true)
            }
            let generation = self.generation(deleted, in: f.realm)
            let unmanaged = ContentFile()
            unmanaged.url = URL(string: "ebook://ebook/load/local/unmanaged.epub")!
            let rejected = try await EbookFileManager.enrichMetadata(
                [deleted, valid.freeze(), unmanaged], resolveLocalURL: { _ in
                    XCTFail("Retired or unmanaged inputs must be rejected before file I/O")
                    throw CocoaError(.fileReadUnknown)
                }
            )
            XCTAssertTrue(rejected.isEmpty)
            XCTAssertTrue(deleted.isDeleted)
            XCTAssertEqual(self.generation(deleted, in: f.realm), generation)
            XCTAssertEqual(valid.title, "Before")
            XCTAssertNil(self.generation(valid, in: f.realm))
        }
    }

    @RealmBackgroundActor
    func testSameClockSourceURLOrTypeReplacementRejectsTheProposal() async throws {
        try await withFixture { f in
            for changeURL in [false, true] {
                let file = try await self.seed("source-\(changeURL)", in: f.realm)
                var update = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
                update.desired.title = "Parsed from the former source"
                let originalDate = file.modifiedAt
                try await f.realm.asyncWrite {
                    if changeURL {
                        file.url = URL(string: "ebook://ebook/load/local/other.epub")!
                    } else {
                        file.mimeType = "text/plain"
                    }
                    file.refreshChangeMetadata(explicitlyModified: false, at: originalDate)
                }
                let rejected = try await EbookFileManager.applyPreparedMetadataUpdates([update])
                XCTAssertEqual(rejected, [file.compoundKey])
                XCTAssertEqual(file.title, "Before")
                XCTAssertNil(self.generation(file, in: f.realm))
            }
        }
    }

    @RealmBackgroundActor
    func testPreparedUpdateRejectsPhysicalReplacementAtTheSamePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EbookMetadataReplacement-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = Realm.Configuration(fileURL: root.appendingPathComponent("current.realm"))
        configuration.objectTypes = [ContentFile.self, BigSyncPendingMutation.self]
        var replacementConfiguration = configuration
        replacementConfiguration.fileURL = root.appendingPathComponent("replacement.realm")
        // Registration is keyed by physical path, not by the copied configuration.
        BigSyncMutationTracking.install(
            configurations: [configuration, replacementConfiguration], excludedClassNames: []
        )
        let original = configuration
        let replacement = replacementConfiguration
        addTeardownBlock {
            await Self.releaseDiskCache(original)
            await Self.releaseDiskCache(replacement)
            try? FileManager.default.removeItem(at: root)
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let otherRealm = try await RealmBackgroundActor.shared.cachedRealm(for: replacementConfiguration)
        let file = try await seed("physical", in: realm)
        let successor = try await seed("physical", in: otherRealm)
        let creation = file.createdAt
        try await otherRealm.asyncWrite { successor.createdAt = creation }
        var update = try XCTUnwrap(EbookFileManager.MetadataUpdate(file))
        update.desired.title = "Old file proposal"
        try FileManager.default.moveItem(
            at: try XCTUnwrap(configuration.fileURL), to: root.appendingPathComponent("retired.realm")
        )
        try FileManager.default.moveItem(
            at: try XCTUnwrap(replacementConfiguration.fileURL), to: try XCTUnwrap(configuration.fileURL)
        )
        do {
            _ = try await EbookFileManager.applyPreparedMetadataUpdates([update])
            XCTFail("A proposal must not follow a replaced physical store")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        XCTAssertEqual(file.title, "Before")
        XCTAssertEqual(successor.title, "Before")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertTrue(otherRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    private static func releaseDiskCache(_ configuration: Realm.Configuration) {
        // Only this fixture's two paths; their current file identities changed.
        let owner = RealmBackgroundActor.shared
        let keys = owner.cachedRealms.keys.filter {
            owner.cachedRealms[$0]?.configuration.fileURL == configuration.fileURL
        }
        for key in keys {
            guard let realm = owner.cachedRealms[key], !realm.isInWriteTransaction else { continue }
            owner.cachedRealms.removeValue(forKey: key)
            realm.invalidate()
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
