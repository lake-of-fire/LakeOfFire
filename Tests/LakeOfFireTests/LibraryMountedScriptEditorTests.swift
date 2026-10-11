import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

final class LibraryMountedScriptEditorTests: XCTestCase {
    @MainActor
    func testClosingEditorFlushesLatestDebouncedDraftIntoItsOwningStore() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let target = try await Self.insertScript(in: configurationA)
        let realm = try await Realm.open(configuration: configurationA)
        let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: target.scriptID))
        let model = LibraryScriptFormSectionsViewModel(realmConfiguration: configurationB)
        model.script = script
        model.refresh()
        model.scriptTitle = "First draft"
        model.scriptTitle = "Final draft"
        model.scriptText = "window.finalDraft = true;"
        model.refresh()
        XCTAssertEqual(model.scriptTitle, "Final draft")

        await model.finishEditing()

        XCTAssertNil(model.persistenceErrorMessage)
        try await { @RealmBackgroundActor in
            let realmA = try await RealmBackgroundActor.shared.cachedRealm(for: configurationA)
            let saved = try XCTUnwrap(realmA.object(ofType: UserScript.self, forPrimaryKey: target.scriptID))
            XCTAssertEqual(saved.title, "Final draft")
            XCTAssertEqual(saved.script, "window.finalDraft = true;")
            let realmB = try await RealmBackgroundActor.shared.cachedRealm(for: configurationB)
            XCTAssertNil(realmB.object(ofType: UserScript.self, forPrimaryKey: target.scriptID))
        }()
    }

    @MainActor
    func testSwitchingEditorRetainsThePreviousDraftWithoutReplacingTheNewDraft() async throws {
        let configuration = makeConfiguration()
        let firstTarget = try await Self.insertScript(in: configuration)
        let secondTarget = try await Self.insertScript(in: configuration)
        let realm = try await Realm.open(configuration: configuration)
        let model = LibraryScriptFormSectionsViewModel(realmConfiguration: configuration)
        model.script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: firstTarget.scriptID))
        model.refresh()
        model.scriptTitle = "First final draft"
        model.script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: secondTarget.scriptID))
        model.refresh()
        model.scriptTitle = "Second final draft"

        await model.finishEditing()

        XCTAssertEqual(model.scriptTitle, "Second final draft")
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertEqual(realm.object(ofType: UserScript.self, forPrimaryKey: firstTarget.scriptID)?.title,
                           "First final draft")
            XCTAssertEqual(realm.object(ofType: UserScript.self, forPrimaryKey: secondTarget.scriptID)?.title,
                           "Second final draft")
        }()
    }

    @MainActor
    func testUnavailableScriptPresentsSaveFailureAndRetainsDraft() async throws {
        let configuration = makeConfiguration()
        let target = try await Self.insertScript(in: configuration, deleted: true)
        let realm = try await Realm.open(configuration: configuration)
        let model = LibraryScriptFormSectionsViewModel(realmConfiguration: configuration)
        model.script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: target.scriptID))
        model.scriptTitle = "Unavailable draft"

        await model.finishEditing()
        model.refresh()

        XCTAssertNotNil(model.persistenceErrorMessage)
        XCTAssertEqual(model.scriptTitle, "Unavailable draft")
    }

    func testEnabledMembershipRepairIsJournaledAndReplayIsUnchanged() async throws {
        let configuration = makeConfiguration()
        let setup = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let script = UserScript()
            let library = LibraryConfiguration()
            try realm.write { realm.add([script, library]) }
            return (LibraryUserScriptTarget(scriptID: script.id, createdAt: script.createdAt),
                    library.id, library.createdAt)
        }()
        let changedAt = Date(timeIntervalSinceReferenceDate: 95_000)
        let repaired = try await LibraryUserScriptLifecycleCommand.setEnabled(
            true, target: setup.0, configurationID: setup.1, configurationCreatedAt: setup.2,
            realmConfiguration: configuration, at: changedAt
        )
        XCTAssertTrue(repaired.membershipChanged)
        let replay = try await LibraryUserScriptLifecycleCommand.setEnabled(
            true, target: setup.0, configurationID: setup.1, configurationCreatedAt: setup.2,
            realmConfiguration: configuration, at: changedAt.addingTimeInterval(1)
        )
        XCTAssertFalse(replay.membershipChanged)
        XCTAssertTrue(replay.restoredScriptIDs.isEmpty)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let library = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: setup.1))
            XCTAssertEqual(Array(library.userScriptIDs), [setup.0.scriptID])
            let mutation = realm.object(ofType: BigSyncPendingMutation.self,
                                        forPrimaryKey: library.objectSchema.className + "." + setup.1.uuidString)
            XCTAssertEqual(mutation?.changedAt, changedAt)
        }()
    }

    func testDisablingAnAlreadyArchivedScriptDoesNotDeleteOrRejournalIt() async throws {
        let configuration = makeConfiguration()
        let setup = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let script = UserScript()
            script.isArchived = true
            let libraryConfiguration = LibraryConfiguration()
            libraryConfiguration.userScriptIDs.append(script.id)
            try realm.write {
                realm.add([script, libraryConfiguration])
            }
            return (
                LibraryUserScriptTarget(scriptID: script.id, createdAt: script.createdAt),
                libraryConfiguration.id,
                libraryConfiguration.createdAt
            )
        }()

        let result = try await LibraryUserScriptLifecycleCommand.setEnabled(
            false,
            target: setup.0,
            configurationID: setup.1,
            configurationCreatedAt: setup.2,
            realmConfiguration: configuration,
            at: Date(timeIntervalSinceReferenceDate: 90_015)
        )

        XCTAssertTrue(result.archivedScriptIDs.isEmpty)
        XCTAssertTrue(result.deletedScriptIDs.isEmpty)
        XCTAssertTrue(result.restoredScriptIDs.isEmpty)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let script = try XCTUnwrap(
                realm.object(ofType: UserScript.self, forPrimaryKey: setup.0.scriptID)
            )
            XCTAssertTrue(script.isArchived)
            XCTAssertFalse(script.isDeleted)
            let pending = realm.objects(BigSyncPendingMutation.self)
            XCTAssertTrue(pending.isEmpty)
        }()
    }

    @MainActor
    func testEnabledEditUsesCapturedMembershipOwnerInsteadOfTheFirstConfiguration() async throws {
        let configuration = makeConfiguration()
        let setup = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let script = UserScript()
            let unrelated = LibraryConfiguration()
            unrelated.createdAt = Date(timeIntervalSinceReferenceDate: 1)
            let owner = LibraryConfiguration()
            owner.createdAt = Date(timeIntervalSinceReferenceDate: 2)
            owner.userScriptIDs.append(script.id)
            try realm.write { realm.add([script, unrelated, owner]) }
            return (script.id, unrelated.id, owner.id)
        }()
        let realm = try await Realm.open(configuration: configuration)
        let model = LibraryScriptFormSectionsViewModel(realmConfiguration: configuration)
        model.script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: setup.0))
        model.scriptEnabled = false

        await model.finishEditing()

        XCTAssertNil(model.persistenceErrorMessage)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertTrue(realm.object(ofType: UserScript.self, forPrimaryKey: setup.0)?.isArchived == true)
            XCTAssertTrue(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: setup.1)?
                .userScriptIDs.isEmpty == true)
            XCTAssertEqual(Array(try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self,
                                                           forPrimaryKey: setup.2)).userScriptIDs), [setup.0])
        }()
    }

    func testEnabledCommandRejectsRemovedCapturedMembershipWithoutRepairingIt() async throws {
        let configuration = makeConfiguration()
        let setup = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let script = UserScript()
            let library = LibraryConfiguration()
            try realm.write { realm.add([script, library]) }
            return (LibraryUserScriptTarget(scriptID: script.id, createdAt: script.createdAt),
                    library.id, library.createdAt)
        }()
        do {
            _ = try await LibraryUserScriptLifecycleCommand.setEnabled(
                false, target: setup.0, configurationID: setup.1, configurationCreatedAt: setup.2,
                realmConfiguration: configuration, requiringExistingMembership: true
            )
            XCTFail("Removed editor membership must reject the edit")
        } catch RealmBackgroundActorError.unableToResolveObject {
        }
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertFalse(try XCTUnwrap(realm.object(ofType: UserScript.self,
                                                     forPrimaryKey: setup.0.scriptID)).isArchived)
            XCTAssertTrue(try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self,
                                                    forPrimaryKey: setup.1)).userScriptIDs.isEmpty)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }()
    }

    @MainActor
    func testFailedDraftIsNotRetriedWhenTheEditorIsReleased() async throws {
        let configuration = makeConfiguration()
        let target = try await Self.insertScript(in: configuration, deleted: true)
        let realm = try await Realm.open(configuration: configuration)
        let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: target.scriptID))
        var model: LibraryScriptFormSectionsViewModel? = LibraryScriptFormSectionsViewModel(
            realmConfiguration: configuration
        )
        model?.script = script
        model?.scriptTitle = "Rejected draft"
        await model?.finishEditing()
        XCTAssertNotNil(model?.persistenceErrorMessage)

        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let saved = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: target.scriptID))
            try realm.write {
                saved.isDeleted = false
                saved.title = "Newer edit"
                saved.refreshChangeMetadata(explicitlyModified: true)
            }
        }()
        await realm.asyncRefresh()
        let overwritten = expectation(description: "Editor destruction must not retry a failed draft")
        overwritten.isInverted = true
        let token = script.observe { change in
            if case .change = change, script.title == "Rejected draft" { overwritten.fulfill() }
        }
        defer { token.invalidate() }
        model = nil

        await fulfillment(of: [overwritten], timeout: 0.5)
        await realm.asyncRefresh()
        XCTAssertEqual(script.title, "Newer edit")
    }

    @RealmBackgroundActor
    private static func insertScript(
        in configuration: Realm.Configuration,
        deleted: Bool = false
    ) async throws -> LibraryUserScriptEditorTarget {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let script = UserScript()
        script.title = "Persisted"
        script.isDeleted = deleted
        try realm.write { realm.add(script) }
        return LibraryUserScriptEditorTarget(scriptID: script.id, createdAt: script.createdAt)
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self,
                                     Feed.self, UserScript.self, UserScriptAllowedDomain.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }
}
