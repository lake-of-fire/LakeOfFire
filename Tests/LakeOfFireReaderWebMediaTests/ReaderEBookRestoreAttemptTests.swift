import Foundation
import XCTest
@testable import LakeOfFireReader

final class ReaderEBookRestoreAttemptTests: XCTestCase {
    private func terminal(
        id: String?, savedID: String? = nil, locator: String = "none",
        terminal: String = "noTarget", geometry: Any? = nil, mode: String? = nil
    ) -> ReaderContentEbookInitialRestoreResult? {
        var payload: [String: Any] = [
            "requestedLocator": locator, "terminalState": terminal,
            "navigationOk": true, "restoreSatisfied": terminal == "satisfied",
            "handledFractionalCompletion": 0.125, "currentFractionalCompletion": 0.125,
        ]
        payload["loadRequestID"] = id
        payload["requestID"] = savedID
        payload["firstPageGeometry"] = geometry
        payload["positionMode"] = mode
        return ReaderContentEbookInitialRestoreResult(payload: payload)
    }

    private func request(_ id: String, cfi: String = "", fraction: Double? = nil) -> ReaderEBookRestoreRequest {
        .init(loadRequestID: id, contentURL: URL(string: "https://example.com/book.epub")!,
              cfi: cfi, fractionalCompletion: fraction,
              requestedLocator: !cfi.isEmpty ? "cfi" : (fraction != nil ? "fraction" : "none"))
    }

    func test_newerReceiptReservesBeforeOlderCallbackBegins() throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let newer = try XCTUnwrap(state.reserve(owner: "binding", sequence: 20))
        XCTAssertNil(state.reserve(owner: "binding", sequence: 19))
        XCTAssertNil(state.reserve(owner: "binding", sequence: 20))
        XCTAssertTrue(state.isCurrent(newer, owner: "binding"))
    }

    func test_delayedReadAndErrorCannotDispatchOrRetireSuccessor() throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let first = try XCTUnwrap(state.reserve(owner: "binding", sequence: 1))
        let second = try XCTUnwrap(state.reserve(owner: "binding", sequence: 2))
        XCTAssertFalse(state.dispatch(request(first, fraction: 0), owner: "binding"))
        XCTAssertFalse(state.settle(first, owner: "binding"))
        XCTAssertTrue(state.dispatch(request(second, fraction: 0), owner: "binding"))
        XCTAssertTrue(state.isCurrent(second, owner: "binding"))
    }

    func test_registeredDispatchCanReceiveFastTerminalAndSettleOnlyOnce() throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let id = try XCTUnwrap(state.reserve(owner: "binding", sequence: 1))
        let result = try XCTUnwrap(terminal(id: id))
        XCTAssertNil(state.capture(result: result, owner: "binding"))
        XCTAssertTrue(state.dispatch(request(id), owner: "binding"))
        XCTAssertNotNil(state.capture(result: result, owner: "binding"))
        XCTAssertNil(state.capture(result: result, owner: "binding"))
        XCTAssertTrue(state.settle(id, owner: "binding"))
        XCTAssertFalse(state.settle(id, owner: "binding"))
        XCTAssertNil(state.capture(result: result, owner: "binding"))
        XCTAssertNil(state.reserve(owner: "binding", sequence: 1))
    }

    func test_savedRequestCannotDowngradeOrAdoptDifferentRequestOrKind() throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let id = try XCTUnwrap(state.reserve(owner: "binding", sequence: 1))
        XCTAssertTrue(state.dispatch(request(id, fraction: 0), owner: "binding"))
        let malformed = [
            terminal(id: id),
            terminal(id: id, savedID: id, locator: "fraction", terminal: "noTarget"),
            terminal(id: "other", savedID: id, locator: "fraction", terminal: "satisfied"),
            terminal(id: nil, savedID: id, locator: "fraction", terminal: "satisfied"),
            terminal(id: id, savedID: "other", locator: "fraction", terminal: "satisfied"),
            terminal(id: id, savedID: id, locator: "cfi", terminal: "satisfied"),
        ]
        for result in malformed {
            XCTAssertNil(state.capture(result: try XCTUnwrap(result), owner: "binding"))
        }
        let valid = try XCTUnwrap(terminal(id: id, savedID: id, locator: "fraction", terminal: "satisfied"))
        XCTAssertNil(state.capture(result: valid, owner: "replaced binding"))
        XCTAssertEqual(state.capture(result: valid, owner: "binding")?.fractionalCompletion, 0)
    }

    func test_absentRequestRequiresItsExactIDAndRetirementRejectsCompletion() throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let id = try XCTUnwrap(state.reserve(owner: "binding", sequence: 1))
        XCTAssertTrue(state.dispatch(request(id), owner: "binding"))
        XCTAssertNil(state.capture(result: try XCTUnwrap(terminal(id: "old")), owner: "binding"))
        XCTAssertNil(state.capture(result: try XCTUnwrap(terminal(id: id, savedID: id)), owner: "binding"))
        XCTAssertTrue(state.settle(id, owner: "binding"))
        XCTAssertNil(state.capture(result: try XCTUnwrap(terminal(id: id)), owner: "binding"))
    }

    func test_bindingScopeRetainsOrderAcrossDifferentURLTargets() throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let id = try XCTUnwrap(state.reserve(owner: "binding-new-url", sequence: 8))
        let rejected = state.reserve(owner: "binding-old-url", sequence: 7, sharesReceiptOrder: { _, _ in true })
        XCTAssertNil(rejected)
        XCTAssertTrue(state.isCurrent(id, owner: "binding-new-url"))
        XCTAssertNotNil(state.reserve(owner: "replacement-binding", sequence: 1))
    }

    func test_originalLocatorIsFrozenAtDispatchAndFailedTerminalCanSettle() throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let id = try XCTUnwrap(state.reserve(owner: "binding", sequence: 1))
        let original = request(id, cfi: "epubcfi(/6/2)", fraction: 0.7)
        XCTAssertTrue(state.dispatch(original, owner: "binding"))
        XCTAssertFalse(state.dispatch(request(id, fraction: 0), owner: "binding"))
        let failed = try XCTUnwrap(terminal(id: id, savedID: id, locator: "cfi", terminal: "failed"))
        XCTAssertEqual(state.capture(result: failed, owner: "binding"), original)
        XCTAssertTrue(state.settle(id, owner: "binding"))
    }

    func test_nonStringLoadIdentifierDecodesAsAbsentAndCannotClaimCurrentRequest() throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let identifier = try XCTUnwrap(state.reserve(owner: "binding", sequence: 1))
        XCTAssertTrue(state.dispatch(request(identifier), owner: "binding"))
        let result = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: [
            "loadRequestID": 17, "requestedLocator": "none", "terminalState": "noTarget",
            "navigationOk": true, "restoreSatisfied": false,
        ]))
        XCTAssertNil(result.loadRequestID)
        XCTAssertNil(state.capture(result: result, owner: "binding"))
        XCTAssertTrue(state.isCurrent(identifier, owner: "binding"))
    }

    func test_geometryStrictlyDecodesNumericEndpointsAndKeepsActualCompletion() throws {
        let geometry: [String: Any] = [
            "kind": "paginated-first-page-v1", "targetSectionIndex": 3, "sectionIndex": 3,
            "targetAnchor": 0, "fractionInSection": 0, "pageFraction": 1,
        ]
        let result = try XCTUnwrap(terminal(id: "load", geometry: geometry, mode: "paginated"))
        XCTAssertTrue(try XCTUnwrap(result.firstPageGeometry).matchesFirstPage)
        XCTAssertEqual(result.handledFractionalCompletion, 0.125)
        XCTAssertEqual(result.currentFractionalCompletion, 0.125)
        for (key, invalid) in [
            ("targetAnchor", NSNumber(value: false)), ("sectionIndex", NSNumber(value: true)),
            ("sectionIndex", NSNumber(value: 1.5)), ("sectionIndex", NSNumber(value: -1)),
            ("sectionIndex", NSNumber(value: 9_007_199_254_740_992.0)),
            ("pageFraction", NSNumber(value: 0)), ("pageFraction", NSNumber(value: 1.1)),
            ("pageFraction", NSNumber(value: Double.infinity)),
        ] {
            var malformed = geometry
            malformed[key] = invalid
            XCTAssertNil(terminal(id: "load", geometry: malformed, mode: "paginated"), key)
        }
        XCTAssertNil(terminal(id: "load", geometry: [:], mode: "paginated"))
        XCTAssertNil(terminal(id: "load", geometry: geometry, mode: "unknown"))
    }
}

@MainActor
final class ReaderEBookOrderedInitializationTests: XCTestCase {
    private final class Gate {
        let entered = XCTestExpectation(description: "Saved read suspended")
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    func test_delayedOriginalReadCannotDispatchAfterNewerInitialization() async throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let first = try XCTUnwrap(state.reserve(owner: "binding", sequence: 1))
        let gate = Gate()
        defer { gate.release() }
        var publications = [String]()
        let firstTask = Task { @MainActor in
            do {
                try await ReaderEBookInitialization.perform(
                    receiptBinding: "binding",
                    currentBinding: { state.isCurrent(first, owner: "binding") ? "binding" : nil },
                    registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in () },
                    restore: { _ in await gate.suspend(); return "saved first" },
                    publish: { _, _, _ in publications.append(first) }
                )
                return false
            } catch is CancellationError {
                _ = state.settle(first, owner: "binding")
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }
        let entered = await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(entered, .completed)
        let second = try XCTUnwrap(state.reserve(owner: "binding", sequence: 2))
        try await ReaderEBookInitialization.perform(
            receiptBinding: "binding",
            currentBinding: { state.isCurrent(second, owner: "binding") ? "binding" : nil },
            registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in () },
            restore: { _ in "saved second" }, publish: { _, _, _ in publications.append(second) }
        )
        gate.release()
        let firstCancelled = await firstTask.value
        XCTAssertTrue(firstCancelled)
        XCTAssertEqual(publications, [second])
        XCTAssertTrue(state.isCurrent(second, owner: "binding"))
    }

    func test_suspendedReadWithRetainedOwnerDispatchesAndConsumesOriginalOnce() async throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let identifier = try XCTUnwrap(state.reserve(owner: "retained binding", sequence: 1))
        let gate = Gate()
        defer { gate.release() }
        let original = ReaderEBookRestoreRequest(
            loadRequestID: identifier, contentURL: URL(string: "https://example.com/book.epub")!,
            cfi: "", fractionalCompletion: 0, requestedLocator: "fraction"
        )
        var registrations = 0
        var acknowledgements = 0
        var dispatches = 0
        let initialization = Task { @MainActor in
            try await ReaderEBookInitialization.perform(
                receiptBinding: "retained binding",
                currentBinding: {
                    state.isCurrent(identifier, owner: "retained binding") ? "retained binding" : nil
                },
                registerFrame: { _ in registrations += 1 },
                acknowledge: { _ in acknowledgements += 1 },
                prepare: { _ in () },
                restore: { _ in await gate.suspend(); return original },
                publish: { _, _, request in
                    XCTAssertTrue(state.dispatch(request, owner: "retained binding"))
                    dispatches += 1
                }
            )
        }
        let entered = await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(entered, .completed)
        // A suspended read alone does not revoke its binding or attempt. This
        // exercises retained-owner callbacks, not a simulated SwiftUI lifecycle.
        XCTAssertTrue(state.isCurrent(identifier, owner: "retained binding"))
        gate.release()
        try await initialization.value
        let result = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: [
            "loadRequestID": identifier, "requestID": identifier, "requestedLocator": "fraction",
            "terminalState": "satisfied", "navigationOk": true, "restoreSatisfied": true,
        ]))
        XCTAssertEqual(state.capture(result: result, owner: "retained binding"), original)
        XCTAssertNil(state.capture(result: result, owner: "retained binding"))
        XCTAssertTrue(state.settle(identifier, owner: "retained binding"))
        XCTAssertFalse(state.settle(identifier, owner: "retained binding"))
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(dispatches, 1)
    }

    func test_bindingReplacementRejectsSuspendedOriginalAndPreservesSuccessorDispatch() async throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        var currentBinding = "original binding"
        let originalID = try XCTUnwrap(state.reserve(owner: currentBinding, sequence: 5))
        let gate = Gate()
        defer { gate.release() }
        var dispatches = [String]()
        let original = Task { @MainActor in
            do {
                try await ReaderEBookInitialization.perform(
                    receiptBinding: "original binding",
                    currentBinding: {
                        state.isCurrent(originalID, owner: "original binding") ? currentBinding : nil
                    },
                    registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in () },
                    restore: { _ in await gate.suspend(); return () },
                    publish: { _, _, _ in dispatches.append(originalID) }
                )
                return false
            } catch is CancellationError {
                // Original attempt cleanup has no authority over the replacement.
                XCTAssertFalse(state.settle(originalID, owner: "original binding"))
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }
        let entered = await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(entered, .completed)
        currentBinding = "replacement binding"
        let successorID = try XCTUnwrap(state.reserve(owner: currentBinding, sequence: 1))
        let successor = ReaderEBookRestoreRequest(
            loadRequestID: successorID, contentURL: URL(string: "https://example.com/book.epub")!,
            cfi: "", fractionalCompletion: nil, requestedLocator: "none"
        )
        try await ReaderEBookInitialization.perform(
            receiptBinding: "replacement binding",
            currentBinding: {
                state.isCurrent(successorID, owner: "replacement binding") ? currentBinding : nil
            },
            registerFrame: { _ in }, acknowledge: { _ in }, prepare: { _ in () },
            restore: { _ in successor },
            publish: { _, _, request in
                XCTAssertTrue(state.dispatch(request, owner: "replacement binding"))
                dispatches.append(successorID)
            }
        )
        gate.release()
        let wasRejected = await original.value
        XCTAssertTrue(wasRejected)
        XCTAssertEqual(dispatches, [successorID])
        XCTAssertTrue(state.isCurrent(successorID, owner: "replacement binding"))
        let terminal = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: [
            "loadRequestID": successorID, "requestedLocator": "none", "terminalState": "noTarget",
            "navigationOk": true, "restoreSatisfied": false,
        ]))
        XCTAssertEqual(state.capture(result: terminal, owner: "replacement binding"), successor)
        XCTAssertTrue(state.settle(successorID, owner: "replacement binding"))
        XCTAssertNil(state.reserve(owner: "replacement binding", sequence: 1))
    }

    func test_olderReceiptIsRejectedBeforeRegistrationOrAcknowledgement() async throws {
        var state = ReaderEBookRestoreAttemptState<String>()
        let newer = try XCTUnwrap(state.reserve(owner: "binding", sequence: 2))
        var effects = 0
        if let older = state.reserve(owner: "binding", sequence: 1) {
            try await ReaderEBookInitialization.perform(
                receiptBinding: "binding",
                currentBinding: { state.isCurrent(older, owner: "binding") ? "binding" : nil },
                registerFrame: { _ in effects += 1 }, acknowledge: { _ in effects += 1 },
                prepare: { _ in () }, restore: { _ in () }, publish: { _, _, _ in effects += 1 }
            )
        }
        XCTAssertEqual(effects, 0)
        XCTAssertTrue(state.isCurrent(newer, owner: "binding"))
    }
}
