import Foundation
import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private final class LibraryCategoryCommitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@RealmBackgroundActor
final class LibraryCategoryOwnedWriteTests: XCTestCase {
    func testArchiveCommitCancellationReturnsDurableCategoryAndRelationship() async throws {
        try await verifyCancellationAfterMutationSubmission(initiallyArchived: false, restoring: false)
    }

    func testRestoreCommitCancellationReturnsDurableCategoryAndRelationship() async throws {
        try await verifyCancellationAfterMutationSubmission(initiallyArchived: true, restoring: true)
    }

    func testPermanentDeleteCommitCancellationReturnsDurableTombstone() async throws {
        try await verifyCancellationAfterMutationSubmission(initiallyArchived: true, restoring: false)
    }

    func testPreCancelledCategoryCommandsDoNotMutateCategoryOrLibrary() async throws {
        let (configuration, realm) = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let category = FeedCategory()
        let library = LibraryConfiguration()
        library.categoryIDs.append(category.id)
        let categoryID = category.id
        try realm.write { realm.add(category); realm.add(library) }
        for restoring in [false, true] {
            let task = Task { @RealmBackgroundActor in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    if restoring {
                        try await manager.restoreCategory(categoryID: categoryID, realmConfiguration: configuration)
                    } else {
                        try await manager.deleteCategory(categoryID: categoryID, realmConfiguration: configuration)
                    }
                    return false
                } catch is CancellationError { return true }
                catch { XCTFail("Unexpected error: \(error)"); return false }
            }
            let cancelled = await task.value
            XCTAssertTrue(cancelled)
        }
        XCTAssertFalse(category.isArchived)
        XCTAssertFalse(category.isDeleted)
        XCTAssertEqual(Array(library.categoryIDs), [categoryID])
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private func verifyCancellationAfterMutationSubmission(
        initiallyArchived: Bool,
        restoring: Bool
    ) async throws {
        let (configuration, realm) = try await makeRealm()
        let manager = LibraryDataManager(observesChanges: false)
        let category = FeedCategory()
        category.isArchived = initiallyArchived
        let categoryID = category.id
        let library = LibraryConfiguration()
        if !initiallyArchived { library.categoryIDs.append(categoryID) }
        try realm.write { realm.add(category); realm.add(library) }
        let counter = LibraryCategoryCommitCounter()

        let task = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                // First commit settles consolidation. Cancel only after the
                // second commit, the actual category mutation, is submitted.
                if counter.next() == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }) {
                if restoring {
                    try await manager.restoreCategory(categoryID: categoryID, realmConfiguration: configuration)
                } else {
                    try await manager.deleteCategory(categoryID: categoryID, realmConfiguration: configuration)
                }
            }
        }
        try await task.value

        XCTAssertEqual(counter.value, 2)
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(category.isArchived, !restoring)
        XCTAssertEqual(category.isDeleted, initiallyArchived && !restoring)
        XCTAssertEqual(library.categoryIDs.contains(categoryID), restoring)
        XCTAssertNotNil(category.explicitlyModifiedAt)
        let categoryMutation = realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: category.objectSchema.className + "." + String(describing: categoryID)
        )
        XCTAssertNotNil(categoryMutation)
        if restoring || !initiallyArchived {
            XCTAssertNotNil(library.explicitlyModifiedAt)
            XCTAssertNotNil(realm.object(
                ofType: BigSyncPendingMutation.self,
                forPrimaryKey: library.objectSchema.className + "." + String(describing: library.id)
            ))
        }
    }

    private func makeRealm() async throws -> (Realm.Configuration, Realm) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let capturedConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        return (configuration, realm)
    }
}
