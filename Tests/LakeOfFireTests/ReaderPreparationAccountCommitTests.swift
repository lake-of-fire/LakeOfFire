import Foundation
import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeKit
@testable import LakeOfFireContent

private final class PreparationCommitAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountSessionSnapshot
    private var permitsSelection = true

    init(identity: AccountSessionIdentity = .authenticated(userID: 11)) {
        value = AccountSessionSnapshot(identity: identity, generation: 1)
    }

    func snapshot() -> AccountSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replaceAccount() {
        lock.lock()
        value = AccountSessionSnapshot(identity: .authenticated(userID: 22), generation: 2)
        lock.unlock()
    }

    func selectionIsCurrent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return permitsSelection
    }

    func retireSelection() {
        lock.lock()
        permitsSelection = false
        lock.unlock()
    }
}

@MainActor
final class ReaderPreparationAccountCommitTests: XCTestCase {
    private func fixture() throws -> (Realm, Bookmark) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString,
                                                objectTypes: [Bookmark.self, BigSyncPendingMutation.self])
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let realm = try Realm(configuration: configuration)
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/preparation-commit")!
        bookmark.title = "Original"
        bookmark.updateCompoundKey()
        try realm.write { realm.add(bookmark) }
        let capturedConfiguration = configuration
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration) }
        return (realm, bookmark)
    }

    func testAccountReplacementAfterMutationRollsBackFieldsAndJournal() async throws {
        let (realm, bookmark) = try fixture()
        let admission = PreparationCommitAdmission()
        let access = AccountSessionAccess(testSnapshotProvider: { admission.snapshot() })
        let snapshot = access.snapshot
        do {
            try await bookmark.asyncWrite(account: (access, snapshot)) { _, row in
                row.title = "Retired account mutation"
                row.refreshChangeMetadata(explicitlyModified: true)
                admission.replaceAccount()
            }
            XCTFail("An obsolete account cannot submit the native commit")
        } catch is CancellationError { }
        realm.refresh()
        XCTAssertEqual(bookmark.title, "Original")
        XCTAssertNil(bookmark.explicitlyModifiedAt)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertFalse(realm.isInWriteTransaction)
    }

    func testCurrentAccountCommitsFieldsAndJournalTogether() async throws {
        let (realm, bookmark) = try fixture()
        let admission = PreparationCommitAdmission()
        let access = AccountSessionAccess(testSnapshotProvider: { admission.snapshot() })
        try await bookmark.asyncWrite(account: (access, access.snapshot)) { _, row in
            row.title = "Admitted preparation"
            row.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        XCTAssertEqual(bookmark.title, "Admitted preparation")
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).first?.changedAt, bookmark.explicitlyModifiedAt)
        XCTAssertFalse(realm.isInWriteTransaction)
    }

    func testRetiredSelectionRollsBackTheActualMutation() async throws {
        let (realm, bookmark) = try fixture()
        let admission = PreparationCommitAdmission()
        do {
            try await bookmark.asyncWrite(admittingMutation: { admission.selectionIsCurrent() }) { _, row in
                row.title = "Retired selection mutation"
                row.refreshChangeMetadata(explicitlyModified: true)
                admission.retireSelection()
            }
            XCTFail("The originating selection must still own commit admission")
        } catch is CancellationError { }
        realm.refresh()
        XCTAssertEqual(bookmark.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testTransitioningAccountIsRejectedBeforeMutation() async throws {
        let (realm, bookmark) = try fixture()
        let admission = PreparationCommitAdmission(identity: .transitioning)
        let access = AccountSessionAccess(testSnapshotProvider: { admission.snapshot() })
        do {
            try await bookmark.asyncWrite(account: (access, access.snapshot)) { _, _ in
                XCTFail("A transitioning account must not enter the mutation")
            }
            XCTFail("Expected account transition cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(bookmark.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }
}
