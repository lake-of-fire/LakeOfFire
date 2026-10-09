import Foundation
import XCTest
@testable import LakeOfFireReader

@MainActor
private final class InitializationPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var reached = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            reached = true
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ReaderEBookInitializationTests: XCTestCase {
    private struct Binding: Equatable, Sendable {
        let window: Int
        let document: Int
        static let original = Self(window: 1, document: 1)
        static let replacement = Self(window: 1, document: 2)
        static let otherWindow = Self(window: 2, document: 1)
    }

    private enum Stage: Int, CaseIterable {
        case register, acknowledge, prepare, restore, publish
    }

    private enum InjectedError: Error { case failed }

    @MainActor
    private final class Probe {
        var current: Binding? = .original
        var effects = [Stage]()
        var observed = [Binding]()
        var inject: ((Stage) throws -> Void)?
        var pause: (Stage, InitializationPause)?
        var prepared: String? = "native-session"
        var fraction: Double? = 0
        var publication: (String?, Double?)?

        private func record(_ stage: Stage, _ binding: Binding) throws {
            effects.append(stage)
            observed.append(binding)
            try inject?(stage)
        }

        private func recordAsync(_ stage: Stage, _ binding: Binding) async throws {
            try record(stage, binding)
            if let (pausedStage, gate) = pause, stage == pausedStage {
                await gate.wait()
            }
        }

        func run(receipt: Binding? = .original) async throws {
            try await ReaderEBookInitialization.perform(
                receiptBinding: receipt,
                currentBinding: { self.current },
                registerFrame: { try self.record(.register, $0) },
                acknowledge: { try await self.recordAsync(.acknowledge, $0) },
                prepare: {
                    try await self.recordAsync(.prepare, $0)
                    return self.prepared
                },
                restore: {
                    try await self.recordAsync(.restore, $0)
                    return self.fraction
                },
                publish: {
                    try await self.recordAsync(.publish, $0)
                    self.publication = ($1, $2)
                }
            )
        }
    }

    private func rejects(_ probe: Probe, receipt: Binding? = .original,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await probe.run(receipt: receipt)
            XCTFail("Stale initialization completed", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected rejection: \(error)", file: file, line: line)
        }
        XCTAssertNil(probe.publication, file: file, line: line)
    }

    func testExactReceiptReachesEveryStageAndKeepsSavedZero() async throws {
        let probe = Probe()
        try await probe.run()
        XCTAssertEqual(probe.effects, Stage.allCases)
        XCTAssertEqual(probe.observed, Array(repeating: .original, count: 5))
        XCTAssertEqual(probe.publication?.0, "native-session")
        XCTAssertEqual(probe.publication?.1, 0)
    }

    func testMissingReceiptCannotBorrowCurrentDocument() async {
        let probe = Probe()
        await rejects(probe, receipt: nil)
        XCTAssertTrue(probe.effects.isEmpty)
    }

    func testUnboundCallerCannotRegisterAFrame() async {
        let probe = Probe()
        probe.current = nil
        await rejects(probe)
        XCTAssertTrue(probe.effects.isEmpty)
    }

    func testSameURLReplacementBeforeDeliveryCannotRegisterOrAcknowledge() async {
        let probe = Probe()
        probe.current = .replacement
        await rejects(probe)
        XCTAssertTrue(probe.effects.isEmpty)
    }

    func testAnotherWindowAtSameURLCannotUseTheReceipt() async {
        let probe = Probe()
        probe.current = .otherWindow
        await rejects(probe)
        XCTAssertTrue(probe.effects.isEmpty)
    }

    func testRegistrationReentryStopsBeforeAcknowledgment() async {
        let probe = Probe()
        probe.inject = { if $0 == .register { probe.current = .replacement } }
        await rejects(probe)
        XCTAssertEqual(probe.effects, [.register])
    }

    func testAcknowledgmentReentryCannotRecaptureReplacementForPreparation() async {
        let probe = Probe()
        probe.inject = { if $0 == .acknowledge { probe.current = .replacement } }
        await rejects(probe)
        XCTAssertEqual(probe.effects, [.register, .acknowledge])
    }

    func testUnbindingDuringAcknowledgmentCannotStartPreparation() async {
        let probe = Probe()
        probe.inject = { if $0 == .acknowledge { probe.current = nil } }
        await rejects(probe)
        XCTAssertEqual(probe.effects, [.register, .acknowledge])
    }

    func testPreparationReentryCannotReadReplacementPosition() async {
        let probe = Probe()
        probe.inject = { if $0 == .prepare { probe.current = .replacement } }
        await rejects(probe)
        XCTAssertEqual(probe.effects, [.register, .acknowledge, .prepare])
    }

    func testRestoreReentryCannotPublishToReplacement() async {
        let probe = Probe()
        probe.inject = { if $0 == .restore { probe.current = .replacement } }
        await rejects(probe)
        XCTAssertEqual(probe.effects, [.register, .acknowledge, .prepare, .restore])
    }

    func testEveryStageErrorStopsWithoutFallback() async {
        for failure in Stage.allCases {
            let probe = Probe()
            probe.inject = { if $0 == failure { throw InjectedError.failed } }
            do {
                try await probe.run()
                XCTFail("Stage error was swallowed")
            } catch InjectedError.failed {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(probe.effects, Array(Stage.allCases.prefix(failure.rawValue + 1)))
            XCTAssertNil(probe.publication)
        }
    }

    func testNoPreparerStillRequiresExactBindingAndAllowsNoSavedState() async throws {
        let probe = Probe()
        probe.prepared = nil
        probe.fraction = nil
        try await probe.run()
        XCTAssertEqual(probe.effects, Stage.allCases)
        XCTAssertNotNil(probe.publication)
        XCTAssertNil(probe.publication?.0)
        XCTAssertNil(probe.publication?.1)
    }

    func testAlreadyCanceledCallerHasNoSideEffects() async {
        let probe = Probe()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await rejects(probe)
        }
        await task.value
        XCTAssertTrue(probe.effects.isEmpty)
    }

    func testCancellationDuringAcknowledgmentStopsPreparation() async {
        let probe = Probe()
        probe.inject = { stage in
            if stage == .acknowledge { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let task = Task { @MainActor in await rejects(probe) }
        await task.value
        XCTAssertEqual(probe.effects, [.register, .acknowledge])
    }

    func testSuspendedAcknowledgmentCannotAdoptSameURLReplacement() async {
        let probe = Probe(), gate = InitializationPause()
        probe.pause = (.acknowledge, gate)
        let task = Task { @MainActor in await rejects(probe) }
        await gate.waitUntilReached()
        XCTAssertEqual(probe.effects, [.register, .acknowledge])
        probe.current = .replacement
        gate.resume()
        await task.value
        XCTAssertEqual(probe.effects, [.register, .acknowledge])
    }

    func testUncooperativePreparationCannotReturnAfterCallerCancellation() async {
        let probe = Probe(), gate = InitializationPause()
        probe.pause = (.prepare, gate)
        let task = Task { @MainActor in await rejects(probe) }
        await gate.waitUntilReached()
        task.cancel()
        gate.resume()
        await task.value
        XCTAssertEqual(probe.effects, [.register, .acknowledge, .prepare])
    }

    func testRestoreSuspensionCannotPublishIntoAnotherWindow() async {
        let probe = Probe(), gate = InitializationPause()
        probe.pause = (.restore, gate)
        let task = Task { @MainActor in await rejects(probe) }
        await gate.waitUntilReached()
        probe.current = .otherWindow
        gate.resume()
        await task.value
        XCTAssertEqual(probe.effects, [.register, .acknowledge, .prepare, .restore])
    }

    func testFreshReplacementReceiptSucceedsAfterStaleOneIsRejected() async throws {
        let stale = Probe(), gate = InitializationPause()
        stale.pause = (.acknowledge, gate)
        let task = Task { @MainActor in await rejects(stale) }
        await gate.waitUntilReached()
        stale.current = .replacement
        let fresh = Probe()
        fresh.current = .replacement
        fresh.fraction = 0.75
        try await fresh.run(receipt: .replacement)
        gate.resume()
        await task.value
        XCTAssertEqual(fresh.effects, Stage.allCases)
        XCTAssertEqual(fresh.observed, Array(repeating: .replacement, count: 5))
        XCTAssertEqual(fresh.publication?.1, 0.75)
        XCTAssertNil(stale.publication)
    }
}
