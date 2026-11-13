import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LibraryCapturedMutationPortTests: XCTestCase {
    func testManagerAddAndDuplicateStayInRealmCapturedAtInitialization() async throws {
        let previousLibrary = LibraryDataManager.realmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            LibraryDataManager.realmConfiguration = previousLibrary
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }

        let captured = makeConfiguration()
        let replacement = makeConfiguration()
        LibraryDataManager.realmConfiguration = captured
        ReaderContentLoader.feedEntryRealmConfiguration = captured
        let manager = LibraryManagerViewModel(observesRealm: false)

        LibraryDataManager.realmConfiguration = replacement
        ReaderContentLoader.feedEntryRealmConfiguration = replacement

        let rssURL = URL(string: "https://example.org/captured.xml")!
        try await manager.add(rssURL: rssURL, title: "Captured feed")
        let first = try XCTUnwrap(manager.selectedFeed)
        XCTAssertEqual(first.rssUrl, rssURL)
        let categoryID = try XCTUnwrap(first.categoryID)

        let capturedRealm = try await Realm.open(configuration: captured)
        capturedRealm.autorefresh = false
        defer { capturedRealm.autorefresh = true }
        let category = try XCTUnwrap(
            capturedRealm.object(
                ofType: FeedCategory.self,
                forPrimaryKey: categoryID
            )
        )
        let firstID = first.id

        let categoryReference = ThreadSafeReference(to: category)
        try await manager.duplicate(
            feed: ThreadSafeReference(to: first),
            inCategory: categoryReference,
            overwriteExisting: false
        )
        XCTAssertTrue(categoryReference.isInvalidated,
                      "The writer consumes the one-shot category reference")
        XCTAssertEqual(manager.navigationPath.count, 1)
        let duplicate = try XCTUnwrap(manager.selectedFeed)
        XCTAssertNotEqual(duplicate.id, firstID)
        XCTAssertEqual(duplicate.categoryID, categoryID)
        XCTAssertEqual(duplicate.rssUrl, rssURL)

        let counts = try await Task { @RealmBackgroundActor in
            let capturedRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: captured
            )
            let replacementRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: replacement
            )
            return (
                capturedRealm.objects(LibraryConfiguration.self).count,
                capturedRealm.objects(FeedCategory.self).count,
                capturedRealm.objects(Feed.self).count,
                replacementRealm.objects(LibraryConfiguration.self).count,
                replacementRealm.objects(FeedCategory.self).count,
                replacementRealm.objects(Feed.self).count
            )
        }.value
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 2)
        XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(counts.4, 0)
        XCTAssertEqual(counts.5, 0)
    }

    func testExplicitScriptCreationUsesSuppliedRealmAfterGlobalReplacement() async throws {
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }

        let captured = makeConfiguration()
        let replacement = makeConfiguration()
        LibraryDataManager.realmConfiguration = replacement

        let scriptID = try await Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.createEmptyScript(
                addToLibrary: true,
                realmConfiguration: captured
            )
        }.value

        let result = try await Task { @RealmBackgroundActor in
            let capturedRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: captured
            )
            let replacementRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: replacement
            )
            let library = try XCTUnwrap(
                capturedRealm.objects(LibraryConfiguration.self).first
            )
            return (
                capturedRealm.object(
                    ofType: UserScript.self,
                    forPrimaryKey: scriptID
                ) != nil,
                library.userScriptIDs.contains(scriptID),
                replacementRealm.objects(UserScript.self).count,
                replacementRealm.objects(LibraryConfiguration.self).count
            )
        }.value
        XCTAssertTrue(result.0)
        XCTAssertTrue(result.1)
        XCTAssertEqual(result.2, 0)
        XCTAssertEqual(result.3, 0)
    }


    func testOPMLImportAppendsAllScriptsWithoutDuplicatingExistingReferences() async throws {
        let configuration = makeConfiguration()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = UUID()
        let secondID = UUID()
        let url = directory.appendingPathComponent("scripts.opml")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head><title>Imported scripts</title></head><body>
          <outline text="First" uuid="\(firstID.uuidString)" script="void(0);" allowedDomains="example.org,example.org,%65xample.org" />
          <outline text="Second" uuid="\(secondID.uuidString)" script="void(1);" isArchived="invalid" />
        </body></opml>
        """
        try Data(xml.utf8).write(to: url)
        try await Task { @RealmBackgroundActor in
            let existingID = try await LibraryDataManager.shared.createEmptyScript(
                addToLibrary: true, realmConfiguration: configuration
            )
            try await LibraryDataManager.shared.importOPML(
                fileURL: url, realmConfiguration: configuration
            )
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            XCTAssertEqual(Array(library.userScriptIDs), [existingID, firstID, secondID],
                           "Unrelated references must not suppress new imported scripts")
            XCTAssertEqual(realm.objects(UserScript.self).count, 3)
            XCTAssertEqual(library.getUserScripts()?.count, 3)
            let firstImported = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: firstID))
            XCTAssertEqual(firstImported.getAllowedDomains()?.map(\.domain), ["example.org"])
            XCTAssertEqual(firstImported.allowedDomainIDs.count, 1)
            XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
            XCTAssertTrue(try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: firstID)).isArchived,
                          "An omitted archive flag retains the importer's disabled default")
            XCTAssertTrue(try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: secondID)).isArchived,
                          "An invalid archive flag must not silently enable the imported script")

            try await LibraryDataManager.shared.importOPML(
                fileURL: url, realmConfiguration: configuration
            )
            XCTAssertEqual(Array(library.userScriptIDs), [existingID, firstID, secondID])
            XCTAssertEqual(realm.objects(UserScript.self).count, 3)
            XCTAssertEqual(firstImported.allowedDomainIDs.count, 1)
            XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
        }.value
    }


    func testOPMLRoundTripPreservesDisabledScriptsAndRepeatedImportIsStable() async throws {
        let sourceConfiguration = makeConfiguration()
        let destinationConfiguration = makeConfiguration()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("round-trip.opml")
        let disabledSource = #"const escaped = "%20";"#
        let enabledSource = #"const label = "100% 日本"; const remainder = 5 % 2;"#

        try await Task { @RealmBackgroundActor in
            let disabledID = try await LibraryDataManager.shared.createEmptyScript(
                addToLibrary: true, realmConfiguration: sourceConfiguration
            )
            let enabledID = try await LibraryDataManager.shared.createEmptyScript(
                addToLibrary: true, realmConfiguration: sourceConfiguration
            )
            let sourceRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: sourceConfiguration
            )
            let disabled = try XCTUnwrap(sourceRealm.object(ofType: UserScript.self, forPrimaryKey: disabledID))
            let enabled = try XCTUnwrap(sourceRealm.object(ofType: UserScript.self, forPrimaryKey: enabledID))
            try await sourceRealm.asyncWrite {
                disabled.title = "Disabled"
                disabled.script = disabledSource
                disabled.isArchived = true
                enabled.title = "Enabled"
                enabled.script = enabledSource
                enabled.isArchived = false
            }
            let exported = try await LibraryDataManager.shared.exportUserOPML(
                realmConfiguration: sourceConfiguration
            )
            try Data(exported.xml.utf8).write(to: url)
            try await LibraryDataManager.shared.importOPML(
                fileURL: url, realmConfiguration: destinationConfiguration
            )
            let destinationRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: destinationConfiguration
            )
            let importedDisabled = try XCTUnwrap(destinationRealm.object(ofType: UserScript.self, forPrimaryKey: disabledID))
            let importedEnabled = try XCTUnwrap(destinationRealm.object(ofType: UserScript.self, forPrimaryKey: enabledID))
            XCTAssertTrue(importedDisabled.isArchived)
            XCTAssertFalse(importedEnabled.isArchived)
            XCTAssertEqual(Data(importedDisabled.script.utf8), Data(disabledSource.utf8))
            XCTAssertEqual(Data(importedEnabled.script.utf8), Data(enabledSource.utf8))
            let modifiedAt = importedDisabled.modifiedAt
            let library = try XCTUnwrap(destinationRealm.objects(LibraryConfiguration.self).first)
            XCTAssertEqual(Set(library.userScriptIDs), Set([disabledID, enabledID]))

            try await LibraryDataManager.shared.importOPML(
                fileURL: url, realmConfiguration: destinationConfiguration
            )
            XCTAssertTrue(importedDisabled.isArchived)
            XCTAssertFalse(importedEnabled.isArchived)
            XCTAssertEqual(Data(importedDisabled.script.utf8), Data(disabledSource.utf8))
            XCTAssertEqual(Data(importedEnabled.script.utf8), Data(enabledSource.utf8))
            XCTAssertEqual(importedDisabled.modifiedAt, modifiedAt,
                           "Reimporting an unchanged disabled script must not journal it again")
            XCTAssertEqual(destinationRealm.objects(UserScript.self).count, 2)
        }.value
    }


    func testMalformedImportedDomainsCannotRemoveRestrictionsOrCreateUnrestrictedScript() async throws {
        let configuration = makeConfiguration()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingID = UUID()
        let newID = UUID()
        let validURL = directory.appendingPathComponent("valid.opml")
        let validXML = """
        <opml version="2.0"><head><title>Scripts</title></head><body>
          <outline text="Restricted" uuid="\(existingID.uuidString)" script="void(0);"
                   allowedDomains="example.org" isArchived="false" />
        </body></opml>
        """
        try Data(validXML.utf8).write(to: validURL)
        let malformed = ["%ZZ", "%", " ", ",", ",,,", ",example.org", "example.org,",
                         "example.org,,other.org", "%20", "%09%0A", "example.org,%20"]
        let invalidURLs = try [existingID, newID].flatMap { id in
            try malformed.enumerated().map { index, domains in
                let url = directory.appendingPathComponent("\(id.uuidString)-\(index).opml")
                let xml = """
                <opml version="2.0"><head><title>Scripts</title></head><body>
                  <outline text="Changed" uuid="\(id.uuidString)" script="void(1);"
                           allowedDomains="\(domains)" isArchived="false" />
                </body></opml>
                """
                try Data(xml.utf8).write(to: url)
                return url
            }
        }
        try await Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.importOPML(
                fileURL: validURL, realmConfiguration: configuration
            )
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let existing = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: existingID))
            let originalModifiedAt = existing.modifiedAt
            let originalDomainIDs = Array(existing.allowedDomainIDs)
            let domain = try XCTUnwrap(existing.getAllowedDomains()?.first)
            let originalDomainModifiedAt = domain.modifiedAt
            let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            let originalScriptIDs = Array(library.userScriptIDs)
            let originalLibraryModifiedAt = library.modifiedAt
            let originalJournal = try capturedImportJournalSnapshot(realm)
            for url in invalidURLs {
                do {
                    try await LibraryDataManager.shared.importOPML(
                        fileURL: url, realmConfiguration: configuration
                    )
                    XCTFail("Malformed domain encoding must reject the imported script")
                } catch let error as CocoaError {
                    XCTAssertEqual(error.code, .fileReadCorruptFile)
                }
                XCTAssertEqual(existing.title, "Restricted")
                XCTAssertEqual(existing.script, "void(0);")
                XCTAssertFalse(existing.isArchived)
                XCTAssertEqual(existing.getAllowedDomains()?.map(\.domain), ["example.org"])
                XCTAssertEqual(existing.modifiedAt, originalModifiedAt)
                XCTAssertEqual(Array(existing.allowedDomainIDs), originalDomainIDs)
                XCTAssertFalse(domain.isDeleted)
                XCTAssertEqual(domain.modifiedAt, originalDomainModifiedAt)
                XCTAssertEqual(Array(library.userScriptIDs), originalScriptIDs)
                XCTAssertEqual(library.modifiedAt, originalLibraryModifiedAt)
                XCTAssertEqual(try capturedImportJournalSnapshot(realm), originalJournal)
                XCTAssertNil(realm.object(ofType: UserScript.self, forPrimaryKey: newID))
                XCTAssertEqual(realm.objects(UserScript.self).count, 1)
                XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
            }
        }.value
    }

    func testImportedDomainsPreserveValidBytesAndIntentionalUnrestrictedLists() async throws {
        let cases: [(encoded: String?, expected: [String])] = [
            (nil, []), ("", []),
            ("example.org,%65xample.org,EXAMPLE.org,%E4%BE%8B%E3%81%88.%E3%83%86%E3%82%B9%E3%83%88",
             ["example.org", "EXAMPLE.org", "例え.テスト"]),
        ]
        for testCase in cases {
            let configuration = makeConfiguration()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let existingID = UUID()
            let newID = UUID()
            let seedURL = directory.appendingPathComponent("seed.opml")
            let seedXML = """
            <opml version="2.0"><head><title>Scripts</title></head><body>
              <outline text="Imported" uuid="\(existingID.uuidString)" script="void(0);"
                       allowedDomains="example.org" isArchived="false" />
            </body></opml>
            """
            try Data(seedXML.utf8).write(to: seedURL)
            let requestedURL = directory.appendingPathComponent("requested.opml")
            let domainAttribute = testCase.encoded.map { "allowedDomains=\"\($0)\"" } ?? ""
            let outlines = [existingID, newID].map { id in
                "<outline text=\"Imported\" uuid=\"\(id.uuidString)\" script=\"void(0);\" \(domainAttribute) isArchived=\"false\" />"
            }.joined()
            let xml = "<opml version=\"2.0\"><head><title>Scripts</title></head><body>" + outlines + "</body></opml>"
            try Data(xml.utf8).write(to: requestedURL)
            try await Task { @RealmBackgroundActor in
                try await LibraryDataManager.shared.importOPML(fileURL: seedURL, realmConfiguration: configuration)
                try await LibraryDataManager.shared.importOPML(fileURL: requestedURL, realmConfiguration: configuration)
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let library = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
                XCTAssertEqual(Array(library.userScriptIDs), [existingID, newID])
                for id in [existingID, newID] {
                    let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: id))
                    let domains = script.getAllowedDomains()?.map(\.domain) ?? []
                    let descriptor = try XCTUnwrap(script.getWebViewUserScriptDescriptor())
                    XCTAssertEqual(Set(descriptor.allowedDomains.map { Data($0.utf8) }),
                                   Set(testCase.expected.map { Data($0.utf8) }))
                    let userScript = await MainActor.run { descriptor.makeUserScript() }
                    XCTAssertEqual(Set(userScript.allowedDomains.map { Data($0.utf8) }),
                                   Set(testCase.expected.map { Data($0.utf8) }))
                    XCTAssertEqual(Set(domains.map { Data($0.utf8) }), Set(testCase.expected.map { Data($0.utf8) }))
                    XCTAssertEqual(script.allowedDomainIDs.count, testCase.expected.count)
                    XCTAssertFalse(script.isDeleted)
                    XCTAssertFalse(script.isArchived)
                }
                let journal = try capturedImportJournalSnapshot(realm)
                try await LibraryDataManager.shared.importOPML(fileURL: requestedURL, realmConfiguration: configuration)
                XCTAssertEqual(try capturedImportJournalSnapshot(realm), journal,
                               "A valid unchanged reimport must not add journal work")
            }.value
        }
    }

    func testIncompleteScriptDomainRelationshipsCannotBecomeUnrestrictedDescriptors() async throws {
        let configuration = makeConfiguration()
        let descriptor = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let script = UserScript()
            let domain = UserScriptAllowedDomain()
            domain.domain = "EXAMPLE.org"
            try await realm.asyncWritePreservingOwnership {
                realm.add(script)
                script.allowedDomainIDs.append(domain.id)
                script.refreshChangeMetadata(explicitlyModified: true)
            }
            let missingJournal = try capturedImportJournalSnapshot(realm)
            XCTAssertNil(script.getWebViewUserScriptDescriptor())
            XCTAssertEqual(try capturedImportJournalSnapshot(realm), missingJournal)

            try await realm.asyncWritePreservingOwnership {
                realm.add(domain)
                domain.refreshChangeMetadata(explicitlyModified: true)
            }
            let complete = try XCTUnwrap(script.getWebViewUserScriptDescriptor())
            XCTAssertEqual(complete.allowedDomains, ["EXAMPLE.org"])
            try await realm.asyncWritePreservingOwnership {
                domain.isDeleted = true
                domain.refreshChangeMetadata(explicitlyModified: true)
            }
            let deletedJournal = try capturedImportJournalSnapshot(realm)
            XCTAssertNil(script.getWebViewUserScriptDescriptor())
            XCTAssertEqual(try capturedImportJournalSnapshot(realm), deletedJournal)
            return complete
        }.value
        XCTAssertEqual(descriptor.makeUserScript().allowedDomains, ["EXAMPLE.org"])
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = [
            LibraryConfiguration.self,
            FeedCategory.self,
            Feed.self,
            FeedDirectory.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }
}

// Runtime journal snapshots for synthetic fixtures; no source/schema roster.
private func capturedImportJournalSnapshot(_ realm: Realm) throws -> [Data] {
    try realm.objects(BigSyncPendingMutation.self).map { row in
        let fields = Dictionary(uniqueKeysWithValues: row.objectSchema.properties.map {
            ($0.name, String(describing: row[$0.name]))
        })
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }.sorted { $0.lexicographicallyPrecedes($1) }
}
