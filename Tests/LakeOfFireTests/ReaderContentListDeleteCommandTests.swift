import Foundation
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

@objc(LakeOfFireTestsUpstreamDeleteCommandContent)
private final class UpstreamDeleteCommandContent: Bookmark, DeletableReaderContent {
    var deleteCalls = 0
    var deletion: (@MainActor () async throws -> Void)?
    var deleteActionTitle: String { "Delete" }

    override class func shouldIncludeInDefaultSchema() -> Bool { false }

    @MainActor
    func delete() async throws {
        deleteCalls += 1
        try await deletion?()
    }
}

@MainActor
final class ReaderContentListDeleteCommandTests: XCTestCase {
    func testDeleteConfirmationCancelPerformsZeroDeletes() {
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        model.clearDeleteDialog()
        XCTAssertEqual(item.deleteCalls, 0)
        XCTAssertNil(model.deleteDialog)
    }

    func testDeleteConfirmationCommandDeletesExactlyOnce() async {
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        await model.deleteConfirmedItems([item])
        XCTAssertEqual(item.deleteCalls, 1)
        XCTAssertNil(model.deleteDialog)
    }

    func testDeleteConfirmationCommandRetainsError() async {
        let item = UpstreamDeleteCommandContent()
        item.deletion = { throw ReaderFileDeleteError.blockedCloudOnly }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        await model.deleteConfirmedItems([item])
        XCTAssertEqual(item.deleteCalls, 1)
        guard case .error? = model.deleteDialog else {
            return XCTFail("The command error must remain available to the alert presenter")
        }
    }

    func testOlderDeleteCompletionDoesNotClearNewerConfirmation() async {
        await checkOlderDeletePreservesNewerConfirmation(sameItem: false, fails: false)
    }

    func testConfirmedCommandRetainsErrorAfterAlertBindingDismissal() async {
        let item = UpstreamDeleteCommandContent()
        item.deletion = { throw ReaderFileDeleteError.blockedCloudOnly }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let generation = model.deleteDialogGeneration
        // SwiftUI dismisses the alert through its binding when a button is
        // tapped; this is not a new user request or an explicit cancellation.
        model.deleteDialog = nil
        await model.deleteConfirmedItems([item], generation: generation)
        XCTAssertEqual(item.deleteCalls, 1)
        guard case .error? = model.deleteDialog else {
            return XCTFail("Alert dismissal must not suppress the confirmed command's error")
        }
    }

    func testOlderDeleteCompletionDoesNotClearNewerSameItemConfirmation() async {
        await checkOlderDeletePreservesNewerConfirmation(sameItem: true, fails: false)
    }

    func testOlderDeleteErrorDoesNotReplaceNewerConfirmation() async {
        await checkOlderDeletePreservesNewerConfirmation(sameItem: false, fails: true)
    }

    func testOlderDeleteErrorDoesNotReplaceNewerSameItemConfirmation() async {
        await checkOlderDeletePreservesNewerConfirmation(sameItem: true, fails: true)
    }

    private func checkOlderDeletePreservesNewerConfirmation(sameItem: Bool, fails: Bool) async {
        let oldItem = UpstreamDeleteCommandContent()
        oldItem.compoundKey = "old"
        let newItem = sameItem ? oldItem : UpstreamDeleteCommandContent()
        if !sameItem { newItem.compoundKey = "new" }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [oldItem])
        let oldGeneration = model.deleteDialogGeneration
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
        await model.deleteConfirmedItems([oldItem], generation: oldGeneration)
        XCTAssertEqual(oldItem.deleteCalls, 1)
        XCTAssertEqual(newItem.deleteCalls, sameItem ? 1 : 0)
        XCTAssertNotEqual(model.deleteDialogGeneration, oldGeneration)
        guard case .confirm(let items, _, _, _)? = model.deleteDialog else {
            return XCTFail("An older completion must preserve the newer confirmation")
        }
        XCTAssertEqual(items.map(\.compoundKey), [newItem.compoundKey])
    }

    func testConfirmedCommandCapturedBeforeTaskStartsPreservesNewerRequest() async {
        let item = UpstreamDeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let generation = model.deleteDialogGeneration
        model.presentDeleteConfirmation(for: [item])
        let newerGeneration = model.deleteDialogGeneration
        await model.deleteConfirmedItems([item], generation: generation)
        XCTAssertEqual(item.deleteCalls, 1, "Presentation fencing must not revoke confirmed deletion")
        XCTAssertEqual(model.deleteDialogGeneration, newerGeneration)
        guard case .confirm? = model.deleteDialog else {
            return XCTFail("The request made before task entry must remain presented")
        }
    }

}
