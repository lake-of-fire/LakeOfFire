import BigSyncKit
import Combine
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor ScriptListCommandGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait(registered: @Sendable () -> Void) async {
        if released { registered(); return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            registered()
        }
    }

    func release() {
        released = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor
final class LibraryScriptListCommandTests: XCTestCase {
    private struct Fixture {
        let configuration: Realm.Configuration
        let realm: Realm
        let library: LibraryConfiguration
        let scripts: [UserScript]
    }

    private struct Journal: Equatable {
        let generation: String
        let changedAt: Date
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    private func fixture(archived: Bool = false, fileURL: URL? = nil) throws -> Fixture {
        var configuration = fileURL.map { Realm.Configuration(fileURL: $0) }
            ?? Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        let realm = try Realm(configuration: configuration)
        let library = LibraryConfiguration()
        let scripts = (0..<3).map { index in
            let script = UserScript()
            script.title = "Script \(index)"
            script.createdAt = Date(timeIntervalSinceReferenceDate: 100 + Double(index))
            script.isArchived = archived
            return script
        }
        try realm.write {
            realm.add(library)
            realm.add(scripts)
            library.userScriptIDs.append(objectsIn: scripts.map(\.id))
            library.refreshChangeMetadata(explicitlyModified: true)
            scripts.forEach { $0.refreshChangeMetadata(explicitlyModified: true) }
        }
        return Fixture(configuration: configuration, realm: realm, library: library, scripts: scripts)
    }

    private func journal(_ object: Object & ChangeMetadataRecordable, in realm: Realm) throws -> Journal {
        let key = try XCTUnwrap(object.objectSchema.primaryKeyProperty?.name)
        let identifier = String(describing: try XCTUnwrap(object[key]))
        let mutation = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + identifier
        ))
        XCTAssertEqual(mutation.changedAt, object.modifiedAt)
        XCTAssertEqual(mutation.changedAt, object.explicitlyModifiedAt)
        return Journal(generation: mutation.generation, changedAt: mutation.changedAt,
                       modifiedAt: object.modifiedAt, explicitlyModifiedAt: object.explicitlyModifiedAt)
    }

    private func selection(_ fixture: Fixture, scripts: [UserScript]? = nil) throws -> LibraryScriptListSelection {
        try XCTUnwrap(LibraryScriptListSelection(configuration: fixture.library, scripts: scripts ?? fixture.scripts))
    }

    private func retainForCleanup(_ task: Task<Bool, Error>, gate: ScriptListCommandGate) {
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
    }

    func testDeleteUsesRenderedRowsAfterModelAndGlobalStoreReplacement() async throws {
        let original = try fixture()
        let replacement = try fixture()
        let displayed = try selection(original)
        let oldGlobal = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = oldGlobal }
        let model = LibraryScriptsListViewModel(observesRealm: false)
        model.libraryConfiguration = original.library
        model.userScripts = original.scripts
        let originalIDs = Array(original.library.userScriptIDs)
        let originalLibraryJournal = try journal(original.library, in: original.realm)
        let successorJournal = try journal(replacement.library, in: replacement.realm)

        let deletion = model.deleteScript(at: IndexSet(integer: 0), selection: displayed)
        model.userScripts = Array(replacement.scripts.reversed())
        model.libraryConfiguration = replacement.library
        LibraryDataManager.realmConfiguration = replacement.configuration
        let changed = try await deletion.value
        original.realm.refresh()
        replacement.realm.refresh()

        XCTAssertTrue(changed)
        XCTAssertTrue(original.scripts[0].isArchived)
        XCTAssertFalse(original.scripts[1].isArchived)
        XCTAssertFalse(original.scripts[2].isArchived)
        XCTAssertEqual(Array(original.library.userScriptIDs), originalIDs)
        XCTAssertEqual(try journal(original.library, in: original.realm), originalLibraryJournal)
        XCTAssertTrue(replacement.scripts.allSatisfy { !$0.isArchived && !$0.isDeleted })
        XCTAssertEqual(try journal(replacement.library, in: replacement.realm), successorJournal)
    }

    func testDisableThenFreshDeletePreservesSlotAndJournalsOnlyChangedOwners() async throws {
        let f = try fixture()
        let initial = try selection(f)
        let ids = Array(f.library.userScriptIDs)
        let libraryBefore = try journal(f.library, in: f.realm)
        let first = try await initial.delete(at: IndexSet(integer: 1))
        f.realm.refresh()
        XCTAssertTrue(first)
        XCTAssertEqual(Array(f.library.userScriptIDs), ids)
        XCTAssertEqual(f.library.getUserScripts()?.map(\.id), ids)
        XCTAssertTrue(f.scripts[1].isArchived)
        XCTAssertFalse(f.scripts[1].isDeleted)
        XCTAssertEqual(try journal(f.library, in: f.realm), libraryBefore)
        let disabledJournal = try journal(f.scripts[1], in: f.realm)

        let repeated = try await initial.delete(at: IndexSet(integer: 1))
        f.realm.refresh()
        XCTAssertFalse(repeated, "Replaying a disable gesture must not become deletion")
        XCTAssertEqual(try journal(f.scripts[1], in: f.realm), disabledJournal)

        let fresh = try selection(f)
        let deleted = try await fresh.delete(at: IndexSet(integer: 1))
        f.realm.refresh()
        XCTAssertTrue(deleted)
        XCTAssertTrue(f.scripts[1].isDeleted)
        XCTAssertNotNil(f.realm.object(ofType: UserScript.self, forPrimaryKey: f.scripts[1].id))
        XCTAssertEqual(Array(f.library.userScriptIDs), [ids[0], ids[2]])
        let tombstoneJournal = try journal(f.scripts[1], in: f.realm)
        let libraryAfter = try journal(f.library, in: f.realm)
        XCTAssertNotEqual(tombstoneJournal.generation, disabledJournal.generation)
        XCTAssertNotEqual(libraryAfter.generation, libraryBefore.generation)
        XCTAssertEqual(tombstoneJournal.changedAt, libraryAfter.changedAt)
        let repeatedDelete = try await fresh.delete(at: IndexSet(integer: 1))
        f.realm.refresh()
        XCTAssertFalse(repeatedDelete)
        XCTAssertEqual(try journal(f.scripts[1], in: f.realm), tombstoneJournal)
        XCTAssertEqual(try journal(f.library, in: f.realm), libraryAfter)
    }

    func testMovePreservesHiddenAndManagedSlotsInCapturedStore() async throws {
        // Adapt the actual script reorder regression from #95/#138, with an
        // additional unresolved raw slot and immutable rendered selection.
        let f = try fixture()
        let successor = try fixture()
        let hidden = UUID()
        try f.realm.write {
            f.scripts[1].opmlURL = URL(string: "https://example.com/managed.opml")!
            f.scripts[1].refreshChangeMetadata(explicitlyModified: true)
            f.library.userScriptIDs.insert(hidden, at: 0)
            f.library.refreshChangeMetadata(explicitlyModified: true)
        }
        let displayed = try selection(f)
        let rowJournals = try f.scripts.map { try journal($0, in: f.realm) }
        let oldGlobal = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = oldGlobal }
        LibraryDataManager.realmConfiguration = successor.configuration
        let model = LibraryScriptsListViewModel(observesRealm: false)
        model.libraryConfiguration = successor.library
        model.userScripts = successor.scripts
        let moved = try await model.moveScripts(
            fromOffsets: IndexSet(integer: 2), toOffset: 0, selection: displayed
        ).value
        f.realm.refresh()
        successor.realm.refresh()

        XCTAssertTrue(moved)
        XCTAssertEqual(Array(f.library.userScriptIDs), [hidden, f.scripts[2].id, f.scripts[1].id, f.scripts[0].id])
        XCTAssertEqual(try f.scripts.map { try journal($0, in: f.realm) }, rowJournals)
        XCTAssertEqual(Array(successor.library.userScriptIDs), successor.scripts.map(\.id))
        let settled = try journal(f.library, in: f.realm)
        let staleRepeat = try await displayed.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        f.realm.refresh()
        XCTAssertFalse(staleRepeat)
        XCTAssertEqual(try journal(f.library, in: f.realm), settled)
    }

    func testInvalidOffsetsManagedRowsAndNoOpMoveDoNotJournal() async throws {
        let f = try fixture()
        try f.realm.write {
            f.scripts[1].opmlURL = URL(string: "https://example.com/managed.opml")!
            f.scripts[1].refreshChangeMetadata(explicitlyModified: true)
        }
        let displayed = try selection(f)
        let libraryBefore = try journal(f.library, in: f.realm)
        let rowBefore = try f.scripts.map { try journal($0, in: f.realm) }
        let invalidDelete = try await displayed.delete(at: IndexSet(integer: 99))
        let managedDelete = try await displayed.delete(at: IndexSet(integer: 1))
        let managedMove = try await displayed.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let invalidMove = try await displayed.move(fromOffsets: IndexSet(integer: 0), toOffset: 99)
        let noOp = try await displayed.move(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        f.realm.refresh()
        XCTAssertFalse(invalidDelete)
        XCTAssertFalse(managedDelete)
        XCTAssertFalse(managedMove)
        XCTAssertFalse(invalidMove)
        XCTAssertFalse(noOp)
        XCTAssertEqual(try journal(f.library, in: f.realm), libraryBefore)
        XCTAssertEqual(try f.scripts.map { try journal($0, in: f.realm) }, rowBefore)
    }

    func testCaptureRejectsMixedStoresAndIncoherentRenderedOrder() throws {
        let f = try fixture()
        let other = try fixture()
        XCTAssertNil(LibraryScriptListSelection(configuration: f.library, scripts: other.scripts))
        XCTAssertNil(LibraryScriptListSelection(configuration: f.library, scripts: Array(f.scripts.reversed())))
        XCTAssertNil(LibraryScriptListSelection(configuration: f.library, scripts: [f.scripts[0], f.scripts[0]]))
    }

    func testHeldDeleteRejectsRecreatedScript() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        let configuration = f.configuration
        let id = f.scripts[0].id
        let createdAt = f.scripts[0].createdAt
        let gate = ScriptListCommandGate()
        let arrived = expectation(description: "delete opened its captured Realm")
        let task = Task { @RealmBackgroundActor in
            try await displayed.delete(at: IndexSet(integer: 0), beforeWrite: {
                await gate.wait { arrived.fulfill() }
            })
        }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [arrived], timeout: 2)
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await realm.asyncWritePreservingOwnership {
                let old = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: id))
                realm.delete(old) // Model acknowledged cleanup followed by a different creation.
                let replacement = UserScript()
                replacement.id = id
                replacement.createdAt = createdAt.addingTimeInterval(1)
                replacement.title = "Replacement"
                realm.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        f.realm.refresh()
        let replacement = try XCTUnwrap(f.realm.object(ofType: UserScript.self, forPrimaryKey: id))
        let before = try journal(replacement, in: f.realm)
        await gate.release()
        let changed = try await task.value
        f.realm.refresh()
        XCTAssertFalse(changed)
        XCTAssertFalse(replacement.isArchived)
        XCTAssertFalse(replacement.isDeleted)
        XCTAssertEqual(try journal(replacement, in: f.realm), before)
    }

    func testHeldMoveRejectsRecreatedLibrary() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        let configuration = f.configuration
        let id = f.library.id
        let createdAt = f.library.createdAt
        let ids = Array(f.library.userScriptIDs)
        let gate = ScriptListCommandGate()
        let arrived = expectation(description: "move opened its captured Realm")
        let task = Task { @RealmBackgroundActor in
            try await displayed.move(fromOffsets: IndexSet(integer: 0), toOffset: 3, beforeWrite: {
                await gate.wait { arrived.fulfill() }
            })
        }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [arrived], timeout: 2)
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await realm.asyncWritePreservingOwnership {
                let old = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: id))
                realm.delete(old)
                let replacement = LibraryConfiguration()
                replacement.id = id
                replacement.createdAt = createdAt.addingTimeInterval(1)
                replacement.userScriptIDs.append(objectsIn: ids)
                realm.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        f.realm.refresh()
        let replacement = try XCTUnwrap(f.realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: id))
        let before = try journal(replacement, in: f.realm)
        await gate.release()
        let changed = try await task.value
        f.realm.refresh()
        XCTAssertFalse(changed)
        XCTAssertEqual(Array(replacement.userScriptIDs), ids)
        XCTAssertEqual(try journal(replacement, in: f.realm), before)
    }

    func testHeldCommandsRejectNewEditabilityAndActivationIntent() async throws {
        for startsArchived in [false, true] {
            let f = try fixture(archived: startsArchived)
            let displayed = try selection(f)
            let configuration = f.configuration
            let id = f.scripts[0].id
            let gate = ScriptListCommandGate()
            let arrived = expectation(description: "delete held before eligibility recheck")
            let task = Task { @RealmBackgroundActor in
                try await displayed.delete(at: IndexSet(integer: 0), beforeWrite: {
                    await gate.wait { arrived.fulfill() }
                })
            }
            retainForCleanup(task, gate: gate)
            await fulfillment(of: [arrived], timeout: 2)
            try await Task { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try await realm.asyncWritePreservingOwnership {
                    let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: id))
                    script.isArchived = !startsArchived
                    script.refreshChangeMetadata(explicitlyModified: true)
                }
            }.value
            f.realm.refresh()
            let before = try journal(f.scripts[0], in: f.realm)
            await gate.release()
            let changed = try await task.value
            f.realm.refresh()
            XCTAssertFalse(changed)
            XCTAssertEqual(f.scripts[0].isArchived, !startsArchived)
            XCTAssertFalse(f.scripts[0].isDeleted)
            XCTAssertEqual(try journal(f.scripts[0], in: f.realm), before)
        }

        let f = try fixture()
        let displayed = try selection(f)
        try f.realm.write {
            f.scripts[0].opmlURL = URL(string: "https://example.com/now-managed.opml")!
            f.scripts[0].refreshChangeMetadata(explicitlyModified: true)
        }
        let before = try journal(f.scripts[0], in: f.realm)
        let deleted = try await displayed.delete(at: IndexSet(integer: 0))
        let moved = try await displayed.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        f.realm.refresh()
        XCTAssertFalse(deleted)
        XCTAssertFalse(moved)
        XCTAssertEqual(try journal(f.scripts[0], in: f.realm), before)
    }

    func testStaleRawOrderRejectsReorderWithoutOverwritingNewIntent() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        let changedIDs = [f.scripts[1].id, f.scripts[0].id, f.scripts[2].id]
        try f.realm.write {
            f.library.userScriptIDs.removeAll()
            f.library.userScriptIDs.append(objectsIn: changedIDs)
            f.library.refreshChangeMetadata(explicitlyModified: true)
        }
        let before = try journal(f.library, in: f.realm)
        let moved = try await displayed.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        f.realm.refresh()
        XCTAssertFalse(moved)
        XCTAssertEqual(Array(f.library.userScriptIDs), changedIDs)
        XCTAssertEqual(try journal(f.library, in: f.realm), before)
    }

    func testPreCancelledCommandDoesNotMutateOrJournal() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        let before = try journal(f.scripts[0], in: f.realm)
        let task = Task { @RealmBackgroundActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await displayed.delete(at: IndexSet(integer: 0))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        f.realm.refresh()
        XCTAssertFalse(f.scripts[0].isArchived)
        XCTAssertEqual(try journal(f.scripts[0], in: f.realm), before)
    }

    func testPostCommitCancellationReturnsSettledDisableWithoutReplay() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        let task = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await displayed.delete(at: IndexSet(integer: 0))
            }
        }
        let changed = try await task.value
        f.realm.refresh()
        XCTAssertTrue(changed)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(f.scripts[0].isArchived)
        let settled = try journal(f.scripts[0], in: f.realm)
        let repeated = try await displayed.delete(at: IndexSet(integer: 0))
        f.realm.refresh()
        XCTAssertFalse(repeated)
        XCTAssertEqual(try journal(f.scripts[0], in: f.realm), settled)
    }

    func testCapturedCommandSurvivesModelRelease() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        let gate = ScriptListCommandGate()
        let arrived = expectation(description: "captured command retained independently")
        var model: LibraryScriptsListViewModel? = LibraryScriptsListViewModel(observesRealm: false)
        weak var releasedModel = model
        let task = try XCTUnwrap(model).deleteScript(
            at: IndexSet(integer: 0), selection: displayed,
            beforeWrite: { await gate.wait { arrived.fulfill() } }
        )
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [arrived], timeout: 2)
        model = nil
        XCTAssertNil(releasedModel)
        await gate.release()
        let changed = try await task.value
        f.realm.refresh()
        XCTAssertTrue(changed)
        XCTAssertTrue(f.scripts[0].isArchived)
    }
    func testMixedDeleteKeepsManagedRowAndCommitsOnlyCapturedActions() async throws {
        let f = try fixture()
        try f.realm.write {
            f.scripts[1].opmlURL = URL(string: "https://example.com/managed.opml")!
            f.scripts[1].refreshChangeMetadata(explicitlyModified: true)
            f.scripts[2].isArchived = true
            f.scripts[2].refreshChangeMetadata(explicitlyModified: true)
        }
        let displayed = try selection(f)
        let managedBefore = try journal(f.scripts[1], in: f.realm)
        let changed = try await displayed.delete(at: IndexSet(integersIn: 0..<3))
        f.realm.refresh()
        XCTAssertTrue(changed)
        XCTAssertTrue(f.scripts[0].isArchived)
        XCTAssertFalse(f.scripts[0].isDeleted)
        XCTAssertFalse(f.scripts[1].isArchived)
        XCTAssertFalse(f.scripts[1].isDeleted)
        XCTAssertTrue(f.scripts[2].isDeleted)
        XCTAssertEqual(f.realm.objects(UserScript.self).count, 3, "Deletion must preserve a synchronized tombstone")
        XCTAssertEqual(Array(f.library.userScriptIDs), [f.scripts[0].id, f.scripts[1].id])
        XCTAssertEqual(try journal(f.scripts[1], in: f.realm), managedBefore)
        let configurationMutation = try journal(f.library, in: f.realm)
        XCTAssertEqual(try journal(f.scripts[0], in: f.realm).changedAt, configurationMutation.changedAt)
        XCTAssertEqual(try journal(f.scripts[2], in: f.realm).changedAt, configurationMutation.changedAt)
    }

    func testQueuedCommandCancellationDoesNotCancelAnotherOwnersTransaction() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        let configuration = f.configuration
        let scriptID = f.scripts[0].id
        let gate = ScriptListCommandGate()
        let ownerEntered = expectation(description: "other writer has registered its held transaction")
        let owner = Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try realm.beginWrite()
            defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
            let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: scriptID))
            script.title = "Other writer"
            script.refreshChangeMetadata(explicitlyModified: true)
            await gate.wait { ownerEntered.fulfill() }
            try realm.commitWrite()
        }
        addTeardownBlock { owner.cancel(); await gate.release(); _ = await owner.result }
        await fulfillment(of: [ownerEntered], timeout: 2)
        let submitted = expectation(description: "list command submitted a distinct SDK begin ticket")
        let model = LibraryScriptsListViewModel(observesRealm: false)
        let command = RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
            model.deleteScript(at: IndexSet(integer: 0), selection: displayed)
        }
        addTeardownBlock { command.cancel(); _ = await command.result }
        await fulfillment(of: [submitted], timeout: 2)
        command.cancel()
        do { _ = try await command.value; XCTFail("Queued command must report cancellation") }
        catch is CancellationError { }
        let ownerStillIntact = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            return realm.isInWriteTransaction
                && realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)?.title == "Other writer"
        }.value
        XCTAssertTrue(ownerStillIntact)
        await gate.release()
        try await owner.value
        f.realm.refresh()
        XCTAssertEqual(f.scripts[0].title, "Other writer")
        XCTAssertFalse(f.scripts[0].isArchived)
        XCTAssertFalse(f.scripts[0].isDeleted)
    }

    private func diskFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("current.realm")
        // Registered before the fixture and command teardowns: their task
        // joining runs first, then every cached incarnation at this unique path.
        addTeardownBlock {
            if await Self.releaseDiskRealms(at: url) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return try fixture(fileURL: url)
    }

    @RealmBackgroundActor
    private static func releaseDiskRealms(at fileURL: URL) -> Bool {
        let owner = RealmBackgroundActor.shared
        let matches = owner.cachedRealms.filter {
            $0.value.configuration.fileURL?.standardizedFileURL == fileURL.standardizedFileURL
        }
        guard matches.values.allSatisfy({ !$0.isInWriteTransaction }) else {
            XCTFail("Disk teardown cannot cancel an active writer")
            return false
        }
        for key in matches.keys { owner.cachedRealms.removeValue(forKey: key)?.invalidate() }
        return true
    }

    private func replaceFile(_ f: Fixture) throws -> Data {
        let current = try XCTUnwrap(f.configuration.fileURL)
        let directory = current.deletingLastPathComponent()
        let replacement = directory.appendingPathComponent("replacement.realm")
        try f.realm.writeCopy(toFile: replacement)
        let bytes = try Data(contentsOf: replacement)
        try FileManager.default.moveItem(at: current, to: directory.appendingPathComponent("retired.realm"))
        try FileManager.default.moveItem(at: replacement, to: current)
        return bytes
    }

    func testCapturedDeleteRejectsSamePathStoreReplacementBeforeOpen() async throws {
        let f = try diskFixture()
        let displayed = try selection(f)
        let originalJournal = try journal(f.scripts[0], in: f.realm)
        let replacementBytes = try replaceFile(f)
        do {
            _ = try await displayed.delete(at: IndexSet(integer: 0))
            XCTFail("Captured deletion must not adopt a replacement file with matching IDs and creation dates")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(f.configuration.fileURL)), replacementBytes)
        f.realm.refresh()
        XCTAssertFalse(f.scripts[0].isArchived)
        XCTAssertEqual(try journal(f.scripts[0], in: f.realm), originalJournal)
    }

    func testCapturedMoveRejectsSamePathStoreReplacementAfterOpen() async throws {
        let f = try diskFixture()
        let displayed = try selection(f)
        let ids = Array(f.library.userScriptIDs)
        let originalJournal = try journal(f.library, in: f.realm)
        let gate = ScriptListCommandGate()
        let opened = expectation(description: "move opened its original physical store")
        let task = Task { @RealmBackgroundActor in
            try await displayed.move(fromOffsets: IndexSet(integer: 0), toOffset: 3, beforeWrite: {
                await gate.wait { opened.fulfill() }
            })
        }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [opened], timeout: 2)
        let replacementBytes = try replaceFile(f)
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Final write admission must reject a replacement file")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(f.configuration.fileURL)), replacementBytes)
        f.realm.refresh()
        XCTAssertEqual(Array(f.library.userScriptIDs), ids)
        XCTAssertEqual(try journal(f.library, in: f.realm), originalJournal)
    }

    private enum AdmissionFailure: Error { case injected }

    func testFailedAdmissionCanRetryWithoutPartialMutation() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        let libraryBefore = try journal(f.library, in: f.realm)
        let rowBefore = try journal(f.scripts[0], in: f.realm)
        do {
            _ = try await displayed.delete(at: IndexSet(integer: 0), beforeWrite: {
                throw AdmissionFailure.injected
            })
            XCTFail("Expected held admission failure")
        } catch AdmissionFailure.injected { }
        f.realm.refresh()
        XCTAssertFalse(f.scripts[0].isArchived)
        XCTAssertEqual(try journal(f.library, in: f.realm), libraryBefore)
        XCTAssertEqual(try journal(f.scripts[0], in: f.realm), rowBefore)
        let retried = try await displayed.delete(at: IndexSet(integer: 0))
        f.realm.refresh()
        XCTAssertTrue(retried)
        XCTAssertTrue(f.scripts[0].isArchived)
        XCTAssertEqual(try journal(f.library, in: f.realm), libraryBefore)
        XCTAssertNotEqual(try journal(f.scripts[0], in: f.realm).generation, rowBefore.generation)
    }

    func testStaleCommandsPreserveExistingScriptTombstoneAndJournal() async throws {
        let f = try fixture()
        let displayed = try selection(f)
        try f.realm.write {
            f.scripts[0].isDeleted = true
            f.scripts[0].refreshChangeMetadata(explicitlyModified: true)
        }
        let tombstone = try journal(f.scripts[0], in: f.realm)
        let libraryBefore = try journal(f.library, in: f.realm)
        let deleted = try await displayed.delete(at: IndexSet(integer: 0))
        let moved = try await displayed.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        f.realm.refresh()
        XCTAssertFalse(deleted)
        XCTAssertFalse(moved)
        XCTAssertTrue(f.scripts[0].isDeleted)
        XCTAssertEqual(try journal(f.scripts[0], in: f.realm), tombstone)
        XCTAssertEqual(try journal(f.library, in: f.realm), libraryBefore)
    }

    func testActualObserverPublishesDisabledAndEnabledRowsWithoutLibraryJournalChurn() async throws {
        let f = try fixture()
        let model = LibraryScriptsListViewModel(realmConfiguration: f.configuration)
        let initial = expectation(description: "real list observer publishes the fixture")
        let initialSubscription = model.$userScripts
            .compactMap { $0 }
            .filter { $0.count == 3 }
            .first()
            .sink { _ in initial.fulfill() }
        defer { initialSubscription.cancel() }
        await fulfillment(of: [initial], timeout: 3)
        let initialRows = try XCTUnwrap(model.userScripts)
        XCTAssertEqual(initialRows.map(\.id), f.scripts.map(\.id))
        let libraryBefore = try journal(f.library, in: f.realm)
        let configuration = f.configuration
        let scriptID = f.scripts[0].id

        let disabled = expectation(description: "UserScript modification publishes Disabled without membership edits")
        let disabledSubscription = model.$userScripts
            .dropFirst()
            .compactMap { $0 }
            .filter { $0.first?.id == scriptID && $0.first?.isArchived == true }
            .first()
            .sink { _ in disabled.fulfill() }
        defer { disabledSubscription.cancel() }
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await realm.asyncWritePreservingOwnership {
                let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: scriptID))
                script.isArchived = true
                script.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        await fulfillment(of: [disabled], timeout: 3)
        f.realm.refresh()
        XCTAssertEqual(Array(f.library.userScriptIDs), f.scripts.map(\.id))
        XCTAssertEqual(try journal(f.library, in: f.realm), libraryBefore)

        let enabled = expectation(description: "real observer publishes re-enabled script in the same slot")
        let enabledSubscription = model.$userScripts
            .dropFirst()
            .compactMap { $0 }
            .filter { $0.first?.id == scriptID && $0.first?.isArchived == false }
            .first()
            .sink { _ in enabled.fulfill() }
        defer { enabledSubscription.cancel() }
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await realm.asyncWritePreservingOwnership {
                let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: scriptID))
                script.isArchived = false
                script.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        await fulfillment(of: [enabled], timeout: 3)
        f.realm.refresh()
        XCTAssertEqual(model.userScripts?.map(\.id), f.scripts.map(\.id))
        XCTAssertEqual(try journal(f.library, in: f.realm), libraryBefore)
    }

}
