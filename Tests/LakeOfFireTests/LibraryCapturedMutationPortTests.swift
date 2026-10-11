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
          <outline text="Second" uuid="\(secondID.uuidString)" script="void(1);" />
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
        let invalidURLs = try [existingID, newID].map { id in
            let url = directory.appendingPathComponent("\(id.uuidString).opml")
            let xml = """
            <opml version="2.0"><head><title>Scripts</title></head><body>
              <outline text="Changed" uuid="\(id.uuidString)" script="void(1);"
                       allowedDomains="%ZZ" isArchived="false" />
            </body></opml>
            """
            try Data(xml.utf8).write(to: url)
            return url
        }
        try await Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.importOPML(
                fileURL: validURL, realmConfiguration: configuration
            )
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let existing = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: existingID))
            let originalModifiedAt = existing.modifiedAt
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
                XCTAssertNil(realm.object(ofType: UserScript.self, forPrimaryKey: newID))
                XCTAssertEqual(realm.objects(UserScript.self).count, 1)
                XCTAssertEqual(realm.objects(UserScriptAllowedDomain.self).count, 1)
            }
        }.value
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
