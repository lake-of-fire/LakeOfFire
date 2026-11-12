import BigSyncKit
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
    var beforeScan: (@MainActor (Int) async -> Void)?

    override func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath? = nil,
        realmConfiguration: Realm.Configuration? = nil
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        scanCount += 1
        await beforeScan?(scanCount)
        try Task.checkCancellation()
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
            _ = try await manager.ensureImported(downloadable: downloadable, existsLocally: { _ in true })
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
        let readerURL = try await manager.ensureImported(downloadable: downloadable, existsLocally: { _ in true })
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
        do {
            _ = try await manager.importFile(fileURL: source, fromDownloadURL: nil)
            XCTFail("A deleted discovered row cannot authorize a complete import inventory")
        } catch ReaderFileManagerError.incompleteFileInventory {
        }
        XCTAssertNil(deletionError)
        XCTAssertNil(manager.files)
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
        do {
            try await refresh(manager)
            XCTFail("A retired discovered row must fail the complete inventory")
        } catch ReaderFileManagerError.incompleteFileInventory {
        }
        XCTAssertNil(deletionError)
        XCTAssertNil(manager.files)
        let realm = try await Realm.open(configuration: config)
        XCTAssertEqual(realm.objects(ContentFile.self).first?.isDeleted, true)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testUnresolvedDiscoveredRowCannotAuthorizeOrphansAndRemainsRetryable() async throws {
        try await requireOriginalDiscoveredRow(beforeOrphanReconciliation: false)
    }

    func testPhysicalReplacementAfterDiscoveryResolutionCannotAuthorizeOrphansAndRemainsRetryable() async throws {
        try await requireOriginalDiscoveredRow(beforeOrphanReconciliation: true)
    }

    private func requireOriginalDiscoveredRow(beforeOrphanReconciliation: Bool) async throws {
        for replace in [false, true] {
            let directory = try root()
            let anchorURL = directory.appendingPathComponent("anchor.txt")
            let newURL = directory.appendingPathComponent("new.txt")
            let anchorBytes = Data("anchor bytes".utf8)
            let newBytes = Data("new retained bytes".utf8)
            try anchorBytes.write(to: anchorURL)
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
            let previousPublishedIDs = manager.files?.map(\.compoundKey)
            XCTAssertEqual(previousPublishedIDs?.count, 1)
            try newBytes.write(to: newURL)

            var hookError: Error?
            var evidence: (key: String, createdAt: Date, modifiedAt: Date, journal: [Data])?
            var publications = 0
            var orphanPasses = 0
            let intervene: @MainActor () async -> Void = {
                publications += 1
                do {
                    evidence = try await Task { @RealmBackgroundActor in
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
                        let original = try XCTUnwrap(realm.objects(ContentFile.self).first {
                            $0.url.lastPathComponent == "new.txt"
                        })
                        let key = original.compoundKey
                        let createdAt = original.createdAt
                        let modifiedAt = original.modifiedAt
                        if replace {
                            // Separate transactions retire the actual discovered
                            // row, then install an exact persisted-field clone.
                            let clone = ContentFile(value: original)
                            try realm.write { realm.delete(original) }
                            try realm.write { realm.add(clone) }
                            XCTAssertTrue(original.isInvalidated)
                            XCTAssertEqual(clone.compoundKey, key)
                            XCTAssertEqual(clone.createdAt, createdAt)
                            XCTAssertEqual(clone.modifiedAt, modifiedAt)
                        }
                        return (key, createdAt, modifiedAt, try capturedInventoryJournalSnapshot(realm))
                    }.value
                    // Advance the publication actor to the committed replacement;
                    // the real discovered ThreadSafeReference must resolve there.
                    let publicationRealm = try await Realm.open(configuration: config)
                    publicationRealm.refresh()
                } catch { hookError = error }
            }
            manager.inventoryBeforeOrphanReconciliation = {
                orphanPasses += 1
                if beforeOrphanReconciliation { await intervene() }
            }
            manager.inventoryBeforePublication = beforeOrphanReconciliation ? nil : intervene
            if replace {
                do {
                    try await refresh(manager, force: true)
                    XCTFail("An unresolved discovered row must abort the complete inventory")
                } catch ReaderFileManagerError.incompleteFileInventory {
                }
            } else {
                try await refresh(manager, force: true)
            }
            XCTAssertNil(hookError)
            XCTAssertEqual(publications, 1)
            let captured = try XCTUnwrap(evidence)
            let realm = try await Realm.open(configuration: config)
            realm.refresh()
            let successor = try XCTUnwrap(realm.object(ofType: ContentFile.self, forPrimaryKey: captured.key))
            XCTAssertFalse(successor.isDeleted)
            XCTAssertEqual(successor.createdAt, captured.createdAt)
            XCTAssertEqual(successor.modifiedAt, captured.modifiedAt)
            XCTAssertEqual(realm.objects(ContentFile.self).count, 2,
                           "Earlier per-file metadata commits remain intact")
            XCTAssertEqual(try capturedInventoryJournalSnapshot(realm), captured.journal)
            XCTAssertEqual(orphanPasses, replace && !beforeOrphanReconciliation ? 0 : 1)
            if replace {
                XCTAssertEqual(manager.files?.map(\.compoundKey), previousPublishedIDs,
                               "A failed pass must retain the last complete valid UI state")
                manager.inventoryBeforePublication = nil
                manager.inventoryBeforeOrphanReconciliation = { orphanPasses += 1 }
                var inspections = 0
                manager.inventoryBeforeItemInspection = { _ in inspections += 1 }
                // No force: a failed pass must not leave a success debounce.
                try await refresh(manager)
                realm.refresh()
                XCTAssertEqual(inspections, 2)
                XCTAssertEqual(orphanPasses, beforeOrphanReconciliation ? 2 : 1)
                XCTAssertFalse(successor.isDeleted)
                XCTAssertEqual(try capturedInventoryJournalSnapshot(realm), captured.journal)
            }
            XCTAssertEqual(Set(manager.files?.map { $0.url.lastPathComponent } ?? []), Set(["anchor.txt", "new.txt"]))
            XCTAssertEqual(try Data(contentsOf: anchorURL), anchorBytes)
            XCTAssertEqual(try Data(contentsOf: newURL), newBytes)
        }
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

    private func trackedRefresh(
        _ manager: ReaderFileManager, force: Bool = false, gates: [InventoryOwnershipGate] = [],
        finished: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Error> {
        let task = Task { @MainActor in
            defer { finished() }
            try await manager.refreshAllFilesMetadata(force: force)
        }
        addTeardownBlock {
            await MainActor.run {
                manager.appSuspendedDidChange(isSuspended: true)
                gates.forEach { $0.release() }
            }
            task.cancel()
            _ = await task.result
        }
        return task
    }

    private func trackedResume(
        _ manager: ReaderFileManager, gates: [InventoryOwnershipGate]
    ) throws -> Task<Void, Never> {
        var scheduled: Task<Void, Never>?
        manager.inventoryDidScheduleResume = { scheduled = $0 }
        manager.appSuspendedDidChange(isSuspended: false)
        manager.inventoryDidScheduleResume = nil
        let task = try XCTUnwrap(scheduled)
        addTeardownBlock {
            await MainActor.run {
                manager.appSuspendedDidChange(isSuspended: true)
                gates.forEach { $0.release() }
            }
            task.cancel()
            _ = await task.result
        }
        return task
    }

    private func requireJoin(_ expectation: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed else {
            throw InventoryFixtureError.seamNotReached
        }
    }

    func testCancelledCompletedPassRejectsJoinedFollowUpAndOrdinaryRetryPreservesJournal() async throws {
        for withJoinedRequests in [false, true] {
            let directory = try root()
            let config = configuration()
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
                try realm.write {
                    let orphan = ContentFile()
                    orphan.url = URL(string: "reader-file://file/load/local/retired.txt")!
                    orphan.title = "Retired file"
                    orphan.updateCompoundKey()
                    realm.add(orphan)
                    orphan.refreshChangeMetadata(explicitlyModified: true)
                }
            }()
            let realm = try await Realm.open(configuration: config)
            let orphan = try XCTUnwrap(realm.objects(ContentFile.self).first)
            let seededJournal = try capturedInventoryJournalSnapshot(realm)
            let manager = FailingInventoryReaderFileManager()
            manager.historyRealmConfigurationOverride = config
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
            manager.inventoryNow = { Date(timeIntervalSince1970: 1_700_000_000) }
            let gate = InventoryOwnershipGate()
            manager.beforeScan = { scan in if scan == 1 { await gate.blockFirst() } }
            manager.inventoryDidFinishPass = { manager.appSuspendedDidChange(isSuspended: true) }
            let owner = trackedRefresh(manager, gates: [gate])
            try await waitForEntry(gate, producer: owner)
            var callers = [owner]
            if withJoinedRequests {
                let forcedJoin = expectation(description: "Forced caller joined actual inventory")
                let ordinaryJoin = expectation(description: "Ordinary caller joined actual inventory")
                manager.inventoryDidJoin = { force in
                    if force { forcedJoin.fulfill() } else { ordinaryJoin.fulfill() }
                }
                callers.append(trackedRefresh(manager, force: true, gates: [gate]))
                callers.append(trackedRefresh(manager, gates: [gate]))
                try await requireJoin(forcedJoin)
                try await requireJoin(ordinaryJoin)
            }
            gate.release()
            for caller in callers {
                await requireCancellation(caller)
                XCTAssertFalse(caller.isCancelled, "The independent waiter did not cancel itself")
            }
            XCTAssertFalse(Task.isCancelled)
            realm.refresh()
            XCTAssertEqual(manager.scanCount, 1)
            XCTAssertEqual(manager.files?.count, 0)
            XCTAssertTrue(orphan.isDeleted, "The committed orphan transaction remains durable")
            XCTAssertEqual(orphan.title, "Retired file")
            let committedJournal = try capturedInventoryJournalSnapshot(realm)
            XCTAssertNotEqual(committedJournal, seededJournal)
            let committed = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first)
            XCTAssertEqual(committed.changedAt, orphan.modifiedAt)
            XCTAssertEqual(committed.changedAt, orphan.explicitlyModifiedAt)
            let orphanGeneration = committed.generation
            let orphanDate = committed.changedAt
            manager.inventoryDidFinishPass = nil
            manager.inventoryDidJoin = nil
            try Data("current".utf8).write(to: directory.appendingPathComponent("current.txt"))
            try await refresh(manager)
            realm.refresh()
            XCTAssertEqual(manager.scanCount, 2)
            XCTAssertEqual(manager.files?.map(\.title), ["current"])
            XCTAssertTrue(orphan.isDeleted)
            XCTAssertEqual(committed.generation, orphanGeneration)
            XCTAssertEqual(committed.changedAt, orphanDate)
            XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 1)
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 2)
        }
    }

    func testJoinedCallersWaitForTheCoalescedForcedFollowUp() async throws {
        let manager = FailingInventoryReaderFileManager()
        let config = configuration()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: root()))
        let first = InventoryOwnershipGate()
        let second = InventoryOwnershipGate()
        manager.beforeScan = { scan in
            switch scan {
            case 1: await first.blockFirst()
            case 2: await second.blockFirst()
            default: XCTFail("Coalesced force requests require only one follow-up")
            }
        }
        var ownerReturned = false
        var forcedReturned = false
        var ordinaryReturned = false
        let owner = trackedRefresh(manager, gates: [first, second]) { ownerReturned = true }
        try await waitForEntry(first, producer: owner)
        let forcedJoin = expectation(description: "Forced caller joined")
        let ordinaryJoin = expectation(description: "Ordinary caller joined")
        manager.inventoryDidJoin = { force in
            if force { forcedJoin.fulfill() } else { ordinaryJoin.fulfill() }
        }
        let forced = trackedRefresh(manager, force: true, gates: [first, second]) { forcedReturned = true }
        let ordinary = trackedRefresh(manager, gates: [first, second]) { ordinaryReturned = true }
        try await requireJoin(forcedJoin)
        try await requireJoin(ordinaryJoin)
        first.release()
        try await waitForEntry(second, producer: owner)
        XCTAssertEqual(manager.scanCount, 2)
        XCTAssertFalse(ownerReturned)
        XCTAssertFalse(forcedReturned)
        XCTAssertFalse(ordinaryReturned)
        second.release()
        for task in [owner, forced, ordinary] { try await result(of: task) }
        XCTAssertTrue(ownerReturned && forcedReturned && ordinaryReturned)
        XCTAssertEqual(manager.scanCount, 2)
        XCTAssertEqual(manager.files?.count, 0)
        let realm = try await Realm.open(configuration: config)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testSuccessfulInventoryDebouncesFromCompletionAtTheExactBoundary() async throws {
        let directory = try root()
        try Data("first".utf8).write(to: directory.appendingPathComponent("first.txt"))
        let manager = FailingInventoryReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var now = start
        manager.inventoryNow = { now }
        manager.inventoryDidFinishPass = { now = start.addingTimeInterval(10) }
        try await refresh(manager)
        manager.inventoryDidFinishPass = nil
        XCTAssertEqual(manager.scanCount, 1)
        try await refresh(manager)
        XCTAssertEqual(manager.scanCount, 1)
        now = start.addingTimeInterval(11.999)
        try await refresh(manager)
        XCTAssertEqual(manager.scanCount, 1)
        now = start.addingTimeInterval(12)
        try await refresh(manager)
        XCTAssertEqual(manager.scanCount, 2)
        XCTAssertEqual(manager.files?.map(\.title), ["first"])
    }

    func testFailedForcedAndReplacementPassesKeepTheirPreviousJournalAndRetryAtTheSameTime() async throws {
        for replaceDrive in [false, true] {
            let directory = try root()
            try Data("first".utf8).write(to: directory.appendingPathComponent("first.txt"))
            let manager = FailingInventoryReaderFileManager()
            let config = configuration()
            manager.historyRealmConfigurationOverride = config
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
            manager.inventoryNow = { Date(timeIntervalSince1970: 1_700_000_000) }
            try await refresh(manager)
            let realm = try await Realm.open(configuration: config)
            let first = try XCTUnwrap(realm.objects(ContentFile.self).first)
            let journal = try capturedInventoryJournalSnapshot(realm)
            let nextRoot = replaceDrive ? try root() : directory
            try Data("second".utf8).write(to: nextRoot.appendingPathComponent("second.txt"))
            if replaceDrive {
                manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: nextRoot))
            }
            manager.failNextScan = true
            do {
                try await refresh(manager, force: !replaceDrive)
                XCTFail("Expected the actual requested scan failure")
            } catch InventoryFixtureError.scanFailed { }
            realm.refresh()
            XCTAssertEqual(manager.files?.map(\.title), ["first"])
            XCTAssertFalse(first.isDeleted)
            XCTAssertEqual(try capturedInventoryJournalSnapshot(realm), journal)
            try await refresh(manager)
            realm.refresh()
            XCTAssertEqual(manager.scanCount, 3)
            XCTAssertEqual(Set(manager.files?.map(\.title) ?? []),
                           replaceDrive ? Set(["second"]) : Set(["first", "second"]))
            XCTAssertEqual(first.isDeleted, replaceDrive)
            XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, replaceDrive ? 1 : 2)
        }
    }

    func testReturningToPreviousDriveAndExternalPublicationCannotReuseDebounce() async throws {
        let firstRoot = try root()
        let secondRoot = try root()
        try Data("first".utf8).write(to: firstRoot.appendingPathComponent("first.txt"))
        try Data("second".utf8).write(to: secondRoot.appendingPathComponent("second.txt"))
        let manager = FailingInventoryReaderFileManager()
        let config = configuration()
        manager.historyRealmConfigurationOverride = config
        let firstDrive = try await CloudDrive(storage: .localDirectory(rootURL: firstRoot))
        manager.localDrive = firstDrive
        manager.inventoryNow = { Date(timeIntervalSince1970: 1_700_000_000) }
        try await refresh(manager)
        let realm = try await Realm.open(configuration: config)
        let first = try XCTUnwrap(realm.objects(ContentFile.self).first)
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: secondRoot))
        try await refresh(manager)
        realm.refresh()
        let second = try XCTUnwrap(realm.objects(ContentFile.self).first { !$0.isDeleted })
        XCTAssertTrue(first.isDeleted)
        XCTAssertFalse(second.isDeleted)
        manager.localDrive = firstDrive
        try await refresh(manager)
        realm.refresh()
        XCTAssertEqual(manager.scanCount, 3)
        XCTAssertEqual(manager.files?.map(\.title), ["first"])
        XCTAssertFalse(first.isDeleted)
        XCTAssertTrue(second.isDeleted)
        manager.files = []
        try await refresh(manager)
        XCTAssertEqual(manager.scanCount, 4)
        XCTAssertEqual(manager.files?.map(\.title), ["first"])
    }

    func testLateCompletionCannotAuthorizeADifferentPublication() async throws {
        let firstRoot = try root()
        let secondRoot = try root()
        try Data("first".utf8).write(to: firstRoot.appendingPathComponent("first.txt"))
        try Data("second".utf8).write(to: secondRoot.appendingPathComponent("second.txt"))
        let manager = FailingInventoryReaderFileManager()
        let config = configuration()
        manager.historyRealmConfigurationOverride = config
        let firstDrive = try await CloudDrive(storage: .localDirectory(rootURL: firstRoot))
        manager.localDrive = firstDrive
        manager.inventoryNow = { Date(timeIntervalSince1970: 1_700_000_000) }
        let gate = InventoryOwnershipGate()
        manager.inventoryBeforeCompletion = { await gate.blockFirst() }
        let original = trackedRefresh(manager, gates: [gate])
        try await waitForEntry(gate, producer: original)
        XCTAssertEqual(manager.files?.map(\.title), ["first"])
        manager.inventoryBeforeCompletion = nil
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: secondRoot))
        try await refresh(manager)
        manager.localDrive = firstDrive
        gate.release()
        // Current receipt fencing is stricter than the old harness: the late
        // caller reports cancellation while its prior commit remains durable.
        await requireCancellation(original)
        XCTAssertEqual(manager.files?.map(\.title), ["second"])
        try await refresh(manager)
        XCTAssertEqual(manager.scanCount, 3)
        XCTAssertEqual(manager.files?.map(\.title), ["first"])
        let realm = try await Realm.open(configuration: config)
        XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 1)
    }

    func testResumeJoinsCancelledInventoryThenScansWithoutRejournalingUnchangedFiles() async throws {
        let directory = try root()
        let firstURL = directory.appendingPathComponent("first.txt")
        try Data("first".utf8).write(to: firstURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                              ofItemAtPath: firstURL.path)
        let manager = FailingInventoryReaderFileManager()
        let config = configuration()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        manager.inventoryNow = { Date(timeIntervalSince1970: 1_700_000_000) }
        try await refresh(manager)
        let realm = try await Realm.open(configuration: config)
        let first = try XCTUnwrap(realm.objects(ContentFile.self).first)
        let journalKey = first.objectSchema.className + "." + first.compoundKey
        let generation = try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
                                                   forPrimaryKey: journalKey)).generation
        try Data("resumed".utf8).write(to: directory.appendingPathComponent("resumed.txt"))
        let gate = InventoryOwnershipGate()
        manager.beforeScan = { scan in if scan == 2 { await gate.blockFirst() } }
        let owner = trackedRefresh(manager, force: true, gates: [gate])
        try await waitForEntry(gate, producer: owner)
        manager.appSuspendedDidChange(isSuspended: true)
        let joined = expectation(description: "Resume joins the cancelled owner")
        manager.inventoryDidJoin = { force in XCTAssertFalse(force); joined.fulfill() }
        let resume = try trackedResume(manager, gates: [gate])
        try await requireJoin(joined)
        XCTAssertEqual(manager.scanCount, 2)
        gate.release()
        await requireCancellation(owner)
        await resume.value
        realm.refresh()
        XCTAssertFalse(owner.isCancelled)
        XCTAssertEqual(manager.scanCount, 3)
        XCTAssertEqual(Set(manager.files?.map(\.title) ?? []), Set(["first", "resumed"]))
        XCTAssertFalse(first.isDeleted)
        XCTAssertEqual(realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: journalKey)?.generation,
                       generation)
        XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 2)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 2)
    }

    func testSuspensionRetiresWaitingAndQueuedResumeTasks() async throws {
        let directory = try root()
        try Data("current".utf8).write(to: directory.appendingPathComponent("current.txt"))
        let manager = FailingInventoryReaderFileManager()
        let config = configuration()
        manager.historyRealmConfigurationOverride = config
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        let gate = InventoryOwnershipGate()
        manager.beforeScan = { scan in if scan == 1 { await gate.blockFirst() } }
        let owner = trackedRefresh(manager, gates: [gate])
        try await waitForEntry(gate, producer: owner)
        manager.appSuspendedDidChange(isSuspended: true)
        let joined = expectation(description: "Waiting resume joins original retirement")
        manager.inventoryDidJoin = { force in XCTAssertFalse(force); joined.fulfill() }
        let waiting = try trackedResume(manager, gates: [gate])
        try await requireJoin(joined)
        manager.appSuspendedDidChange(isSuspended: true)
        gate.release()
        await requireCancellation(owner)
        await waiting.value
        XCTAssertEqual(manager.scanCount, 1)
        XCTAssertNil(manager.files)
        let queued = try trackedResume(manager, gates: [gate])
        manager.appSuspendedDidChange(isSuspended: true)
        await queued.value
        XCTAssertEqual(manager.scanCount, 1)
        manager.inventoryDidJoin = nil
        let current = try trackedResume(manager, gates: [gate])
        await current.value
        XCTAssertEqual(manager.scanCount, 2)
        XCTAssertEqual(manager.files?.map(\.title), ["current"])
        let realm = try await Realm.open(configuration: config)
        XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 1)
    }

    func testNewestResumeUsesCurrentRealmAfterJoiningTheCancelledOwner() async throws {
        let directory = try root()
        try Data("current".utf8).write(to: directory.appendingPathComponent("current.txt"))
        let manager = FailingInventoryReaderFileManager()
        let oldConfig = configuration()
        let newConfig = configuration()
        manager.historyRealmConfigurationOverride = oldConfig
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: directory))
        let gate = InventoryOwnershipGate()
        manager.beforeScan = { scan in if scan == 1 { await gate.blockFirst() } }
        let owner = trackedRefresh(manager, gates: [gate])
        try await waitForEntry(gate, producer: owner)
        let healthyJoin = expectation(description: "Healthy activation shares original inventory")
        manager.inventoryDidJoin = { force in XCTAssertFalse(force); healthyJoin.fulfill() }
        let healthy = try trackedResume(manager, gates: [gate])
        try await requireJoin(healthyJoin)
        manager.appSuspendedDidChange(isSuspended: true)
        let earlierJoin = expectation(description: "Earlier activation awaits cancellation")
        manager.inventoryDidJoin = { force in XCTAssertFalse(force); earlierJoin.fulfill() }
        let earlier = try trackedResume(manager, gates: [gate])
        try await requireJoin(earlierJoin)
        let latestJoin = expectation(description: "Latest activation awaits cancellation")
        manager.inventoryDidJoin = { force in XCTAssertFalse(force); latestJoin.fulfill() }
        let latest = try trackedResume(manager, gates: [gate])
        try await requireJoin(latestJoin)
        manager.historyRealmConfigurationOverride = newConfig
        gate.release()
        await requireCancellation(owner)
        await healthy.value
        await earlier.value
        await latest.value
        XCTAssertEqual(manager.scanCount, 2, "Only the newest resume may recover")
        XCTAssertEqual(manager.files?.map(\.title), ["current"])
        let previous = try await Realm.open(configuration: oldConfig)
        let current = try await Realm.open(configuration: newConfig)
        XCTAssertTrue(previous.objects(ContentFile.self).isEmpty)
        XCTAssertTrue(previous.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertEqual(current.objects(ContentFile.self).filter("isDeleted == false").count, 1)
        XCTAssertEqual(current.objects(BigSyncPendingMutation.self).count, 1)
    }

}

// Runtime journal snapshots for synthetic fixtures; no source/schema roster.
private func capturedInventoryJournalSnapshot(_ realm: Realm) throws -> [Data] {
    try realm.objects(BigSyncPendingMutation.self).map { row in
        let fields = Dictionary(uniqueKeysWithValues: row.objectSchema.properties.map {
            ($0.name, String(describing: row[$0.name]))
        })
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }.sorted { $0.lexicographicallyPrecedes($1) }
}
