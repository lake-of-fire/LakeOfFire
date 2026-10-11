import Foundation
import XCTest
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
@testable import LakeOfFireContent

private enum InventoryFixtureError: Error {
    case seamNotReached
    case taskTimedOut
    case scanFailed
}

@MainActor
private final class InventoryOwnershipGate {
    private let entry = XCTestExpectation(description: "inventory seam entered or producer completed")
    private let exit = XCTestExpectation(description: "inventory seam released")
    private var entered = false
    private var released = false
    private var completedBeforeEntry = false

    func blockFirst() async {
        guard !entered else { return }
        entered = true
        if !completedBeforeEntry { entry.fulfill() }
        if !released {
            let status = await XCTWaiter.fulfillment(of: [exit], timeout: 5)
            if status != .completed {
                release()
                XCTFail("Inventory seam release timed out")
            }
        }
    }

    func producerFinished() {
        if !entered, !completedBeforeEntry {
            completedBeforeEntry = true
            entry.fulfill()
        }
    }

    func waitForEntry() async throws {
        let status = await XCTWaiter.fulfillment(of: [entry], timeout: 5)
        guard status == .completed, entered, !completedBeforeEntry else {
            release()
            throw InventoryFixtureError.seamNotReached
        }
    }

    func release() {
        if !released { released = true; exit.fulfill() }
    }
}

@MainActor
private final class FailingInventoryReaderFileManager: ReaderFileManager, @unchecked Sendable {
    var failNextScan = false
    private(set) var scanCount = 0

    override func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath? = nil,
        realmConfiguration: Realm.Configuration? = nil
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        scanCount += 1
        if failNextScan {
            failNextScan = false
            throw InventoryFixtureError.scanFailed
        }
        return try await super.refreshFilesMetadata(drive: drive, relativePath: relativePath,
                                                   realmConfiguration: realmConfiguration)
    }
}

@MainActor
final class ReaderFileInventoryOwnershipTests: XCTestCase, @unchecked Sendable {
    private func configuration() -> Realm.Configuration {
        var result = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        result.objectTypes = [Bookmark.self, ContentFile.self, ContentPackageFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&result)
        return result
    }

    private func root() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("InventoryOwnership-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    private func result(of task: Task<Void, Error>) async throws {
        let completed = XCTestExpectation(description: "inventory task completed")
        var outcome: Result<Void, Error>?
        let observer = Task { @MainActor in
            outcome = await task.result
            completed.fulfill()
        }
        let status = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        guard status == .completed, let outcome else {
            task.cancel()
            observer.cancel()
            throw InventoryFixtureError.taskTimedOut
        }
        try outcome.get()
    }

    private func waitForEntry(_ gate: InventoryOwnershipGate, producer: Task<Void, Error>) async throws {
        let observer = Task { @MainActor in
            _ = await producer.result
            gate.producerFinished()
        }
        defer { observer.cancel() }
        do { try await gate.waitForEntry() }
        catch {
            gate.release()
            producer.cancel()
            _ = try? await result(of: producer)
            throw error
        }
    }

    private func refresh(_ manager: ReaderFileManager, force: Bool = false) async throws {
        try await result(of: Task { @MainActor in try await manager.refreshAllFilesMetadata(force: force) })
    }

    private func requireCancellation(_ task: Task<Void, Error>) async {
        do {
            try await result(of: task)
            XCTFail("Obsolete inventory must not report success")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }

    func testReplacementDriveStartsItsOwnScanBeforeOldMetadataWriteResumes() async throws {
        let oldRoot = try root()
        let newRoot = try root()
        try Data("old bytes".utf8).write(to: oldRoot.appendingPathComponent("old.txt"))
        try Data("new bytes".utf8).write(to: newRoot.appendingPathComponent("new.txt"))
        let config = configuration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: oldRoot))
        let gate = InventoryOwnershipGate()
        manager.inventoryBeforeMetadataWrite = { await gate.blockFirst() }
        let original = Task { @MainActor in try await manager.refreshAllFilesMetadata() }
        defer { gate.release(); original.cancel() }
        try await waitForEntry(gate, producer: original)
        do {
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: newRoot))
            try await refresh(manager)
        } catch {
            gate.release()
            original.cancel()
            _ = try? await result(of: original)
            throw error
        }
        gate.release()
        await requireCancellation(original)
        let realm = try await Realm.open(configuration: config)
        XCTAssertEqual(realm.objects(ContentFile.self).count, 1)
        XCTAssertEqual(manager.files?.map(\.title), ["new"])
        XCTAssertFalse(realm.objects(ContentFile.self).contains { $0.url.lastPathComponent == "old.txt" })
    }

    func testReplacementConfigurationRejectsOriginalPerFileWrite() async throws {
        let directory = try root()
        try Data("bytes".utf8).write(to: directory.appendingPathComponent("book.txt"))
        let oldConfig = configuration()
        let newConfig = configuration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = oldConfig
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        let gate = InventoryOwnershipGate()
        manager.inventoryBeforeMetadataWrite = { await gate.blockFirst() }
        let original = Task { @MainActor in try await manager.refreshAllFilesMetadata() }
        defer { gate.release(); original.cancel() }
        try await waitForEntry(gate, producer: original)
        manager.historyRealmConfigurationOverride = newConfig
        do { try await refresh(manager) }
        catch {
            gate.release()
            original.cancel()
            _ = try? await result(of: original)
            throw error
        }
        gate.release()
        await requireCancellation(original)
        let oldRealm = try await Realm.open(configuration: oldConfig)
        let newRealm = try await Realm.open(configuration: newConfig)
        XCTAssertEqual(oldRealm.objects(ContentFile.self).count, 0)
        XCTAssertEqual(newRealm.objects(ContentFile.self).count, 1)
    }

    func testReplacementBeforeFinalPublicationCannotTombstoneOriginalOrPublishOldFiles() async throws {
        let oldRoot = try root()
        let newRoot = try root()
        let config = configuration()
        let originalURL = URL(string: "reader-file://file/load/local/absent.txt")!
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
            try await realm.asyncWrite {
                let file = ContentFile()
                file.url = originalURL
                file.title = "Retained"
                file.updateCompoundKey()
                realm.add(file)
                file.refreshChangeMetadata(explicitlyModified: true)
            }
        }()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: oldRoot))
        let gate = InventoryOwnershipGate()
        manager.inventoryBeforePublication = { await gate.blockFirst() }
        let original = Task { @MainActor in try await manager.refreshAllFilesMetadata() }
        defer { gate.release(); original.cancel() }
        try await waitForEntry(gate, producer: original)
        do {
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: newRoot))
        } catch {
            gate.release()
            original.cancel()
            _ = try? await result(of: original)
            throw error
        }
        gate.release()
        await requireCancellation(original)
        let realm = try await Realm.open(configuration: config)
        XCTAssertEqual(realm.objects(ContentFile.self).first?.isDeleted, false)
        XCTAssertNil(manager.files)
    }

    func testNewDriveReceiptBypassesPreviousCompletedScanDebounce() async throws {
        let oldRoot = try root()
        let newRoot = try root()
        try Data("replacement".utf8).write(to: newRoot.appendingPathComponent("replacement.txt"))
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: oldRoot))
        try await refresh(manager)
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: newRoot))
        try await refresh(manager)
        XCTAssertEqual(manager.files?.map(\.title), ["replacement"])
    }

    func testFailedReplacementReceiptRemainsImmediatelyRetryableWithOldFilesVisible() async throws {
        let oldRoot = try root()
        let newRoot = try root()
        try Data("old".utf8).write(to: oldRoot.appendingPathComponent("old.txt"))
        try Data("replacement".utf8).write(to: newRoot.appendingPathComponent("replacement.txt"))
        let manager = FailingInventoryReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: oldRoot))
        try await refresh(manager)
        XCTAssertEqual(manager.files?.map(\.title), ["old"])
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: newRoot))
        manager.failNextScan = true
        do {
            try await refresh(manager)
            XCTFail("Expected the replacement scan error")
        } catch InventoryFixtureError.scanFailed {
        }
        XCTAssertEqual(manager.files?.map(\.title), ["old"])
        try await refresh(manager)
        XCTAssertEqual(manager.scanCount, 3)
        XCTAssertEqual(manager.files?.map(\.title), ["replacement"])
    }

    func testFailedForcedPassInvalidatesEarlierReceiptPublicationDebounce() async throws {
        let directory = try root()
        try Data("first".utf8).write(to: directory.appendingPathComponent("first.txt"))
        let manager = FailingInventoryReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        try await refresh(manager)
        try Data("second".utf8).write(to: directory.appendingPathComponent("second.txt"))
        manager.failNextScan = true
        do {
            try await refresh(manager, force: true)
            XCTFail("Expected the forced scan error")
        } catch InventoryFixtureError.scanFailed {
        }
        try await refresh(manager)
        XCTAssertEqual(manager.scanCount, 3)
        XCTAssertEqual(Set(manager.files?.map(\.title) ?? []), Set(["first", "second"]))
    }

}
