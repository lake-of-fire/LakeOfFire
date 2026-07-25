import XCTest
@testable import LakeOfFireContent

final class LibraryConfigurationActorBoundaryTests: XCTestCase {
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
