import Foundation
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
}
