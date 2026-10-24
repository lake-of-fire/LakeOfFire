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
        let editor = model(script)
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

}
