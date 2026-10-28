import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class OPMLScriptDomainAdmissionTests: XCTestCase {
    @MainActor
    func testMalformedDomainsPreserveExistingScriptAndRestrictions() async throws {
        let manager = Self.makeManager()
        try await Self.withFixture { realm, configuration, directory in
            let id = UUID()
            let validURL = try Self.writeEntry(
                id: id, title: "Restricted", source: "void(0);",
                domains: "restricted.example", in: directory
            )
            try await manager.importOPML(fileURL: validURL, realmConfiguration: configuration)
            let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: id))
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            let original = Self.snapshot(script: script, in: realm)
            let originalMembership = Array(library.userScriptIDs)
            let originalJournal = Self.generations(in: realm)

            for domains in ["%ZZ", "other.example,%ZZ"] {
                let invalidURL = try Self.writeEntry(
                    id: id, title: "Changed", source: "void(1);",
                    domains: domains, in: directory
                )
                try await Self.assertRejected(
                    manager: manager, fileURL: invalidURL, configuration: configuration
                )
                XCTAssertEqual(Self.snapshot(script: script, in: realm), original)
                XCTAssertEqual(Array(library.userScriptIDs), originalMembership)
                XCTAssertEqual(Self.generations(in: realm), originalJournal)
                XCTAssertEqual(realm.objects(UserScript.self).count, 1)
                XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
                let descriptor = try XCTUnwrap(script.getWebViewUserScript())
                XCTAssertEqual(descriptor.allowedDomains, ["restricted.example"])
            }
        }
    }

    @MainActor
    func testMalformedDomainsRejectNewScriptsAndValidRetryRemainsPossible() async throws {
        let manager = Self.makeManager()
        try await Self.withFixture { realm, configuration, directory in
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            let originalJournal = Self.generations(in: realm)
            let retryID = UUID()
            for (id, domains) in [(retryID, "%ZZ"), (UUID(), "example.org,%ZZ")] {
                let invalidURL = try Self.writeEntry(
                    id: id, title: "Rejected", source: "void(1);",
                    domains: domains, in: directory
                )
                try await Self.assertRejected(
                    manager: manager, fileURL: invalidURL, configuration: configuration
                )
                XCTAssertNil(realm.object(ofType: UserScript.self, forPrimaryKey: id))
                XCTAssertTrue(library.userScriptIDs.isEmpty)
                XCTAssertEqual(realm.objects(UserScript.self).count, 0)
                XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 0)
                XCTAssertEqual(Self.generations(in: realm), originalJournal)
                XCTAssertTrue(library.getActiveWebViewUserScripts()?.isEmpty == true)
            }

            let retryURL = try Self.writeEntry(
                id: retryID, title: "Restricted retry", source: "void(0);",
                domains: "retry%2Eexample", in: directory
            )
            try await manager.importOPML(fileURL: retryURL, realmConfiguration: configuration)
            let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: retryID))
            let descriptor = try XCTUnwrap(script.getWebViewUserScript())
            XCTAssertEqual(script.title, "Restricted retry")
            XCTAssertFalse(script.isArchived)
            XCTAssertEqual(descriptor.allowedDomains, ["retry.example"])
            XCTAssertEqual(Array(library.userScriptIDs), [retryID])
            XCTAssertEqual(realm.objects(UserScript.self).count, 1)
            XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
        }
    }

    @MainActor
    func testValidPercentEncodedDomainsRemainRestrictedAfterImport() async throws {
        let manager = Self.makeManager()
        try await Self.withFixture { realm, configuration, directory in
            let id = UUID()
            let url = try Self.writeEntry(
                id: id, title: "Encoded restrictions", source: "void(0);",
                domains: "%65xample.org,sub.%65xample.net", in: directory
            )
            try await manager.importOPML(fileURL: url, realmConfiguration: configuration)
            let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: id))
            let descriptor = try XCTUnwrap(script.getWebViewUserScript())
            XCTAssertEqual(descriptor.allowedDomains, ["example.org", "sub.example.net"])
            XCTAssertEqual(script.allowedDomainIDs.count, 2)
            XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 2)
            XCTAssertFalse(script.isArchived)
        }
    }

    @MainActor
    func testEmptyDraftScriptsPreserveAbsentEmptyAndExplicitDomainPolicy() async throws {
        let manager = Self.makeManager()
        let policies: [(String?, Set<String>)] = [
            (nil, []),
            ("", []),
            ("draft.example", ["draft.example"]),
        ]
        for (domains, expectedDomains) in policies {
            try await Self.withFixture { realm, configuration, directory in
                let id = UUID()
                let url = try Self.writeEntry(
                    id: id, title: "Empty draft", source: "",
                    domains: domains, in: directory
                )
                try await manager.importOPML(fileURL: url, realmConfiguration: configuration)
                let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: id))
                let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
                XCTAssertEqual(script.title, "Empty draft")
                XCTAssertEqual(script.script, "")
                XCTAssertFalse(script.isDeleted)
                XCTAssertFalse(script.isArchived)
                XCTAssertEqual(Array(library.userScriptIDs), [id])
                XCTAssertEqual(Set(try XCTUnwrap(script.getAllowedDomains()).map(\.domain)), expectedDomains)
                XCTAssertEqual(script.allowedDomainIDs.count, expectedDomains.count)
                XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).where { !$0.isDeleted }.count,
                               expectedDomains.count)
                let webViewScript = try XCTUnwrap(script.getWebViewUserScript())
                XCTAssertEqual(webViewScript.allowedDomains, expectedDomains)
                XCTAssertEqual(try XCTUnwrap(library.getActiveWebViewUserScripts()).count, 1)
            }
        }
    }

    @MainActor
    private static func makeManager() -> LibraryDataManager {
        // Imports pass their private fixture store; neither observer may attach
        // to process-global configuration during fixture construction.
        return LibraryDataManager(observesChanges: false)
    }

    @RealmBackgroundActor
    private static func withFixture(
        _ body: @RealmBackgroundActor (Realm, Realm.Configuration, URL) async throws -> Void
    ) async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self,
            FeedCategory.self,
            Feed.self,
            FeedDirectory.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await LibraryConfiguration.getConsolidatedOrCreate(
                realmConfiguration: configuration
            )
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await body(realm, configuration, directory)
        } catch {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            throw error
        }
        let removed = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        XCTAssertTrue(removed)
        let remaining = await RealmBackgroundActor.shared.existingCachedRealm(for: configuration)
        XCTAssertNil(remaining, "Release only the quiesced fixture's cached Realm.")
    }

    @RealmBackgroundActor
    private static func assertRejected(
        manager: LibraryDataManager,
        fileURL: URL,
        configuration: Realm.Configuration
    ) async throws {
        do {
            try await manager.importOPML(fileURL: fileURL, realmConfiguration: configuration)
            XCTFail("Malformed domain encoding must reject the whole script entry")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadCorruptFile)
        }
    }

    @RealmBackgroundActor
    private static func writeEntry(
        id: UUID,
        title: String,
        source: String,
        domains: String?,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("opml")
        let domainAttribute = domains.map { "allowedDomains=\"\($0)\"" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head><title>Domain admission</title></head><body>
            <outline text="\(title)" uuid="\(id.uuidString)" script="\(source)"
                     \(domainAttribute) isArchived="false" />
        </body></opml>
        """
        try Data(xml.utf8).write(to: url)
        return url
    }

    private struct ScriptSnapshot: Equatable {
        let title: String
        let source: String
        let isArchived: Bool
        let isDeleted: Bool
        let createdAt: Date
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
        let allowedDomainIDs: [UUID]
        let domains: [DomainSnapshot]
    }

    private struct DomainSnapshot: Equatable {
        let id: UUID
        let domain: String
        let isDeleted: Bool
        let createdAt: Date
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    @RealmBackgroundActor
    private static func snapshot(script: UserScript, in realm: Realm) -> ScriptSnapshot {
        ScriptSnapshot(
            title: script.title,
            source: script.script,
            isArchived: script.isArchived,
            isDeleted: script.isDeleted,
            createdAt: script.createdAt,
            modifiedAt: script.modifiedAt,
            explicitlyModifiedAt: script.explicitlyModifiedAt,
            allowedDomainIDs: Array(script.allowedDomainIDs),
            domains: realm.objects(UserScriptAllowedDomain.self).map {
                DomainSnapshot(
                    id: $0.id, domain: $0.domain, isDeleted: $0.isDeleted,
                    createdAt: $0.createdAt, modifiedAt: $0.modifiedAt,
                    explicitlyModifiedAt: $0.explicitlyModifiedAt
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    @RealmBackgroundActor
    private static func generations(in realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }
}
