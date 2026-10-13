import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor LibraryScriptDomainGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// In-memory fixtures only. All mutations use the background write lane;
/// physical replacement simulates cleanup/recreation, never production deletion policy.
@MainActor
final class LibraryScriptDomainOwnershipTests: XCTestCase, @unchecked Sendable {
    private enum Retirement: CaseIterable, Sendable {
        case unlinked, domainDeleted, scriptDeleted, scriptManaged, domainReplaced, scriptReplaced
    }

    private func configuration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [UserScript.self, UserScriptAllowedDomain.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        return configuration
    }

    @RealmBackgroundActor
    private static func mutate(
        configuration: Realm.Configuration,
        _ body: @RealmBackgroundActor @Sendable (Realm) -> Void
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await realm.asyncWrite { body(realm) }
    }

    private func fixture(
        scriptID: UUID = UUID(), domainIDs: [UUID] = [UUID(), UUID()]
    ) async throws -> (Realm, UserScript, [UserScriptAllowedDomain]) {
        let configuration = configuration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        try await Self.mutate(configuration: configuration) { realm in
            let script = UserScript()
            script.id = scriptID
            script.createdAt = Date(timeIntervalSinceReferenceDate: 100)
            script.title = "Original"
            for (index, domainID) in domainIDs.enumerated() {
                let domain = UserScriptAllowedDomain()
                domain.id = domainID
                domain.createdAt = Date(timeIntervalSinceReferenceDate: 200 + Double(index))
                domain.domain = "original-\(index).example"
                realm.add(domain)
                domain.refreshChangeMetadata(explicitlyModified: true)
                script.allowedDomainIDs.append(domainID)
            }
            realm.add(script)
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: scriptID))
        let domains = try domainIDs.map {
            try XCTUnwrap(realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: $0))
        }
        return (realm, script, domains)
    }

    private func generations(_ realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        )
    }

    private func journal(for object: Object, in realm: Realm) -> BigSyncPendingMutation? {
        guard let primaryKey = object.objectSchema.primaryKeyProperty?.name,
              let identifier = object[primaryKey] else { return nil }
        return realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + String(describing: identifier)
        )
    }

    func testDelayedDomainEditKeepsCapturedStorageAfterDefaultReplacement() async throws {
        let (original, script, domains) = try await fixture()
        let (replacement, otherScript, otherDomains) = try await fixture(
            scriptID: script.id, domainIDs: domains.map(\.id)
        )
        let editor = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domains[0].id))
        XCTAssertEqual(editor.initialText, domains[0].domain)
        let command = editor.makeEdit("captured.example")
        let started = expectation(description: "domain writer suspended")
        let gate = LibraryScriptDomainGate()
        let writer = Task { @RealmBackgroundActor in
            try await command.write(beforeWrite: { started.fulfill(); await gate.wait() })
        }
        defer { writer.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = replacement.configuration
        let replacementGenerations = generations(replacement)
        await gate.release()
        try await writer.value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(domains[0].domain, "captured.example")
        XCTAssertEqual(otherDomains[0].domain, "original-0.example")
        XCTAssertEqual(Array(otherScript.allowedDomainIDs), otherDomains.map(\.id))
        XCTAssertEqual(generations(replacement), replacementGenerations)
    }

    func testDelayedDomainEditRejectsRetiredMembershipPolicyAndIncarnations() async throws {
        for retirement in Retirement.allCases {
            let (realm, script, domains) = try await fixture()
            let configuration = realm.configuration
            let scriptID = script.id
            let domainID = domains[0].id
            let editor = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domainID))
            let command = editor.makeEdit("obsolete.example")
            let started = expectation(description: "domain writer suspended for \(retirement)")
            let gate = LibraryScriptDomainGate()
            let writer = Task { @RealmBackgroundActor in
                try await command.write(beforeWrite: { started.fulfill(); await gate.wait() })
            }
            defer { writer.cancel(); Task { await gate.release() } }
            await fulfillment(of: [started], timeout: 5)
            try await Self.mutate(configuration: configuration) { realm in
                let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)!
                let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID)!
                switch retirement {
                case .unlinked:
                    script.allowedDomainIDs.removeAll()
                    script.refreshChangeMetadata(explicitlyModified: true)
                case .domainDeleted:
                    domain.isDeleted = true
                    domain.refreshChangeMetadata(explicitlyModified: true)
                case .scriptDeleted:
                    script.isDeleted = true
                    script.refreshChangeMetadata(explicitlyModified: true)
                case .scriptManaged:
                    script.opmlURL = URL(string: "https://example.com/managed.opml")!
                    script.refreshChangeMetadata(explicitlyModified: true)
                case .domainReplaced:
                    let replacement = UserScriptAllowedDomain()
                    replacement.id = domainID
                    replacement.createdAt = domain.createdAt.addingTimeInterval(1)
                    replacement.domain = "replacement.example"
                    realm.delete(domain)
                    realm.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                case .scriptReplaced:
                    let replacement = UserScript()
                    replacement.id = scriptID
                    replacement.createdAt = script.createdAt.addingTimeInterval(1)
                    replacement.allowedDomainIDs.append(domainID)
                    realm.delete(script)
                    realm.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            realm.refresh()
            let afterRetirement = generations(realm)
            await gate.release()
            try await writer.value
            realm.refresh()
            let current = try XCTUnwrap(realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID))
            XCTAssertNotEqual(current.domain, "obsolete.example", "\(retirement)")
            XCTAssertEqual(generations(realm), afterRetirement, "\(retirement)")
        }
    }

    func testNewEditorNoOpInputRetiresAnOlderSuspendedWriteBeforeCommit() async throws {
        let (realm, script, domains) = try await fixture()
        let olderEditor = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domains[0].id))
        let oldCommand = olderEditor.makeEdit("obsolete.example")
        let gate = LibraryScriptDomainGate()
        let started = expectation(description: "old domain edit suspended")
        let older = Task { @RealmBackgroundActor in
            try await oldCommand.write(beforeWrite: { started.fulfill(); await gate.wait() })
        }
        defer { older.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let newerEditor = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domains[0].id))
        let newest = newerEditor.makeEdit(domains[0].domain)
        let before = generations(realm)
        // Input is already reserved even while its debounced write is still pending.
        await gate.release()
        try await older.value
        try await newest.write()
        try await newest.write()
        realm.refresh()
        XCTAssertEqual(domains[0].domain, "original-0.example")
        XCTAssertEqual(generations(realm), before)
    }

    func testListDeleteUsesRenderedIdentityAfterReorderAndDefaultReplacement() async throws {
        let (realm, script, domains) = try await fixture()
        let (replacement, otherScript, otherDomains) = try await fixture(
            scriptID: script.id, domainIDs: domains.map(\.id)
        )
        let displayed = try domains.map { domain in
            try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domain.id))
        }
        let owner = try XCTUnwrap(LibraryScriptDomainOwner(script: script))
        let model = LibraryScriptFormSectionsViewModel()
        let gate = LibraryScriptDomainGate()
        let started = expectation(description: "rendered list deletion suspended")
        let deletion = model.onDeleteOfAllowedDomains(
            at: IndexSet(integer: 0), displayedDomains: displayed, owner: owner,
            beforeWrite: { started.fulfill(); await gate.wait() }
        )
        defer { deletion.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let scriptID = script.id
        let reversedIDs = domains.map(\.id).reversed().map { $0 }
        try await Self.mutate(configuration: realm.configuration) { realm in
            let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)!
            script.allowedDomainIDs.removeAll()
            script.allowedDomainIDs.append(objectsIn: reversedIDs)
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = replacement.configuration
        let otherGenerations = generations(replacement)
        await gate.release()
        try await deletion.value
        realm.refresh()
        replacement.refresh()
        XCTAssertEqual(Array(script.allowedDomainIDs), [domains[1].id])
        XCTAssertTrue(domains[0].isDeleted)
        XCTAssertFalse(domains[1].isDeleted)
        XCTAssertEqual(script.explicitlyModifiedAt, domains[0].explicitlyModifiedAt)
        XCTAssertEqual(Array(otherScript.allowedDomainIDs), otherDomains.map(\.id))
        XCTAssertFalse(otherDomains[0].isDeleted)
        XCTAssertEqual(generations(replacement), otherGenerations)
        let afterDeletion = generations(realm)
        try await model.onDeleteOfAllowedDomains(
            at: IndexSet([0, 99]), displayedDomains: displayed, owner: owner
        ).value
        realm.refresh()
        XCTAssertEqual(generations(realm), afterDeletion)
    }

    func testSharedDomainOrdersInputAcrossDifferentAdmittedScriptOwners() async throws {
        let (realm, script, domains) = try await fixture()
        let first = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domains[0].id))
        let oldCommand = first.makeEdit("obsolete.example")
        let otherScriptID = UUID()
        let domainID = domains[0].id
        try await Self.mutate(configuration: realm.configuration) { realm in
            let other = UserScript()
            other.id = otherScriptID
            other.allowedDomainIDs.append(domainID)
            realm.add(other)
            other.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        let other = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: otherScriptID))
        let second = try XCTUnwrap(UserScriptAllowedDomainEditor(script: other, domainID: domainID))
        XCTAssertNotEqual(first.identity, second.identity)
        let current = second.makeEdit(domains[0].domain)
        let before = generations(realm)
        try await oldCommand.write()
        try await current.write()
        realm.refresh()
        XCTAssertEqual(domains[0].domain, "original-0.example")
        XCTAssertEqual(generations(realm), before)
    }

    func testSelectedDomainDeletionRejectsRecreatedRowWithSameID() async throws {
        let (realm, script, domains) = try await fixture()
        let owner = try XCTUnwrap(LibraryScriptDomainOwner(script: script))
        let editor = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domains[0].id))
        let selected = editor.selection
        try await Self.mutate(configuration: realm.configuration) { realm in
            let original = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: selected.id)!
            let replacement = UserScriptAllowedDomain()
            replacement.id = selected.id
            replacement.createdAt = selected.createdAt.addingTimeInterval(1)
            replacement.domain = "replacement.example"
            realm.delete(original)
            realm.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        let before = generations(realm)
        try await owner.write(.delete([selected]))
        realm.refresh()
        let current = try XCTUnwrap(realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: selected.id))
        XCTAssertFalse(current.isDeleted)
        XCTAssertTrue(script.allowedDomainIDs.contains(selected.id))
        XCTAssertEqual(generations(realm), before)
    }

    func testAddDomainJournalsBothRowsAndRejectsRetiredOwner() async throws {
        let (realm, script, domains) = try await fixture()
        let owner = try XCTUnwrap(LibraryScriptDomainOwner(script: script))
        let model = LibraryScriptFormSectionsViewModel()
        let initialIDs = Set(domains.map(\.id))
        let initialGenerations = generations(realm)
        let initialScriptGeneration = try XCTUnwrap(journal(for: script, in: realm)?.generation)
        try await model.addEmptyDomain(owner: owner).value
        realm.refresh()
        let addedID = try XCTUnwrap(Set(script.allowedDomainIDs).subtracting(initialIDs).first)
        let added = try XCTUnwrap(realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: addedID))
        XCTAssertEqual(added.domain, "")
        XCTAssertEqual(script.explicitlyModifiedAt, added.explicitlyModifiedAt)
        XCTAssertNotNil(added.explicitlyModifiedAt)
        XCTAssertNotNil(journal(for: added, in: realm))
        XCTAssertNotEqual(journal(for: script, in: realm)?.generation, initialScriptGeneration)
        XCTAssertEqual(generations(realm).count, initialGenerations.count + 1)
        XCTAssertNotEqual(generations(realm), initialGenerations)
        let scriptID = script.id
        try await Self.mutate(configuration: realm.configuration) { realm in
            let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID)!
            script.opmlURL = URL(string: "https://example.com/managed.opml")!
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        let before = generations(realm)
        let ids = Array(script.allowedDomainIDs)
        try await model.addEmptyDomain(owner: owner).value
        realm.refresh()
        XCTAssertEqual(Array(script.allowedDomainIDs), ids)
        XCTAssertEqual(generations(realm), before)
    }

    func testPreCancelledDomainCommandDoesNotWrite() async throws {
        let (realm, script, domains) = try await fixture()
        let editor = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domains[0].id))
        let command = editor.makeEdit("cancelled.example")
        let before = generations(realm)
        let cancelled = Task { @RealmBackgroundActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await command.write()
        }
        do { try await cancelled.value; XCTFail("Cancelled edit succeeded") }
        catch is CancellationError {}
        realm.refresh()
        XCTAssertEqual(domains[0].domain, "original-0.example")
        XCTAssertEqual(generations(realm), before)
    }

    func testCancelledSuspendedDomainCommandsLeaveRowsAndJournalUnchanged() async throws {
        for addingDomain in [false, true] {
            let (realm, script, domains) = try await fixture()
            let editor = try XCTUnwrap(UserScriptAllowedDomainEditor(script: script, domainID: domains[0].id))
            let command = editor.makeEdit("cancelled.example")
            let owner = editor.owner
            let before = generations(realm)
            let ids = Array(script.allowedDomainIDs)
            let gate = LibraryScriptDomainGate()
            let started = expectation(description: "domain command suspended before cancellation")
            let writer = Task { @RealmBackgroundActor in
                if addingDomain {
                    try await owner.write(.add, beforeWrite: { started.fulfill(); await gate.wait() })
                } else {
                    try await command.write(beforeWrite: { started.fulfill(); await gate.wait() })
                }
            }
            defer { writer.cancel(); Task { await gate.release() } }
            await fulfillment(of: [started], timeout: 5)
            writer.cancel()
            await gate.release()
            do { try await writer.value; XCTFail("Cancelled command succeeded") }
            catch is CancellationError {}
            realm.refresh()
            XCTAssertEqual(Array(script.allowedDomainIDs), ids)
            XCTAssertEqual(domains[0].domain, "original-0.example")
            XCTAssertEqual(generations(realm), before)
        }
    }
}
