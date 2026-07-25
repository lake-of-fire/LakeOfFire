import XCTest
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent

final class LibraryConfigurationActorBoundaryTests: XCTestCase {
    func testSyncFromServersConsolidatesBeforeReturning() async throws {
        let originalRealmConfiguration = LibraryDataManager.realmConfiguration
        let originalObservesDownloadController = LibraryDataManager.observesDownloadController
        let originalApplicationGroupIdentifier = LibraryConfiguration.securityApplicationGroupIdentifier
        let originalOPMLURLs = LibraryConfiguration.opmlURLs
        defer {
            LibraryDataManager.realmConfiguration = originalRealmConfiguration
            LibraryDataManager.observesDownloadController = originalObservesDownloadController
            LibraryConfiguration.securityApplicationGroupIdentifier = originalApplicationGroupIdentifier
            LibraryConfiguration.opmlURLs = originalOPMLURLs
        }

        var configuration = DefaultRealmConfiguration.configuration
        configuration.inMemoryIdentifier = UUID().uuidString
        configuration.fileURL = nil
        LibraryDataManager.realmConfiguration = configuration
        LibraryDataManager.observesDownloadController = false
        LibraryConfiguration.securityApplicationGroupIdentifier = "test.group"
        LibraryConfiguration.opmlURLs = []

        try await LibraryDataManager().syncFromServers(isWaiting: true)

        let configurationCount = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            return realm.objects(LibraryConfiguration.self).where { !$0.isDeleted }.count
        }

        XCTAssertEqual(configurationCount, 1)
    }

    @MainActor
    func testConfiguredDownloadablesUsesProcessConfiguration() throws {
        let originalApplicationGroupIdentifier = LibraryConfiguration.securityApplicationGroupIdentifier
        let originalOPMLURLs = LibraryConfiguration.opmlURLs
        defer {
            LibraryConfiguration.securityApplicationGroupIdentifier = originalApplicationGroupIdentifier
            LibraryConfiguration.opmlURLs = originalOPMLURLs
        }

        let opmlURL = try XCTUnwrap(URL(string: "https://example.com/library.opml"))
        LibraryConfiguration.securityApplicationGroupIdentifier = "test.group"
        LibraryConfiguration.opmlURLs = [opmlURL]

        let downloadables = LibraryConfiguration.configuredDownloadables

        XCTAssertEqual(downloadables.map(\.url), [opmlURL])
    }
}
