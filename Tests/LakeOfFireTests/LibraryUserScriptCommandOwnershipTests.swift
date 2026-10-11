import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@RealmBackgroundActor
final class LibraryUserScriptCommandOwnershipTests: XCTestCase {
    func testFieldCommandUsesItsCapturedRealmAndSuppressesEqualReplay() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let target = LibraryUserScriptEditorTarget(
            scriptID: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: 96_000)
        )
        let realmA = try await insertScript(target, title: "A", configuration: configurationA)
        let realmB = try await insertScript(target, title: "B", configuration: configurationB)
        let timestamp = Date(timeIntervalSinceReferenceDate: 96_010)

        let changed = try await LibraryUserScriptEditorFieldCommand.perform(
            .title("Saved in A"), target: target, configuration: configurationA, at: timestamp
        )
        XCTAssertEqual(changed, .changed(changedAt: timestamp))
        let generation = try XCTUnwrap(journal(scriptID: target.scriptID, in: realmA)?.generation)
        let unchanged = try await LibraryUserScriptEditorFieldCommand.perform(
            .title("Saved in A"), target: target, configuration: configurationA, at: timestamp.addingTimeInterval(1)
        )
        XCTAssertEqual(unchanged, .unchanged)
        XCTAssertEqual(journal(scriptID: target.scriptID, in: realmA)?.generation, generation)
        XCTAssertEqual(journal(scriptID: target.scriptID, in: realmA)?.changedAt, timestamp)
        XCTAssertEqual(realmA.object(ofType: UserScript.self, forPrimaryKey: target.scriptID)?.title, "Saved in A")
        XCTAssertEqual(realmB.object(ofType: UserScript.self, forPrimaryKey: target.scriptID)?.title, "B")
        XCTAssertTrue(realmB.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testDomainFieldRejectsRemovedMembershipWithoutChangingItsJournal() async throws {
        let configuration = makeConfiguration()
        let target = LibraryUserScriptEditorTarget(scriptID: UUID(), createdAt: Date())
        let realm = try await insertScript(target, title: "Owner", configuration: configuration)
        let added = try await LibraryUserScriptAllowedDomainMembershipCommand.addEmptyDomain(
            to: target, configuration: configuration
        )
        let domainTarget = try XCTUnwrap(added.1)
        let saved = try await LibraryUserScriptAllowedDomainFieldCommand.setDomain(
            "original.example", target: domainTarget, from: target, configuration: configuration
        )
        guard case .changed = saved else { return XCTFail("Initial domain edit must commit") }
        let domain = try XCTUnwrap(
            realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainTarget.domainID)
        )
        let mutationID = UserScriptAllowedDomain.className() + "." + domainTarget.domainID.uuidString
        let generation = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: mutationID
        )?.generation)
        let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: target.scriptID))
        try await realm.asyncWrite {
            script.allowedDomainIDs.removeAll()
            script.refreshChangeMetadata(explicitlyModified: true)
        }

        let result = try await LibraryUserScriptAllowedDomainFieldCommand.setDomain(
            "stale.example", target: domainTarget, from: target, configuration: configuration
        )

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(domain.domain, "original.example")
        XCTAssertEqual(realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: mutationID)?.generation,
                       generation)
    }

    func testDomainBatchRejectsAReplacedMemberBeforeAnyMutation() async throws {
        let configuration = makeConfiguration()
        let target = LibraryUserScriptEditorTarget(scriptID: UUID(), createdAt: Date())
        let realm = try await insertScript(target, title: "Owner", configuration: configuration)
        let first = try await LibraryUserScriptAllowedDomainMembershipCommand.addEmptyDomain(
            to: target, configuration: configuration
        )
        let second = try await LibraryUserScriptAllowedDomainMembershipCommand.addEmptyDomain(
            to: target, configuration: configuration
        )
        let firstTarget = try XCTUnwrap(first.1)
        let secondTarget = try XCTUnwrap(second.1)
        let staleSecond = LibraryUserScriptAllowedDomainTarget(
            domainID: secondTarget.domainID, createdAt: secondTarget.createdAt.addingTimeInterval(-1)
        )
        let generation = try XCTUnwrap(journal(scriptID: target.scriptID, in: realm)?.generation)

        let result = try await LibraryUserScriptAllowedDomainMembershipCommand.deleteDomains(
            [firstTarget, staleSecond], from: target, configuration: configuration
        )

        XCTAssertEqual(result, .superseded)
        let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: target.scriptID))
        XCTAssertEqual(Array(script.allowedDomainIDs), [firstTarget.domainID, secondTarget.domainID])
        XCTAssertFalse(try XCTUnwrap(realm.object(
            ofType: UserScriptAllowedDomain.self, forPrimaryKey: firstTarget.domainID
        )).isDeleted)
        XCTAssertFalse(try XCTUnwrap(realm.object(
            ofType: UserScriptAllowedDomain.self, forPrimaryKey: secondTarget.domainID
        )).isDeleted)
        XCTAssertEqual(journal(scriptID: target.scriptID, in: realm)?.generation, generation)
    }

    private func insertScript(
        _ target: LibraryUserScriptEditorTarget,
        title: String,
        configuration: Realm.Configuration
    ) async throws -> Realm {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let script = UserScript()
        script.id = target.scriptID
        script.createdAt = target.createdAt
        script.title = title
        try await realm.asyncWrite { realm.add(script) }
        return realm
    }

    private func journal(scriptID: UUID, in realm: Realm) -> BigSyncPendingMutation? {
        realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: UserScript.className() + "." + scriptID.uuidString)
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [UserScript.self, UserScriptAllowedDomain.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        return configuration
    }
}
