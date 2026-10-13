import Foundation
import XCTest
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import SwiftUIDownloads
@testable import LakeOfFireContent

private enum InventoryFixtureError: Error {
    case seamNotReached
    case taskTimedOut
    case scanFailed
}

private actor ImportURLResolutionCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
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

    func testExistingImportRejectsDriveReplacementBeforePartialPublication() async throws {
        try await requireExistingImportReplacementCancellation(replaceConfiguration: false)
    }

    func testExistingImportRejectsConfigurationReplacementBeforePartialPublication() async throws {
        try await requireExistingImportReplacementCancellation(replaceConfiguration: true)
    }

    private func requireExistingImportReplacementCancellation(replaceConfiguration: Bool) async throws {
        let oldRoot = try root()
        let newRoot = try root()
        let oldFile = oldRoot.appendingPathComponent("old.txt")
        try Data("old".utf8).write(to: oldFile)
        try Data("successor".utf8).write(to: newRoot.appendingPathComponent("successor.txt"))
        let oldConfiguration = configuration()
        let replacementConfiguration = configuration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = oldConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: oldRoot))
        let downloadable = Downloadable(url: URL(string: "https://example.com/old.txt")!,
                                        name: "Old", localDestination: oldFile)
        let gate = InventoryOwnershipGate()
        manager.inventoryBeforePartialPublication = { await gate.blockFirst() }
        let original = Task { @MainActor in
            _ = try await manager.ensureImported(downloadable: downloadable)
        }
        defer { gate.release(); original.cancel() }
        try await waitForEntry(gate, producer: original)
        do {
            if replaceConfiguration {
                manager.historyRealmConfigurationOverride = replacementConfiguration
            } else {
                manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: newRoot))
                try await refresh(manager)
            }
        } catch {
            gate.release()
            original.cancel()
            _ = try? await result(of: original)
            throw error
        }
        gate.release()
        await requireCancellation(original)
        if replaceConfiguration {
            XCTAssertNil(manager.files)
            let realm = try await Realm.open(configuration: replacementConfiguration)
            XCTAssertTrue(realm.objects(ContentFile.self).isEmpty)
        } else {
            XCTAssertEqual(manager.files?.map(\.title), ["successor"])
        }
    }

    func testExistingImportPublishesCurrentReceipt() async throws {
        let directory = try root()
        let file = directory.appendingPathComponent("current.txt")
        try Data("current".utf8).write(to: file)
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        let downloadable = Downloadable(url: URL(string: "https://example.com/current.txt")!,
                                        name: "Current", localDestination: file)
        let readerURL = try await manager.ensureImported(downloadable: downloadable)
        XCTAssertEqual(readerURL?.absoluteString, "reader-file://file/load/local/current.txt")
        XCTAssertEqual(manager.files?.map(\.title), ["current"])
    }

    func testImportRejectsDriveReplacementDuringDestinationSelectionBeforeCreatingDirectory() async throws {
        try await requireImportDestinationReplacementCancellation(replaceConfiguration: false)
    }

    func testImportRejectsConfigurationReplacementDuringDestinationSelectionBeforeCreatingDirectory() async throws {
        try await requireImportDestinationReplacementCancellation(replaceConfiguration: true)
    }

    private func requireImportDestinationReplacementCancellation(replaceConfiguration: Bool) async throws {
        let sourceRoot = try root()
        let oldRoot = try root()
        let newRoot = try root()
        let source = sourceRoot.appendingPathComponent("import.txt")
        let bytes = Data("selected bytes".utf8)
        try bytes.write(to: source)
        let manager = ReaderFileManager()
        let config = configuration()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: oldRoot))
        let previousProcessors = ReaderFileManager.fileDestinationProcessors
        let gate = InventoryOwnershipGate()
        ReaderFileManager.fileDestinationProcessors = [{ _ in
            await gate.blockFirst()
            return RootRelativePath(path: "Imported")
        }]
        defer { ReaderFileManager.fileDestinationProcessors = previousProcessors }
        let original = Task { @MainActor in
            _ = try await manager.importFile(fileURL: source, fromDownloadURL: nil)
        }
        defer { gate.release(); original.cancel() }
        try await waitForEntry(gate, producer: original)
        if replaceConfiguration {
            manager.historyRealmConfigurationOverride = configuration()
        } else {
            do { manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: newRoot)) }
            catch {
                gate.release()
                original.cancel()
                _ = try? await result(of: original)
                throw error
            }
        }
        gate.release()
        await requireCancellation(original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("Imported").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newRoot.appendingPathComponent("Imported").path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let realm = try await Realm.open(configuration: config)
        XCTAssertTrue(realm.objects(ContentFile.self).isEmpty)
        XCTAssertNil(manager.files)
    }

    func testImportRejectsReplacementAfterIndexingWithoutAdoptingSuccessorRefresh() async throws {
        let sourceRoot = try root()
        let oldRoot = try root()
        let newRoot = try root()
        let source = sourceRoot.appendingPathComponent("import.txt")
        let bytes = Data("selected bytes".utf8)
        try bytes.write(to: source)
        try Data("successor".utf8).write(to: newRoot.appendingPathComponent("successor.txt"))
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: oldRoot))
        let previousDestinations = ReaderFileManager.fileDestinationProcessors
        let previousURLProcessors = ReaderFileManager.readerFileURLProcessors
        let previousFileProcessors = ReaderFileManager.fileProcessors
        let gate = InventoryOwnershipGate()
        let counter = ImportURLResolutionCounter()
        ReaderFileManager.fileDestinationProcessors = []
        ReaderFileManager.fileProcessors = []
        ReaderFileManager.readerFileURLProcessors = [{ _, _ in
            if await counter.next() == 2 { await gate.blockFirst() }
            return nil
        }]
        defer {
            ReaderFileManager.fileDestinationProcessors = previousDestinations
            ReaderFileManager.readerFileURLProcessors = previousURLProcessors
            ReaderFileManager.fileProcessors = previousFileProcessors
        }
        let original = Task { @MainActor in
            _ = try await manager.importFile(fileURL: source, fromDownloadURL: nil)
        }
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
        XCTAssertEqual(manager.files?.map(\.title), ["successor"])
        XCTAssertEqual(try Data(contentsOf: oldRoot.appendingPathComponent("import.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testImportDoesNotReturnFinalRowDeletedDuringFullRefresh() async throws {
        let sourceRoot = try root()
        let destinationRoot = try root()
        let source = sourceRoot.appendingPathComponent("import.txt")
        let bytes = Data("selected bytes".utf8)
        try bytes.write(to: source)
        let config = configuration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: destinationRoot))
        let previousDestinations = ReaderFileManager.fileDestinationProcessors
        let previousURLProcessors = ReaderFileManager.readerFileURLProcessors
        let previousFileProcessors = ReaderFileManager.fileProcessors
        ReaderFileManager.fileDestinationProcessors = []
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        defer {
            ReaderFileManager.fileDestinationProcessors = previousDestinations
            ReaderFileManager.readerFileURLProcessors = previousURLProcessors
            ReaderFileManager.fileProcessors = previousFileProcessors
        }
        var deletionError: Error?
        manager.inventoryBeforePublication = {
            do {
                try await { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
                    try await realm.asyncWrite {
                        let file = try XCTUnwrap(realm.objects(ContentFile.self).first)
                        file.isDeleted = true
                        file.refreshChangeMetadata(explicitlyModified: true)
                    }
                }()
            } catch { deletionError = error }
        }
        let importedURL = try await manager.importFile(fileURL: source, fromDownloadURL: nil)
        XCTAssertNil(deletionError)
        XCTAssertNil(importedURL)
        XCTAssertEqual(manager.files?.count, 0)
        XCTAssertEqual(try Data(contentsOf: destinationRoot.appendingPathComponent("import.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testRefreshDoesNotPublishRowDeletedAfterDiscoveryResolution() async throws {
        let directory = try root()
        let fileURL = directory.appendingPathComponent("deleted.txt")
        let bytes = Data("retained bytes".utf8)
        try bytes.write(to: fileURL)
        let config = configuration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        let previousURLProcessors = ReaderFileManager.readerFileURLProcessors
        let previousFileProcessors = ReaderFileManager.fileProcessors
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        defer {
            ReaderFileManager.readerFileURLProcessors = previousURLProcessors
            ReaderFileManager.fileProcessors = previousFileProcessors
        }
        var deletionError: Error?
        manager.inventoryBeforeOrphanReconciliation = {
            do {
                try await { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
                    try await realm.asyncWrite {
                        let file = try XCTUnwrap(realm.objects(ContentFile.self).first)
                        file.isDeleted = true
                        file.refreshChangeMetadata(explicitlyModified: true)
                    }
                }()
            } catch { deletionError = error }
        }
        try await refresh(manager)
        XCTAssertNil(deletionError)
        XCTAssertEqual(manager.files?.count, 0)
        let realm = try await Realm.open(configuration: config)
        XCTAssertEqual(realm.objects(ContentFile.self).first?.isDeleted, true)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testListedItemInspectionFailureDoesNotTombstonePreviousInventory() async throws {
        let directory = try root()
        let fileURL = directory.appendingPathComponent("retained.txt")
        let bytes = Data("retained bytes".utf8)
        try bytes.write(to: fileURL)
        let config = configuration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        let previousURLProcessors = ReaderFileManager.readerFileURLProcessors
        let previousFileProcessors = ReaderFileManager.fileProcessors
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        defer {
            ReaderFileManager.readerFileURLProcessors = previousURLProcessors
            ReaderFileManager.fileProcessors = previousFileProcessors
        }
        try await refresh(manager, force: true)
        XCTAssertEqual(manager.files?.map(\.title), ["retained"])
        var inspections = 0
        manager.inventoryBeforeItemInspection = { inspectedURL in
            XCTAssertEqual(inspectedURL.lastPathComponent, "retained.txt")
            inspections += 1
            // Deterministic provider disappearance at the real item-inspection
            // boundary, without deleting any fixture bytes or replacing a scan.
            throw CocoaError(.fileReadNoSuchFile)
        }
        do {
            try await refresh(manager, force: true)
            XCTFail("A listed-but-unavailable item must invalidate the scan")
        } catch ReaderFileManagerError.incompleteFileInventory {
        }
        XCTAssertEqual(inspections, 1)
        let realm = try await Realm.open(configuration: config)
        realm.refresh()
        let row = try XCTUnwrap(realm.objects(ContentFile.self).first)
        XCTAssertFalse(row.isDeleted)
        XCTAssertEqual(manager.files?.map(\.title), ["retained"])
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

        // The failed pass must not establish the debounce success timestamp.
        manager.inventoryBeforeItemInspection = { _ in inspections += 1 }
        try await refresh(manager)
        XCTAssertEqual(inspections, 2)
        XCTAssertFalse(row.isDeleted)
        XCTAssertEqual(manager.files?.map(\.title), ["retained"])
    }

    func testNestedListedItemFailureCannotPublishPartialRootInventory() async throws {
        let directory = try root()
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: nested.appendingPathComponent("book.txt"))
        let config = configuration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        let previousURLProcessors = ReaderFileManager.readerFileURLProcessors
        let previousFileProcessors = ReaderFileManager.fileProcessors
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        defer {
            ReaderFileManager.readerFileURLProcessors = previousURLProcessors
            ReaderFileManager.fileProcessors = previousFileProcessors
        }
        try await refresh(manager, force: true)
        let before = manager.files?.map(\.compoundKey)
        XCTAssertEqual(before?.count, 1)
        var reachedBook = false
        manager.inventoryBeforeItemInspection = { url in
            if url.lastPathComponent == "book.txt" {
                reachedBook = true
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
        do {
            try await refresh(manager, force: true)
            XCTFail("A partial subtree must not authorize a complete root scan")
        } catch ReaderFileManagerError.incompleteFileInventory {
        }
        XCTAssertTrue(reachedBook)
        XCTAssertEqual(manager.files?.map(\.compoundKey), before)
        let realm = try await Realm.open(configuration: config)
        realm.refresh()
        XCTAssertEqual(realm.objects(ContentFile.self).count, 1)
        XCTAssertFalse(try XCTUnwrap(realm.objects(ContentFile.self).first).isDeleted)
    }

}
