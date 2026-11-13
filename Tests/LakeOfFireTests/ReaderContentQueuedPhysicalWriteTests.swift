import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

private actor GuardedWriteAdmissionGate {
    nonisolated let entered = XCTestExpectation(description: "Foreign transaction is held")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        entered.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ReaderContentQueuedPhysicalWriteTests: XCTestCase {
    private enum FixtureError: Error { case boundaryNotReached }
    private static let mutationDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testQueuedLiveWriteRejectsEqualMetadataPhysicalReplacement() async throws {
        try await assertQueuedWrite(replace: true, frozen: false)
    }

    func testQueuedFrozenWriteRejectsEqualMetadataPhysicalReplacement() async throws {
        try await assertQueuedWrite(replace: true, frozen: true)
    }

    func testQueuedOriginalRowReadsFreshMetadataAndMayChangeItsURL() async throws {
        try await assertQueuedWrite(replace: false, frozen: false)
    }

    private func assertQueuedWrite(replace: Bool, frozen: Bool) async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [HistoryRecord.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let config = configuration
        let key = "queued-physical-row"
        let url = URL(string: "https://example.invalid/queued-physical-row")!
        let initialDate = Self.mutationDate
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
            try realm.write {
                let row = HistoryRecord()
                row.compoundKey = key
                row.url = url
                row.title = "Original"
                row.author = "Original author"
                row.createdAt = initialDate
                realm.add(row)
                row.refreshChangeMetadata(explicitlyModified: true, at: initialDate)
            }
        }()
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: config) }
        let realm = try Realm(configuration: config)
        let original = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
        let originalID = original.id
        let source = frozen ? original.freeze() : original
        XCTAssertEqual(source.id, originalID)
        let gate = GuardedWriteAdmissionGate()
        let owner = Task { @RealmBackgroundActor () throws -> (journal: [Data], generation: String) in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: config)
            try target.beginWrite()
            defer { if target.isInWriteTransaction { target.cancelWrite() } }
            await gate.hold()
            let current = try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            if replace {
                let successor = HistoryRecord(value: current)
                target.delete(current)
                target.add(successor)
                XCTAssertNotEqual(successor.id, originalID)
                XCTAssertEqual(successor.url, url)
                XCTAssertEqual(successor.createdAt, initialDate)
                successor.refreshChangeMetadata(explicitlyModified: true, at: initialDate)
            } else {
                XCTAssertEqual(current.id, originalID)
                current.title = "Current title"
                current.author = "Current author"
                current.refreshChangeMetadata(explicitlyModified: true, at: initialDate)
            }
            let state = try guardedWriteJournalSnapshot(target)
            let generation = try XCTUnwrap(target.objects(BigSyncPendingMutation.self).first).generation
            try target.commitWrite()
            return (state, generation)
        }
        addTeardownBlock { await gate.release(); _ = await owner.result }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 5) == .completed else {
            throw FixtureError.boundaryNotReached
        }
        let submitted = XCTestExpectation(description: "Actual owned write ticket submitted")
        let finalDate = initialDate.addingTimeInterval(1)
        let changedURL = url.appendingPathComponent("accepted-edit")
        let writer = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.asyncWrite { target, row in
                    XCTAssertTrue(target.isInWriteTransaction)
                    if replace { XCTFail("A recreated row cannot inherit the queued mutation") }
                    XCTAssertEqual(row.id, originalID)
                    XCTAssertEqual(row.title, "Current title")
                    XCTAssertEqual(row.author, "Current author")
                    row.title = "Accepted edit"
                    row.url = changedURL
                    row.refreshChangeMetadata(explicitlyModified: true, at: finalDate)
                }
            }
        }
        addTeardownBlock {
            writer.cancel()
            await gate.release()
            _ = await writer.result
            _ = await owner.result
        }
        guard await XCTWaiter.fulfillment(of: [submitted], timeout: 5) == .completed else {
            throw FixtureError.boundaryNotReached
        }
        await gate.release()
        let admittedState = try await owner.value
        try await writer.value
        realm.refresh()
        let current = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertEqual(current.compoundKey, key)
        if replace {
            XCTAssertTrue(original.isInvalidated)
            XCTAssertNotEqual(current.id, originalID)
            XCTAssertEqual(current.url, url)
            XCTAssertEqual(current.createdAt, initialDate)
            XCTAssertEqual(current.title, "Original")
            XCTAssertEqual(current.author, "Original author")
            XCTAssertEqual(current.modifiedAt, initialDate)
            XCTAssertEqual(current.explicitlyModifiedAt, initialDate)
            XCTAssertEqual(try guardedWriteJournalSnapshot(realm), admittedState.journal)
            if frozen {
                XCTAssertFalse(source.isInvalidated)
                XCTAssertEqual(source.id, originalID)
                XCTAssertEqual(source.title, "Original")
            }
        } else {
            XCTAssertFalse(original.isInvalidated)
            XCTAssertEqual(current.id, originalID)
            XCTAssertEqual(current.url, changedURL)
            XCTAssertEqual(current.title, "Accepted edit")
            XCTAssertEqual(current.author, "Current author")
            XCTAssertNotEqual(try guardedWriteJournalSnapshot(realm), admittedState.journal)
            let journal = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first)
            XCTAssertNotEqual(journal.generation, admittedState.generation)
            XCTAssertEqual(journal.changedAt, finalDate)
        }
    }
}

private func guardedWriteJournalSnapshot(_ realm: Realm) throws -> [Data] {
    try realm.objects(BigSyncPendingMutation.self).map { row in
        let fields = Dictionary(uniqueKeysWithValues: row.objectSchema.properties.map {
            ($0.name, String(describing: row[$0.name]))
        })
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }.sorted { $0.lexicographicallyPrecedes($1) }
}
