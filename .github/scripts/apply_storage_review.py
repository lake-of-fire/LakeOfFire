from pathlib import Path
import json, subprocess

MANAGER = 'Sources/LakeOfFireContent/Files/ReaderFileManager.swift'
p = Path(MANAGER)
s = p.read_text()
assert subprocess.check_output(['git','hash-object',MANAGER], text=True).strip() == 'cbf770134200f72623e1264e251fe75bd3f27b1e'

def replace(old, new):
    global s
    assert s.count(old) == 1, (old[:100], s.count(old))
    s = s.replace(old, new)

def block(start, end, new):
    global s
    assert s.count(start) == 1 and s.count(end) == 1
    a = s.index(start)
    b = s.index(end, a)
    s = s[:a] + new + s[b:]

replace('public enum CloudDriveSyncStatus {', 'public enum CloudDriveSyncStatus: Sendable {')
replace('    private var hasInitializedUbiquityContainerIdentifier = false', '''    private var hasInitializedUbiquityContainerIdentifier = false
    @MainActor private var initializationID: UUID?''')
replace('''    public func initialize(ubiquityContainerIdentifier: String) async throws {
        // Prepare''', '''    public func initialize(ubiquityContainerIdentifier: String) async throws {
        // A cancelled entrant cannot revoke a healthy initialization or invoke
        // a factory whose preparation may itself create directories/presenters.
        try Task.checkCancellation()
        let identifier = UUID()
        initializationID = identifier
        // Prepare''')
replace('''        try Task.checkCancellation()
        let nextLocalDrive = try await localDriveFactory()
        try Task.checkCancellation()''', '''        try validateInitialization(identifier)
        let nextLocalDrive = try await localDriveFactory()
        try validateInitialization(identifier)''')
replace('''        try await refreshAllFilesMetadata()
    }
    
    @MainActor
    public func appSuspendedDidChange''', '''        try validateInitialization(identifier)
        try await refreshAllFilesMetadata()
        try validateInitialization(identifier)
    }

    @MainActor
    private func validateInitialization(_ identifier: UUID) throws {
        try Task.checkCancellation()
        guard initializationID == identifier else { throw CancellationError() }
    }
    
    @MainActor
    public func appSuspendedDidChange''')
block('''    @RealmBackgroundActor
    public func delete(readerFileURL contentURL: URL) async throws {''', '''    @MainActor
    public static func get(fileURL: URL)''', '''    typealias DeleteStatusLoader = @MainActor (URL) async throws -> CloudDriveSyncStatus

    @RealmBackgroundActor
    public func delete(readerFileURL contentURL: URL) async throws {
        try await delete(readerFileURL: contentURL, statusLoader: { [self] url in
            try await cloudDriveSyncStatus(forReaderBackingURL: url)
        })
    }

    /// The public command and native boundary tests share the same executor.
    /// Only its asynchronous availability collaborator can be supplied by tests.
    @RealmBackgroundActor
    func delete(readerFileURL contentURL: URL, statusLoader: DeleteStatusLoader) async throws {
        try Task.checkCancellation()
        let realmConfiguration = resolvedHistoryRealmConfiguration
        guard let readerBackingURL = canonicalReaderBackingURL(for: contentURL) else {
            throw ReaderFileDeleteError.removeFailed()
        }
        let pathContext = try readerBackingPathContext(for: readerBackingURL)
        let drive = pathContext.storageLocation == .local ? localDrive : cloudDrive
        let status: CloudDriveSyncStatus
        do {
            status = try await statusLoader(readerBackingURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReaderFileDeleteError.blockedLoadingStatus
        }
        try validateDeletionSelection(pathContext, drive: drive)
        switch status {
        case .cloudOnly: throw ReaderFileDeleteError.blockedCloudOnly
        case .loadingStatus: throw ReaderFileDeleteError.blockedLoadingStatus
        default: break
        }

        if status != .fileMissing {
            // Resolve once, before availability can suspend. A replacement
            // drive may contain an unrelated file with the same logical URL.
            guard let drive else { throw ReaderFileManagerError.driveMissing }
            do {
                let isDirectory = try await drive.directoryExists(at: pathContext.relativePath)
                try validateDeletionSelection(pathContext, drive: drive)
                if isDirectory {
                    try await drive.removeDirectory(at: pathContext.relativePath)
                } else {
                    try await drive.removeFile(at: pathContext.relativePath)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReaderFileDeleteError {
                throw error
            } catch {
                throw ReaderFileDeleteError.removeFailed(underlyingDescription: error.localizedDescription)
            }
        }

        // The physical removal, if any, is already committed. This next phase
        // can fail independently; it must never mutate a replacement's index.
        try await markDeleted(contentURL: contentURL, realmConfiguration: realmConfiguration,
                              pathContext: pathContext, drive: drive)
        await removeDeletedFileFromPublishedFiles(matching: readerBackingURL,
            realmConfiguration: realmConfiguration, pathContext: pathContext, drive: drive)
        Task { @MainActor [weak self] in
            guard let self, self.deletionDriveIsCurrent(pathContext, drive: drive),
                  Self.sameHistoryRealm(self.resolvedHistoryRealmConfiguration, realmConfiguration) else { return }
            try await self.refreshAllFilesMetadata(force: true, realmConfiguration: realmConfiguration)
        }
    }

    private func deletionDriveIsCurrent(_ context: ReaderBackingPathContext, drive: CloudDrive?) -> Bool {
        let current = context.storageLocation == .local ? localDrive : cloudDrive
        return current === drive
    }

    private func validateDeletionSelection(_ context: ReaderBackingPathContext, drive: CloudDrive?) throws {
        try Task.checkCancellation()
        guard deletionDriveIsCurrent(context, drive: drive) else {
            throw ReaderFileDeleteError.removeFailed(
                underlyingDescription: "The selected storage changed. Retry from the current library."
            )
        }
    }

    private static func sameHistoryRealm(_ lhs: Realm.Configuration, _ rhs: Realm.Configuration) -> Bool {
        lhs.inMemoryIdentifier == rhs.inMemoryIdentifier
            && lhs.fileURL?.standardizedFileURL == rhs.fileURL?.standardizedFileURL
    }
    
''')
replace('''    private func removeDeletedFileFromPublishedFiles(matching readerBackingURL: URL) {
        guard let canonicalDeletedURL''', '''    private func removeDeletedFileFromPublishedFiles(
        matching readerBackingURL: URL, realmConfiguration: Realm.Configuration,
        pathContext: ReaderBackingPathContext, drive: CloudDrive?
    ) {
        guard deletionDriveIsCurrent(pathContext, drive: drive),
              Self.sameHistoryRealm(resolvedHistoryRealmConfiguration, realmConfiguration) else { return }
        guard let canonicalDeletedURL''')
replace('''        let remainingFiles = files.filter { contentFile in
            guard let fileBackingURL''', '''        let remainingFiles = files.filter { contentFile in
            guard !contentFile.isInvalidated else { return false }
            guard let fileBackingURL''')
block('''    @RealmBackgroundActor
    private func markDeleted(''', '''    private static func extractRelativePath(fileURL: URL)''', '''    @RealmBackgroundActor
    private func markDeleted(
        contentURL: URL, realmConfiguration: Realm.Configuration,
        pathContext: ReaderBackingPathContext, drive: CloudDrive?
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        let canonicalContentURL = pathContext.canonicalURL
        try await realm.asyncWritePreservingOwnership {
            try validateDeletionSelection(pathContext, drive: drive)
            // Missing at the earlier status read is not proof of continued
            // absence. A reimport at the same path must keep its live metadata.
            if let path = pathContext.activeRootURL, Self.fileSystemEntryExists(at: path) {
                throw ReaderFileDeleteError.removeFailed(
                    underlyingDescription: "A file now exists at the selected path. Refresh the library before retrying."
                )
            }
            // Query only after this independent write is admitted. Managed
            // objects captured before an await can be deleted or replaced by
            // the owner whose transaction this writer is waiting to acquire.
            let contentFiles = Array(realm.objects(ContentFile.self)
                .where { !$0.isDeleted }
                .filter { file in
                    file.url == contentURL
                        || self.canonicalReaderBackingURL(for: file.url) == canonicalContentURL
                })
            let timestamp = Date()
            for existing in contentFiles {
                existing.isDeleted = true
                existing.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                let packageContentFiles = realm.objects(ContentPackageFile.self)
                    .where { $0.packageContentFileID == existing.compoundKey && !$0.isDeleted }
                for packageContentFile in packageContentFiles {
                    packageContentFile.isDeleted = true
                    packageContentFile.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            }
            try validateDeletionSelection(pathContext, drive: drive)
        }
    }
    
''')
p.write_text(s)

INITIALIZATION = 'Tests/LakeOfFireTests/ReaderFileInitializationTests.swift'
t = Path(INITIALIZATION)
assert subprocess.check_output(['git','hash-object',INITIALIZATION], text=True).strip() == '3cf70eb21ffa0952f6ead282ec422d07a5807cde'
old = t.read_text()
assert old.startswith('import Foundation\n')
t.write_text('import BigSyncKit\nimport RealmSwift\nimport RealmSwiftGaps\n' + old + r'''

@MainActor
private struct DriveInitializationFixture {
    let root: URL
    let configuration: Realm.Configuration
    let realm: Realm
    let local: CloudDrive
    let first: CloudDrive
    let second: CloudDrive
}

@MainActor
extension ReaderFileInitializationTests {
    private func withDriveFixture(
        _ body: (DriveInitializationFixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderDriveOwnership-" + UUID().uuidString, isDirectory: true)
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [ContentFile.self, ContentPackageFile.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let local = try await CloudDrive(storage: .localDirectory(rootURL: root.appendingPathComponent("local")))
        let first = try await CloudDrive(storage: .localDirectory(rootURL: root.appendingPathComponent("first")))
        let second = try await CloudDrive(storage: .localDirectory(rootURL: root.appendingPathComponent("second")))
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await body(.init(root: root, configuration: configuration, realm: realm,
                                 local: local, first: first, second: second))
        } catch {
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            throw error
        }
        await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
    }

    private func requireCancellation(_ task: Task<Void, Error>) async {
        do {
            try await task.value
            XCTFail("An obsolete preparation must not report successful initialization")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, not \(error)")
        }
    }

    func testAlreadyCancelledInitializationCannotInvokeDriveFactories() async {
        var calls = 0
        let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
            directoryContentsProvider: { _ in [] },
            cloudDriveFactory: { _ in
                calls += 1
                throw ReaderFileInitializationTestError.unexpectedFactoryContinuation
            }, localDriveFactory: {
                calls += 1
                throw ReaderFileInitializationTestError.localFactoryShouldNotRun
            })
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await manager.initialize(ubiquityContainerIdentifier: "cancelled")
        }
        await requireCancellation(cancelled)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(manager.localDrive)
        XCTAssertNil(manager.cloudDrive)
        XCTAssertNil(manager.ubiquityContainerIdentifier)
    }

    func testNewerInitializationWinsWhileOriginalCloudPreparationIsSuspended() async throws {
        try await withDriveFixture { f in
            let gate = ReaderFileInitializationGate()
            var localCalls = 0
            let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
                directoryContentsProvider: { _ in [] }, cloudDriveFactory: { id in
                    if id == "first" { await gate.blockUntilReleased(); return f.first }
                    return f.second
                }, localDriveFactory: { localCalls += 1; return f.local })
            manager.historyRealmConfigurationOverride = f.configuration
            manager.inventoryRefreshQueue = ReaderFileRefreshQueue(interval: 0)
            let original = Task { @MainActor in try await manager.initialize(ubiquityContainerIdentifier: "first") }
            await gate.waitUntilEntered()
            do { try await manager.initialize(ubiquityContainerIdentifier: "second") }
            catch { await gate.release(); _ = try? await original.value; throw error }
            await gate.release()
            await self.requireCancellation(original)
            XCTAssertEqual(localCalls, 1)
            XCTAssertTrue(manager.cloudDrive === f.second)
            XCTAssertTrue(manager.localDrive === f.local)
            XCTAssertEqual(manager.ubiquityContainerIdentifier, "second")
            XCTAssertNil(f.first.observer)
            XCTAssertNotNil(manager.files)
        }
    }

    func testNewerInitializationWinsWhileOriginalLocalPreparationIsSuspended() async throws {
        try await withDriveFixture { f in
            let gate = ReaderFileInitializationGate()
            var localCalls = 0
            let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
                directoryContentsProvider: { _ in [] }, cloudDriveFactory: { id in
                    id == "first" ? f.first : f.second
                }, localDriveFactory: {
                    localCalls += 1
                    if localCalls == 1 { await gate.blockUntilReleased(); return f.first }
                    return f.local
                })
            manager.historyRealmConfigurationOverride = f.configuration
            manager.inventoryRefreshQueue = ReaderFileRefreshQueue(interval: 0)
            let original = Task { @MainActor in try await manager.initialize(ubiquityContainerIdentifier: "first") }
            await gate.waitUntilEntered()
            do { try await manager.initialize(ubiquityContainerIdentifier: "second") }
            catch { await gate.release(); _ = try? await original.value; throw error }
            await gate.release()
            await self.requireCancellation(original)
            XCTAssertTrue(manager.cloudDrive === f.second)
            XCTAssertTrue(manager.localDrive === f.local)
            XCTAssertNil(f.first.observer)
        }
    }

    func testFailedNewerInitializationCannotReactivateOlderPreparation() async throws {
        try await withDriveFixture { f in
            let gate = ReaderFileInitializationGate()
            var localCalls = 0
            let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
                directoryContentsProvider: { _ in [] }, cloudDriveFactory: { id in
                    if id == "first" { await gate.blockUntilReleased(); return f.first }
                    return f.second
                }, localDriveFactory: {
                    localCalls += 1
                    throw ReaderFileInitializationTestError.localFactoryShouldNotRun
                })
            manager.localDrive = f.local
            manager.cloudDrive = f.second
            manager.ubiquityContainerIdentifier = "installed"
            let original = Task { @MainActor in try await manager.initialize(ubiquityContainerIdentifier: "first") }
            await gate.waitUntilEntered()
            do {
                try await manager.initialize(ubiquityContainerIdentifier: "new-failed")
                XCTFail("Expected the newer local factory failure")
            } catch ReaderFileInitializationTestError.localFactoryShouldNotRun {
            } catch { await gate.release(); _ = try? await original.value; throw error }
            await gate.release()
            await self.requireCancellation(original)
            XCTAssertEqual(localCalls, 1, "Failure does not give an obsolete initializer a second admission")
            XCTAssertTrue(manager.localDrive === f.local)
            XCTAssertTrue(manager.cloudDrive === f.second)
            XCTAssertEqual(manager.ubiquityContainerIdentifier, "installed")
        }
    }

    func testCancelledEntrantCannotWithdrawHealthyPendingInitialization() async throws {
        try await withDriveFixture { f in
            let gate = ReaderFileInitializationGate()
            var cloudCalls = 0
            let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
                directoryContentsProvider: { _ in [] }, cloudDriveFactory: { _ in
                    cloudCalls += 1
                    if cloudCalls == 1 { await gate.blockUntilReleased() }
                    return f.first
                }, localDriveFactory: { f.local })
            manager.historyRealmConfigurationOverride = f.configuration
            manager.inventoryRefreshQueue = ReaderFileRefreshQueue(interval: 0)
            let healthy = Task { @MainActor in try await manager.initialize(ubiquityContainerIdentifier: "healthy") }
            await gate.waitUntilEntered()
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                try await manager.initialize(ubiquityContainerIdentifier: "cancelled")
            }
            await self.requireCancellation(cancelled)
            await gate.release()
            try await healthy.value
            XCTAssertEqual(cloudCalls, 1)
            XCTAssertTrue(manager.cloudDrive === f.first)
            XCTAssertEqual(manager.ubiquityContainerIdentifier, "healthy")
        }
    }

    func testObsoleteCloudFailureCannotPublishLocalFallback() async throws {
        try await withDriveFixture { f in
            let gate = ReaderFileInitializationGate()
            var localCalls = 0
            let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
                directoryContentsProvider: { _ in [] }, cloudDriveFactory: { id in
                    if id == "first" {
                        await gate.blockUntilReleased()
                        throw ReaderFileInitializationTestError.unexpectedFactoryContinuation
                    }
                    return f.second
                }, localDriveFactory: { localCalls += 1; return f.local })
            manager.historyRealmConfigurationOverride = f.configuration
            manager.inventoryRefreshQueue = ReaderFileRefreshQueue(interval: 0)
            let original = Task { @MainActor in try await manager.initialize(ubiquityContainerIdentifier: "first") }
            await gate.waitUntilEntered()
            do { try await manager.initialize(ubiquityContainerIdentifier: "second") }
            catch { await gate.release(); _ = try? await original.value; throw error }
            await gate.release()
            await self.requireCancellation(original)
            XCTAssertEqual(localCalls, 1)
            XCTAssertTrue(manager.cloudDrive === f.second)
            XCTAssertEqual(manager.ubiquityContainerIdentifier, "second")
        }
    }

    func testSameIdentifierDoesNotLetOlderPreparationReplaceNewerDrives() async throws {
        try await withDriveFixture { f in
            let gate = ReaderFileInitializationGate()
            var cloudCalls = 0
            let manager = ReaderFileManager(payloadStateProvider: { _ in .current },
                directoryContentsProvider: { _ in [] }, cloudDriveFactory: { _ in
                    cloudCalls += 1
                    if cloudCalls == 1 { await gate.blockUntilReleased(); return f.first }
                    return f.second
                }, localDriveFactory: { f.local })
            manager.historyRealmConfigurationOverride = f.configuration
            manager.inventoryRefreshQueue = ReaderFileRefreshQueue(interval: 0)
            let original = Task { @MainActor in try await manager.initialize(ubiquityContainerIdentifier: "same") }
            await gate.waitUntilEntered()
            do { try await manager.initialize(ubiquityContainerIdentifier: "same") }
            catch { await gate.release(); _ = try? await original.value; throw error }
            await gate.release()
            await self.requireCancellation(original)
            XCTAssertTrue(manager.cloudDrive === f.second)
            XCTAssertNil(f.first.observer)
        }
    }
}
''')

LIBRARY = 'Tests/LakeOfFireTests/ReaderFileLibraryBoundaryTests.swift'
t = Path(LIBRARY)
assert subprocess.check_output(['git','hash-object',LIBRARY], text=True).strip() == '857dc80bd484f9af7842af39e4d65941b5508209'
t.write_text(t.read_text() + r'''

@MainActor
extension ReaderFileLibraryBoundaryTests {
    private func indexedDeletionRecord(_ f: Fixture, name: String = "delete.txt") throws -> ContentFile {
        let record = ContentFile()
        record.url = try XCTUnwrap(URL(string: "reader-file://file/load/local/" + name))
        record.updateCompoundKey()
        try f.realm.write {
            f.realm.add(record)
            record.refreshChangeMetadata(explicitlyModified: true)
        }
        f.manager.files = [record]
        return record
    }

    private func journalGeneration(_ f: Fixture, record: ContentFile) throws -> String {
        try XCTUnwrap(f.realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: ContentFile.className() + "." + record.compoundKey)).generation
    }

    func testDeleteCannotRetargetAReplacementDriveAfterAvailability() async throws {
        try await withFixture { f in
            let originalURL = f.library.appendingPathComponent("delete.txt")
            try self.write("original bytes", to: originalURL)
            let replacementRoot = f.root.appendingPathComponent("replacement", isDirectory: true)
            let replacement = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
            let replacementURL = replacementRoot.appendingPathComponent("delete.txt")
            try self.write("replacement bytes", to: replacementURL)
            let record = try self.indexedDeletionRecord(f)
            let generation = try self.journalGeneration(f, record: record)
            do {
                try await f.manager.delete(readerFileURL: record.url, statusLoader: { url in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    f.manager.localDrive = replacement
                    return status
                })
                XCTFail("A stale deletion must not follow the replacement drive")
            } catch ReaderFileDeleteError.removeFailed { }
            f.realm.refresh()
            XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "original bytes")
            XCTAssertEqual(try String(contentsOf: replacementURL, encoding: .utf8), "replacement bytes")
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(try self.journalGeneration(f, record: record), generation)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [record.compoundKey])
        }
    }

    func testMissingFileOutcomeCannotDeleteReplacementDriveIndex() async throws {
        try await withFixture { f in
            let replacementRoot = f.root.appendingPathComponent("replacement", isDirectory: true)
            let replacement = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
            let replacementURL = replacementRoot.appendingPathComponent("delete.txt")
            try self.write("replacement bytes", to: replacementURL)
            let record = try self.indexedDeletionRecord(f)
            let generation = try self.journalGeneration(f, record: record)
            do {
                try await f.manager.delete(readerFileURL: record.url, statusLoader: { url in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    XCTAssertEqual(status, .fileMissing)
                    f.manager.localDrive = replacement
                    return status
                })
                XCTFail("Old-root absence cannot authorize a new-root tombstone")
            } catch ReaderFileDeleteError.removeFailed { }
            f.realm.refresh()
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(try self.journalGeneration(f, record: record), generation)
            XCTAssertEqual(try String(contentsOf: replacementURL, encoding: .utf8), "replacement bytes")
        }
    }

    func testMissingFileOutcomeCannotTombstoneAReappearedPayload() async throws {
        try await withFixture { f in
            let url = f.library.appendingPathComponent("delete.txt")
            let record = try self.indexedDeletionRecord(f)
            let generation = try self.journalGeneration(f, record: record)
            do {
                try await f.manager.delete(readerFileURL: record.url, statusLoader: { backing in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                    XCTAssertEqual(status, .fileMissing)
                    try self.write("newly imported bytes", to: url)
                    return status
                })
                XCTFail("Absence must still hold when the index write is admitted")
            } catch ReaderFileDeleteError.removeFailed { }
            f.realm.refresh()
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(try self.journalGeneration(f, record: record), generation)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "newly imported bytes")
        }
    }

    func testCancelledAvailabilityCannotDeleteOrJournalAFile() async throws {
        try await withFixture { f in
            let url = f.library.appendingPathComponent("delete.txt")
            try self.write("original bytes", to: url)
            let record = try self.indexedDeletionRecord(f)
            let generation = try self.journalGeneration(f, record: record)
            let deletion = Task { @MainActor in
                try await f.manager.delete(readerFileURL: record.url, statusLoader: { backing in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: backing)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return status
                })
            }
            do { try await deletion.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            f.realm.refresh()
            XCTAssertFalse(record.isDeleted)
            XCTAssertEqual(try self.journalGeneration(f, record: record), generation)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original bytes")
        }
    }

    func testCurrentFileDeletionAndRepeatedMissingDeleteKeepTruthfulJournals() async throws {
        try await withFixture { f in
            let url = f.library.appendingPathComponent("delete.txt")
            try self.write("original bytes", to: url)
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let initial = try self.journalGeneration(f, record: record)
            let package = ContentPackageFile()
            package.url = try XCTUnwrap(URL(string: "reader-file://file/load/local/delete.txt?entry=1"))
            package.packageContentFileID = record.compoundKey
            package.updateCompoundKey()
            try f.realm.write {
                f.realm.add(package)
                package.refreshChangeMetadata(explicitlyModified: true)
            }
            try await f.manager.delete(readerFileURL: backing)
            await f.manager.inventoryRefreshQueue?.waitForIdle()
            f.realm.refresh()
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(record.isDeleted)
            XCTAssertTrue(package.isDeleted)
            XCTAssertEqual(record.modifiedAt, package.modifiedAt)
            let committed = try self.journalGeneration(f, record: record)
            XCTAssertNotEqual(committed, initial)
            try await f.manager.delete(readerFileURL: backing)
            await f.manager.inventoryRefreshQueue?.waitForIdle()
            f.realm.refresh()
            XCTAssertEqual(try self.journalGeneration(f, record: record), committed)
        }
    }
}
''')
subprocess.run(['git','diff','--check'], check=True)
for name in (MANAGER, INITIALIZATION, LIBRARY):
    print(json.dumps({'path': name, 'blob': subprocess.check_output(['git','hash-object',name],text=True).strip()}))
