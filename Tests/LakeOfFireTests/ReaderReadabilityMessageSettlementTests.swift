import Foundation
import BigSyncKit
@testable import LakeKit
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent
import XCTest
@testable import LakeOfFireReader

@MainActor
final class ReaderReadabilityMessageSettlementTests: XCTestCase {
    func testAlreadyCancelledCallbackDoesNotStartLookupOrPublish() async {
        let settlement = ReaderReadabilityMessageSettlement { true }
        var startedLookup = false
        var published = false
        let callback = Task { @MainActor in
            do {
                _ = try await settlement.perform {
                    startedLookup = true
                    return "obsolete HTML"
                }
                XCTFail("An already cancelled callback must not complete its lookup")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertFalse(settlement.settle { published = true })
        }

        // The MainActor task cannot start before this synchronous cancellation.
        callback.cancel()
        await callback.value

        XCTAssertFalse(startedLookup)
        XCTAssertFalse(published)
    }

    func testCancellationDuringLookupRejectsNoncooperativeSuccess() async {
        let lookup = HeldReadabilityOperation<String>()
        let settlement = ReaderReadabilityMessageSettlement { true }
        let viewModel = ReaderModeViewModel()
        viewModel.readabilityContent = "current HTML"
        var evaluatedScript = false
        let callback = Task { @MainActor in
            do {
                let html = try await settlement.perform { try await lookup.suspend() }
                _ = await settlement.performIgnoringFailure { evaluatedScript = true }
                settlement.settle { viewModel.readabilityContent = html }
                XCTFail("The cancelled callback must reject the lookup's late value")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }

        await lookup.waitUntilSuspended()
        callback.cancel()
        lookup.complete(.success("obsolete HTML"))
        await callback.value

        XCTAssertEqual(lookup.resumedWhileCancelled, true)
        XCTAssertFalse(evaluatedScript)
        XCTAssertEqual(viewModel.readabilityContent, "current HTML")
    }

    func testOwnerReplacementDuringLookupRejectsLateCompletion() async {
        let originalOwner = ReaderModeViewModel()
        var currentOwner = originalOwner
        await assertLookupRejectsRetiredPresentation(
            ownsPresentation: { currentOwner === originalOwner },
            retire: { currentOwner = ReaderModeViewModel() }
        )
    }

    func testBindingReplacementDuringLookupRejectsLateCompletion() async {
        let originalBinding = UUID()
        var currentBinding = originalBinding
        await assertLookupRejectsRetiredPresentation(
            ownsPresentation: { currentBinding == originalBinding },
            retire: { currentBinding = UUID() }
        )
    }

    func testPageChangeDuringLookupRejectsLateCompletion() async {
        let originalPage = URL(string: "https://example.com/original")!
        var currentPage = originalPage
        await assertLookupRejectsRetiredPresentation(
            ownsPresentation: { currentPage == originalPage },
            retire: { currentPage = URL(string: "https://example.com/replacement")! }
        )
    }

    func testCurrentLookupErrorIsPreserved() async {
        let settlement = ReaderReadabilityMessageSettlement { true }
        do {
            let _: String = try await settlement.perform {
                throw ReadabilityOperationError.lookupFailed
            }
            XCTFail("A current lookup failure must still reach its caller")
        } catch {
            XCTAssertEqual(error as? ReadabilityOperationError, .lookupFailed)
            XCTAssertTrue(settlement.isCurrent)
        }
    }

    func testRetiredLookupErrorBecomesCancellation() async {
        let lookup = HeldReadabilityOperation<String>()
        var ownsPresentation = true
        let settlement = ReaderReadabilityMessageSettlement { ownsPresentation }
        let callback = Task { @MainActor in
            do {
                _ = try await settlement.perform { try await lookup.suspend() }
                XCTFail("A retired callback must reject failed lookup settlement")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }

        await lookup.waitUntilSuspended()
        ownsPresentation = false
        lookup.complete(.failure(ReadabilityOperationError.lookupFailed))
        await callback.value

        XCTAssertEqual(lookup.resumedWhileCancelled, false)
        XCTAssertFalse(settlement.isCurrent)
    }

    func testCancellationDuringEvaluationRejectsNoncooperativeError() async {
        let evaluation = HeldReadabilityOperation<Void>()
        let settlement = ReaderReadabilityMessageSettlement { true }
        let viewModel = ReaderModeViewModel()
        viewModel.isReaderMode = true
        viewModel.readabilityContent = "current HTML"
        let callback = Task { @MainActor in
            let mayContinue = await settlement.performIgnoringFailure {
                try await evaluation.suspend()
            }
            XCTAssertFalse(mayContinue)
            XCTAssertFalse(settlement.settle {
                viewModel.isReaderMode = false
            })
        }

        await evaluation.waitUntilSuspended()
        callback.cancel()
        evaluation.complete(.failure(ReadabilityOperationError.evaluationFailed))
        await callback.value

        XCTAssertEqual(evaluation.resumedWhileCancelled, true)
        XCTAssertTrue(viewModel.isReaderMode)
        XCTAssertEqual(viewModel.readabilityContent, "current HTML")
    }

    func testOwnerLossDuringEvaluationRejectsNoncooperativeSuccess() async {
        let evaluation = HeldReadabilityOperation<Void>()
        var ownsPresentation = true
        let settlement = ReaderReadabilityMessageSettlement { ownsPresentation }
        var published = false
        let callback = Task { @MainActor in
            let mayContinue = await settlement.performIgnoringFailure {
                try await evaluation.suspend()
            }
            XCTAssertFalse(mayContinue)
            XCTAssertFalse(settlement.settle { published = true })
        }

        await evaluation.waitUntilSuspended()
        ownsPresentation = false
        evaluation.complete(.success(()))
        await callback.value

        XCTAssertEqual(evaluation.resumedWhileCancelled, false)
        XCTAssertFalse(published)
    }

    func testCurrentEvaluationFailureStillAllowsSettlement() async {
        let evaluation = HeldReadabilityOperation<Void>()
        let settlement = ReaderReadabilityMessageSettlement { true }
        let viewModel = ReaderModeViewModel()
        let callback = Task { @MainActor in
            let mayContinue = await settlement.performIgnoringFailure {
                try await evaluation.suspend()
            }
            XCTAssertTrue(mayContinue)
            XCTAssertTrue(settlement.settle {
                viewModel.readabilityContent = "accepted HTML"
            })
        }

        await evaluation.waitUntilSuspended()
        evaluation.complete(.failure(ReadabilityOperationError.evaluationFailed))
        await callback.value

        XCTAssertEqual(evaluation.resumedWhileCancelled, false)
        XCTAssertEqual(viewModel.readabilityContent, "accepted HTML")
    }

    func testCurrentLookupAndEvaluationPublishOriginalResult() async {
        let lookup = HeldReadabilityOperation<String>()
        let evaluation = HeldReadabilityOperation<Void>()
        let settlement = ReaderReadabilityMessageSettlement { true }
        let viewModel = ReaderModeViewModel()
        var publications = 0
        let callback = Task { @MainActor in
            do {
                let html = try await settlement.perform { try await lookup.suspend() }
                let mayContinue = await settlement.performIgnoringFailure {
                    try await evaluation.suspend()
                }
                XCTAssertTrue(mayContinue)
                XCTAssertTrue(settlement.settle {
                    publications += 1
                    viewModel.readabilityContent = html
                })
            } catch {
                XCTFail("Current successful work must settle: \(error)")
            }
        }

        await lookup.waitUntilSuspended()
        lookup.complete(.success("accepted HTML"))
        await evaluation.waitUntilSuspended()
        XCTAssertNil(viewModel.readabilityContent)
        XCTAssertEqual(publications, 0)
        evaluation.complete(.success(()))
        await callback.value

        XCTAssertEqual(viewModel.readabilityContent, "accepted HTML")
        XCTAssertEqual(publications, 1)
    }

    func testSettlementRechecksPresentationAfterSuccessfulOperation() async throws {
        var ownsPresentation = true
        let settlement = ReaderReadabilityMessageSettlement { ownsPresentation }
        let html = try await settlement.perform { "accepted lookup value" }
        var publishedHTML: String?

        ownsPresentation = false

        XCTAssertFalse(settlement.settle { publishedHTML = html })
        XCTAssertNil(publishedHTML)
    }

    // The predicate is a controlled dependency of the production settlement
    // helper. These cases do not duplicate the handler's binding capture or
    // HTTP/in-flight policy, which require the real callback integration.
    private func assertLookupRejectsRetiredPresentation(
        ownsPresentation: @escaping @MainActor () -> Bool,
        retire: @MainActor () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let lookup = HeldReadabilityOperation<String>()
        let settlement = ReaderReadabilityMessageSettlement(ownsPresentation: ownsPresentation)
        var deliveredValue: String?
        var published = false
        let callback = Task { @MainActor in
            do {
                deliveredValue = try await settlement.perform { try await lookup.suspend() }
                XCTFail("A changed presentation must reject late lookup success", file: file, line: line)
            } catch {
                XCTAssertTrue(error is CancellationError, file: file, line: line)
            }
            XCTAssertFalse(settlement.settle { published = true }, file: file, line: line)
        }

        await lookup.waitUntilSuspended()
        retire()
        lookup.complete(.success("obsolete HTML"))
        await callback.value

        XCTAssertEqual(lookup.resumedWhileCancelled, false, file: file, line: line)
        XCTAssertNil(deliveredValue, file: file, line: line)
        XCTAssertFalse(published, file: file, line: line)
    }
}

private enum ReadabilityOperationError: Error, Equatable {
    case lookupFailed
    case evaluationFailed
}

/// A collaborator that deliberately ignores cancellation until explicitly
/// completed, as a shared content lookup or WebKit evaluation can do.
@MainActor
private final class HeldReadabilityOperation<Value: Sendable> {
    private var completion: CheckedContinuation<Value, Error>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var resumedWhileCancelled: Bool?

    func suspend() async throws -> Value {
        defer { resumedWhileCancelled = Task.isCancelled }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(completion == nil)
            completion = continuation
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilSuspended() async {
        guard completion == nil else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func complete(_ result: Result<Value, Error>) {
        guard let continuation = completion else {
            XCTFail("The controlled operation must be suspended before completion")
            return
        }
        completion = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class ReaderReadabilityMutationAdmissionTests: XCTestCase {

    func testSelectionFenceNeverRevivesAfterPageReturns() {
        let content = ReaderContent()
        let original = URL(string: "https://example.com/original")!
        content.pageURL = original
        let fence = content.makeReadabilityMutationFence()
        XCTAssertTrue(fence())
        content.pageURL = URL(string: "https://example.com/replacement")!
        content.pageURL = original
        XCTAssertFalse(fence())
        XCTAssertTrue(content.makeReadabilityMutationFence()())
    }

    private struct Snapshot: Equatable {
        let available: Bool
        let demoted: Bool?
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
        let generations: [String: String]
    }

    private func snapshot(_ realm: Realm, key: String) throws -> Snapshot {
        realm.refresh()
        let row = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
        return Snapshot(available: row.isReaderModeAvailable, demoted: row.isDemoted,
            modifiedAt: row.modifiedAt, explicitlyModifiedAt: row.explicitlyModifiedAt,
            generations: Dictionary(uniqueKeysWithValues:
                realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }))
    }

    private func fixture(available: Bool = false) async throws -> (Realm, ReaderContentLoader.ContentReference, String) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [HistoryRecord.self, Bookmark.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let row = HistoryRecord()
        row.url = URL(string: "https://example.com/readability-admission")!
        row.updateCompoundKey()
        row.isDemoted = true
        row.isReaderModeAvailable = available
        try realm.write {
            realm.add(row)
            row.refreshChangeMetadata(explicitlyModified: true)
        }
        return (realm, try XCTUnwrap(ReaderContentLoader.ContentReference(content: row)), row.compoundKey)
    }

    func testRevokedOwnerCannotMutateOrJournalAfterQueuedAdmission() async throws {
        try await assertQueuedRejection(recreate: false, demotion: false)
    }

    func testEqualFieldReplacementCannotInheritQueuedReadabilityMutation() async throws {
        try await assertQueuedRejection(recreate: true, demotion: false)
    }

    func testRevokedOwnerCannotCommitHistoryDemotionAfterQueueing() async throws {
        try await assertQueuedRejection(recreate: false, demotion: true)
    }

    func testRevocationDuringMutationRollsBackFieldsAndJournal() async throws {
        let (realm, reference, key) = try await fixture()
        let before = try snapshot(realm, key: key)
        let owner = ReaderReadabilityMutationOwner()
        let permitsMutation = owner.capture()
        do {
            try await reference.mutateIfAdmitted(admittingMutation: permitsMutation) { row in
                row.isReaderModeAvailable = true
                owner.invalidate()
                return true
            }
            XCTFail("Revoked write committed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try snapshot(realm, key: key), before)
    }

    func testEqualFieldReplacementCannotInheritQueuedHistoryDemotion() async throws {
        try await assertQueuedRejection(recreate: true, demotion: true)
    }

    private func assertQueuedRejection(recreate: Bool, demotion: Bool) async throws {
        let (realm, reference, key) = try await fixture(available: demotion)
        let configuration = realm.configuration
        let owner = ReaderReadabilityMutationOwner()
        let permitsMutation = owner.capture()
        let gate = ReadabilityMutationGate()
        let entered = expectation(description: "Real writer captured original reference before admission")
        let operation = Task { @RealmBackgroundActor in
            if demotion {
                let resolved = try await reference.resolveOnBackgroundActor()
                let row = try XCTUnwrap(resolved as? HistoryRecord)
                try await row.refreshDemotedStatus(admittingMutation: permitsMutation,
                    beforeWrite: { await gate.wait { entered.fulfill() } })
            } else {
                try await reference.mutateIfAdmitted(admittingMutation: permitsMutation,
                    beforeWrite: { await gate.wait { entered.fulfill() } }) { row in
                    row.isReaderModeAvailable = true
                    return true
                }
            }
        }
        addTeardownBlock { operation.cancel(); await gate.release(); _ = await operation.result }
        await fulfillment(of: [entered], timeout: 5)
        if recreate {
            try await { @RealmBackgroundActor in
                let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try await writer.asyncWritePreservingOwnership {
                    let original = try XCTUnwrap(writer.object(ofType: HistoryRecord.self, forPrimaryKey: key))
                    let replacement = HistoryRecord(value: original)
                    writer.delete(original)
                    writer.add(replacement)
                }
            }()
        } else {
            owner.invalidate()
        }
        let beforeAdmission = try snapshot(realm, key: key)
        await gate.release()
        do {
            try await operation.value
            if !recreate { XCTFail("Retired owner reached write admission") }
        } catch {
            XCTAssertFalse(recreate)
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try snapshot(realm, key: key), beforeAdmission)
    }

    func testSameAccountGenerationChangeRejectsQueuedFieldsAndJournal() async throws {
        let (realm, reference, key) = try await fixture()
        let before = try snapshot(realm, key: key)
        let account = ReadabilityAccountFixture(.init(identity: .authenticated(userID: 1), generation: 1))
        let model = ReaderModeViewModel()
        model.readerAccountSessionAccess = account.access
        let admission = model.makeReadabilityAccountAdmission()
        let gate = ReadabilityMutationGate()
        let entered = expectation(description: "Account-owned writer awaits admission")
        let operation = Task { @RealmBackgroundActor in
            try await reference.mutateIfAdmitted(admittingMutation: admission.permits,
                commitIfCurrent: admission.commit,
                beforeWrite: { await gate.wait { entered.fulfill() } }) { row in
                row.isReaderModeAvailable = true
                return true
            }
        }
        addTeardownBlock { operation.cancel(); await gate.release(); _ = await operation.result }
        await fulfillment(of: [entered], timeout: 5)
        account.replace(.init(identity: .authenticated(userID: 1), generation: 2))
        await gate.release()
        do { try await operation.value; XCTFail("Retired account generation committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try snapshot(realm, key: key), before)
    }

    func testCurrentAccountCommitsThroughItsPublicationBoundary() async throws {
        let (realm, reference, key) = try await fixture()
        let before = try snapshot(realm, key: key)
        let account = ReadabilityAccountFixture(.init(identity: .signedOut, generation: 0))
        let model = ReaderModeViewModel()
        model.readerAccountSessionAccess = account.access
        let admission = model.makeReadabilityAccountAdmission()
        try await reference.mutateIfAdmitted(admittingMutation: admission.permits,
            commitIfCurrent: admission.commit) { row in
            row.isReaderModeAvailable = true
            return true
        }
        let after = try snapshot(realm, key: key)
        XCTAssertTrue(after.available)
        XCTAssertNotEqual(after.generations, before.generations)
    }

    func testCurrentReadabilityMutationJournalsOnlyAnActualChange() async throws {
        let (realm, reference, key) = try await fixture()
        let before = try snapshot(realm, key: key)
        var settled: Snapshot?
        for _ in 0..<2 {
            try await reference.mutateIfAdmitted(admittingMutation: { true }) { row in
                guard !row.isReaderModeAvailable else { return false }
                row.isReaderModeAvailable = true
                return true
            }
            let after = try snapshot(realm, key: key)
            XCTAssertTrue(after.available)
            XCTAssertNotEqual(after.generations, before.generations)
            if let settled { XCTAssertEqual(after, settled) }
            settled = after
        }
    }
}

private actor ReadabilityMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(_ onSuspension: @Sendable () -> Void) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            onSuspension()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class ReadabilityAccountFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountSessionSnapshot

    init(_ value: AccountSessionSnapshot) { self.value = value }

    private var snapshot: AccountSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(_ value: AccountSessionSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    var access: AccountSessionAccess {
        AccountSessionAccess(testSnapshotProvider: { self.snapshot })
    }
}
