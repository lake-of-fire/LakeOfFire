import Foundation
@testable import LakeKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderContentGuardedWriteTests: XCTestCase {
    private func fixture() throws -> (Realm, HistoryRecord) {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "GuardedContentWrite-\(UUID().uuidString)",
            objectTypes: [HistoryRecord.self]
        )
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        let realm = try Realm(configuration: configuration)
        let record = HistoryRecord()
        record.url = URL(string: "https://example.com/exact-write")!
        record.title = "Original"
        record.updateCompoundKey()
        try realm.write { realm.add(record) }
        return (realm, record)
    }

    func testLiveManagedContentWritesInsideOwnedTransaction() async throws {
        let (realm, record) = try fixture()
        try await record.asyncWrite { targetRealm, content in
            XCTAssertTrue(targetRealm.isInWriteTransaction)
            content.title = "Edited"
        }
        realm.refresh()
        XCTAssertEqual(record.title, "Edited")
    }

    func testThrowingMutationRollsBackItsAdmittedTransaction() async throws {
        let (realm, record) = try fixture()
        do {
            try await record.asyncWrite { _, content in
                content.title = "Must roll back"
                throw CancellationError()
            }
            XCTFail("A rejected mutation must throw")
        } catch is CancellationError { }
        realm.refresh()
        XCTAssertEqual(record.title, "Original")
    }

    func testCurrentAccountCommitsThroughItsPublicationBoundary() async throws {
        let (realm, record) = try fixture()
        let account = GuardedWriteAccountFixture(.init(identity: .signedOut, generation: 0))
        let access = account.access
        try await record.asyncWrite(account: (access, access.snapshot)) { _, content in
            content.title = "Accepted"
        }
        realm.refresh()
        XCTAssertEqual(record.title, "Accepted")
    }

    func testAccountGenerationChangeDuringMutationRollsBack() async throws {
        let (realm, record) = try fixture()
        let account = GuardedWriteAccountFixture(.init(identity: .authenticated(userID: 1), generation: 1))
        let access = account.access
        let snapshot = access.snapshot
        do {
            try await record.asyncWrite(account: (access, snapshot)) { _, content in
                content.title = "Retired account edit"
                account.replace(.init(identity: .authenticated(userID: 1), generation: 2))
            }
            XCTFail("A retired account generation must not commit")
        } catch is CancellationError { }
        realm.refresh()
        XCTAssertEqual(record.title, "Original")
    }

    func testFrozenLiveRowWritesWithoutRefreshingFrozenRealm() async throws {
        let (realm, record) = try fixture()
        let frozen = record.freeze()
        try await frozen.asyncWrite { _, content in content.title = "Edited" }
        realm.refresh()
        XCTAssertEqual(record.title, "Edited")
        XCTAssertEqual(frozen.title, "Original")
    }

    func testFrozenDeletedRowDoesNotRunMutation() async throws {
        let (realm, record) = try fixture()
        let frozen = record.freeze()
        try realm.write { realm.delete(record) }
        XCTAssertFalse(frozen.isInvalidated, "Historical frozen row remains readable.")
        try await frozen.asyncWrite { _, _ in
            XCTFail("A physically deleted row must not run the mutation.")
        }
        realm.refresh()
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
    }

    func testAlreadyInvalidatedRowDoesNotReadIdentityOrRunMutation() async throws {
        let (realm, record) = try fixture()
        try realm.write { realm.delete(record) }
        XCTAssertTrue(record.isInvalidated)
        try await record.asyncWrite { _, _ in XCTFail("Invalidated input must be ignored") }
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
    }

    func testUnmanagedContentDoesNotOpenDefaultStorage() async throws {
        let record = HistoryRecord()
        record.url = URL(string: "https://example.com/unmanaged")!
        record.updateCompoundKey()
        try await record.asyncWrite { _, _ in XCTFail("Unmanaged input cannot nominate default storage") }
        XCTAssertNil(record.realm)
    }

    func testPreCancelledWriteLeavesOriginalContentUnchanged() async throws {
        let (realm, record) = try fixture()
        let cancelled = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await record.asyncWrite { _, _ in XCTFail("Cancelled write must not mutate") }
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
        realm.refresh()
        XCTAssertEqual(record.title, "Original")
    }
    func testFrozenWriteRejectsEqualFieldPhysicalReplacement() async throws {
        let (realm, record) = try fixture()
        let original = record.freeze()
        let replacement = HistoryRecord(value: record)
        try realm.write {
            realm.delete(record)
            realm.add(replacement)
        }
        XCTAssertFalse(replacement.isSameObject(as: original))
        XCTAssertEqual(replacement.compoundKey, original.compoundKey)
        XCTAssertEqual(replacement.createdAt, original.createdAt)
        XCTAssertEqual(replacement.modifiedAt, original.modifiedAt)
        try await original.asyncWrite { _, _ in
            XCTFail("A same-key, same-metadata successor must not inherit the original row's write")
        }
        realm.refresh()
        XCTAssertEqual(replacement.title, "Original")
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
    }

    func testFrozenOriginalWriteReadsFreshMetadataAndCanChangeURL() async throws {
        let (realm, record) = try fixture()
        let original = record.freeze()
        try realm.write {
            record.title = "Current title"
            record.author = "Current author"
        }
        let updatedURL = record.url.appendingPathComponent("accepted-edit")
        try await original.asyncWrite { target, content in
            XCTAssertTrue(target.isInWriteTransaction)
            XCTAssertEqual(content.title, "Current title")
            XCTAssertEqual(content.author, "Current author")
            content.title = "Accepted edit"
            content.url = updatedURL
        }
        realm.refresh()
        XCTAssertEqual(record.title, "Accepted edit")
        XCTAssertEqual(record.author, "Current author")
        XCTAssertEqual(record.url, updatedURL)
    }

}

private final class GuardedWriteAccountFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountSessionSnapshot

    init(_ value: AccountSessionSnapshot) { self.value = value }

    private var snapshot: AccountSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(_ value: AccountSessionSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    var access: AccountSessionAccess {
        AccountSessionAccess(testSnapshotProvider: { self.snapshot })
    }
}
