import Foundation
import RealmSwift
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

/// Controls only the production model's eligibility I/O. Completion deliberately
/// ignores cancellation, like the selected coordinated-file status operation.
private actor DeleteTargetEligibilityProbe {
    private var requestedURLs: [URL] = []
    private var pending: [Int: CheckedContinuation<ReaderFileDeleteEligibility, Never>] = [:]
    private var observers: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func read(_ url: URL) async -> ReaderFileDeleteEligibility {
        let index = requestedURLs.count
        requestedURLs.append(url)
        return await withCheckedContinuation { continuation in
            pending[index] = continuation
            for observer in observers.removeValue(forKey: index) ?? [] { observer.resume() }
        }
    }

    func waitForRequest(_ index: Int) async {
        if requestedURLs.count > index { return }
        await withCheckedContinuation { observers[index, default: []].append($0) }
    }

    func complete(_ index: Int, with eligibility: ReaderFileDeleteEligibility) {
        pending.removeValue(forKey: index)?.resume(returning: eligibility)
    }

    func urls() -> [URL] { requestedURLs }
}

private actor DeleteTargetDelegateGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let pendingObservers = observers
            self.observers = []
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
private final class DeleteTargetDelegateRecorder {
    var urls: [URL] = []
    var operation: (@MainActor (any DeletableReaderContent) async throws -> Void)?

    func delete(_ item: any DeletableReaderContent) async throws {
        guard !item.isInvalidated else {
            XCTFail("The production command delegated an invalidated row")
            return
        }
        urls.append(item.url)
        try await operation?(item)
    }
}

@MainActor
private final class DeleteTargetRealmFixture {
    let realm: Realm
    let file: ContentFile

    init() throws {
        realm = try Realm(configuration: Realm.Configuration(
            inMemoryIdentifier: "ReaderDeleteTarget-\(UUID().uuidString)",
            objectTypes: [ContentFile.self, Bookmark.self]
        ))
        file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/first.epub")!
        file.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        file.updateCompoundKey()
        try realm.write { realm.add(file) }
    }

    func addFile(named name: String) throws -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/\(name).epub")!
        file.updateCompoundKey()
        try realm.write { realm.add(file) }
        return file
    }

    func addBookmark(named name: String) throws -> Bookmark {
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/\(name)")!
        bookmark.updateCompoundKey()
        try realm.write { realm.add(bookmark) }
        return bookmark
    }
}

@MainActor
final class ReaderContentDeleteTargetAdmissionTests: XCTestCase {
    private func makeModel(
        probe: DeleteTargetEligibilityProbe,
        recorder: DeleteTargetDelegateRecorder
    ) -> ReaderContentListModalsModel {
        ReaderContentListModalsModel(
            readDeleteEligibility: { await probe.read($0) },
            deleteItem: { try await recorder.delete($0) }
        )
    }

    private func presentation(
        _ model: ReaderContentListModalsModel
    ) throws -> ReaderContentListDeletePresentation {
        try XCTUnwrap(model.deleteDialogBinding(isActive: .constant(true)).wrappedValue)
    }

    private func confirm(
        _ items: [any DeletableReaderContent],
        in model: ReaderContentListModalsModel
    ) throws -> Task<Void, Never> {
        model.presentDeleteConfirmation(for: items)
        return try XCTUnwrap(presentation(model).confirm?())
    }

    func testInvalidatedAndTombstonedInitialTargetsDoNotOpenConfirmation() async throws {
        for physicallyDeleted in [false, true] {
            let fixture = try DeleteTargetRealmFixture()
            let probe = DeleteTargetEligibilityProbe()
            let recorder = DeleteTargetDelegateRecorder()
            let model = makeModel(probe: probe, recorder: recorder)
            try fixture.realm.write {
                if physicallyDeleted { fixture.realm.delete(fixture.file) }
                else { fixture.file.isDeleted = true }
            }

            model.presentDeleteConfirmation(for: [fixture.file])

            XCTAssertNil(model.deleteDialogBinding(isActive: .constant(true)).wrappedValue)
            let urls = await probe.urls()
            XCTAssertEqual(urls, [])
            XCTAssertEqual(recorder.urls, [])
        }
    }

    func testRetainedConfirmationRejectsPhysicalDeletionBeforeButton() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        model.presentDeleteConfirmation(for: [fixture.file])
        let displayed = try presentation(model)
        try fixture.realm.write { fixture.realm.delete(fixture.file) }

        let task = try XCTUnwrap(displayed.confirm?())
        await task.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
        XCTAssertEqual(recorder.urls, [])
        XCTAssertNil(model.deleteDialog)
    }

    func testAcceptedCommandCapturesURLAndCreationIdentityBeforeTaskEntry() async throws {
        for changeURL in [false, true] {
            let fixture = try DeleteTargetRealmFixture()
            let probe = DeleteTargetEligibilityProbe()
            let recorder = DeleteTargetDelegateRecorder()
            let model = makeModel(probe: probe, recorder: recorder)
            let task = try confirm([fixture.file], in: model)
            try fixture.realm.write {
                if changeURL { fixture.file.url = URL(string: "reader-file://file/load/local/replacement.epub")! }
                else { fixture.file.createdAt = fixture.file.createdAt.addingTimeInterval(1) }
            }

            await task.value

            let urls = await probe.urls()
            XCTAssertEqual(urls, [])
            XCTAssertEqual(recorder.urls, [])
            XCTAssertNil(model.deleteDialog)
        }
    }

    func testPhysicalReplacementWithEqualValuesCannotInheritAcceptedCommand() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let replacement = ContentFile()
        replacement.url = fixture.file.url
        replacement.createdAt = fixture.file.createdAt
        replacement.updateCompoundKey()
        let task = try confirm([fixture.file], in: model)
        try fixture.realm.write {
            fixture.realm.delete(fixture.file)
            fixture.realm.add(replacement)
        }

        await task.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
        XCTAssertEqual(recorder.urls, [])
        XCTAssertTrue(fixture.file.isInvalidated)
        XCTAssertFalse(replacement.isDeleted)
    }

    func testTombstoneBeforeQueuedCommandRetiresTarget() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file], in: model)
        try fixture.realm.write { fixture.file.isDeleted = true }

        await task.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
        XCTAssertEqual(recorder.urls, [])
    }

    func testPhysicalDeletionDuringEligibilityDiscardsSuccessAndOldErrors() async throws {
        let outcomes: [ReaderFileDeleteEligibility] = [.allowed, .blockedCloudOnly, .blockedLoadingStatus]
        for outcome in outcomes {
            let fixture = try DeleteTargetRealmFixture()
            let probe = DeleteTargetEligibilityProbe()
            let recorder = DeleteTargetDelegateRecorder()
            let model = makeModel(probe: probe, recorder: recorder)
            let task = try confirm([fixture.file], in: model)
            await probe.waitForRequest(0)
            try fixture.realm.write { fixture.realm.delete(fixture.file) }

            await probe.complete(0, with: outcome)
            await task.value

            XCTAssertEqual(recorder.urls, [])
            XCTAssertNil(model.deleteDialog)
        }
    }

    func testURLChangeDuringEligibilityCanRetryWithCurrentURL() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let originalURL = fixture.file.url
        let replacementURL = URL(string: "reader-file://file/load/local/replacement.epub")!
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let original = try confirm([fixture.file], in: model)
        await probe.waitForRequest(0)
        try fixture.realm.write { fixture.file.url = replacementURL }

        await probe.complete(0, with: .blockedCloudOnly)
        await original.value
        XCTAssertEqual(recorder.urls, [])
        XCTAssertNil(model.deleteDialog)

        let retry = try confirm([fixture.file], in: model)
        await probe.waitForRequest(1)
        await probe.complete(1, with: .allowed)
        await retry.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [originalURL, replacementURL])
        XCTAssertEqual(recorder.urls, [replacementURL])
        XCTAssertNil(model.deleteDialog)
    }

    func testCreationChangeDuringEligibilityRetiresTarget() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file], in: model)
        await probe.waitForRequest(0)
        try fixture.realm.write { fixture.file.createdAt = fixture.file.createdAt.addingTimeInterval(1) }

        await probe.complete(0, with: .allowed)
        await task.value

        XCTAssertEqual(recorder.urls, [])
        XCTAssertNil(model.deleteDialog)
    }

    func testTombstoneDuringEligibilityCannotDeleteOrPresentOldError() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file], in: model)
        await probe.waitForRequest(0)
        try fixture.realm.write { fixture.file.isDeleted = true }

        await probe.complete(0, with: .blockedLoadingStatus)
        await task.value

        XCTAssertEqual(recorder.urls, [])
        XCTAssertNil(model.deleteDialog)
    }

    func testLaterFileInvalidatedBeforeItsPreflightIsSkipped() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let second = try fixture.addFile(named: "second")
        let firstURL = fixture.file.url
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file, second], in: model)
        await probe.waitForRequest(0)
        try fixture.realm.write { fixture.realm.delete(second) }

        await probe.complete(0, with: .allowed)
        await task.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [firstURL])
        XCTAssertEqual(recorder.urls, [firstURL])
    }

    func testEarlierFileRetiredDuringLaterPreflightIsNotDelegated() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let second = try fixture.addFile(named: "second")
        let secondURL = second.url
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file, second], in: model)
        await probe.waitForRequest(0)
        await probe.complete(0, with: .allowed)
        await probe.waitForRequest(1)
        try fixture.realm.write { fixture.realm.delete(fixture.file) }

        await probe.complete(1, with: .allowed)
        await task.value

        XCTAssertEqual(recorder.urls, [secondURL])
    }

    func testSuspendedEarlierDeletionCannotDispatchRetiredLaterRow() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let first = try fixture.addBookmark(named: "first")
        let second = try fixture.addBookmark(named: "second")
        let firstURL = first.url
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let gate = DeleteTargetDelegateGate()
        recorder.operation = { _ in await gate.wait() }
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([first, second], in: model)
        await gate.waitUntilStarted()
        try fixture.realm.write { fixture.realm.delete(second) }

        await gate.resume()
        await task.value

        XCTAssertEqual(recorder.urls, [firstURL])
    }

    func testCurrentCloudOrLoadingBlockPreventsEveryMixedBatchDeletion() async throws {
        let outcomes: [ReaderFileDeleteEligibility] = [.blockedCloudOnly, .blockedLoadingStatus]
        for outcome in outcomes {
            let fixture = try DeleteTargetRealmFixture()
            let bookmark = try fixture.addBookmark(named: "saved")
            let probe = DeleteTargetEligibilityProbe()
            let recorder = DeleteTargetDelegateRecorder()
            let model = makeModel(probe: probe, recorder: recorder)
            let task = try confirm([bookmark, fixture.file], in: model)
            await probe.waitForRequest(0)
            XCTAssertEqual(recorder.urls, [], "Preflight must precede even the first non-file deletion")

            await probe.complete(0, with: outcome)
            await task.value

            XCTAssertEqual(recorder.urls, [])
            guard case .error? = model.deleteDialog else { return XCTFail("Expected the current preflight error") }
        }
    }

    func testCancellationBeforeTaskEntryPerformsNoIO() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file], in: model)
        task.cancel()

        await task.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
        XCTAssertEqual(recorder.urls, [])
        XCTAssertNil(model.deleteDialog)
    }

    func testNoncooperativeEligibilityAfterCancellationDoesNotDeleteOrPresentError() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file], in: model)
        await probe.waitForRequest(0)
        task.cancel()

        await probe.complete(0, with: .blockedCloudOnly)
        await task.value

        XCTAssertEqual(recorder.urls, [])
        XCTAssertNil(model.deleteDialog)
    }

    func testCancelledDelegateFailureCannotPresentErrorOrDispatchNextTarget() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let first = try fixture.addBookmark(named: "first")
        let second = try fixture.addBookmark(named: "second")
        let firstURL = first.url
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let gate = DeleteTargetDelegateGate()
        recorder.operation = { _ in
            await gate.wait()
            throw ReaderFileDeleteError.blockedLoadingStatus
        }
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([first, second], in: model)
        await gate.waitUntilStarted()
        let binding = model.deleteDialogBinding(isActive: .constant(true))
        binding.wrappedValue = nil
        task.cancel()

        await gate.resume()
        await task.value

        XCTAssertEqual(recorder.urls, [firstURL])
        XCTAssertNil(model.deleteDialog)
    }

    func testAcceptedFileDeletionSurvivesNewDialogWithoutClearingIt() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let newItem = try fixture.addBookmark(named: "new")
        let firstURL = fixture.file.url
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file], in: model)
        await probe.waitForRequest(0)
        model.presentDeleteConfirmation(for: [newItem])
        let current = try presentation(model)

        await probe.complete(0, with: .allowed)
        await task.value

        XCTAssertEqual(recorder.urls, [firstURL])
        XCTAssertEqual(try presentation(model).id, current.id)
    }

    func testOlderPreflightFailureCannotReplaceNewerConfirmation() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let newItem = try fixture.addBookmark(named: "new")
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([fixture.file], in: model)
        await probe.waitForRequest(0)
        model.presentDeleteConfirmation(for: [newItem])
        let current = try presentation(model)

        await probe.complete(0, with: .blockedCloudOnly)
        await task.value

        XCTAssertEqual(recorder.urls, [])
        XCTAssertEqual(try presentation(model).id, current.id)
    }

    func testStableMixedBatchPreflightsFilesThenDeletesOriginalOrder() async throws {
        let fixture = try DeleteTargetRealmFixture()
        let second = try fixture.addFile(named: "second")
        let bookmark = try fixture.addBookmark(named: "saved")
        let backingURL = fixture.file.url
        let originalURL = URL(string: "\(backingURL.absoluteString)?progress=1#section")!
        try fixture.realm.write { fixture.file.url = originalURL }
        let expected = [bookmark.url, originalURL, second.url]
        let expectedPreflight = [backingURL, second.url]
        let probe = DeleteTargetEligibilityProbe()
        let recorder = DeleteTargetDelegateRecorder()
        let model = makeModel(probe: probe, recorder: recorder)
        let task = try confirm([bookmark, fixture.file, second], in: model)
        await probe.waitForRequest(0)
        XCTAssertEqual(recorder.urls, [])
        await probe.complete(0, with: .allowed)
        await probe.waitForRequest(1)
        XCTAssertEqual(recorder.urls, [])

        await probe.complete(1, with: .allowed)
        await task.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, expectedPreflight)
        XCTAssertEqual(recorder.urls, expected)
        XCTAssertNil(model.deleteDialog)
    }

    func testDirectInvalidatedContentFileDeletionReturnsBeforeURLAccess() async throws {
        let fixture = try DeleteTargetRealmFixture()
        try fixture.realm.write { fixture.realm.delete(fixture.file) }

        try await fixture.file.delete()

        XCTAssertTrue(fixture.file.isInvalidated)
    }
}
