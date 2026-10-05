import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import Foundation
import XCTest
@testable import LakeOfFireContent
import SwiftCloudDrive

private actor ReaderFileInitializationGate {
    private var entered = false
    private var released = false
    private var enteredWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func blockUntilReleased() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private enum ReaderFileInitializationTestError: Swift.Error {
    case unexpectedFactoryContinuation
    case localFactoryShouldNotRun
}

final class ReaderFileInitializationTests: XCTestCase {
    @MainActor
    func testCancelledCloudDrivePreparationDoesNotCommitPartialManagerState()
    async throws {
        let gate = ReaderFileInitializationGate()
        let manager = ReaderFileManager(
            payloadStateProvider: { _ in .current },
            directoryContentsProvider: { _ in [] },
            cloudDriveFactory: { _ in
                await gate.blockUntilReleased()
                try Task.checkCancellation()
                throw ReaderFileInitializationTestError
                    .unexpectedFactoryContinuation
            },
            localDriveFactory: {
                XCTFail("Local drive construction must not follow cancellation")
                throw ReaderFileInitializationTestError.localFactoryShouldNotRun
            }
        )

        let initialization = Task { @MainActor in
            try await manager.initialize(
                ubiquityContainerIdentifier: "iCloud.cancelled-initialization"
            )
        }
        await gate.waitUntilEntered()
        initialization.cancel()
        await gate.release()

        do {
            try await initialization.value
            XCTFail("Expected initialization cancellation")
        } catch is CancellationError {
        }

        XCTAssertNil(manager.ubiquityContainerIdentifier)
        XCTAssertNil(manager.cloudDrive)
        XCTAssertNil(manager.localDrive)
    }

    @MainActor
    func testAlreadyCancelledInventoryRefreshThrowsInsteadOfReportingSuccess()
    async throws {
        let manager = ReaderFileManager()

        let refresh = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await manager.refreshAllFilesMetadata()
        }

        do {
            try await refresh.value
            XCTFail("Cancelled refresh must not report successful completion")
        } catch is CancellationError {
        }
    }

}


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
