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

private enum ReaderFileInitializationTestError: Error {
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
}
