import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import SwiftCloudDrive
import UniformTypeIdentifiers
import XCTest
@testable import LakeOfFireContent

private actor ReaderFileDeletionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@RealmBackgroundActor
private final class ReaderFileDeletionForeignWriteSnapshot {
    var generation: String?
    var modifiedAt: Date?
}

/// Native regressions use the production ContentFile/manager, local CloudDrive
/// accessor, Realm transactions and mutation journal. No iCloud account is used.
@MainActor
final class ReaderFileDeletionTests: XCTestCase {
    private struct Fixture: @unchecked Sendable {
        let root: URL
        let library: URL
        let manager: ReaderFileManager
        let historyConfiguration: Realm.Configuration
        let feedConfiguration: Realm.Configuration
        let transcriptConfiguration: Realm.Configuration
        let additionalConfiguration: Realm.Configuration
        let history: Realm
        let feed: Realm
        let transcripts: Realm
        let additional: Realm
    }

    private func configuration(_ types: [Object.Type]) -> Realm.Configuration {
        var result = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        result.objectTypes = types + [BigSyncPendingMutation.self]
        return result
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderFileDeletionTests." + UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let historyConfiguration = configuration([
            ContentFile.self, ContentPackageFile.self, Bookmark.self, HistoryRecord.self,
        ])
        let feedConfiguration = configuration([FeedEntry.self])
        let transcriptConfiguration = configuration([MediaTranscript.self])
        let additionalConfiguration = configuration([Bookmark.self])
        let configurations = [historyConfiguration, feedConfiguration,
                              transcriptConfiguration, additionalConfiguration]
        BigSyncMutationTracking.install(configurations: configurations, excludedClassNames: [])
        let history = try await Realm(configuration: historyConfiguration, actor: MainActor.shared)
        let feed = try await Realm(configuration: feedConfiguration, actor: MainActor.shared)
        let transcripts = try await Realm(configuration: transcriptConfiguration, actor: MainActor.shared)
        let additional = try await Realm(configuration: additionalConfiguration, actor: MainActor.shared)
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { library })
        manager.historyRealmConfigurationOverride = historyConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: library))
        manager.readerContentMimeTypes = [.plainText]

        let oldShared = ReaderFileManager.shared
        let oldHistory = ReaderContentLoader.historyRealmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        let oldTranscript = ReaderContentLoader.transcriptRealmConfiguration
        let oldProviders = ReaderContentLoader.additionalContentProviders
        let oldProcessors = ReaderFileManager.fileProcessors
        let oldURLProcessors = ReaderFileManager.readerFileURLProcessors
        ReaderFileManager.shared = manager
        ReaderContentLoader.historyRealmConfiguration = historyConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = feedConfiguration
        ReaderContentLoader.transcriptRealmConfiguration = transcriptConfiguration
        ReaderContentLoader.additionalContentProviders = []
        ReaderFileManager.fileProcessors = []
        ReaderFileManager.readerFileURLProcessors = []
        defer {
            ReaderFileManager.shared = oldShared
            ReaderContentLoader.historyRealmConfiguration = oldHistory
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
            ReaderContentLoader.transcriptRealmConfiguration = oldTranscript
            ReaderContentLoader.additionalContentProviders = oldProviders
            ReaderFileManager.fileProcessors = oldProcessors
            ReaderFileManager.readerFileURLProcessors = oldURLProcessors
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = Fixture(root: root, library: library, manager: manager,
                              historyConfiguration: historyConfiguration,
                              feedConfiguration: feedConfiguration,
                              transcriptConfiguration: transcriptConfiguration,
                              additionalConfiguration: additionalConfiguration,
                              history: history, feed: feed, transcripts: transcripts,
                              additional: additional)
        do {
            try await body(fixture)
        } catch {
            await cleanUp(fixture, configurations: configurations)
            throw error
        }
        await cleanUp(fixture, configurations: configurations)
    }

    private func cleanUp(_ fixture: Fixture, configurations: [Realm.Configuration]) async {
        fixture.manager.deletionStatusLoader = nil
        let manager = fixture.manager
        await { @RealmBackgroundActor in
            manager.beforeDeletionRemovalAdmission = nil
            manager.deletionObserver = nil
            for configuration in configurations {
                await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            }
        }()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func requireDeniedInspection(at url: URL) throws {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let error = error as NSError
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            let denied = (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                || (error.domain == NSPOSIXErrorDomain
                    && error.code == Int(POSIXErrorCode.EACCES.rawValue))
                || (underlying?.domain == NSPOSIXErrorDomain
                    && underlying?.code == Int(POSIXErrorCode.EACCES.rawValue))
            guard denied else { throw error }
            return
        }
        throw XCTSkip("This test process can inspect mode-000 directories; denied-inspection coverage requires an unprivileged native host.")
    }

    private func record(_ fixture: Fixture, storage: String = "local", name: String = "book.txt") throws -> ContentFile {
        let file = ContentFile()
        file.url = try XCTUnwrap(URL(string: "reader-file://file/load/\(storage)/\(name)"))
        file.title = "Original"
        file.mimeType = "text/plain"
        file.updateCompoundKey()
        try fixture.history.write {
            fixture.history.add(file)
            file.refreshChangeMetadata(explicitlyModified: true)
        }
        fixture.manager.files = [file.freeze()]
        return file
    }

    private func transcript(_ fixture: Fixture, for url: URL) throws -> MediaTranscript {
        let transcript = MediaTranscript()
        transcript.contentURL = MediaTranscript.canonicalContentURL(from: url)
        transcript.stableMediaIdentity = "offline:fixture"
        transcript.updateCompoundKey()
        try fixture.transcripts.write {
            fixture.transcripts.add(transcript)
            transcript.refreshChangeMetadata(explicitlyModified: true)
        }
        return transcript
    }

    private func generation(_ realm: Realm, _ type: Object.Type, _ key: String) throws -> String {
        realm.refresh()
        return try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: type.className() + "." + key)).generation
    }

    private func assertRejected(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("The captured deletion should be retired") }
        catch ReaderFileDeleteError.removeFailed { }
        catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        catch { XCTFail("Unexpected failure: \(error)") }
    }

    func testContentFileDeletionJournalsPackageAndTranscriptAndRetryIsNoOp() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("original bytes", to: payload)
            let file = try record(f)
            let transcript = try transcript(f, for: file.url)
            let package = ContentPackageFile()
            package.packageContentFileID = file.compoundKey
            package.url = try XCTUnwrap(URL(string: file.url.absoluteString + "?entry=one"))
            package.updateCompoundKey()
            try f.history.write {
                f.history.add(package)
                package.refreshChangeMetadata(explicitlyModified: true)
            }
            let before = try generation(f.history, ContentFile.self, file.compoundKey)
            try await file.delete()
            f.history.refresh()
            f.transcripts.refresh()
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            XCTAssertTrue(file.isDeleted)
            XCTAssertTrue(package.isDeleted)
            XCTAssertTrue(transcript.isDeleted)
            XCTAssertEqual(file.modifiedAt, package.modifiedAt)
            XCTAssertTrue(f.manager.files?.isEmpty == true)
            let fileGeneration = try generation(f.history, ContentFile.self, file.compoundKey)
            let packageGeneration = try generation(f.history, ContentPackageFile.self, package.compoundKey)
            let transcriptGeneration = try generation(f.transcripts, MediaTranscript.self, transcript.compoundKey)
            XCTAssertNotEqual(fileGeneration, before)
            try await file.delete()
            XCTAssertEqual(try generation(f.history, ContentFile.self, file.compoundKey), fileGeneration)
            XCTAssertEqual(try generation(f.history, ContentPackageFile.self, package.compoundKey), packageGeneration)
            XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, transcript.compoundKey), transcriptGeneration)
        }
    }

    func testInvalidatedContentFileDoesNotReadPersistedIdentity() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("retained bytes", to: payload)
            let file = try record(f)
            try f.history.write { f.history.delete(file) }
            XCTAssertTrue(file.isInvalidated)
            try await file.delete()
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "retained bytes")
        }
    }

    func testSameKeyAndCreationReplacementDuringStatusCannotDeleteNewRow() async throws {
        for frozen in [false, true] {
            try await withFixture { f in
                let payload = f.library.appendingPathComponent("book.txt")
                try write("retained bytes", to: payload)
                let file = try record(f)
                let presented = frozen ? file.freeze() : file
                let key = file.compoundKey, originalID = file.id
                let creation = file.createdAt, url = file.url
                var replacementGeneration: String?
                f.manager.deletionStatusLoader = { backing in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                    let replacement = ContentFile()
                    replacement.compoundKey = key
                    replacement.createdAt = creation
                    replacement.url = url
                    replacement.title = "Replacement"
                    try f.history.write {
                        f.history.delete(file)
                        f.history.add(replacement)
                        replacement.refreshChangeMetadata(explicitlyModified: true)
                    }
                    XCTAssertNotEqual(replacement.id, originalID)
                    replacementGeneration = try self.generation(f.history, ContentFile.self, key)
                    return status
                }
                await assertRejected { try await presented.delete() }
                let current = try XCTUnwrap(f.history.object(ofType: ContentFile.self, forPrimaryKey: key))
                XCTAssertFalse(current.isDeleted)
                XCTAssertEqual(current.title, "Replacement")
                XCTAssertEqual(try generation(f.history, ContentFile.self, key), replacementGeneration)
                XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "retained bytes")
            }
        }
    }

    func testDriveHistoryAndABASupersessionCannotRetargetDeletion() async throws {
        for change in ["drive", "history", "aba"] {
            try await withFixture { f in
                let payload = f.library.appendingPathComponent("book.txt")
                try write("original bytes", to: payload)
                let file = try record(f)
                let oldGeneration = try generation(f.history, ContentFile.self, file.compoundKey)
                let originalDrive = try XCTUnwrap(f.manager.localDrive)
                let replacementRoot = f.root.appendingPathComponent("replacement", isDirectory: true)
                let replacementDrive = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
                let replacementPayload = replacementRoot.appendingPathComponent("book.txt")
                try write("replacement bytes", to: replacementPayload)
                f.manager.deletionStatusLoader = { backing in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                    if change == "history" {
                        f.manager.historyRealmConfigurationOverride = f.additionalConfiguration
                    } else {
                        f.manager.localDrive = replacementDrive
                        if change == "aba" { f.manager.localDrive = originalDrive }
                    }
                    return status
                }
                await assertRejected { try await file.delete() }
                f.history.refresh()
                XCTAssertFalse(file.isDeleted)
                XCTAssertEqual(try generation(f.history, ContentFile.self, file.compoundKey), oldGeneration)
                XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "original bytes")
                XCTAssertEqual(try String(contentsOf: replacementPayload, encoding: .utf8), "replacement bytes")
            }
        }
    }

    func testFinalNativeAccessorRejectsReplacementForFileAndDirectory() async throws {
        for isDirectory in [false, true] {
            try await withFixture { f in
                let name = isDirectory ? "book" : "book.txt"
                let root = f.library.appendingPathComponent(name, isDirectory: isDirectory)
                let payload = isDirectory ? root.appendingPathComponent("chapter.txt") : root
                try write("retained bytes", to: payload)
                let file = try record(f, name: name)
                let key = file.compoundKey, url = file.url, createdAt = file.createdAt
                let manager = f.manager
                await { @RealmBackgroundActor in
                    manager.beforeDeletionRemovalAdmission = { realm in
                        let original = try XCTUnwrap(realm.object(ofType: ContentFile.self, forPrimaryKey: key))
                        let replacement = ContentFile()
                        replacement.compoundKey = key
                        replacement.url = url
                        replacement.createdAt = createdAt
                        try realm.write {
                            realm.delete(original)
                            realm.add(replacement)
                            replacement.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                }()
                await assertRejected { try await file.delete() }
                f.history.refresh()
                let current = try XCTUnwrap(f.history.object(ofType: ContentFile.self, forPrimaryKey: key))
                XCTAssertFalse(current.isDeleted)
                XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "retained bytes")
            }
        }
    }

    func testCancellationInsideNativeAccessorPreservesBytesAndJournal() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("retained bytes", to: payload)
            let file = try record(f)
            let before = try generation(f.history, ContentFile.self, file.compoundKey)
            let manager = f.manager
            await { @RealmBackgroundActor in
                manager.beforeDeletionRemovalAdmission = { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }()
            let deletion = Task { @MainActor in try await file.delete() }
            do { try await deletion.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            f.history.refresh()
            XCTAssertFalse(file.isDeleted)
            XCTAssertEqual(try generation(f.history, ContentFile.self, file.compoundKey), before)
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "retained bytes")
        }
    }

    func testICloudLocalFallbackAndUploadingKeepSelectedDeletionPolicy() async throws {
        for uploading in [false, true] {
            try await withFixture { f in
                let cloudRoot = f.root.appendingPathComponent("cloud", isDirectory: true)
                f.manager.cloudDrive = try await CloudDrive(storage: .localDirectory(rootURL: cloudRoot))
                let localPayload = f.library.appendingPathComponent("book.txt")
                let cloudPayload = cloudRoot.appendingPathComponent("book.txt")
                try write("local bytes", to: localPayload)
                let file = try record(f, storage: "icloud")
                if uploading {
                    try write("uploading bytes", to: cloudPayload)
                    f.manager.deletionStatusLoader = { _ in .uploading }
                } else {
                    let status = try await f.manager.cloudDriveSyncStatus(readerFileURL: file.url)
                    XCTAssertEqual(status, .localOnly)
                }
                try await file.delete()
                f.history.refresh()
                XCTAssertTrue(file.isDeleted)
                XCTAssertFalse(FileManager.default.fileExists(atPath: cloudPayload.path))
                XCTAssertEqual(FileManager.default.fileExists(atPath: localPayload.path), uploading)
            }
        }
    }

    func testLocalDeleteIgnoresUnselectedDriveButFallbackRejectsCloudArrival() async throws {
        for fallback in [false, true] {
            try await withFixture { f in
                let cloudRoot = f.root.appendingPathComponent("cloud", isDirectory: true)
                let cloud = try await CloudDrive(storage: .localDirectory(rootURL: cloudRoot))
                f.manager.cloudDrive = cloud
                let payload = f.library.appendingPathComponent("book.txt")
                try write("local bytes", to: payload)
                let file = try record(f, storage: fallback ? "icloud" : "local")
                f.manager.deletionStatusLoader = { backing in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                    if fallback {
                        try self.write("new cloud bytes", to: cloudRoot.appendingPathComponent("book.txt"))
                    } else {
                        f.manager.cloudDrive = nil
                    }
                    return status
                }
                if fallback { await assertRejected { try await file.delete() } }
                else { try await file.delete() }
                f.history.refresh()
                XCTAssertEqual(file.isDeleted, !fallback)
                XCTAssertEqual(FileManager.default.fileExists(atPath: payload.path), fallback)
            }
        }
    }

    func testReimportBeforeIndexWriteCannotJournalAFalseTombstone() async throws {
        for initiallyMissing in [false, true] {
            try await withFixture { f in
                let payload = f.library.appendingPathComponent("book.txt")
                if !initiallyMissing { try write("original bytes", to: payload) }
                let file = try record(f)
                let generationBefore = try generation(f.history, ContentFile.self, file.compoundKey)
                let manager = f.manager
                await { @RealmBackgroundActor in
                    manager.deletionObserver = { event in
                        guard case .beforeIndexWrite = event else { return }
                        do { try Data("newly imported bytes".utf8).write(to: payload) }
                        catch { XCTFail("Unable to stage the reimport: \(error)") }
                    }
                }()
                await assertRejected { try await file.delete() }
                f.history.refresh()
                XCTAssertFalse(file.isDeleted)
                XCTAssertEqual(try generation(f.history, ContentFile.self, file.compoundKey), generationBefore)
                XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "newly imported bytes")
            }
        }
    }

    func testSameRowReimportAfterCommitRemainsPublished() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("original bytes", to: payload)
            let file = try record(f)
            let transcript = try transcript(f, for: file.url)
            let objectID = file.id
            let manager = f.manager
            await { @RealmBackgroundActor in
                manager.deletionObserver = { event in
                    guard case .indexCommitted = event else { return }
                    await { @MainActor in
                        do {
                            try self.write("reimported bytes", to: payload)
                            // Exercise the selected producer that revives the same
                            // row in setMetadata, including its normal publication.
                            try await manager.refreshAllFilesMetadata(force: true)
                        } catch { XCTFail("Unable to stage the reimport: \(error)") }
                    }()
                }
            }()
            try await file.delete()
            f.history.refresh()
            f.transcripts.refresh()
            XCTAssertEqual(file.id, objectID)
            XCTAssertFalse(file.isDeleted)
            XCTAssertFalse(transcript.isDeleted)
            XCTAssertEqual(f.manager.files?.map(\.id), [objectID])
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "reimported bytes")
        }
    }

    func testTombstonedRetryCannotRemoveSameRowReimportDuringStatus() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("original bytes", to: payload)
            let file = try record(f)
            try await file.delete()
            f.history.refresh()
            XCTAssertTrue(file.isDeleted)
            let originalID = file.id
            f.manager.deletionStatusLoader = { backing in
                let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                XCTAssertEqual(status, .fileMissing)
                try self.write("reimported bytes", to: payload)
                try await f.manager.refreshAllFilesMetadata(force: true)
                return status
            }
            await assertRejected { try await file.delete() }
            f.history.refresh()
            XCTAssertEqual(file.id, originalID)
            XCTAssertFalse(file.isDeleted)
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "reimported bytes")
        }
    }

    func testCommittedManagerRemovalSurvivesLateSelectionChangeAndCancellation() async throws {
        for change in ["drive", "mixed-presentation", "cancel"] {
            try await withFixture { f in
                let payload = f.library.appendingPathComponent("book.txt")
                try write("original bytes", to: payload)
                let file = try record(f)
                let originalPresentation = file.freeze()
                let backing = file.url, key = file.compoundKey
                let manager = f.manager
                let replacementRoot = f.root.appendingPathComponent("replacement", isDirectory: true)
                let replacementDrive = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
                let foreignFile = ContentFile()
                foreignFile.url = backing
                foreignFile.compoundKey = key
                foreignFile.createdAt = file.createdAt
                let foreignConfiguration = configuration([ContentFile.self, ContentPackageFile.self])
                BigSyncMutationTracking.install(configurations: [foreignConfiguration], excludedClassNames: [])
                let foreignRealm = try await Realm(configuration: foreignConfiguration, actor: MainActor.shared)
                try foreignRealm.write { foreignRealm.add(foreignFile) }
                XCTAssertEqual(foreignFile.id, file.id)
                await { @RealmBackgroundActor in
                    manager.deletionObserver = { event in
                        guard case .indexCommitted = event else { return }
                        if change == "cancel" {
                            withUnsafeCurrentTask { $0?.cancel() }
                        } else {
                            await MainActor.run {
                                if change == "drive" {
                                    manager.localDrive = replacementDrive
                                    manager.files = [foreignFile]
                                } else {
                                    manager.files = [originalPresentation, foreignFile]
                                }
                            }
                        }
                    }
                }()
                let deletion = Task { try await manager.delete(readerFileURL: backing) }
                try await deletion.value
                f.history.refresh()
                XCTAssertTrue(file.isDeleted)
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
                if change != "cancel" {
                    XCTAssertEqual(f.manager.files?.count, 1)
                    XCTAssertEqual(f.manager.files?.first?.realm?.configuration.inMemoryIdentifier,
                                   foreignConfiguration.inMemoryIdentifier)
                    XCTAssertFalse(foreignFile.isDeleted)
                }
            }
        }
    }

    func testPostIndexCancellationLeavesTranscriptCleanupForRetry() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("original bytes", to: payload)
            let file = try record(f)
            let transcript = try transcript(f, for: file.url)
            let manager = f.manager
            await { @RealmBackgroundActor in
                manager.deletionObserver = { event in
                    if case .indexCommitted = event { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }()
            let deletion = Task { @MainActor in try await file.delete() }
            do { try await deletion.value; XCTFail("Cleanup must observe cancellation") }
            catch is CancellationError { }
            f.history.refresh()
            f.transcripts.refresh()
            XCTAssertTrue(file.isDeleted)
            XCTAssertFalse(transcript.isDeleted)
            let committed = try generation(f.history, ContentFile.self, file.compoundKey)
            await { @RealmBackgroundActor in manager.deletionObserver = nil }()
            try await file.delete()
            f.transcripts.refresh()
            XCTAssertTrue(transcript.isDeleted)
            XCTAssertEqual(try generation(f.history, ContentFile.self, file.compoundKey), committed)
            XCTAssertTrue(f.manager.files?.isEmpty == true)
        }
    }

    func testHistoryFeedAndAdditionalOwnersPreserveTranscript() async throws {
        for kind in ["history", "feed", "additional"] {
            try await withFixture { f in
                let payload = f.library.appendingPathComponent("book.txt")
                try write("original bytes", to: payload)
                let file = try record(f)
                let transcript = try transcript(f, for: file.url)
                let before = try generation(f.transcripts, MediaTranscript.self, transcript.compoundKey)
                if kind == "history" {
                    let owner = HistoryRecord()
                    owner.url = file.url
                    owner.updateCompoundKey()
                    try f.history.write { f.history.add(owner) }
                } else if kind == "feed" {
                    let owner = FeedEntry()
                    owner.url = file.url
                    owner.updateCompoundKey()
                    try f.feed.write { f.feed.add(owner) }
                } else {
                    let owner = Bookmark()
                    owner.url = file.url
                    owner.updateCompoundKey()
                    try f.additional.write { f.additional.add(owner) }
                    let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: owner))
                    ReaderContentLoader.additionalContentProviders = [
                        ReaderContentAdditionalProvider(id: "fixture") { _ in [reference] },
                    ]
                }
                try await file.delete()
                f.history.refresh()
                f.transcripts.refresh()
                XCTAssertTrue(file.isDeleted)
                XCTAssertFalse(transcript.isDeleted)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, transcript.compoundKey), before)
            }
        }
    }

    func testCleanupDoesNotAdoptChangedFeedOrTranscriptSelection() async throws {
        for changeFeed in [false, true] {
            try await withFixture { f in
                let payload = f.library.appendingPathComponent("book.txt")
                try write("original bytes", to: payload)
                let file = try record(f)
                let transcript = try transcript(f, for: file.url)
                let before = try generation(f.transcripts, MediaTranscript.self, transcript.compoundKey)
                let entered = expectation(description: "captured cleanup reached provider")
                let release = ReaderFileDeletionGate()
                ReaderContentLoader.additionalContentProviders = [
                    ReaderContentAdditionalProvider(id: "held") { _ in
                        entered.fulfill()
                        await release.wait()
                        return []
                    },
                ]
                let replacementConfiguration = configuration([MediaTranscript.self, FeedEntry.self])
                let replacementRealm = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
                let replacementTranscript = MediaTranscript()
                replacementTranscript.compoundKey = transcript.compoundKey
                replacementTranscript.contentURL = transcript.contentURL
                try replacementRealm.write { replacementRealm.add(replacementTranscript) }
                let deletion = Task { @MainActor in try await file.delete() }
                await fulfillment(of: [entered], timeout: 2)
                if changeFeed { ReaderContentLoader.feedEntryRealmConfiguration = replacementConfiguration }
                else { ReaderContentLoader.transcriptRealmConfiguration = replacementConfiguration }
                await release.open()
                await assertRejected { try await deletion.value }
                f.history.refresh()
                f.transcripts.refresh()
                XCTAssertTrue(file.isDeleted)
                XCTAssertFalse(transcript.isDeleted)
                XCTAssertFalse(replacementTranscript.isDeleted)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, transcript.compoundKey), before)
                ReaderContentLoader.feedEntryRealmConfiguration = f.feedConfiguration
                ReaderContentLoader.transcriptRealmConfiguration = f.transcriptConfiguration
                ReaderContentLoader.additionalContentProviders = []
                try await file.delete()
                f.transcripts.refresh()
                XCTAssertTrue(transcript.isDeleted)
            }
        }
    }

    func testCleanupRetainsMissingProviderReferenceUntilFinalOwnerCheck() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("original bytes", to: payload)
            let file = try record(f)
            let transcript = try transcript(f, for: file.url)
            let owner = Bookmark()
            owner.url = file.url
            owner.updateCompoundKey()
            try f.additional.write { f.additional.add(owner) }
            let key = owner.compoundKey, url = owner.url
            let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: owner))
            try f.additional.write { f.additional.delete(owner) }
            let entered = expectation(description: "first missing owner reference resolved")
            let release = ReaderFileDeletionGate()
            ReaderContentLoader.additionalContentProviders = [
                ReaderContentAdditionalProvider(id: "missing") { _ in [reference] },
                ReaderContentAdditionalProvider(id: "held-after-resolution") { _ in
                    entered.fulfill()
                    await release.wait()
                    return []
                },
            ]
            let deletion = Task { @MainActor in try await file.delete() }
            await fulfillment(of: [entered], timeout: 2)
            do {
                // A peer transcript writer prevents cleanup commit while this
                // real owner is installed after the first provider lookup.
                f.transcripts.beginWrite()
                let replacement = Bookmark()
                replacement.compoundKey = key
                replacement.url = url
                try f.additional.write { f.additional.add(replacement) }
                await release.open()
                await Task.yield()
                try f.transcripts.commitWrite()
                try await deletion.value
            } catch {
                if f.transcripts.isInWriteTransaction { f.transcripts.cancelWrite() }
                await release.open()
                _ = try? await deletion.value
                throw error
            }
            f.transcripts.refresh()
            XCTAssertFalse(transcript.isDeleted)
            XCTAssertFalse(try XCTUnwrap(f.additional.object(ofType: Bookmark.self, forPrimaryKey: key)).isDeleted)
        }
    }

    func testForeignOwnerTransactionCannotProveTranscriptOrphanhood() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("original bytes", to: payload)
            let file = try record(f)
            let transcript = try transcript(f, for: file.url)
            let ownerConfiguration = f.historyConfiguration
            let ownerURL = file.url
            ReaderContentLoader.additionalContentProviders = [
                ReaderContentAdditionalProvider(id: "borrowed-owner-write") { _ in
                    try await { @RealmBackgroundActor in
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ownerConfiguration)
                        let owner = Bookmark()
                        owner.url = ownerURL
                        owner.updateCompoundKey()
                        try realm.write { realm.add(owner) }
                        realm.beginWrite()
                        owner.isDeleted = true // Tentative absence; the caller rolls it back.
                        return [ReaderContentLoader.ContentReference]()
                    }()
                },
            ]
            do { try await file.delete() }
            catch {
                await { @RealmBackgroundActor in
                    if let realm = try? await RealmBackgroundActor.shared.cachedRealm(for: ownerConfiguration),
                       realm.isInWriteTransaction { realm.cancelWrite() }
                }()
                throw error
            }
            let borrowedWriteWasPreserved = try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ownerConfiguration)
                let wasWriting = realm.isInWriteTransaction
                if wasWriting { realm.cancelWrite() }
                return wasWriting
            }()
            f.history.refresh()
            f.transcripts.refresh()
            XCTAssertTrue(borrowedWriteWasPreserved)
            XCTAssertFalse(transcript.isDeleted)
            XCTAssertEqual(f.history.objects(Bookmark.self).filter("isDeleted == false").count, 1)
        }
    }

    func testNarrowSourceViewUsesCapturedOwningInventoryForCleanup() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("original bytes", to: payload)
            var inventory = Realm.Configuration(fileURL: f.root.appendingPathComponent("narrow.realm"))
            inventory.objectTypes = [ContentFile.self, ContentPackageFile.self,
                                     Bookmark.self, HistoryRecord.self, BigSyncPendingMutation.self]
            BigSyncMutationTracking.install(configurations: [inventory], excludedClassNames: [])
            let inventoryConfiguration = inventory
            let backing = try XCTUnwrap(URL(string: "reader-file://file/load/local/book.txt"))
            let key = try autoreleasepool { () throws -> String in
                let realm = try Realm(configuration: inventoryConfiguration)
                let file = ContentFile()
                file.url = backing
                file.updateCompoundKey()
                let owner = Bookmark()
                owner.url = backing
                owner.updateCompoundKey()
                try realm.write {
                    realm.add(file)
                    realm.add(owner)
                    file.refreshChangeMetadata(explicitlyModified: true)
                }
                return file.compoundKey
            }
            var narrow = inventoryConfiguration
            narrow.objectTypes = [ContentFile.self, ContentPackageFile.self, BigSyncPendingMutation.self]
            let sourceRealm = try await Realm(configuration: narrow, actor: MainActor.shared)
            XCTAssertFalse(sourceRealm.schema.objectSchema.contains { $0.className == Bookmark.className() })
            XCTAssertFalse(sourceRealm.schema.objectSchema.contains { $0.className == HistoryRecord.className() })
            let file = try XCTUnwrap(sourceRealm.object(ofType: ContentFile.self, forPrimaryKey: key))
            let transcript = try transcript(f, for: backing)
            f.manager.historyRealmConfigurationOverride = inventoryConfiguration
            ReaderContentLoader.historyRealmConfiguration = inventoryConfiguration
            f.manager.files = [file.freeze()]
            do { try await file.delete() }
            catch {
                await RealmBackgroundActor.shared.removeCachedRealm(for: inventoryConfiguration)
                throw error
            }
            sourceRealm.refresh()
            f.transcripts.refresh()
            XCTAssertTrue(file.isDeleted)
            XCTAssertFalse(transcript.isDeleted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            await RealmBackgroundActor.shared.removeCachedRealm(for: inventoryConfiguration)
        }
    }

    func testStaleLiveSnapshotCannotRemovePayloadOwnedByCurrentTombstone() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            let file = try record(f)
            let presented = file.freeze()
            try f.history.write {
                file.isDeleted = true
                file.refreshChangeMetadata(explicitlyModified: true)
            }
            try write("new payload awaiting indexing", to: payload)
            let before = try generation(f.history, ContentFile.self, file.compoundKey)
            await assertRejected { try await presented.delete() }
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "new payload awaiting indexing")
            XCTAssertEqual(try generation(f.history, ContentFile.self, file.compoundKey), before)
        }
    }

    func testQueuedIndexCancellationKeepsForeignWriteAndMissingFileRetryRepairsIndex() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("original bytes", to: payload)
            let file = try record(f)
            let transcript = try transcript(f, for: file.url)
            let key = file.compoundKey
            let before = try generation(f.history, ContentFile.self, key)
            let configuration = f.historyConfiguration
            let manager = f.manager
            let snapshot = await ReaderFileDeletionForeignWriteSnapshot()
            await { @RealmBackgroundActor in
                manager.deletionObserver = { event in
                    guard case .beforeIndexWrite = event else { return }
                    do {
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                        let original = try XCTUnwrap(realm.object(ofType: ContentFile.self, forPrimaryKey: key))
                        realm.beginWrite()
                        original.title = "Other owner's tentative title"
                        original.refreshChangeMetadata(explicitlyModified: true)
                        snapshot.modifiedAt = original.modifiedAt
                        snapshot.generation = realm.object(ofType: BigSyncPendingMutation.self,
                            forPrimaryKey: ContentFile.className() + "." + key)?.generation
                    } catch { XCTFail("Unable to open the foreign transaction: \(error)") }
                }
            }()
            let submitted = expectation(description: "index begin ticket submitted")
            let settled = expectation(description: "cancelled index request settled")
            let deletion = Task { @MainActor in
                defer { settled.fulfill() }
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await file.delete()
                }
            }
            await fulfillment(of: [submitted], timeout: 2)
            deletion.cancel()
            await fulfillment(of: [settled], timeout: 2)
            // The actual owned-write submission was observed. Release the peer
            // only after checking that cancellation did not roll its write back.
            let preserved = try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let original = realm.object(ofType: ContentFile.self, forPrimaryKey: key)
                let journal = realm.object(ofType: BigSyncPendingMutation.self,
                    forPrimaryKey: ContentFile.className() + "." + key)
                let result = realm.isInWriteTransaction
                    && original?.title == "Other owner's tentative title"
                    && original?.modifiedAt == snapshot.modifiedAt
                    && journal?.generation == snapshot.generation
                if realm.isInWriteTransaction { realm.cancelWrite() }
                manager.deletionObserver = nil
                return result
            }()
            do { try await deletion.value; XCTFail("Expected queued cancellation") }
            catch is CancellationError { }
            XCTAssertTrue(preserved)
            f.history.refresh()
            XCTAssertFalse(file.isDeleted)
            XCTAssertEqual(try generation(f.history, ContentFile.self, key), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            try await file.delete()
            f.history.refresh()
            f.transcripts.refresh()
            XCTAssertTrue(file.isDeleted)
            XCTAssertTrue(transcript.isDeleted)
            XCTAssertNotEqual(try generation(f.history, ContentFile.self, key), before)
        }
    }

    func testExistingRealmFileReplacementDuringStatusCannotBeAdopted() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("book.txt")
            try write("retained payload", to: payload)
            let sourceURL = f.root.appendingPathComponent("source.realm")
            let replacementURL = f.root.appendingPathComponent("replacement.realm")
            let retiredURL = f.root.appendingPathComponent("retired.realm")
            var sourceConfiguration = Realm.Configuration(fileURL: sourceURL)
            sourceConfiguration.objectTypes = [ContentFile.self, ContentPackageFile.self,
                Bookmark.self, HistoryRecord.self, BigSyncPendingMutation.self]
            var replacementConfiguration = sourceConfiguration
            replacementConfiguration.fileURL = replacementURL
            BigSyncMutationTracking.install(configurations: [sourceConfiguration, replacementConfiguration],
                                             excludedClassNames: [])
            let sourceRealm = try await Realm(configuration: sourceConfiguration, actor: MainActor.shared)
            let replacementRealm = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
            let file = ContentFile()
            file.url = try XCTUnwrap(URL(string: "reader-file://file/load/local/book.txt"))
            file.updateCompoundKey()
            try sourceRealm.write {
                sourceRealm.add(file)
                file.refreshChangeMetadata(explicitlyModified: true)
            }
            let replacement = ContentFile()
            replacement.compoundKey = file.compoundKey
            replacement.createdAt = file.createdAt
            replacement.url = file.url
            replacement.title = "Replacement store"
            try replacementRealm.write {
                replacementRealm.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
            }
            let sourceGeneration = try generation(sourceRealm, ContentFile.self, file.compoundKey)
            let replacementGeneration = try generation(replacementRealm, ContentFile.self, replacement.compoundKey)
            f.manager.historyRealmConfigurationOverride = sourceConfiguration
            ReaderContentLoader.historyRealmConfiguration = sourceConfiguration
            f.manager.files = [file.freeze()]
            var didReplace = false
            f.manager.deletionStatusLoader = { backing in
                let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                try FileManager.default.moveItem(at: sourceURL, to: retiredURL)
                do { try FileManager.default.moveItem(at: replacementURL, to: sourceURL) }
                catch {
                    try FileManager.default.moveItem(at: retiredURL, to: sourceURL)
                    throw error
                }
                didReplace = true
                return status
            }
            await assertRejected { try await file.delete() }
            XCTAssertTrue(didReplace)
            XCTAssertFalse(file.isDeleted)
            XCTAssertFalse(replacement.isDeleted)
            XCTAssertEqual(try generation(sourceRealm, ContentFile.self, file.compoundKey), sourceGeneration)
            XCTAssertEqual(try generation(replacementRealm, ContentFile.self, replacement.compoundKey), replacementGeneration)
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "retained payload")
            if didReplace {
                // Restore the original inode before using the public cache
                // eviction API; a successor path cannot identify the old cache.
                try FileManager.default.moveItem(at: sourceURL, to: replacementURL)
                try FileManager.default.moveItem(at: retiredURL, to: sourceURL)
            }
            await RealmBackgroundActor.shared.removeCachedRealm(for: sourceConfiguration)
        }
    }

    func testDeniedInspectionIsNotEvidenceForMissingFileTombstone() async throws {
        try await withFixture { f in
            let blocked = f.library.appendingPathComponent("blocked", isDirectory: true)
            let payload = blocked.appendingPathComponent("book.txt")
            try write("retained bytes", to: payload)
            let file = try record(f, name: "blocked/book.txt")
            let before = try generation(f.history, ContentFile.self, file.compoundKey)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
            try requireDeniedInspection(at: payload)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            f.manager.deletionStatusLoader = { backing in
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
                let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                XCTAssertEqual(status, .fileMissing)
                return status
            }
            do { try await file.delete(); XCTFail("Denied inspection cannot authorize a tombstone") }
            catch { XCTAssertFalse(error is CancellationError) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            f.history.refresh()
            XCTAssertFalse(file.isDeleted)
            XCTAssertEqual(try generation(f.history, ContentFile.self, file.compoundKey), before)
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "retained bytes")
        }
    }

    func testInaccessibleUnselectedLocalCounterpartDoesNotBlockCloudDeletion() async throws {
        try await withFixture { f in
            let blocked = f.library.appendingPathComponent("blocked", isDirectory: true)
            let localPayload = blocked.appendingPathComponent("book.txt")
            try write("unselected local bytes", to: localPayload)
            let cloudRoot = f.root.appendingPathComponent("cloud", isDirectory: true)
            f.manager.cloudDrive = try await CloudDrive(storage: .localDirectory(rootURL: cloudRoot))
            let cloudPayload = cloudRoot.appendingPathComponent("blocked/book.txt")
            try write("selected cloud bytes", to: cloudPayload)
            let file = try record(f, storage: "icloud", name: "blocked/book.txt")
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
            try requireDeniedInspection(at: localPayload)
            let status = try await f.manager.cloudDriveSyncStatus(readerFileURL: file.url)
            XCTAssertEqual(status, .availableLocally)
            try await file.delete()
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            f.history.refresh()
            XCTAssertTrue(file.isDeleted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cloudPayload.path))
            XCTAssertEqual(try String(contentsOf: localPayload, encoding: .utf8), "unselected local bytes")
        }
    }
}
