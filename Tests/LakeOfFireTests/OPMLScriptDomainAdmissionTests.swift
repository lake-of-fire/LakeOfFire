import BigSyncKit
import Foundation
import OPML
import RealmSwift
import RealmSwiftGaps
import SwiftUIDownloads
import XCTest
@testable import LakeOfFireContent

final class OPMLScriptDomainAdmissionTests: XCTestCase {
    @MainActor
    func testIgnoredScriptEntriesNeverAdmitOrModifyScripts() async throws {
        let manager = Self.makeManager()
        try await Self.withFixture { realm, configuration, directory in
            let script = try Self.authorScript(in: realm, domains: ["restricted.example"])
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            let original = Self.snapshot(script: script, in: realm)
            let membership = Array(library.userScriptIDs)
            let journal = Self.generations(in: realm)
            for id in [script.id, UUID()] {
                for domains in [nil, "", "%ZZ", "other.example,%ZZ", "retry%2Eexample"] as [String?] {
                    let url = try Self.writeEntry(
                        id: id, title: "Remote change", source: "void(1);",
                        domains: domains, in: directory
                    )
                    try await manager.importOPML(fileURL: url, realmConfiguration: configuration)
                    XCTAssertEqual(Self.snapshot(script: script, in: realm), original)
                    XCTAssertEqual(Array(library.userScriptIDs), membership)
                    XCTAssertEqual(Self.generations(in: realm), journal)
                    XCTAssertEqual(realm.objects(UserScript.self).count, 1)
                    XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
                }
            }
            let domains = try await Self.webViewDomains(script.freeze())
            XCTAssertEqual(domains, ["restricted.example"])
        }
    }

    @MainActor
    func testManualDomainValidationRejectsMalformedEncodingWithoutMutation() async throws {
        try await Self.withFixture { realm, _, directory in
            let script = try Self.authorScript(in: realm, domains: ["restricted.example"])
            let original = Self.snapshot(script: script, in: realm)
            let journal = Self.generations(in: realm)
            for domains in ["%ZZ", "other.example,%ZZ"] {
                let url = try Self.writeEntry(
                    id: script.id, title: script.title, source: script.script,
                    domains: domains, in: directory
                )
                let opml = try OPML(Data(contentsOf: url))
                let entry = try XCTUnwrap(opml.entries.first)
                XCTAssertThrowsError(try realm.write {
                    try LibraryDataManager.applyScriptDomains(opml: opml, opmlEntry: entry, script: script)
                }) { error in
                    XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile)
                }
                XCTAssertEqual(Self.snapshot(script: script, in: realm), original)
                XCTAssertEqual(Self.generations(in: realm), journal)
            }
            let url = try Self.writeEntry(
                id: script.id, title: script.title, source: script.script,
                domains: "%65xample.org,sub.%65xample.net", in: directory
            )
            let opml = try OPML(Data(contentsOf: url))
            let entry = try XCTUnwrap(opml.entries.first)
            try realm.write {
                try LibraryDataManager.applyScriptDomains(opml: opml, opmlEntry: entry, script: script)
            }
            let domains = try await Self.webViewDomains(script.freeze())
            XCTAssertEqual(domains, ["example.org", "sub.example.net"])
            XCTAssertNotEqual(Self.generations(in: realm)["UserScript.\(script.id)"],
                              journal["UserScript.\(script.id)"])
        }
    }

    @MainActor
    func testAuthoredEmptyDraftsAndUnresolvedDomainsUseRealExecutionAdmission() async throws {
        for domains in [[], ["draft.example"]] as [[String]] {
            try await Self.withFixture { realm, _, _ in
                let script = try Self.authorScript(in: realm, domains: domains)
                try realm.write {
                    script.script = ""
                    script.refreshChangeMetadata(explicitlyModified: true)
                }
                let admitted = try await Self.webViewDomains(script.freeze())
                XCTAssertEqual(admitted, Set(domains))
                let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
                let activeCount = await Self.activeWebViewScriptCount(library.freeze())
                XCTAssertEqual(activeCount, 1)
                // Missing or tombstoned restrictions must never broaden admission.
                let missingID = UUID()
                try realm.write {
                    script.allowedDomainIDs.append(missingID)
                    script.refreshChangeMetadata(explicitlyModified: true)
                }
                let missingCount = await Self.activeWebViewScriptCount(library.freeze())
                XCTAssertEqual(missingCount, 0)
                let deletedDomain = UserScriptAllowedDomain()
                deletedDomain.id = missingID
                deletedDomain.domain = "deleted.example"
                deletedDomain.isDeleted = true
                try realm.write {
                    realm.add(deletedDomain)
                    deletedDomain.refreshChangeMetadata(explicitlyModified: true)
                }
                let deletedCount = await Self.activeWebViewScriptCount(library.freeze())
                XCTAssertEqual(deletedCount, 0)
            }
        }
    }

    @MainActor
    func testDuplicateDomainLinksRequireEveryDeclaredDomainToBeLive() async throws {
        try await Self.withFixture { realm, _, _ in
            let script = try Self.authorScript(in: realm, domains: ["restricted.example"])
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            let domainID = try XCTUnwrap(script.allowedDomainIDs.first)
            try realm.write {
                script.allowedDomainIDs.append(domainID)
                script.refreshChangeMetadata(explicitlyModified: true)
            }
            XCTAssertEqual(Array(script.allowedDomainIDs), [domainID, domainID])
            let duplicateDomains = try await Self.webViewDomains(script.freeze())
            XCTAssertEqual(duplicateDomains, ["restricted.example"])
            let duplicateCount = await Self.activeWebViewScriptCount(library.freeze())
            XCTAssertEqual(duplicateCount, 1)

            let missingID = UUID()
            try realm.write {
                script.allowedDomainIDs.append(missingID)
                script.refreshChangeMetadata(explicitlyModified: true)
            }
            let missingScript = script.freeze()
            let missingAdmitted = await MainActor.run { missingScript.getWebViewUserScript() != nil }
            XCTAssertFalse(missingAdmitted)
            let missingCount = await Self.activeWebViewScriptCount(library.freeze())
            XCTAssertEqual(missingCount, 0)

            let domain = UserScriptAllowedDomain()
            domain.id = missingID
            domain.domain = "second.example"
            domain.isDeleted = true
            try realm.write {
                realm.add(domain)
                domain.refreshChangeMetadata(explicitlyModified: true)
            }
            let tombstonedScript = script.freeze()
            let tombstonedAdmitted = await MainActor.run { tombstonedScript.getWebViewUserScript() != nil }
            XCTAssertFalse(tombstonedAdmitted)
            let tombstonedCount = await Self.activeWebViewScriptCount(library.freeze())
            XCTAssertEqual(tombstonedCount, 0)

            try realm.write {
                domain.isDeleted = false
                domain.refreshChangeMetadata(explicitlyModified: true)
            }
            XCTAssertEqual(Array(script.allowedDomainIDs), [domainID, domainID, missingID])
            let recoveredDomains = try await Self.webViewDomains(script.freeze())
            XCTAssertEqual(recoveredDomains, ["restricted.example", "second.example"])
            let recoveredCount = await Self.activeWebViewScriptCount(library.freeze())
            XCTAssertEqual(recoveredCount, 1)
        }
    }

    @MainActor
    func testManagedRefreshPreservesScriptsWhileReconcilingFeedsAndCategories() async throws {
        let manager = Self.makeManager()
        try await Self.withFixture { realm, configuration, directory in
            let source = URL(string: "https://example.invalid/catalog.opml")!
            let fileURL = directory.appendingPathComponent("refresh.opml")
            let download = Downloadable(url: source, name: "Catalog", localDestination: fileURL)
            let script = try Self.authorScript(in: realm, domains: ["restricted.example"])
            let deleted = UserScript()
            deleted.isDeleted = true
            let category = FeedCategory()
            category.title = "Original category"
            category.opmlURL = source
            let feed = Feed()
            feed.title = "Original feed"
            feed.categoryID = category.id
            feed.rssUrl = URL(string: "https://example.invalid/original.xml")!
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            try realm.write {
                script.opmlURL = source
                script.opmlOwnerName = "Original owner"
                script.injectAtStart = false
                script.mainFrameOnly = false
                script.sandboxed = true
                script.previewURL = URL(string: "https://restricted.example/preview")
                script.refreshChangeMetadata(explicitlyModified: true)
                deleted.opmlURL = source
                realm.add([deleted, category, feed])
                deleted.refreshChangeMetadata(explicitlyModified: true)
                category.refreshChangeMetadata(explicitlyModified: true)
                feed.refreshChangeMetadata(explicitlyModified: true)
                library.categoryIDs.append(category.id)
                library.refreshChangeMetadata(explicitlyModified: true)
            }
            let original = Self.snapshot(script: script, in: realm)
            let deletedOriginal = Self.snapshot(script: deleted, in: realm)
            let membership = Array(library.userScriptIDs)
            let journal = Self.generations(in: realm).filter {
                $0.key.hasPrefix("UserScript.") || $0.key.hasPrefix("UserScriptAllowedDomain.")
            }
            XCTAssertEqual(journal.count, 3, "Both scripts and the restriction must have real pending mutations")
            let originalFeedGeneration = try XCTUnwrap(Self.generations(in: realm)["Feed.\(feed.id)"])
            var previousGenerations = [String: String]()
            let hiddenCategoryID = UUID()
            let hiddenFeedID = UUID()
            let newScriptID = UUID()
            let remoteScripts = """
              <outline text="Remote change" uuid="\(script.id)" script="void(1);" allowedDomains="%ZZ"/>
              <outline text="Scripts" isUserScriptList="true">
                <outline text="New script" uuid="\(newScriptID)" script="void(2);"/>
                <outline text="Hidden category" uuid="\(hiddenCategoryID)">
                  <outline text="Hidden feed" uuid="\(hiddenFeedID)" xmlUrl="https://example.invalid/hidden.xml"/>
                </outline>
              </outline>
            """
            for (index, scripts) in [remoteScripts, "", remoteScripts].enumerated() {
                let feedEntries = index == 0 ? "<outline text=\"Updated feed\" uuid=\"\(feed.id)\" xmlUrl=\"\(feed.rssUrl.absoluteString)\"/>" : ""
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <opml version="2.0"><head/><body>
                  <outline text="Updated category" uuid="\(category.id)">\(feedEntries)</outline>
                  \(scripts)
                </body></opml>
                """
                try xml.write(to: fileURL, atomically: true, encoding: .utf8)
                try await manager.importOPML(fileURL: fileURL, fromDownload: download, realmConfiguration: configuration)
                XCTAssertEqual(Self.snapshot(script: script, in: realm), original)
                XCTAssertEqual(Self.snapshot(script: deleted, in: realm), deletedOriginal)
                XCTAssertEqual(Array(library.userScriptIDs), membership)
                XCTAssertEqual(Self.generations(in: realm).filter {
                    $0.key.hasPrefix("UserScript.") || $0.key.hasPrefix("UserScriptAllowedDomain.")
                }, journal)
                XCTAssertEqual(category.title, "Updated category")
                XCTAssertFalse(category.isDeleted)
                XCTAssertEqual(feed.isDeleted, index != 0)
                XCTAssertEqual(feed.title, "Updated feed")
                XCTAssertNotEqual(Self.generations(in: realm)["Feed.\(feed.id)"], originalFeedGeneration)
                XCTAssertEqual(feed.categoryID, category.id)
                XCTAssertEqual(Array(library.categoryIDs), [category.id])
                if index == 2 {
                    XCTAssertEqual(Self.generations(in: realm), previousGenerations,
                                   "Repeated refresh must not create any new journal generations")
                }
                previousGenerations = Self.generations(in: realm)
                XCTAssertNil(realm.object(ofType: UserScript.self, forPrimaryKey: newScriptID))
                XCTAssertNil(realm.object(ofType: FeedCategory.self, forPrimaryKey: hiddenCategoryID))
                XCTAssertNil(realm.object(ofType: Feed.self, forPrimaryKey: hiddenFeedID))
                let activeCount = await Self.activeWebViewScriptCount(library.freeze())
                XCTAssertEqual(activeCount, 0, "Persisted OPML-origin scripts cannot execute")
            }
            let categoryGeneration = try XCTUnwrap(Self.generations(in: realm)["FeedCategory.\(category.id)"])
            try "<opml version=\"2.0\"><head/><body/></opml>".write(to: fileURL, atomically: true, encoding: .utf8)
            try await manager.importOPML(fileURL: fileURL, fromDownload: download, realmConfiguration: configuration)
            XCTAssertTrue(category.isDeleted)
            XCTAssertNotEqual(Self.generations(in: realm)["FeedCategory.\(category.id)"], categoryGeneration)
            XCTAssertEqual(Self.snapshot(script: script, in: realm), original)
            XCTAssertEqual(Self.snapshot(script: deleted, in: realm), deletedOriginal)
            XCTAssertEqual(Array(library.userScriptIDs), membership)
            XCTAssertEqual(Self.generations(in: realm).filter {
                $0.key.hasPrefix("UserScript.") || $0.key.hasPrefix("UserScriptAllowedDomain.")
            }, journal)
        }
    }

    @RealmBackgroundActor
    private static func authorScript(in realm: Realm, domains: [String]) throws -> UserScript {
        let script = UserScript()
        script.title = "Authored script"
        script.script = "void(0);"
        let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
        try realm.write {
            realm.add(script)
            for name in domains {
                let domain = UserScriptAllowedDomain()
                domain.domain = name
                realm.add(domain)
                domain.refreshChangeMetadata(explicitlyModified: true)
                script.allowedDomainIDs.append(domain.id)
            }
            script.refreshChangeMetadata(explicitlyModified: true)
            library.userScriptIDs.append(script.id)
            library.refreshChangeMetadata(explicitlyModified: true)
        }
        return script
    }

    // Keep Realm fixture reads on their owning actor and construct WebKit
    // descriptors on MainActor, as the production browser does. Frozen values
    // retain the original fixture snapshot across that boundary.
    @MainActor
    private static func webViewDomains(_ script: UserScript) throws -> Set<String> {
        try XCTUnwrap(script.getWebViewUserScript()).allowedDomains
    }

    @MainActor
    private static func activeWebViewScriptCount(_ library: LibraryConfiguration) -> Int? {
        library.getActiveWebViewUserScripts()?.count
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
            BigSyncPendingMutation.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            let trash = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".Trash", isDirectory: true)
            try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(
                at: directory,
                to: trash.appendingPathComponent("opml-script-tests-\(directory.lastPathComponent)")
            )
        }

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
        let injectAtStart: Bool
        let mainFrameOnly: Bool
        let sandboxed: Bool
        let previewURL: URL?
        let opmlURL: URL?
        let opmlOwnerName: String?
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
            injectAtStart: script.injectAtStart,
            mainFrameOnly: script.mainFrameOnly,
            sandboxed: script.sandboxed,
            previewURL: script.previewURL,
            opmlURL: script.opmlURL,
            opmlOwnerName: script.opmlOwnerName,
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
