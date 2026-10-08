import Foundation
import XCTest
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
@testable import LakeOfFireContent

/// Actual Realm companions for the committed-view repair. These fixtures use
/// only existing models and their own explicitly configured in-memory stores.
final class HistoryDemotionCommittedStateTests: XCTestCase {
    @RealmBackgroundActor
    private final class Fixture {
        let configurations: [Realm.Configuration]
        let historyRealm: Realm
        let bookmarkRealm: Realm
        let history: HistoryRecord
        let bookmark: Bookmark
        let previousBookmark: Realm.Configuration
        let previousGate: (@Sendable (ReaderContentLoader.ContentWriteOperation) async -> Void)?
        let url = URL(string: "https://history-demotion.example/entry")!
        let originalDate = Date(timeIntervalSince1970: 100)
        var gateWasReached = false
        var gateError: Error?

        init(shared: Bool = false, hasBookmark: Bool = true,
             demoted: Bool? = nil, insertHistory: Bool = true) async throws {
            previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
            previousGate = ReaderContentLoader.contentWriteGateForTesting
            configurations = (0..<(shared ? 1 : 2)).map { _ in
                Realm.Configuration(inMemoryIdentifier: "history-demotion-\(UUID())",
                    objectTypes: [Bookmark.self, HistoryRecord.self, BigSyncPendingMutation.self])
            }
            BigSyncMutationTracking.install(configurations: configurations, excludedClassNames: [],
                mutationJournalIdentityProvider: {
                    .init(installationIdentifier: "history-demotion-fixture",
                          replicaBindingGenerationIdentifier: "history-demotion-binding")
                })
            historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configurations[0])
            bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configurations[shared ? 0 : 1])
            history = HistoryRecord()
            history.url = url
            history.updateCompoundKey()
            history.createdAt = originalDate
            history.modifiedAt = originalDate
            history.isDemoted = demoted
            bookmark = Bookmark()
            bookmark.url = url
            bookmark.updateCompoundKey()
            bookmark.createdAt = originalDate
            bookmark.modifiedAt = originalDate
            if insertHistory { try historyRealm.write { historyRealm.add(history) } }
            if hasBookmark { try bookmarkRealm.write { bookmarkRealm.add(bookmark) } }
            ReaderContentLoader.bookmarkRealmConfiguration = bookmarkRealm.configuration
            ReaderContentLoader.contentWriteGateForTesting = nil
        }

        func close() async {
            ReaderContentLoader.contentWriteGateForTesting = previousGate
            for realm in [historyRealm, bookmarkRealm] where realm.isInWriteTransaction {
                realm.cancelWrite()
            }
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            for configuration in configurations {
                _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            }
        }
        func apply(skipPreviouslyDemoted: Bool = true) async throws {
            try await history.refreshDemotedStatus(bookmarkRealmConfiguration: bookmarkRealm.configuration,
                skipPreviouslyDemoted: skipPreviouslyDemoted)
        }
        func mutation() -> BigSyncPendingMutation? {
            historyRealm.object(ofType: BigSyncPendingMutation.self,
                forPrimaryKey: HistoryRecord.className() + "." + history.compoundKey)
        }
        func rollbackHistoryAtGate() {
            gateWasReached = true
            XCTAssertTrue(historyRealm.isInWriteTransaction)
            if historyRealm.isInWriteTransaction { historyRealm.cancelWrite() }
        }
        func commitHistoryAtGate() {
            gateWasReached = true
            XCTAssertTrue(historyRealm.isInWriteTransaction)
            do { try historyRealm.commitWrite() }
            catch {
                gateError = error
                if historyRealm.isInWriteTransaction { historyRealm.cancelWrite() }
            }
        }
        func commitEligibilityAtGate() {
            gateWasReached = true
            do { try historyRealm.write { history.isReaderModeAvailable = true } }
            catch { gateError = error }
        }
        func assertJournaled(_ demoted: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(history.isDemoted, demoted, file: file, line: line)
            let row = try XCTUnwrap(mutation(), file: file, line: line)
            XCTAssertEqual(row.changedAt, history.explicitlyModifiedAt, file: file, line: line)
            // The journal tracks a record generation; deletion state belongs to the domain object.
            XCTAssertFalse(history.isDeleted, file: file, line: line)
            XCTAssertFalse(historyRealm.isInWriteTransaction, file: file, line: line)
        }
    }

    @RealmBackgroundActor
    func testProvisionalBookmarkDeletionDoesNotDemoteCommittedHistory() async throws {
        let f = try await Fixture()
        addTeardownBlock { await f.close() }
        f.bookmarkRealm.beginWrite()
        f.bookmark.isDeleted = true
        try await f.apply()
        try f.assertJournaled(false)
        XCTAssertTrue(f.bookmarkRealm.isInWriteTransaction)
        XCTAssertTrue(f.bookmark.isDeleted)
        XCTAssertTrue(f.bookmarkRealm.objects(BigSyncPendingMutation.self).isEmpty)
        f.bookmarkRealm.cancelWrite()
        XCTAssertFalse(f.bookmark.isDeleted)
        XCTAssertEqual(f.history.isDemoted, false)
    }

    @RealmBackgroundActor
    func testProvisionalBookmarkInsertionCannotPromoteHistory() async throws {
        let f = try await Fixture(hasBookmark: false)
        addTeardownBlock { await f.close() }
        f.bookmarkRealm.beginWrite()
        f.bookmarkRealm.add(f.bookmark)
        try await f.apply()
        try f.assertJournaled(true)
        XCTAssertTrue(f.bookmarkRealm.isInWriteTransaction)
        XCTAssertTrue(f.bookmarkRealm.objects(BigSyncPendingMutation.self).isEmpty)
        f.bookmarkRealm.cancelWrite()
        XCTAssertTrue(f.bookmarkRealm.objects(Bookmark.self).isEmpty)
        XCTAssertEqual(f.history.isDemoted, true)
    }

    @RealmBackgroundActor
    func testProvisionalBookmarkURLCannotHideCommittedMembership() async throws {
        let f = try await Fixture()
        addTeardownBlock { await f.close() }
        f.bookmarkRealm.beginWrite()
        let other = URL(string: "https://history-demotion.example/provisional")!
        f.bookmark.url = other
        try await f.apply()
        try f.assertJournaled(false)
        XCTAssertTrue(f.bookmarkRealm.isInWriteTransaction)
        XCTAssertEqual(f.bookmark.url, other)
        f.bookmarkRealm.cancelWrite()
        XCTAssertEqual(f.bookmark.url, f.url)
    }

    @RealmBackgroundActor
    func testProvisionalHistoryDeletionCannotSuppressCommittedRequest() async throws {
        let f = try await Fixture(hasBookmark: false)
        addTeardownBlock { await f.close() }
        f.historyRealm.beginWrite()
        f.history.isDeleted = true
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            await f.rollbackHistoryAtGate()
        }
        try await f.apply()
        XCTAssertTrue(f.gateWasReached, "The real method must reach admission after its committed preflight")
        XCTAssertFalse(f.history.isDeleted)
        try f.assertJournaled(true)
    }

    @RealmBackgroundActor
    func testProvisionalVisibilityCannotSupplyCommittedNoOp() async throws {
        let f = try await Fixture(hasBookmark: false)
        addTeardownBlock { await f.close() }
        f.historyRealm.beginWrite()
        f.history.isDemoted = false
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            await f.rollbackHistoryAtGate()
        }
        try await f.apply()
        XCTAssertTrue(f.gateWasReached)
        try f.assertJournaled(true)
    }

    @RealmBackgroundActor
    func testCommittedVisibleHistoryRemainsANoOp() async throws {
        let f = try await Fixture(hasBookmark: false, demoted: false)
        addTeardownBlock { await f.close() }
        ReaderContentLoader.contentWriteGateForTesting = { _ in
            XCTFail("A committed visible row should retain the existing early no-op")
        }
        try await f.apply()
        XCTAssertEqual(f.history.isDemoted, false)
        XCTAssertEqual(f.history.modifiedAt, f.originalDate)
        XCTAssertNil(f.mutation())
    }

    @RealmBackgroundActor
    func testExplicitRefreshReconsidersCommittedVisibility() async throws {
        let f = try await Fixture(hasBookmark: false, demoted: false)
        addTeardownBlock { await f.close() }
        try await f.apply(skipPreviouslyDemoted: false)
        try f.assertJournaled(true)
        let generation = try XCTUnwrap(f.mutation()?.generation)
        try await f.apply(skipPreviouslyDemoted: false)
        XCTAssertEqual(f.mutation()?.generation, generation)
    }

    @RealmBackgroundActor
    func testCommittedBookmarkDeletionIsStillObserved() async throws {
        let f = try await Fixture()
        addTeardownBlock { await f.close() }
        try f.bookmarkRealm.write { f.bookmark.isDeleted = true }
        try await f.apply()
        try f.assertJournaled(true)
    }

    @RealmBackgroundActor
    func testEligibilityCommittedBeforeAdmissionUsesCurrentHistory() async throws {
        let f = try await Fixture(hasBookmark: false)
        addTeardownBlock { await f.close() }
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            await f.commitEligibilityAtGate()
        }
        try await f.apply()
        XCTAssertTrue(f.gateWasReached)
        XCTAssertNil(f.gateError)
        try f.assertJournaled(false)
        XCTAssertTrue(f.history.isReaderModeAvailable)
    }

    @RealmBackgroundActor
    func testSharedRealmPreservesOrdinaryBookmarkAndNoOpSemantics() async throws {
        let f = try await Fixture(shared: true)
        addTeardownBlock { await f.close() }
        XCTAssertEqual(f.historyRealm, f.bookmarkRealm)
        try await f.apply()
        try f.assertJournaled(false)
        XCTAssertEqual(f.historyRealm.objects(BigSyncPendingMutation.self).count, 1)
        let generation = try XCTUnwrap(f.mutation()?.generation)
        try await f.apply(skipPreviouslyDemoted: false)
        XCTAssertEqual(f.mutation()?.generation, generation)
    }

    @RealmBackgroundActor
    func testExplicitBookmarkStoreDoesNotFollowGlobalReplacement() async throws {
        let f = try await Fixture()
        addTeardownBlock { await f.close() }
        ReaderContentLoader.bookmarkRealmConfiguration = f.historyRealm.configuration
        // There is no Bookmark row in historyRealm. The explicit original store
        // remains valid and must not silently follow the new default route.
        XCTAssertTrue(f.historyRealm.objects(Bookmark.self).isEmpty)
        try await f.apply()
        try f.assertJournaled(false)
    }

    @RealmBackgroundActor
    func testMismatchedExplicitAdmissionRejectsWithoutHistoryMutation() async throws {
        let f = try await Fixture()
        addTeardownBlock { await f.close() }
        let wrong = RealmBackgroundActor.shared.captureStorageAdmission(for: f.historyRealm.configuration)
        do {
            try await f.history.refreshDemotedStatus(bookmarkRealmConfiguration: f.bookmarkRealm.configuration,
                bookmarkStorageAdmission: wrong)
            XCTFail("An admission from another store must be rejected")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertNil(f.history.isDemoted)
        XCTAssertNil(f.mutation())
        XCTAssertEqual(f.history.modifiedAt, f.originalDate)
    }

    @RealmBackgroundActor
    func testPendingHistoryCreationIsRefreshedAfterItsOwnerCommits() async throws {
        let f = try await Fixture(hasBookmark: false, insertHistory: false)
        addTeardownBlock { await f.close() }
        f.historyRealm.beginWrite()
        f.historyRealm.add(f.history)
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            await f.commitHistoryAtGate()
        }
        try await f.apply()
        XCTAssertTrue(f.gateWasReached)
        XCTAssertNil(f.gateError)
        try f.assertJournaled(true)
    }

    @RealmBackgroundActor
    func testRolledBackHistoryCreationIsNotRecreatedOrJournaled() async throws {
        let f = try await Fixture(hasBookmark: false, insertHistory: false)
        addTeardownBlock { await f.close() }
        f.historyRealm.beginWrite()
        f.historyRealm.add(f.history)
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            await f.rollbackHistoryAtGate()
        }
        try await f.apply()
        XCTAssertTrue(f.gateWasReached)
        // A rolled-back insertion may invalidate its managed wrapper. Inspect
        // the owning Realm, not fields on that now-retired object.
        XCTAssertTrue(f.historyRealm.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(f.historyRealm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertFalse(f.historyRealm.isInWriteTransaction)
    }
}
