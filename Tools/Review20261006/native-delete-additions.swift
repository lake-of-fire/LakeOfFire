
// MARK: Original deletion admission (2026-10-06)
// Real manager, filesystem, Realm and mutation journal; status is the existing
// asynchronous seam. No production account or externally supplied file is used.
@MainActor
extension ReaderFileLibraryBoundaryTests {
    private func checkDeletionRealmReplacement(missing: Bool) async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            if !missing { try self.write("original bytes", to: payload) }
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let before = self.refreshStorageSnapshot(f.realm)
            var configuration = f.configuration
            configuration.inMemoryIdentifier = "delete-successor-" + UUID().uuidString
            BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
            let successorRealm = try await Realm(configuration: configuration, actor: MainActor.shared)
            let successor = try await self.seedRefreshRecord("successor", in: successorRealm)
            let successorBefore = self.refreshStorageSnapshot(successorRealm)
            let originalDrive = f.manager.localDrive
            do {
                try await f.manager.delete(readerFileURL: backing, statusLoader: { url in
                    let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    XCTAssertEqual(status, missing ? .fileMissing : .localOnly)
                    f.manager.historyRealmConfigurationOverride = configuration
                    f.manager.files = [successor]
                    return status
                })
                XCTFail("The original Realm must still own deletion before physical removal or tombstones")
            } catch ReaderFileDeleteError.removeFailed { }
            XCTAssertTrue(f.manager.localDrive === originalDrive)
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertEqual(self.refreshStorageSnapshot(successorRealm), successorBefore)
            XCTAssertEqual(f.manager.files?.map(\.compoundKey), [successor.compoundKey])
            XCTAssertFalse(record.isDeleted)
            if missing {
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: payload), Data("original bytes".utf8))
            }
        }
    }

    private func checkDeletionFailedInitialization(missing: Bool) async throws {
        let manager = ReaderFileManager(
            payloadStateProvider: { _ in .current },
            directoryContentsProvider: { _ in [] },
            cloudDriveFactory: { _ in throw ReaderFileManagerError.driveMissing },
            localDriveFactory: { throw ReaderFileManagerError.driveMissing }
        )
        try await withFixture(manager: manager) { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            if !missing { try self.write("original bytes", to: payload) }
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let before = self.refreshStorageSnapshot(f.realm)
            let originalDrive = manager.localDrive
            do {
                try await manager.delete(readerFileURL: backing, statusLoader: { url in
                    let status = try await manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                    XCTAssertEqual(status, missing ? .fileMissing : .localOnly)
                    do {
                        try await manager.initialize(ubiquityContainerIdentifier: "replacement-fails")
                        XCTFail("Injected replacement preparation must fail")
                    } catch ReaderFileManagerError.driveMissing { }
                    return status
                })
                XCTFail("A newer initialization revokes the original delete even when drives are unchanged")
            } catch ReaderFileDeleteError.removeFailed { }
            XCTAssertTrue(manager.localDrive === originalDrive)
            XCTAssertEqual(self.refreshStorageSnapshot(f.realm), before)
            XCTAssertEqual(manager.files?.map(\.compoundKey), [record.compoundKey])
            XCTAssertFalse(record.isDeleted)
            if missing {
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: payload), Data("original bytes".utf8))
            }
        }
    }

    func testDeleteRejectsRealmReplacementBeforeRemovingPayload() async throws {
        try await checkDeletionRealmReplacement(missing: false)
    }

    func testMissingDeleteRejectsRealmReplacementBeforeTombstoning() async throws {
        try await checkDeletionRealmReplacement(missing: true)
    }

    func testDeleteRejectsFailedNewInitializationBeforeRemovingPayload() async throws {
        try await checkDeletionFailedInitialization(missing: false)
    }

    func testMissingDeleteRejectsFailedNewInitializationBeforeTombstoning() async throws {
        try await checkDeletionFailedInitialization(missing: true)
    }

    func testAlreadyCancelledInitializationLeavesCurrentDeleteAdmitted() async throws {
        let manager = ReaderFileManager(
            payloadStateProvider: { _ in .current },
            cloudDriveFactory: { _ in
                XCTFail("A cancelled entrant must not invoke the cloud factory")
                throw ReaderFileManagerError.driveMissing
            },
            localDriveFactory: {
                XCTFail("A cancelled entrant must not invoke the local factory")
                throw ReaderFileManagerError.driveMissing
            }
        )
        try await withFixture(manager: manager) { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            try self.write("current bytes", to: payload)
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            let before = try self.journalGeneration(f, record: record)
            try await manager.delete(readerFileURL: backing, statusLoader: { url in
                let status = try await manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                let entrant = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await manager.initialize(ubiquityContainerIdentifier: "already-cancelled")
                }
                do { try await entrant.value; XCTFail("Expected cancelled entrant") }
                catch is CancellationError { }
                return status
            })
            f.realm.refresh()
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            XCTAssertTrue(record.isDeleted)
            XCTAssertNotEqual(try self.journalGeneration(f, record: record), before)
        }
    }

    func testLocalDeleteIgnoresReplacementOfUnselectedCloudDrive() async throws {
        try await withFixture { f in
            let payload = f.library.appendingPathComponent("delete.txt")
            try self.write("current bytes", to: payload)
            let cloudRoot = f.root.appendingPathComponent("unselected-cloud", isDirectory: true)
            let replacement = try await CloudDrive(storage: .localDirectory(rootURL: cloudRoot))
            let cloudPayload = cloudRoot.appendingPathComponent("delete.txt")
            try self.write("unrelated bytes", to: cloudPayload)
            let record = try self.indexedDeletionRecord(f)
            let backing = record.url
            try await f.manager.delete(readerFileURL: backing, statusLoader: { url in
                let status = try await f.manager.cloudDriveSyncStatus(forReaderBackingURL: url)
                f.manager.cloudDrive = replacement
                return status
            })
            f.realm.refresh()
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            XCTAssertTrue(record.isDeleted)
            XCTAssertEqual(try Data(contentsOf: cloudPayload), Data("unrelated bytes".utf8))
        }
    }
}
