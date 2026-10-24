import Foundation
import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor LibraryScriptFieldGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(onSuspension: @Sendable () -> Void = {}) async {
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

/// Private in-memory storage. Physical removal/recreation simulates acknowledged cleanup;
/// every fixture mutation still uses the production background write lane.
@MainActor
final class LibraryScriptFieldOwnershipTests: XCTestCase, @unchecked Sendable {
    private enum InjectedFailure: Error { case write }
    private enum Retirement: CaseIterable, Sendable { case deleted, managed, removed, recreated }

    @RealmBackgroundActor
    private static func mutate(
        configuration: Realm.Configuration,
        _ body: @RealmBackgroundActor @Sendable (Realm) -> Void
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await realm.asyncWrite { body(realm) }
    }

    private func fixture(scriptID: UUID = UUID()) async throws -> (Realm, UserScript) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [UserScript.self, UserScriptAllowedDomain.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        try await Self.mutate(configuration: configuration) { realm in
            let script = UserScript()
            script.id = scriptID
            script.createdAt = Date(timeIntervalSinceReferenceDate: 100)
            script.title = "Original"
            script.script = "original();"
            script.previewURL = URL(string: "https://original.example/")!
            realm.add(script)
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        return (realm, try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)))
    }

    private func model(
        _ script: UserScript, observesRealm: Bool = false,
        retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)? = nil
    ) -> LibraryScriptFormSectionsViewModel {
        let model = LibraryScriptFormSectionsViewModel(
            realmConfiguration: script.realm!.configuration, observesRealm: observesRealm,
            retirementDidFinish: retirementDidFinish
        )
        model.script = script
        return model
    }

    private func generations(_ realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        )
    }

    private func command(_ script: UserScript, _ edit: LibraryScriptFieldEdit) throws -> LibraryScriptFieldCommand {
        let owner = try XCTUnwrap(LibraryScriptDomainOwner(script: script))
        let ordering = LibraryScriptFieldWriteOrdering.shared(identity: LibraryScriptEditorIdentity(owner: owner))
        return LibraryScriptFieldCommand(
            owner: owner, edit: edit, intent: ordering.issueIntent(field: edit.field), ordering: ordering
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Expected editor state before the bounded deadline")
    }

    func testDelayedFieldKeepsCapturedStorageAfterDefaultReplacement() async throws {
        let (original, script) = try await fixture()
        let (replacement, otherScript) = try await fixture(scriptID: script.id)
        let editor = model(script)
        let gate = LibraryScriptFieldGate()
        let started = expectation(description: "field writer suspended")
        let write = editor.writeFieldAsync(.title("Captured"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        defer { write.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = replacement.configuration
        let otherGenerations = generations(replacement)
        await gate.release()
        try await write.value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(script.title, "Captured")
        XCTAssertEqual(otherScript.title, "Original")
        XCTAssertEqual(generations(replacement), otherGenerations)
        XCTAssertNotEqual(LibraryScriptEditorIdentity(script: script), LibraryScriptEditorIdentity(script: otherScript))
    }

    func testReplacementFlushesBufferedTitleTextAndPreviewToOriginalScript() async throws {
        let (original, script) = try await fixture()
        let (replacement, otherScript) = try await fixture(scriptID: script.id)
        let retired = expectation(description: "all buffered original commands settled")
        let editor = model(script, retirementDidFinish: { retired.fulfill() })
        editor.scriptTitle = "Leading title"
        editor.scriptTitle = "Final title"
        editor.scriptText = "leading();"
        editor.scriptText = "final();"
        editor.scriptPreviewURL = "https://leading.example/"
        editor.scriptPreviewURL = "https://final.example/"
        editor.script = otherScript
        XCTAssertEqual(editor.scriptTitle, "Original")
        XCTAssertEqual(editor.scriptText, "original();")
        XCTAssertEqual(editor.scriptPreviewURL, "https://original.example/")
        let otherGenerations = generations(replacement)
        try await editor.finishEditing().value
        await fulfillment(of: [retired], timeout: 5)
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(script.title, "Final title")
        XCTAssertEqual(script.script, "final();")
        XCTAssertEqual(script.previewURL?.absoluteString, "https://final.example/")
        XCTAssertEqual(otherScript.title, "Original")
        XCTAssertEqual(generations(replacement), otherGenerations)
    }

    func testOldCompletionCannotSettleReplacementDraft() async throws {
        let (original, script) = try await fixture()
        let (replacement, otherScript) = try await fixture(scriptID: script.id)
        let editor = model(script)
        let oldGate = LibraryScriptFieldGate()
        let newGate = LibraryScriptFieldGate()
        let oldStarted = expectation(description: "old editor write suspended")
        let oldWrite = editor.writeFieldAsync(.title("Old draft"), beforeWrite: {
            oldStarted.fulfill(); await oldGate.wait()
        })
        defer { oldWrite.cancel(); Task { await oldGate.release() } }
        await fulfillment(of: [oldStarted], timeout: 5)
        editor.script = otherScript
        let newStarted = expectation(description: "replacement editor write suspended")
        let newWrite = editor.writeFieldAsync(.title("New draft"), beforeWrite: {
            newStarted.fulfill(); await newGate.wait()
        })
        defer { newWrite.cancel(); Task { await newGate.release() } }
        await fulfillment(of: [newStarted], timeout: 5)
        await oldGate.release()
        try await oldWrite.value
        editor.refresh()
        XCTAssertEqual(editor.scriptTitle, "New draft")
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(script.title, "Old draft")
        XCTAssertEqual(otherScript.title, "Original")
        await newGate.release()
        try await newWrite.value
        replacement.refresh()
        XCTAssertEqual(otherScript.title, "New draft")
    }

    func testAllSevenFieldsPersistAndRepeatedInputDoesNotRejournal() async throws {
        let (realm, script) = try await fixture()
        let editor = model(script)
        let edits: [LibraryScriptFieldEdit] = [
            .title("Edited"), .text("edited();"), .enabled(false), .injectAtStart(false),
            .mainFrameOnly(false), .sandboxed(true), .previewURL("https://edited.example/")
        ]
        var before = generations(realm)
        for edit in edits {
            try await editor.writeFieldAsync(edit).value
            realm.refresh()
            XCTAssertNotEqual(generations(realm), before)
            before = generations(realm)
            try await editor.writeFieldAsync(edit).value
            realm.refresh()
            XCTAssertEqual(generations(realm), before)
        }
        XCTAssertEqual(script.title, "Edited")
        XCTAssertEqual(script.script, "edited();")
        XCTAssertTrue(script.isArchived)
        XCTAssertFalse(script.injectAtStart)
        XCTAssertFalse(script.mainFrameOnly)
        XCTAssertTrue(script.sandboxed)
        XCTAssertEqual(script.previewURL?.absoluteString, "https://edited.example/")
        XCTAssertNotNil(script.explicitlyModifiedAt)
        try await editor.writeFieldAsync(.previewURL("")).value
        realm.refresh()
        XCTAssertNil(script.previewURL)
    }

    func testHydrationAndRefreshDoNotReserveInputOrChangeJournal() async throws {
        let (realm, script) = try await fixture()
        let before = generations(realm)
        let edit = try command(script, .title("Admitted before hydration"))
        let editor = model(script)
        editor.refresh()
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(generations(realm), before)
        try await edit.write()
        realm.refresh()
        editor.refresh()
        XCTAssertEqual(editor.scriptTitle, "Admitted before hydration")
        let after = generations(realm)
        editor.refresh()
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(generations(realm), after)
    }

    func testReopenedEditorsNoOpInputRetiresOldWriteBeforeNewCommit() async throws {
        let (realm, script) = try await fixture()
        let first = model(script)
        let oldGate = LibraryScriptFieldGate()
        let newGate = LibraryScriptFieldGate()
        let oldStarted = expectation(description: "older input suspended")
        let oldWrite = first.writeFieldAsync(.title("Obsolete"), beforeWrite: {
            oldStarted.fulfill(); await oldGate.wait()
        })
        defer { oldWrite.cancel(); Task { await oldGate.release() } }
        await fulfillment(of: [oldStarted], timeout: 5)
        let second = model(script)
        let newStarted = expectation(description: "new unchanged input suspended")
        let newWrite = second.writeFieldAsync(.title("Original"), beforeWrite: {
            newStarted.fulfill(); await newGate.wait()
        })
        defer { newWrite.cancel(); Task { await newGate.release() } }
        await fulfillment(of: [newStarted], timeout: 5)
        let before = generations(realm)
        await oldGate.release()
        try await oldWrite.value
        realm.refresh()
        XCTAssertEqual(script.title, "Original")
        XCTAssertEqual(generations(realm), before)
        await newGate.release()
        try await newWrite.value
        realm.refresh()
        XCTAssertEqual(generations(realm), before)
    }

    func testFinalTransactionRejectsRetiredAndRecreatedScriptOwners() async throws {
        for retirement in Retirement.allCases {
            let (realm, script) = try await fixture()
            let edit = try command(script, .title("Rejected"))
            let scriptID = script.id
            let createdAt = script.createdAt
            let gate = LibraryScriptFieldGate()
            let started = expectation(description: "writer before owner retirement")
            let write = Task { @RealmBackgroundActor in
                try await edit.write(beforeWrite: { started.fulfill(); await gate.wait() })
            }
            defer { write.cancel(); Task { await gate.release() } }
            await fulfillment(of: [started], timeout: 5)
            try await Self.mutate(configuration: realm.configuration) { realm in
                let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)!
                switch retirement {
                case .deleted:
                    script.isDeleted = true
                    script.refreshChangeMetadata(explicitlyModified: true)
                case .managed:
                    script.opmlURL = URL(string: "https://managed.example/scripts.opml")!
                    script.refreshChangeMetadata(explicitlyModified: true)
                case .removed: realm.delete(script)
                case .recreated:
                    realm.delete(script)
                    let replacement = UserScript()
                    replacement.id = scriptID
                    replacement.createdAt = createdAt.addingTimeInterval(1)
                    replacement.title = "Replacement"
                    realm.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            realm.refresh()
            let before = generations(realm)
            await gate.release()
            try await write.value
            realm.refresh()
            let current = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)
            if retirement == .removed { XCTAssertNil(current) }
            else { XCTAssertEqual(current?.title, retirement == .recreated ? "Replacement" : "Original") }
            XCTAssertEqual(generations(realm), before)
        }
    }

    func testPublishedUnchangedInputReservesIntentBeforeDebounce() async throws {
        let (realm, script) = try await fixture()
        let oldCommand = try command(script, .title("Obsolete"))
        let editor = model(script)
        let gate = LibraryScriptFieldGate()
        let started = expectation(description: "older command suspended before published input")
        let write = Task { @RealmBackgroundActor in
            try await oldCommand.write(beforeWrite: { started.fulfill(); await gate.wait() })
        }
        defer { write.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let before = generations(realm)
        editor.scriptTitle = "Intermediate"
        editor.scriptTitle = "Original"
        await gate.release()
        try await write.value
        try await editor.finishEditing().value
        try await Task.sleep(nanoseconds: 500_000_000)
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(script.title, "Original")
        XCTAssertEqual(generations(realm), before)
    }

    func testFailureKeepsObservableDraftForRetirementRetry() async throws {
        let (realm, script) = try await fixture()
        let editor = model(script)
        let before = generations(realm)
        do {
            try await editor.writeFieldAsync(.text("retry();"), beforeWrite: { throw InjectedFailure.write }).value
            XCTFail("Injected write failure was swallowed")
        } catch InjectedFailure.write {}
        editor.refresh()
        realm.refresh()
        XCTAssertEqual(editor.scriptText, "retry();")
        XCTAssertEqual(script.script, "original();")
        XCTAssertEqual(generations(realm), before)
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(script.script, "retry();")
        XCTAssertNotEqual(generations(realm), before)
    }

    func testCancelledSuspendedWritePreservesDraftAndPermitsRetry() async throws {
        let (realm, script) = try await fixture()
        let editor = model(script)
        let before = generations(realm)
        let gate = LibraryScriptFieldGate()
        let started = expectation(description: "writer before cancellation")
        let write = editor.writeFieldAsync(.title("Retry cancelled draft"), beforeWrite: {
            started.fulfill(); await gate.wait()
        })
        defer { write.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        write.cancel()
        await gate.release()
        do { try await write.value; XCTFail("Cancelled writer succeeded") }
        catch is CancellationError {}
        editor.refresh()
        realm.refresh()
        XCTAssertEqual(editor.scriptTitle, "Retry cancelled draft")
        XCTAssertEqual(script.title, "Original")
        XCTAssertEqual(generations(realm), before)
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(script.title, "Retry cancelled draft")
    }

    func testPasteSupersedesBufferedPreviewAndKeepsOriginAcrossReplacement() async throws {
        let (original, script) = try await fixture()
        let (replacement, otherScript) = try await fixture(scriptID: script.id)
        let editor = model(script)
        editor.scriptPreviewURL = "https://leading.example/"
        editor.scriptPreviewURL = "https://buffered.example/"
        let paste = editor.pastePreviewURL(strings: ["  https://pasted.example/\n", "https://ignored.example/"])
        XCTAssertEqual(editor.scriptPreviewURL, "https://pasted.example/")
        editor.script = otherScript
        let otherGenerations = generations(replacement)
        try await paste.value
        try await editor.finishEditing().value
        // Wait beyond the form debounce to also reject its late buffered input.
        try await Task.sleep(nanoseconds: 500_000_000)
        try await editor.finishEditing().value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(script.previewURL?.absoluteString, "https://pasted.example/")
        XCTAssertEqual(otherScript.previewURL?.absoluteString, "https://original.example/")
        XCTAssertEqual(generations(replacement), otherGenerations)
    }

    func testReleasingModelFlushesFinalBufferedDraftWithoutRetainingEditor() async throws {
        let (realm, script) = try await fixture()
        var editor: LibraryScriptFormSectionsViewModel? = model(script)
        weak var releasedEditor = editor
        editor?.scriptTitle = "Leading"
        editor?.scriptTitle = "Final after release"
        editor?.scriptText = "leading();"
        editor?.scriptText = "retired();"
        editor = nil
        XCTAssertNil(releasedEditor)
        try await waitUntil {
            realm.refresh()
            return script.title == "Final after release" && script.script == "retired();"
        }
        XCTAssertNotNil(script.explicitlyModifiedAt)
    }

    func testNewTextInputDoesNotRetirePendingTitleInput() async throws {
        let (realm, script) = try await fixture()
        let editor = model(script)
        let gate = LibraryScriptFieldGate()
        let started = expectation(description: "independent title writer suspended")
        let write = editor.writeFieldAsync(.title("Independent title"), beforeWrite: {
            started.fulfill(); await gate.wait()
        })
        defer { write.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        try await editor.writeFieldAsync(.text("independent();")).value
        await gate.release()
        try await write.value
        realm.refresh()
        XCTAssertEqual(script.title, "Independent title")
        XCTAssertEqual(script.script, "independent();")
    }

    func testLiveObservationFollowsReplacementAndClearsDeletedProjectionWithoutJournaling() async throws {
        let (original, script) = try await fixture()
        let (replacement, otherScript) = try await fixture()
        let editor = model(script, observesRealm: true)
        let scriptID = script.id
        try await Self.mutate(configuration: original.configuration) { realm in
            let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)!
            script.title = "External"
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        try await waitUntil { editor.scriptTitle == "External" }
        original.refresh()
        let originalGenerations = generations(original)
        editor.script = otherScript
        let otherID = otherScript.id
        try await Self.mutate(configuration: original.configuration) { realm in
            let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)!
            script.title = "Retired observation"
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        try await Self.mutate(configuration: replacement.configuration) { realm in
            let script = realm.object(ofType: UserScript.self, forPrimaryKey: otherID)!
            script.title = "Replacement observed"
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        try await waitUntil { editor.scriptTitle == "Replacement observed" }
        replacement.refresh()
        let beforeDeletion = generations(replacement)
        try await Self.mutate(configuration: replacement.configuration) { realm in
            realm.delete(realm.object(ofType: UserScript.self, forPrimaryKey: otherID)!)
        }
        try await waitUntil { editor.scriptTitle.isEmpty && editor.allowedDomainIDs == nil }
        try await editor.finishEditing().value
        replacement.refresh()
        XCTAssertEqual(generations(replacement), beforeDeletion)
        original.refresh()
        XCTAssertNotEqual(generations(original), originalGenerations)
        XCTAssertEqual(script.title, "Retired observation")
    }
    func testPostSubmissionCancellationSettlesDurableFieldDraft() async throws {
        let (realm, script) = try await fixture()
        let editor = model(script)
        let write = RealmWriteCommitObservation.$didSubmit.withValue({
            withUnsafeCurrentTask { $0?.cancel() }
        }) {
            editor.writeFieldAsync(.title("Durable script title"))
        }
        try await write.value
        XCTAssertTrue(write.isCancelled)
        realm.refresh()
        XCTAssertEqual(script.title, "Durable script title")
        XCTAssertEqual(editor.scriptTitle, "Durable script title")
        let afterCommit = generations(realm)
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(generations(realm), afterCommit)
    }

    func testFailureAfterRebindingRetriesTheCapturedFinalDraft() async throws {
        let (original, script) = try await fixture()
        let (replacement, otherScript) = try await fixture(scriptID: script.id)
        let retired = expectation(description: "original binding retirement settled")
        let editor = model(script, retirementDidFinish: { retired.fulfill() })
        let before = generations(original)
        let otherBefore = generations(replacement)
        let gate = LibraryScriptFieldGate()
        let suspended = expectation(description: "original attempt continuation registered")
        let write = editor.writeFieldAsync(.text("retainedFinalDraft();"), beforeWrite: {
            await gate.wait(onSuspension: { suspended.fulfill() })
            throw InjectedFailure.write
        })
        addTeardownBlock { await gate.release(); _ = await write.result }
        await fulfillment(of: [suspended], timeout: 5)

        editor.script = otherScript
        XCTAssertEqual(editor.scriptText, "original();")
        await gate.release()
        do { try await write.value; XCTFail("The original attempt should fail") }
        catch InjectedFailure.write {}
        await fulfillment(of: [retired], timeout: 5)
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(script.script, "retainedFinalDraft();")
        XCTAssertNotEqual(generations(original), before)
        XCTAssertEqual(otherScript.script, "original();")
        XCTAssertEqual(editor.scriptText, "original();")
        XCTAssertEqual(generations(replacement), otherBefore)
    }

    func testRetirementRetryCannotOverwriteNewerInputFromReopenedEditor() async throws {
        let (original, script) = try await fixture()
        let (replacement, otherScript) = try await fixture(scriptID: script.id)
        let retired = expectation(description: "obsolete binding retirement settled")
        let editor = model(script, retirementDidFinish: { retired.fulfill() })
        let gate = LibraryScriptFieldGate()
        let suspended = expectation(description: "older attempt continuation registered")
        let write = editor.writeFieldAsync(.text("obsolete();"), beforeWrite: {
            await gate.wait(onSuspension: { suspended.fulfill() })
            throw InjectedFailure.write
        })
        addTeardownBlock { await gate.release(); _ = await write.result }
        await fulfillment(of: [suspended], timeout: 5)
        editor.script = otherScript
        let newerEditor = model(script)
        try await newerEditor.writeFieldAsync(.text("newer();")).value
        original.refresh()
        let afterNewerInput = generations(original)
        let otherBefore = generations(replacement)

        await gate.release()
        do { try await write.value; XCTFail("The original attempt should fail") }
        catch InjectedFailure.write {}
        await fulfillment(of: [retired], timeout: 5)
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(script.script, "newer();")
        XCTAssertEqual(generations(original), afterNewerInput)
        XCTAssertEqual(otherScript.script, "original();")
        XCTAssertEqual(editor.scriptText, "original();")
        XCTAssertEqual(generations(replacement), otherBefore)
    }

    func testReleaseJoinsFailedActiveAttemptThenRetriesWithoutRetainingEditor() async throws {
        let (realm, script) = try await fixture()
        let retired = expectation(description: "released editor retirement settled")
        var editor: LibraryScriptFormSectionsViewModel? = model(
            script, retirementDidFinish: { retired.fulfill() }
        )
        weak var releasedEditor = editor
        let gate = LibraryScriptFieldGate()
        let suspended = expectation(description: "released attempt continuation registered")
        let write = try XCTUnwrap(editor).writeFieldAsync(.title("Final after release"), beforeWrite: {
            await gate.wait(onSuspension: { suspended.fulfill() })
            throw InjectedFailure.write
        })
        addTeardownBlock { await gate.release(); _ = await write.result }
        await fulfillment(of: [suspended], timeout: 5)
        editor = nil
        XCTAssertNil(releasedEditor)

        await gate.release()
        do { try await write.value; XCTFail("The original attempt should fail") }
        catch InjectedFailure.write {}
        await fulfillment(of: [retired], timeout: 5)
        realm.refresh()
        XCTAssertEqual(script.title, "Final after release")
        XCTAssertNotNil(script.explicitlyModifiedAt)
        XCTAssertNil(releasedEditor)
    }

    // File replacement deliberately preserves model IDs and creation dates. A
    // configuration path plus row incarnation cannot identify the original store.
    private enum DiskMutation: CaseIterable, Sendable { case field, domainText, addDomain, deleteDomain }

    private struct DiskCommands: Sendable {
        let owner: LibraryScriptDomainOwner
        let field: LibraryScriptFieldCommand
        let domain: UserScriptAllowedDomainEditor
        let domainEdit: UserScriptAllowedDomainEdit

        @RealmBackgroundActor
        func write(_ mutation: DiskMutation, beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil) async throws {
            switch mutation {
            case .field: try await field.write(beforeWrite: { await beforeWrite?() })
            case .domainText: try await domainEdit.write(beforeWrite: beforeWrite)
            case .addDomain: try await owner.write(.add, beforeWrite: beforeWrite)
            case .deleteDomain: try await owner.write(.delete([domain.selection]), beforeWrite: beforeWrite)
            }
        }
    }

    private struct DiskState: Equatable, Sendable {
        let title: String
        let domainIDs: [UUID]
        let domains: [String]
        let deletedDomains: [Bool]
        let modifiedAt: [Date]
        let explicitlyModifiedAt: [Date?]
        let generations: [String: String]
    }

    private struct DiskFixture: Sendable {
        let current: Realm.Configuration
        let replacement: Realm.Configuration
        let retired: Realm.Configuration
        let commands: DiskCommands
        let originalState: DiskState
        let replacementState: DiskState
    }

    private func diskCommands(_ configuration: Realm.Configuration, title: String = "Retired title") throws -> DiskCommands {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            defer { realm.invalidate() }
            let script = try XCTUnwrap(realm.objects(UserScript.self).first)
            let domainID = try XCTUnwrap(script.allowedDomainIDs.first)
            let domain = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domainID))
            return DiskCommands(
                owner: try XCTUnwrap(LibraryScriptDomainOwner(script: script)),
                field: try command(script, .title(title)),
                domain: domain, domainEdit: domain.makeEdit("retired.example")
            )
        }
    }

    private func diskState(_ configuration: Realm.Configuration) throws -> DiskState {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            defer { realm.invalidate() }
            let script = try XCTUnwrap(realm.objects(UserScript.self).first)
            let domains = Array(realm.objects(UserScriptAllowedDomain.self).sorted(byKeyPath: "createdAt"))
            return DiskState(
                title: script.title, domainIDs: Array(script.allowedDomainIDs),
                domains: domains.map(\.domain), deletedDomains: domains.map(\.isDeleted),
                modifiedAt: [script.modifiedAt] + domains.map(\.modifiedAt),
                explicitlyModifiedAt: [script.explicitlyModifiedAt] + domains.map(\.explicitlyModifiedAt),
                generations: generations(realm)
            )
        }
    }

    @RealmBackgroundActor
    private static func releaseDiskCache(_ configuration: Realm.Configuration) {
        // A replaced path has two cache keys. Retire only this fixture's keys,
        // including the old inode; the public current-identity eviction is narrower.
        let actor = RealmBackgroundActor.shared
        let keys = actor.cachedRealms.keys.filter {
            actor.cachedRealms[$0]?.configuration.fileURL == configuration.fileURL
        }
        for key in keys {
            guard let realm = actor.cachedRealms[key], !realm.isInWriteTransaction else { continue }
            actor.cachedRealms.removeValue(forKey: key)
            realm.invalidate()
        }
    }

    private func diskFixture() throws -> DiskFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-storage-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var current = Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm"))
        current.objectTypes = [UserScript.self, UserScriptAllowedDomain.self]
        configureLakeOfFireMutationTrackingForTesting(&current)
        var replacement = current
        replacement.fileURL = directory.appendingPathComponent("replacement.realm")
        var retired = current
        retired.fileURL = directory.appendingPathComponent("retired.realm")
        let captured = current
        addTeardownBlock {
            await Self.releaseDiskCache(captured)
            try? FileManager.default.removeItem(at: directory)
        }
        let scriptID = UUID()
        let domainID = UUID()
        for (configuration, title) in [(current, "Original"), (replacement, "Replacement")] {
            try autoreleasepool {
                let realm = try Realm(configuration: configuration)
                defer { realm.invalidate() }
                try realm.write {
                    let domain = UserScriptAllowedDomain()
                    domain.id = domainID
                    domain.createdAt = Date(timeIntervalSinceReferenceDate: 200)
                    domain.domain = "original.example"
                    realm.add(domain)
                    domain.refreshChangeMetadata(explicitlyModified: true)
                    let script = UserScript()
                    script.id = scriptID
                    script.createdAt = Date(timeIntervalSinceReferenceDate: 100)
                    script.title = title
                    script.allowedDomainIDs.append(domainID)
                    realm.add(script)
                    script.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
        return DiskFixture(
            current: current, replacement: replacement, retired: retired,
            commands: try diskCommands(current),
            originalState: try diskState(current), replacementState: try diskState(replacement)
        )
    }

    private func replaceDiskFile(_ fixture: DiskFixture) throws {
        let current = try XCTUnwrap(fixture.current.fileURL)
        let replacement = try XCTUnwrap(fixture.replacement.fileURL)
        let retired = try XCTUnwrap(fixture.retired.fileURL)
        try FileManager.default.moveItem(at: current, to: retired)
        try FileManager.default.moveItem(at: replacement, to: current)
    }

    func testCapturedCommandsRejectSamePathReplacementBeforeOpening() async throws {
        for mutation in DiskMutation.allCases {
            let fixture = try diskFixture()
            try replaceDiskFile(fixture)
            do {
                try await fixture.commands.write(mutation)
                XCTFail("A retained command adopted the replacement store: \(mutation)")
            } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
            await Self.releaseDiskCache(fixture.current)
            XCTAssertEqual(try diskState(fixture.current), fixture.replacementState)
            XCTAssertEqual(try diskState(fixture.retired), fixture.originalState)
        }
    }

    func testCapturedCommandsRejectSamePathReplacementAfterOpening() async throws {
        for mutation in DiskMutation.allCases {
            let fixture = try diskFixture()
            let gate = LibraryScriptFieldGate()
            let opened = expectation(description: "Actual command opened original storage and suspended")
            let writer = Task { @RealmBackgroundActor in
                try await fixture.commands.write(mutation, beforeWrite: {
                    await gate.wait(onSuspension: { opened.fulfill() })
                })
            }
            addTeardownBlock { await gate.release(); _ = await writer.result }
            await fulfillment(of: [opened], timeout: 5)
            try replaceDiskFile(fixture)
            await gate.release()
            do {
                try await writer.value
                XCTFail("The transaction did not revalidate physical storage: \(mutation)")
            } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
            await Self.releaseDiskCache(fixture.current)
            XCTAssertEqual(try diskState(fixture.current), fixture.replacementState)
            XCTAssertEqual(try diskState(fixture.retired), fixture.originalState)
        }
    }

    func testRetirementRetryKeepsTheOriginalPhysicalStorageAdmission() async throws {
        let fixture = try diskFixture()
        let gate = LibraryScriptFieldGate()
        let opened = expectation(description: "Failed attempt registered after opening original storage")
        let command = fixture.commands.field
        let attempt = Task { @RealmBackgroundActor in
            try await command.write(beforeWrite: {
                await gate.wait(onSuspension: { opened.fulfill() })
                throw InjectedFailure.write
            })
        }
        let retirement = LibraryScriptFieldRetirement(commands: [command], activeWrites: [command.intent: attempt])
        let finishing = Task { @RealmBackgroundActor in try await retirement.finish() }
        addTeardownBlock { await gate.release(); _ = await attempt.result; _ = await finishing.result }
        await fulfillment(of: [opened], timeout: 5)
        try replaceDiskFile(fixture)
        await gate.release()
        do { try await attempt.value; XCTFail("Expected the injected failure") }
        catch InjectedFailure.write {}
        do { try await finishing.value; XCTFail("Retirement retry adopted the replacement") }
        catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.current)
        XCTAssertEqual(try diskState(fixture.current), fixture.replacementState)
        XCTAssertEqual(try diskState(fixture.retired), fixture.originalState)
    }

    func testReplacementStoreHasIndependentFieldAndDomainInputOrdering() async throws {
        let fixture = try diskFixture()
        try replaceDiskFile(fixture)
        let fresh = try diskCommands(fixture.current, title: "Successor title")
        let freshDomain = fresh.domain.makeEdit("successor.example")
        XCTAssertNotEqual(LibraryScriptEditorIdentity(owner: fixture.commands.owner), LibraryScriptEditorIdentity(owner: fresh.owner))
        XCTAssertNotEqual(fixture.commands.domain.identity, fresh.domain.identity)

        // Retained controls can reserve old input after the new editor's input.
        // Such input must not revoke the successor's admission.
        let oldField = fixture.commands.field
        _ = oldField.ordering.issueIntent(field: oldField.edit.field)
        _ = fixture.commands.domain.makeEdit("retired.example")
        try await fresh.field.write()
        try await freshDomain.write()
        await Self.releaseDiskCache(fixture.current)
        let after = try diskState(fixture.current)
        XCTAssertEqual(after.title, "Successor title")
        XCTAssertEqual(after.domains, ["successor.example"])
        XCTAssertNotEqual(after.generations, fixture.replacementState.generations)
        XCTAssertEqual(try diskState(fixture.retired), fixture.originalState)
        try await fresh.field.write()
        try await freshDomain.write()
        await Self.releaseDiskCache(fixture.current)
        XCTAssertEqual(try diskState(fixture.current), after, "Same-value replays must not re-journal")
    }

}
