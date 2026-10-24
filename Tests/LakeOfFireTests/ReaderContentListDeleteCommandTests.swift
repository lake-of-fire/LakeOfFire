import Foundation
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

@objc(LakeOfFireTestsUpstreamDeleteCommandContent)
private final class UpstreamDeleteCommandContent: Bookmark {
    var deleteCalls = 0
    var deletion: (@MainActor () async throws -> Void)?
    override var deleteActionTitle: String { "Delete" }

    override class func shouldIncludeInDefaultSchema() -> Bool { false }

    @MainActor
    override func delete() async throws {
        deleteCalls += 1
        try await deletion?()
    }
}

@MainActor
private final class DeleteDialogHostState {
    var isActive = true
}

private actor DeleteCommandSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let pendingObservers = observers
            self.observers.removeAll()
            for observer in pendingObservers { observer.resume() }
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ReaderContentListDeleteCommandTests: XCTestCase {
    private func presentation(_ model: ReaderContentListModalsModel) throws -> ReaderContentListDeletePresentation {
        try XCTUnwrap(model.deleteDialogBinding(isActive: .constant(true)).wrappedValue)
    }

    func testDeleteConfirmationCancelPerformsZeroDeletes() throws {
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        try presentation(model).dismiss()
        XCTAssertEqual(item.deleteCalls, 0)
        XCTAssertNil(model.deleteDialog)
    }

    func testDeleteConfirmationCommandDeletesExactlyOnce() async throws {
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let task = try XCTUnwrap(presentation(model).confirm?())
        await task.value
        XCTAssertEqual(item.deleteCalls, 1)
        XCTAssertNil(model.deleteDialog)
    }

    func testDeleteConfirmationCommandRetainsError() async throws {
        let item = UpstreamDeleteCommandContent()
        item.deletion = { throw ReaderFileDeleteError.blockedCloudOnly }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let task = try XCTUnwrap(presentation(model).confirm?())
        await task.value
        XCTAssertEqual(item.deleteCalls, 1)
        guard case .error? = model.deleteDialog else {
            return XCTFail("The command error must remain available to the alert presenter")
        }
    }

    func testOlderDeleteCompletionDoesNotClearNewerConfirmation() async throws {
        try await checkOlderDeletePreservesNewerConfirmation(sameItem: false, fails: false)
    }

    func testConfirmedCommandRetainsErrorAfterAlertBindingDismissal() async throws {
        let item = UpstreamDeleteCommandContent()
        item.deletion = { throw ReaderFileDeleteError.blockedCloudOnly }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let generation = model.deleteDialogGeneration
        let binding = model.deleteDialogBinding(isActive: .constant(true))
        let displayed = try XCTUnwrap(binding.wrappedValue)
        // SwiftUI dismisses the alert through its binding when a button is
        // tapped; this is not a new user request or an explicit cancellation.
        binding.wrappedValue = nil
        XCTAssertEqual(model.deleteDialogGeneration, generation)
        let task = try XCTUnwrap(displayed.confirm?())
        await task.value
        XCTAssertEqual(item.deleteCalls, 1)
        guard case .error? = model.deleteDialog else {
            return XCTFail("Alert dismissal must not suppress the confirmed command's error")
        }
    }

    func testOlderDeleteCompletionDoesNotClearNewerSameItemConfirmation() async throws {
        try await checkOlderDeletePreservesNewerConfirmation(sameItem: true, fails: false)
    }

    func testOlderDeleteErrorDoesNotReplaceNewerConfirmation() async throws {
        try await checkOlderDeletePreservesNewerConfirmation(sameItem: false, fails: true)
    }

    func testOlderDeleteErrorDoesNotReplaceNewerSameItemConfirmation() async throws {
        try await checkOlderDeletePreservesNewerConfirmation(sameItem: true, fails: true)
    }

    private func checkOlderDeletePreservesNewerConfirmation(sameItem: Bool, fails: Bool) async throws {
        let oldItem = UpstreamDeleteCommandContent()
        oldItem.compoundKey = "old"
        let newItem = sameItem ? oldItem : UpstreamDeleteCommandContent()
        if !sameItem { newItem.compoundKey = "new" }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [oldItem])
        let oldGeneration = model.deleteDialogGeneration
        let displayed = try presentation(model)
        defer { oldItem.deletion = nil }
        oldItem.deletion = {
            // Resume only after the replacement request is installed; this
            // does not depend on a delay or a particular Task.yield schedule.
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    model.presentDeleteConfirmation(for: [newItem])
                    continuation.resume()
                }
            }
            if fails { throw ReaderFileDeleteError.blockedCloudOnly }
        }
        let task = try XCTUnwrap(displayed.confirm?())
        await task.value
        XCTAssertEqual(oldItem.deleteCalls, 1)
        XCTAssertEqual(newItem.deleteCalls, sameItem ? 1 : 0)
        XCTAssertNotEqual(model.deleteDialogGeneration, oldGeneration)
        guard case .confirm(let items, _, _, _)? = model.deleteDialog else {
            return XCTFail("An older completion must preserve the newer confirmation")
        }
        XCTAssertEqual(items.map(\.compoundKey), [newItem.compoundKey])
    }

    func testConfirmedCommandCapturedBeforeTaskStartsPreservesNewerRequest() async throws {
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let displayed = try presentation(model)
        let task = try XCTUnwrap(displayed.confirm?())
        model.presentDeleteConfirmation(for: [item])
        let newerGeneration = model.deleteDialogGeneration
        await task.value
        XCTAssertEqual(item.deleteCalls, 1, "Presentation fencing must not revoke confirmed deletion")
        XCTAssertEqual(model.deleteDialogGeneration, newerGeneration)
        guard case .confirm? = model.deleteDialog else {
            return XCTFail("The request made before task entry must remain presented")
        }
    }

    func testRetainedCancelAndUnacceptedConfirmationCannotAffectReplacement() throws {
        for sameItem in [false, true] {
            let oldItem = UpstreamDeleteCommandContent()
            let newItem = sameItem ? oldItem : UpstreamDeleteCommandContent()
            let model = ReaderContentListModalsModel()
            model.presentDeleteConfirmation(for: [oldItem])
            let oldPresentation = try presentation(model)
            model.presentDeleteConfirmation(for: [newItem])
            let newPresentation = try presentation(model)

            oldPresentation.dismiss()
            XCTAssertNil(oldPresentation.confirm?())

            XCTAssertEqual(model.deleteDialogGeneration, newPresentation.id)
            XCTAssertEqual(try presentation(model).id, newPresentation.id)
            XCTAssertNotEqual(oldPresentation.id, newPresentation.id)
            XCTAssertEqual(oldItem.deleteCalls, 0)
            XCTAssertEqual(newItem.deleteCalls, 0)
        }
    }

    func testRetainedErrorOKCannotDismissNewConfirmation() throws {
        let model = ReaderContentListModalsModel()
        model.presentDeleteError(for: ReaderFileDeleteError.blockedCloudOnly)
        let oldError = try presentation(model)
        let item = UpstreamDeleteCommandContent()
        model.presentDeleteConfirmation(for: [item])
        let current = try presentation(model)

        oldError.dismiss()

        XCTAssertNil(oldError.confirm)
        XCTAssertEqual(try presentation(model).id, current.id)
        XCTAssertEqual(item.deleteCalls, 0)
    }

    func testRetainedBindingCannotReadOrDismissNewSameItemPresentation() throws {
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let oldBinding = model.deleteDialogBinding(isActive: .constant(true))
        let oldPresentation = try XCTUnwrap(oldBinding.wrappedValue)
        model.presentDeleteConfirmation(for: [item])
        let current = try presentation(model)

        XCTAssertNil(oldBinding.wrappedValue)
        oldBinding.wrappedValue = nil

        XCTAssertNotEqual(current.id, oldPresentation.id)
        XCTAssertEqual(try presentation(model).id, current.id)
    }

    func testInactiveHostRejectsBindingAndRetainedActions() throws {
        let host = DeleteDialogHostState()
        let active = Binding(get: { host.isActive }, set: { host.isActive = $0 })
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let binding = model.deleteDialogBinding(isActive: active)
        let displayed = try XCTUnwrap(binding.wrappedValue)
        host.isActive = false

        XCTAssertNil(binding.wrappedValue)
        binding.wrappedValue = nil
        displayed.dismiss()
        XCTAssertNil(displayed.confirm?())

        XCTAssertEqual(model.deleteDialogGeneration, displayed.id)
        XCTAssertEqual(item.deleteCalls, 0)
        host.isActive = true
        XCTAssertEqual(binding.wrappedValue?.id, displayed.id)
    }

    func testConfirmationCallbackAdmitsOnceAndFreshConfirmationCanRetry() async throws {
        let item = UpstreamDeleteCommandContent()
        item.deletion = { throw ReaderFileDeleteError.blockedCloudOnly }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let displayed = try presentation(model)
        let task = try XCTUnwrap(displayed.confirm?())

        XCTAssertNil(displayed.confirm?())
        await task.value
        XCTAssertEqual(item.deleteCalls, 1)
        guard case .error? = model.deleteDialog else { return XCTFail("Expected current command error") }

        item.deletion = nil
        model.presentDeleteConfirmation(for: [item])
        let retry = try XCTUnwrap(presentation(model).confirm?())
        await retry.value

        XCTAssertEqual(item.deleteCalls, 2)
        XCTAssertNil(model.deleteDialog)
    }

    func testCustomDeleteErrorCannotReplaceLaterConfirmation() async throws {
        let model = ReaderContentListModalsModel()
        let gate = DeleteCommandSuspension()
        let task = try XCTUnwrap(model.requestDeleteOperation {
            await gate.wait()
            throw ReaderFileDeleteError.blockedCloudOnly
        })
        await gate.waitUntilStarted()
        model.presentDeleteConfirmation(for: [UpstreamDeleteCommandContent()])
        let current = try presentation(model)

        await gate.resume()
        await task.value

        XCTAssertEqual(try presentation(model).id, current.id)
    }

    func testLateCustomDeleteErrorCannotReplaceNewerCommandError() async throws {
        let model = ReaderContentListModalsModel()
        let gate = DeleteCommandSuspension()
        let old = try XCTUnwrap(model.requestDeleteOperation {
            await gate.wait()
            throw ReaderFileDeleteError.blockedCloudOnly
        })
        await gate.waitUntilStarted()
        let current = try XCTUnwrap(model.requestDeleteOperation {
            throw ReaderFileDeleteError.blockedLoadingStatus
        })
        await current.value
        let currentPresentation = try presentation(model)

        await gate.resume()
        await old.value

        XCTAssertEqual(try presentation(model).id, currentPresentation.id)
        guard case .error(_, let message)? = model.deleteDialog else { return XCTFail("Expected newer error") }
        XCTAssertEqual(message, ReaderFileDeleteError.blockedLoadingStatus.localizedDescription)
    }

    func testCancelledUnacceptedActionsDoNotRevokeCurrentPresentation() async throws {
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let displayed = try presentation(model)
        let cancelled = Task { @MainActor in
            let confirmation = displayed.confirm?()
            let custom = model.requestDeleteOperation { XCTFail("Cancelled entry must not run") }
            return (confirmation, custom)
        }
        cancelled.cancel()
        let rejected = await cancelled.value

        XCTAssertNil(rejected.0)
        XCTAssertNil(rejected.1)
        XCTAssertEqual(model.deleteDialogGeneration, displayed.id)
        XCTAssertEqual(item.deleteCalls, 0)

        let current = try XCTUnwrap(displayed.confirm?())
        await current.value
        XCTAssertEqual(item.deleteCalls, 1)
    }

}
