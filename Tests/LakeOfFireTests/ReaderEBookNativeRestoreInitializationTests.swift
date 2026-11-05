import Foundation
import XCTest
import LakeOfFireContent
@testable import LakeOfFireReader

private enum RestoreReadFailure: Error { case unavailable }
private enum RestoreBindingFixture {
    @TaskLocal static var value: Int?
}

final class ReaderEBookNativeRestoreInitializationTests: XCTestCase {
    @MainActor
    func testBoundInitializationPublishesNumericZeroAndExactBinding() async throws {
        var events: [String] = []
        try await ReaderEBookInitialization.perform(
            receiptBinding: 17, currentBinding: { 17 },
            registerFrame: { _ in events.append("register") },
            acknowledge: { _ in events.append("acknowledge") },
            prepare: { _ in "owned-package" },
            restore: { binding in
                try await RestoreBindingFixture.$value.withValue(binding) {
                    try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                        XCTAssertEqual(RestoreBindingFixture.value, 17)
                        await Task.yield()
                        XCTAssertEqual(RestoreBindingFixture.value, 17)
                        return .init(cfi: "", fractionalCompletion: 0)
                    }
                }
            },
            publish: { binding, package, request in
                XCTAssertEqual(binding, 17)
                XCTAssertEqual(package, "owned-package")
                XCTAssertEqual(request?.fractionalCompletion, 0)
                XCTAssertEqual(request?.javaScriptArgument["requestedLocator"] as? String, "fraction")
                events.append("publish")
            }
        )
        XCTAssertEqual(events, ["register", "acknowledge", "publish"])
        XCTAssertNil(RestoreBindingFixture.value)
    }

    @MainActor
    func testInvalidStoredFractionCannotReachFinalPublication() async {
        var events: [String] = []
        do {
            try await ReaderEBookInitialization.perform(
                receiptBinding: 1, currentBinding: { 1 },
                registerFrame: { _ in events.append("register") },
                acknowledge: { _ in events.append("acknowledge") },
                prepare: { _ in events.append("prepare") },
                restore: { _ in
                    try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                        .init(cfi: "epubcfi(/6/4!)", fractionalCompletion: .infinity)
                    }
                },
                publish: { _, _, _ in events.append("publish") }
            )
            XCTFail("Expected invalid saved-position error")
        } catch { XCTAssertEqual(error as? ReaderEBookInitialRestoreError, .invalidFraction) }
        XCTAssertEqual(events, ["register", "acknowledge", "prepare"])
    }

    @MainActor
    func testUnavailableReadIsNotDefaultOpening() async {
        var published = false
        do {
            try await ReaderEBookInitialization.perform(
                receiptBinding: 1, currentBinding: { 1 },
                registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in },
                restore: { _ in
                    try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                        throw RestoreReadFailure.unavailable
                    }
                }, publish: { _, _, _ in published = true }
            )
            XCTFail("Expected provider error")
        } catch { XCTAssertTrue(error is RestoreReadFailure) }
        XCTAssertFalse(published)
    }

    @MainActor
    func testGenuinelyAbsentPositionStillPublishesNoTarget() async throws {
        var published = false
        try await ReaderEBookInitialization.perform(
            receiptBinding: 1, currentBinding: { 1 },
            registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in },
            restore: { _ in try await ReaderEBookInitialRestoreBridgeRequest.prepare { nil } },
            publish: { _, _, request in XCTAssertNil(request); published = true }
        )
        XCTAssertTrue(published)
    }

    @MainActor
    func testCancelledNilProviderCannotPublishNoTarget() async {
        let rejected = await Task { @MainActor in
            var published = false
            do {
                try await ReaderEBookInitialization.perform(
                    receiptBinding: 1, currentBinding: { 1 },
                    registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in },
                    restore: { _ in
                        try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                            withUnsafeCurrentTask { $0?.cancel() }
                            return nil
                        }
                    }, publish: { _, _, _ in published = true }
                )
                return false
            } catch is CancellationError { return !published }
            catch { return false }
        }.value
        XCTAssertTrue(rejected)
    }

    @MainActor
    func testReplacementDuringReadRejectsOldZeroButFreshBindingCanRestore() async throws {
        var currentBinding = 1
        var published: [Int] = []
        do {
            try await ReaderEBookInitialization.perform(
                receiptBinding: 1, currentBinding: { currentBinding },
                registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in },
                restore: { _ in
                    try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                        await Task.yield()
                        currentBinding = 2
                        return .init(cfi: "", fractionalCompletion: 0)
                    }
                }, publish: { binding, _, _ in published.append(binding) }
            )
            XCTFail("Old receipt must not acquire replacement document")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(published.isEmpty)
        try await ReaderEBookInitialization.perform(
            receiptBinding: 2, currentBinding: { currentBinding },
            registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in },
            restore: { _ in
                try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                    .init(cfi: "", fractionalCompletion: 0)
                }
            }, publish: { binding, _, request in
                XCTAssertEqual(request?.fractionalCompletion, 0)
                published.append(binding)
            }
        )
        XCTAssertEqual(published, [2])
    }
}
