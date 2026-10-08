import Foundation
import XCTest
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
@testable import LakeOfFireContent

/// Actual Realm companions for the committed-view repair. These fixtures use
/// only existing models and their own explicitly configured in-memory stores.
final class HistoryDemotionCommittedStateTests: XCTestCase {
    private enum Caller: CaseIterable { case message, loader }

    @RealmBackgroundActor
    private final class Fixture {
        let configurations: [Realm.Configuration]
        let historyRealm: Realm
        let bookmarkRealm: Realm
        let history: HistoryRecord
        let bookmark: Bookmark
        let previousBookmark: Realm.Configuration
        let previousHistory: Realm.Configuration
        let previousGate: (@Sendable (ReaderContentLoader.ContentWriteOperation) async -> Void)?
        let url = URL(string: "https://history-demotion.example/entry")!
        let originalDate = Date(timeIntervalSince1970: 100)
        var gateWasReached = false
        var gateError: Error?
        var loaderReturnedIdentity = false
        var ownerJournalGeneration: String?

        init(shared: Bool = false, hasBookmark: Bool = true,
             demoted: Bool? = nil, insertHistory: Bool = true) async throws {
            previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
            previousHistory = ReaderContentLoader.historyRealmConfiguration
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
            do {
                historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configurations[0])
                bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configurations[shared ? 0 : 1])
            } catch {
                // A throwing initializer never registers XCTest teardown.
                for configuration in configurations {
                    _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
                }
                throw error
            }
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
            do {
                if insertHistory { try historyRealm.write { historyRealm.add(history) } }
                if hasBookmark { try bookmarkRealm.write { bookmarkRealm.add(bookmark) } }
            } catch {
                for configuration in configurations {
                    _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
                }
                throw error
            }
            ReaderContentLoader.bookmarkRealmConfiguration = bookmarkRealm.configuration
            ReaderContentLoader.contentWriteGateForTesting = nil
        }

        func close() async {
            ReaderContentLoader.contentWriteGateForTesting = previousGate
            for realm in [historyRealm, bookmarkRealm] where realm.isInWriteTransaction {
                realm.cancelWrite()
            }
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            for configuration in configurations {
                _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            }
        }
        func apply(skipPreviouslyDemoted: Bool = true) async throws {
            try await history.refreshDemotedStatus(bookmarkRealmConfiguration: bookmarkRealm.configuration,
                skipPreviouslyDemoted: skipPreviouslyDemoted)
        }
        func applyCaller(_ caller: Caller) async throws {
            let actor = RealmBackgroundActor.shared
            let historyAdmission = actor.captureStorageAdmission(for: historyRealm.configuration)
            let bookmarkAdmission = actor.realmCacheKey(for: historyRealm.configuration) == actor.realmCacheKey(for: bookmarkRealm.configuration)
                ? historyAdmission : actor.captureStorageAdmission(for: bookmarkRealm.configuration)
            switch caller {
            case .message:
                try await HistoryRecord.refreshDemotedStatus(forURL: url,
                    historyRealmConfiguration: historyRealm.configuration,
                    historyStorageAdmission: historyAdmission,
                    bookmarkRealmConfiguration: bookmarkRealm.configuration,
                    bookmarkStorageAdmission: bookmarkAdmission)
            case .loader:
                let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: history,
                    storageAdmission: historyAdmission))
                loaderReturnedIdentity = try await ReaderContentLoader.finishLoadedContentAndRefreshDemotion(reference,
                    countsAsHistoryVisit: false, readerModeRequired: false,
                    bookmarkRealmConfiguration: bookmarkRealm.configuration,
                    bookmarkStorageAdmission: bookmarkAdmission) != nil
            }
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
        func commitDeletionWithMetadataAtGate() {
            history.refreshChangeMetadata(explicitlyModified: true)
            ownerJournalGeneration = mutation()?.generation
            commitHistoryAtGate()
        }
        func deleteHistoryAtGate() {
            gateWasReached = true
            do { try historyRealm.write { historyRealm.delete(history) } }
            catch { gateError = error }
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
            XCTAssertFalse(history.isDeleted, file: file, line: line)
            XCTAssertEqual(row.entityType, HistoryRecord.className(), file: file, line: line)
            XCTAssertEqual(row.objectIdentifier, history.compoundKey, file: file, line: line)
            XCTAssertFalse(historyRealm.isInWriteTransaction, file: file, line: line)
        }
    }

    @RealmBackgroundActor
    func testProvisionalBookmarkDeletionDoesNotDemoteCommittedHistory() async throws {
        let f = try await Fixture()
        addTeardownBlock { await f.close() }
        try f.bookmarkRealm.beginWrite()
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
        try f.bookmarkRealm.beginWrite()
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
        try f.bookmarkRealm.beginWrite()
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
        try f.historyRealm.beginWrite()
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
        try f.historyRealm.beginWrite()
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
        try f.historyRealm.beginWrite()
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
        try f.historyRealm.beginWrite()
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

    @RealmBackgroundActor
    func testPendingDemotionCannotUseCommittedVisibilityAsNoOp() async throws {
        let f = try await Fixture(demoted: false)
        addTeardownBlock { await f.close() }
        try f.historyRealm.beginWrite()
        f.history.isDemoted = true
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            await f.commitHistoryAtGate()
        }
        try await f.apply()
        XCTAssertTrue(f.gateWasReached)
        XCTAssertNil(f.gateError)
        // The settled demoted row must reconsider the committed bookmark.
        try f.assertJournaled(false)
    }

    @RealmBackgroundActor
    func testProductionCallerDeletionRollbackStillDemotes() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false)
            addTeardownBlock { await f.close() }
            try f.historyRealm.beginWrite()
            f.history.isDeleted = true
            // Ordinary reads still exclude provisional deletion; demotion has
            // its own delivered-event boundary used by both production paths.
            XCTAssertNil(HistoryRecord.getOpenedRecord(forURL: f.url, in: f.historyRealm))
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .demotion else { return }
                await f.rollbackHistoryAtGate()
            }
            try await f.applyCaller(caller)
            XCTAssertTrue(f.gateWasReached)
            if caller == .loader { XCTAssertFalse(f.loaderReturnedIdentity) }
            try f.assertJournaled(true)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerDeletionCommitDoesNotDemoteOrJournal() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false)
            addTeardownBlock { await f.close() }
            try f.historyRealm.beginWrite()
            f.history.isDeleted = true
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .demotion else { return }
                await f.commitHistoryAtGate()
            }
            try await f.applyCaller(caller)
            XCTAssertTrue(f.gateWasReached)
            XCTAssertNil(f.gateError)
            XCTAssertTrue(f.history.isDeleted)
            XCTAssertNil(f.history.isDemoted)
            XCTAssertNil(f.mutation())
            XCTAssertEqual(f.history.modifiedAt, f.originalDate)
            XCTAssertFalse(f.historyRealm.isInWriteTransaction)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerDeletionCommitPreservesOwnerJournal() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false)
            addTeardownBlock { await f.close() }
            try f.historyRealm.beginWrite()
            f.history.isDeleted = true
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .demotion else { return }
                await f.commitDeletionWithMetadataAtGate()
            }
            try await f.applyCaller(caller)
            XCTAssertTrue(f.gateWasReached)
            XCTAssertNil(f.gateError)
            let generation = try XCTUnwrap(f.ownerJournalGeneration)
            XCTAssertEqual(f.mutation()?.generation, generation)
            XCTAssertEqual(f.mutation()?.changedAt, f.history.explicitlyModifiedAt)
            XCTAssertTrue(f.history.isDeleted)
            XCTAssertNil(f.history.isDemoted)
            XCTAssertEqual(f.historyRealm.objects(BigSyncPendingMutation.self).count, 1)
            XCTAssertFalse(f.historyRealm.isInWriteTransaction)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerCreationCommitRefreshesSettledIdentity() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false, insertHistory: false)
            addTeardownBlock { await f.close() }
            try f.historyRealm.beginWrite()
            f.historyRealm.add(f.history)
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .demotion else { return }
                await f.commitHistoryAtGate()
            }
            try await f.applyCaller(caller)
            XCTAssertTrue(f.gateWasReached)
            XCTAssertNil(f.gateError)
            try f.assertJournaled(true)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerCreationRollbackNeverRecreatesIdentity() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false, insertHistory: false)
            addTeardownBlock { await f.close() }
            try f.historyRealm.beginWrite()
            f.historyRealm.add(f.history)
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .demotion else { return }
                await f.rollbackHistoryAtGate()
            }
            try await f.applyCaller(caller)
            XCTAssertTrue(f.gateWasReached)
            XCTAssertTrue(f.historyRealm.objects(HistoryRecord.self).isEmpty)
            XCTAssertTrue(f.historyRealm.objects(BigSyncPendingMutation.self).isEmpty)
            XCTAssertFalse(f.historyRealm.isInWriteTransaction)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerRevivalCommitRefreshesSettledIdentity() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false)
            addTeardownBlock { await f.close() }
            try f.historyRealm.write { f.history.isDeleted = true }
            try f.historyRealm.beginWrite()
            f.history.isDeleted = false
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .demotion else { return }
                await f.commitHistoryAtGate()
            }
            try await f.applyCaller(caller)
            XCTAssertTrue(f.gateWasReached)
            XCTAssertNil(f.gateError)
            try f.assertJournaled(true)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerRevivalRollbackDoesNotReviveOrJournal() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false)
            addTeardownBlock { await f.close() }
            try f.historyRealm.write { f.history.isDeleted = true }
            try f.historyRealm.beginWrite()
            f.history.isDeleted = false
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .demotion else { return }
                await f.rollbackHistoryAtGate()
            }
            try await f.applyCaller(caller)
            XCTAssertTrue(f.gateWasReached)
            XCTAssertTrue(f.history.isDeleted)
            XCTAssertNil(f.history.isDemoted)
            XCTAssertNil(f.mutation())
            XCTAssertEqual(f.history.modifiedAt, f.originalDate)
            XCTAssertFalse(f.historyRealm.isInWriteTransaction)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerNoOpPreservesJournalGeneration() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false)
            addTeardownBlock { await f.close() }
            try await f.applyCaller(caller)
            try f.assertJournaled(true)
            let generation = try XCTUnwrap(f.mutation()?.generation)
            let modifiedAt = f.history.modifiedAt
            try await f.applyCaller(caller)
            XCTAssertEqual(f.mutation()?.generation, generation)
            XCTAssertEqual(f.history.modifiedAt, modifiedAt)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerCommittedVisibleNoOpCreatesNoJournal() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(hasBookmark: false, demoted: false)
            addTeardownBlock { await f.close() }
            ReaderContentLoader.contentWriteGateForTesting = { _ in
                XCTFail("A settled visible identity needs no demotion writer")
            }
            try await f.applyCaller(caller)
            XCTAssertEqual(f.history.isDemoted, false)
            XCTAssertEqual(f.history.modifiedAt, f.originalDate)
            XCTAssertNil(f.mutation())
        }
    }

    @RealmBackgroundActor
    func testProductionCallerExplicitStorageSurvivesGlobalReplacement() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture()
            addTeardownBlock { await f.close() }
            let previousHistory = ReaderContentLoader.historyRealmConfiguration
            ReaderContentLoader.historyRealmConfiguration = f.bookmarkRealm.configuration
            ReaderContentLoader.bookmarkRealmConfiguration = f.historyRealm.configuration
            try await f.applyCaller(caller)
            try f.assertJournaled(false)
            XCTAssertTrue(f.bookmarkRealm.objects(HistoryRecord.self).isEmpty)
            XCTAssertTrue(f.bookmarkRealm.objects(BigSyncPendingMutation.self).isEmpty)
            ReaderContentLoader.historyRealmConfiguration = previousHistory
        }
    }

    @RealmBackgroundActor
    func testProductionCallerSharedStoreUsesSettledBookmarkMembership() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture(shared: true)
            addTeardownBlock { await f.close() }
            try f.historyRealm.beginWrite()
            f.history.isDeleted = true
            f.bookmark.isDeleted = true
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .demotion else { return }
                await f.rollbackHistoryAtGate()
            }
            try await f.applyCaller(caller)
            XCTAssertTrue(f.gateWasReached)
            try f.assertJournaled(false)
            XCTAssertFalse(f.bookmark.isDeleted)
            XCTAssertEqual(f.historyRealm.objects(BigSyncPendingMutation.self).count, 1)
        }
    }

    @RealmBackgroundActor
    func testProductionCallerRejectsMismatchedBookmarkAdmission() async throws {
        for caller in Caller.allCases {
            let f = try await Fixture()
            addTeardownBlock { await f.close() }
            let actor = RealmBackgroundActor.shared
            let wrong = actor.captureStorageAdmission(for: f.historyRealm.configuration)
            do {
                switch caller {
                case .message:
                    try await HistoryRecord.refreshDemotedStatus(forURL: f.url,
                        historyRealmConfiguration: f.historyRealm.configuration,
                        historyStorageAdmission: wrong,
                        bookmarkRealmConfiguration: f.bookmarkRealm.configuration,
                        bookmarkStorageAdmission: wrong)
                case .loader:
                    let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: f.history,
                        storageAdmission: wrong))
                    _ = try await ReaderContentLoader.finishLoadedContentAndRefreshDemotion(reference,
                        countsAsHistoryVisit: false, readerModeRequired: false,
                        bookmarkRealmConfiguration: f.bookmarkRealm.configuration,
                        bookmarkStorageAdmission: wrong)
                }
                XCTFail("A captured admission from another store must reject the callback")
            } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
            XCTAssertNil(f.history.isDemoted)
            XCTAssertNil(f.mutation())
            XCTAssertEqual(f.history.modifiedAt, f.originalDate)
        }
    }

    @RealmBackgroundActor
    func testMessageDemotionRejectsMismatchedHistoryAdmission() async throws {
        let f = try await Fixture()
        addTeardownBlock { await f.close() }
        let wrong = RealmBackgroundActor.shared.captureStorageAdmission(for: f.bookmarkRealm.configuration)
        do {
            try await HistoryRecord.refreshDemotedStatus(forURL: f.url,
                historyRealmConfiguration: f.historyRealm.configuration,
                historyStorageAdmission: wrong,
                bookmarkRealmConfiguration: f.bookmarkRealm.configuration,
                bookmarkStorageAdmission: wrong)
            XCTFail("The URL entry must not recapture history authority")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertNil(f.history.isDemoted)
        XCTAssertNil(f.mutation())
        XCTAssertEqual(f.history.modifiedAt, f.originalDate)
    }

    @RealmBackgroundActor
    func testMessageDemotionPrefersCommittedIdentityOverProvisionalRecency() async throws {
        let f = try await Fixture(hasBookmark: false)
        addTeardownBlock { await f.close() }
        let other = HistoryRecord()
        other.url = f.url
        other.compoundKey = f.history.compoundKey + "-other"
        other.lastVisitedAt = f.history.lastVisitedAt.addingTimeInterval(-100)
        try f.historyRealm.write { f.historyRealm.add(other) }
        try f.historyRealm.beginWrite()
        f.history.isDeleted = true
        other.lastVisitedAt = f.history.lastVisitedAt.addingTimeInterval(100)
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            await f.rollbackHistoryAtGate()
        }
        try await f.applyCaller(.message)
        XCTAssertTrue(f.gateWasReached)
        try f.assertJournaled(true)
        XCTAssertNil(other.isDemoted)
        XCTAssertEqual(f.historyRealm.objects(BigSyncPendingMutation.self).count, 1)
    }

    @RealmBackgroundActor
    func testCancellationAtDemotionGateLeavesNoMutation() async throws {
        let f = try await Fixture(hasBookmark: false)
        addTeardownBlock { await f.close() }
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let request = Task { @RealmBackgroundActor in try await f.apply() }
        do {
            try await request.value
            XCTFail("Cancellation before native admission must reject the request")
        } catch is CancellationError { }
        XCTAssertNil(f.history.isDemoted)
        XCTAssertNil(f.mutation())
        XCTAssertEqual(f.history.modifiedAt, f.originalDate)
        XCTAssertFalse(f.historyRealm.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testCommittedTombstoneRemainsANoOpWithoutPendingWriter() async throws {
        let f = try await Fixture(hasBookmark: false)
        addTeardownBlock { await f.close() }
        try f.historyRealm.write { f.history.isDeleted = true }
        ReaderContentLoader.contentWriteGateForTesting = { _ in
            XCTFail("A settled tombstone should retain its existing early no-op")
        }
        try await f.apply()
        XCTAssertTrue(f.history.isDeleted)
        XCTAssertNil(f.history.isDemoted)
        XCTAssertNil(f.mutation())
        XCTAssertEqual(f.history.modifiedAt, f.originalDate)
    }

    @RealmBackgroundActor
    func testHistoryInvalidatedBeforeAdmissionIsNotRecreated() async throws {
        let f = try await Fixture(hasBookmark: false)
        addTeardownBlock { await f.close() }
        ReaderContentLoader.contentWriteGateForTesting = { operation in
            guard operation == .demotion else { return }
            await f.deleteHistoryAtGate()
        }
        try await f.apply()
        XCTAssertTrue(f.gateWasReached)
        XCTAssertNil(f.gateError)
        XCTAssertTrue(f.history.isInvalidated)
        // This fixture hard-deletes to invalidate a wrapper; production deletion
        // remains a soft mutation. Never read persisted fields on that wrapper.
        XCTAssertTrue(f.historyRealm.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(f.historyRealm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertFalse(f.historyRealm.isInWriteTransaction)
    }
}
