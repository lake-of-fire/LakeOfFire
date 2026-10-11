import BigSyncKit
import OPML
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

@RealmBackgroundActor
final class LibraryOPMLExportConfigurationTests: XCTestCase {
    func testExportUsesRequestedRealmForIdenticalRecordIDs() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let categoryID = UUID()
        let feedID = UUID()
        try await insertLibrary(
            categoryID: categoryID, feedID: feedID, title: "Library A", configuration: configurationA
        )
        try await insertLibrary(
            categoryID: categoryID, feedID: feedID, title: "Library B", configuration: configurationB
        )

        let exportedA = try await LibraryDataManager.shared.exportUserOPML(realmConfiguration: configurationA)
        let exportedB = try await LibraryDataManager.shared.exportUserOPML(realmConfiguration: configurationB)
        let categoryA = try XCTUnwrap(exportedA.entries.first { $0.attributeUUIDValue("uuid") == categoryID })
        let categoryB = try XCTUnwrap(exportedB.entries.first { $0.attributeUUIDValue("uuid") == categoryID })

        XCTAssertEqual(categoryA.text, "Library A")
        XCTAssertEqual(categoryB.text, "Library B")
        XCTAssertEqual(categoryA.children?.first?.text, "Library A feed")
        XCTAssertEqual(categoryB.children?.first?.text, "Library B feed")

    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self, Feed.self,
            UserScript.self, UserScriptAllowedDomain.self, BigSyncPendingMutation.self,
        ]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        return configuration
    }

    private func insertLibrary(
        categoryID: UUID,
        feedID: UUID,
        title: String,
        configuration: Realm.Configuration
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let category = FeedCategory()
        category.id = categoryID
        category.title = title
        let feed = Feed()
        feed.id = feedID
        feed.categoryID = categoryID
        feed.title = title + " feed"
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        let library = LibraryConfiguration()
        library.categoryIDs.append(categoryID)
        try await realm.asyncWrite {
            realm.add([library, category, feed])
        }
    }
}
