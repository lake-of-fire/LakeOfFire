import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class ReaderCapturedMediaMutationTests: XCTestCase {
    private final class Authority: @unchecked Sendable {
        private let lock = NSLock()
        private var current = true
        func revoke() { lock.lock(); current = false; lock.unlock() }
        func validate() throws {
            lock.lock(); defer { lock.unlock() }
            if !current { throw CancellationError() }
        }
    }

    private func configuration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func storage(_ configuration: Realm.Configuration) -> ReaderContentLoader.MutationStorage {
        .init(bookmarkConfiguration: configuration, historyConfiguration: configuration,
            feedConfiguration: configuration)
    }

    @MainActor
    private func seed(_ realm: Realm, url: URL) throws -> HistoryRecord {
        let record = HistoryRecord()
        record.url = url
        record.updateCompoundKey()
        record.title = "original"
        try realm.write { realm.add(record) }
        return record
    }

    @MainActor
    func testCapturedStoreDoesNotFollowChangedGlobalConfigurations() async throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let original = try await Realm(configuration: originalConfiguration, actor: MainActor.shared)
        let replacement = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/" + UUID().uuidString)!
        let originalRecord = try seed(original, url: url)
        let replacementRecord = try seed(replacement, url: url)
        let captured = storage(originalConfiguration)
        let previous = (ReaderContentLoader.bookmarkRealmConfiguration,
            ReaderContentLoader.historyRealmConfiguration, ReaderContentLoader.feedEntryRealmConfiguration)
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previous.0
            ReaderContentLoader.historyRealmConfiguration = previous.1
            ReaderContentLoader.feedEntryRealmConfiguration = previous.2
        }
        ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
        ReaderContentLoader.historyRealmConfiguration = replacementConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacementConfiguration
        let replacementJournalCount = replacement.objects(BigSyncPendingMutation.self).count
        let outcome = await ReaderContentLoader.updateContentWithOutcome(url: url, storage: captured,
            validateAuthority: {}) { object in
            object.title = "selected media"
            return true
        }
        await original.asyncRefresh()
        await replacement.asyncRefresh()
        XCTAssertEqual(outcome.matchedObjectCount, 1)
        XCTAssertEqual(outcome.committedObjectCount, 1)
        XCTAssertEqual(outcome.mutatedObjectCount, 1)
        XCTAssertEqual(originalRecord.title, "selected media")
        XCTAssertEqual(replacementRecord.title, "original")
        XCTAssertEqual(replacement.objects(BigSyncPendingMutation.self).count, replacementJournalCount)
        XCTAssertGreaterThan(original.objects(BigSyncPendingMutation.self).count, 0)
    }

    @MainActor
    func testAuthorityRevokedDuringMutationRollsBackFieldsAndJournal() async throws {
        let configuration = configuration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/" + UUID().uuidString)!
        let record = try seed(realm, url: url)
        let journalCount = realm.objects(BigSyncPendingMutation.self).count
        let authority = Authority()
        let outcome = await ReaderContentLoader.updateContentWithOutcome(url: url,
            storage: storage(configuration), validateAuthority: { try authority.validate() }) { object in
            object.title = "must roll back"
            authority.revoke()
            return true
        }
        await realm.asyncRefresh()
        XCTAssertEqual(outcome.committedObjectCount, 0)
        XCTAssertEqual(outcome.mutatedObjectCount, 0)
        XCTAssertTrue(outcome.cancelledBeforeCommit)
        XCTAssertEqual(record.title, "original")
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, journalCount)
    }

    @MainActor
    func testRevokedAuthorityDoesNotInvokeMutation() async throws {
        let configuration = configuration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/" + UUID().uuidString)!
        let record = try seed(realm, url: url)
        let journalCount = realm.objects(BigSyncPendingMutation.self).count
        let authority = Authority()
        authority.revoke()
        let outcome = await ReaderContentLoader.updateContentWithOutcome(url: url,
            storage: storage(configuration), validateAuthority: { try authority.validate() }) { _ in
            XCTFail("Revoked authority reached mutation")
            return true
        }
        await realm.asyncRefresh()
        XCTAssertEqual(outcome.committedObjectCount, 0)
        XCTAssertTrue(outcome.cancelledBeforeCommit)
        XCTAssertEqual(record.title, "original")
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, journalCount)
    }

    @MainActor
    func testAlreadyAppliedSelectionCommitsWithoutNewJournalWork() async throws {
        let configuration = configuration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/" + UUID().uuidString)!
        _ = try seed(realm, url: url)
        let journalCount = realm.objects(BigSyncPendingMutation.self).count
        let outcome = await ReaderContentLoader.updateContentWithOutcome(url: url,
            storage: storage(configuration), validateAuthority: {}) { _ in false }
        await realm.asyncRefresh()
        XCTAssertEqual(outcome.committedObjectCount, 1)
        XCTAssertEqual(outcome.mutatedObjectCount, 0)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, journalCount)
    }
    @MainActor
    func testSamePathRealmReplacementRejectsCapturedMutationAndPreservesBothJournals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-realm-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = URL(string: "https://example.com/" + UUID().uuidString)!
        var originalConfiguration = configuration()
        originalConfiguration.inMemoryIdentifier = nil
        originalConfiguration.fileURL = directory.appendingPathComponent("shared.realm")
        var replacementConfiguration = configuration()
        replacementConfiguration.inMemoryIdentifier = nil
        replacementConfiguration.fileURL = directory.appendingPathComponent("replacement.realm")
        configureLakeOfFireMutationTrackingForTesting(&originalConfiguration)
        configureLakeOfFireMutationTrackingForTesting(&replacementConfiguration)
        let originalCounts = try autoreleasepool {
            let original = try Realm(configuration: originalConfiguration)
            _ = try seed(original, url: url)
            let replacement = try Realm(configuration: replacementConfiguration)
            _ = try seed(replacement, url: url)
            return (original.objects(BigSyncPendingMutation.self).count,
                replacement.objects(BigSyncPendingMutation.self).count)
        }
        let captured = storage(originalConfiguration)
        let originalURL = try XCTUnwrap(originalConfiguration.fileURL)
        let replacementURL = try XCTUnwrap(replacementConfiguration.fileURL)
        let retainedURL = directory.appendingPathComponent("retained.realm")
        try FileManager.default.moveItem(at: originalURL, to: retainedURL)
        try FileManager.default.moveItem(at: replacementURL, to: originalURL)
        let outcome = await ReaderContentLoader.updateContentWithOutcome(url: url,
            storage: captured, validateAuthority: {}) { _ in
            XCTFail("Replacement storage reached mutation")
            return true
        }
        XCTAssertEqual(outcome.committedObjectCount, 0)
        XCTAssertNotNil(outcome.errorMessage)
        var retainedConfiguration = originalConfiguration
        retainedConfiguration.fileURL = retainedURL
        let retained = try Realm(configuration: retainedConfiguration)
        let replacement = try Realm(configuration: originalConfiguration)
        XCTAssertEqual(retained.objects(HistoryRecord.self).first?.title, "original")
        XCTAssertEqual(replacement.objects(HistoryRecord.self).first?.title, "original")
        XCTAssertEqual(retained.objects(BigSyncPendingMutation.self).count, originalCounts.0)
        XCTAssertEqual(replacement.objects(BigSyncPendingMutation.self).count, originalCounts.1)
    }

    @MainActor
    func testSharedFirstCreationUsesOneAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-realm-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = configuration()
        configuration.inMemoryIdentifier = nil
        configuration.fileURL = directory.appendingPathComponent("shared.realm")
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let outcome = await ReaderContentLoader.updateContentWithOutcome(
            url: URL(string: "https://example.com/" + UUID().uuidString)!,
            storage: storage(configuration), validateAuthority: {}) { _ in
            XCTFail("An empty first-created store had a candidate")
            return true
        }
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.matchedObjectCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
    }

    @MainActor
    func testEarlierCommitSurvivesAuthorityRejectionInLaterRepresentation() async throws {
        let configuration = configuration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/" + UUID().uuidString)!
        let history = try seed(realm, url: url)
        let bookmark = Bookmark()
        bookmark.url = url
        bookmark.updateCompoundKey()
        bookmark.title = "original"
        try realm.write { realm.add(bookmark) }
        let journalCount = realm.objects(BigSyncPendingMutation.self).count
        let authority = Authority()
        let outcome = await ReaderContentLoader.updateContentWithOutcome(url: url,
            storage: storage(configuration), validateAuthority: { try authority.validate() }) { object in
            object.title = "selected media"
            if object is HistoryRecord { authority.revoke() }
            return true
        }
        await realm.asyncRefresh()
        XCTAssertEqual(outcome.matchedObjectCount, 2)
        XCTAssertEqual(outcome.committedObjectCount, 1)
        XCTAssertEqual(outcome.mutatedObjectCount, 1)
        XCTAssertTrue(outcome.cancelledBeforeCommit)
        XCTAssertEqual(bookmark.title, "selected media")
        XCTAssertEqual(history.title, "original")
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, journalCount + 1)
    }

    @MainActor
    func testCurrentMutationKeepsEarlierCommitWhenLaterMutationCancels() async throws {
        let configuration = configuration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/" + UUID().uuidString)!
        let history = try seed(realm, url: url)
        let bookmark = Bookmark()
        bookmark.url = url
        bookmark.updateCompoundKey()
        bookmark.title = "original"
        try realm.write { realm.add(bookmark) }
        let journalCount = realm.objects(BigSyncPendingMutation.self).count
        let previous = (ReaderContentLoader.bookmarkRealmConfiguration,
            ReaderContentLoader.historyRealmConfiguration, ReaderContentLoader.feedEntryRealmConfiguration)
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previous.0
            ReaderContentLoader.historyRealmConfiguration = previous.1
            ReaderContentLoader.feedEntryRealmConfiguration = previous.2
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let mutation = Task { @RealmBackgroundActor in
            await ReaderContentLoader.updateContentWithOutcome(url: url) { object in
                object.title = "selected media"
                if object is HistoryRecord {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return true
            }
        }
        let outcome = await mutation.value
        await realm.asyncRefresh()
        XCTAssertEqual(outcome.matchedObjectCount, 2)
        XCTAssertEqual(outcome.committedObjectCount, 1)
        XCTAssertEqual(outcome.mutatedObjectCount, 1)
        XCTAssertTrue(outcome.cancelledBeforeCommit)
        XCTAssertEqual(bookmark.title, "selected media")
        XCTAssertEqual(history.title, "original")
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, journalCount + 1)
    }

    @MainActor
    func testCapturedMutationRoutesFilesToHistoryWithSeparateSchemas() async throws {
        try await exerciseSeparateStorageMutation(captured: true)
    }

    @MainActor
    func testCurrentMutationReportsDurableOutcomesWithSeparateSchemas() async throws {
        try await exerciseSeparateStorageMutation(captured: false)
    }

    @MainActor
    private func exerciseSeparateStorageMutation(captured: Bool) async throws {
        var bookmarks = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        bookmarks.objectTypes = [Bookmark.self]
        configureLakeOfFireMutationTrackingForTesting(&bookmarks)
        var history = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        history.objectTypes = [HistoryRecord.self, ContentFile.self]
        configureLakeOfFireMutationTrackingForTesting(&history)
        var feeds = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        feeds.objectTypes = [FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&feeds)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: bookmarks)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: history)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: feeds)
        }
        let bookmarkRealm = try await Realm(configuration: bookmarks, actor: MainActor.shared)
        let historyRealm = try await Realm(configuration: history, actor: MainActor.shared)
        let feedRealm = try await Realm(configuration: feeds, actor: MainActor.shared)
        let url = URL(string: "https://example.com/media-file/" + UUID().uuidString)!
        let bookmark = Bookmark()
        bookmark.url = url
        bookmark.title = "original bookmark"
        bookmark.updateCompoundKey()
        try bookmarkRealm.write { bookmarkRealm.add(bookmark) }
        let record = try seed(historyRealm, url: url)
        let file = ContentFile()
        file.url = url
        file.title = "original file"
        file.updateCompoundKey()
        try historyRealm.write { historyRealm.add(file) }
        let previous = (ReaderContentLoader.bookmarkRealmConfiguration,
            ReaderContentLoader.historyRealmConfiguration, ReaderContentLoader.feedEntryRealmConfiguration)
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previous.0
            ReaderContentLoader.historyRealmConfiguration = previous.1
            ReaderContentLoader.feedEntryRealmConfiguration = previous.2
        }
        ReaderContentLoader.bookmarkRealmConfiguration = bookmarks
        ReaderContentLoader.historyRealmConfiguration = history
        ReaderContentLoader.feedEntryRealmConfiguration = feeds
        let outcome: ReaderContentMutationOutcome
        if captured {
            outcome = await ReaderContentLoader.updateContentWithOutcome(url: url,
                storage: .init(bookmarkConfiguration: bookmarks, historyConfiguration: history,
                    feedConfiguration: feeds), validateAuthority: {}) { object in
                object.title = "selected media"
                return true
            }
        } else {
            outcome = await ReaderContentLoader.updateContentWithOutcome(url: url) { object in
                object.title = "selected media"
                return true
            }
        }
        await bookmarkRealm.asyncRefresh()
        await historyRealm.asyncRefresh()
        await feedRealm.asyncRefresh()
        XCTAssertNil(outcome.errorMessage)
        XCTAssertFalse(outcome.cancelledBeforeCommit)
        XCTAssertEqual(outcome.matchedObjectCount, 3)
        XCTAssertEqual(outcome.committedObjectCount, 3)
        XCTAssertEqual(outcome.mutatedObjectCount, 3)
        XCTAssertEqual(bookmark.title, "selected media")
        XCTAssertEqual(record.title, "selected media")
        XCTAssertEqual(file.title, "selected media")
        XCTAssertEqual(bookmarkRealm.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertEqual(historyRealm.objects(BigSyncPendingMutation.self).count, 2)
        XCTAssertEqual(feedRealm.objects(BigSyncPendingMutation.self).count, 0)
    }

}
