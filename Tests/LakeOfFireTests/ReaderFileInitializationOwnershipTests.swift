import Foundation
import XCTest
@testable import LakeOfFireContent

private actor ReaderInitializationGate {
    private var entered = false
    private var released = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func block() async {
        entered = true
        entrants.forEach { $0.resume() }
        entrants.removeAll()
        if !released { await withCheckedContinuation { releases.append($0) } }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entrants.append($0) } }
    }

    func release() {
        released = true
        releases.forEach { $0.resume() }
        releases.removeAll()
    }
}

private enum ReaderInitializationTestError: Error {
    case unavailableCloud
    case unavailableLocal
}

@MainActor
final class ReaderFileInitializationOwnershipTests: XCTestCase {
    private func requireCancellation(_ task: Task<Void, Error>) async {
        do {
            try await task.value
            XCTFail("Expected the preparation to lose publication ownership")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }

    func testAlreadyCancelledInitializationDoesNotInvokeFactories() async {
        var calls = 0
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { URL(fileURLWithPath: "/unused") },
            cloudDriveFactory: { _ in
                calls += 1
                throw ReaderInitializationTestError.unavailableCloud
            }, localDriveFactory: {
                calls += 1
                throw ReaderInitializationTestError.unavailableLocal
            })
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await manager.initialize(ubiquityContainerIdentifier: "cancelled")
        }
        await requireCancellation(task)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(manager.ubiquityContainerIdentifier)
    }

    func testCancellationDuringCloudPreparationPreservesInstalledIdentifier() async {
        let gate = ReaderInitializationGate()
        var localCalls = 0
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { URL(fileURLWithPath: "/unused") },
            cloudDriveFactory: { _ in
                await gate.block()
                // A provider that reports an ordinary failure after cancellation
                // must still lose admission before the local fallback begins.
                throw ReaderInitializationTestError.unavailableCloud
            }, localDriveFactory: {
                localCalls += 1
                throw ReaderInitializationTestError.unavailableLocal
            })
        manager.ubiquityContainerIdentifier = "installed"
        let task = Task { @MainActor in
            try await manager.initialize(ubiquityContainerIdentifier: "cancelled")
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.release()
        await requireCancellation(task)
        XCTAssertEqual(localCalls, 0)
        XCTAssertEqual(manager.ubiquityContainerIdentifier, "installed")
        XCTAssertNil(manager.cloudDrive)
        XCTAssertNil(manager.localDrive)
    }

    func testLocalPreparationFailurePreservesInstalledIdentifier() async {
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { URL(fileURLWithPath: "/unused") },
            cloudDriveFactory: { _ in throw ReaderInitializationTestError.unavailableCloud },
            localDriveFactory: { throw ReaderInitializationTestError.unavailableLocal })
        manager.ubiquityContainerIdentifier = "installed"
        do {
            try await manager.initialize(ubiquityContainerIdentifier: "failed")
            XCTFail("Local failure must be returned to the caller")
        } catch ReaderInitializationTestError.unavailableLocal {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(manager.ubiquityContainerIdentifier, "installed")
        XCTAssertNil(manager.cloudDrive)
        XCTAssertNil(manager.localDrive)
    }

    func testFailedNewerAttemptCannotReadmitOlderCloudPreparation() async {
        let gate = ReaderInitializationGate()
        var localCalls = 0
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { URL(fileURLWithPath: "/unused") },
            cloudDriveFactory: { identifier in
                if identifier == "older" { await gate.block() }
                throw ReaderInitializationTestError.unavailableCloud
            }, localDriveFactory: {
                localCalls += 1
                throw ReaderInitializationTestError.unavailableLocal
            })
        manager.ubiquityContainerIdentifier = "installed"
        let original = Task { @MainActor in
            try await manager.initialize(ubiquityContainerIdentifier: "older")
        }
        await gate.waitForEntry()
        do {
            try await manager.initialize(ubiquityContainerIdentifier: "newer")
            XCTFail("Expected the local factory to fail")
        } catch ReaderInitializationTestError.unavailableLocal {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await gate.release()
        await requireCancellation(original)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(manager.ubiquityContainerIdentifier, "installed")
    }
}
