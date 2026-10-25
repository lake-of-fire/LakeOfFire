import Foundation
import SwiftUIDownloads
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

#if DEBUG
    @MainActor
    func testConfiguredCatalogDownloadRespectsInjectedDataRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let groupRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try withCatalogConfiguration(dataRoot: root, appGroupRoot: groupRoot) {
            let source = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID().uuidString).opml"))
            LibraryConfiguration.opmlURLs = [source]

            let downloadable = try XCTUnwrap(LibraryConfiguration.configuredDownloadables.first)
            let destination = root.appendingPathComponent("catalog-fixture", isDirectory: true)
                .appendingPathComponent(source.lastPathComponent)
            XCTAssertEqual(downloadable.url, source)
            XCTAssertEqual(downloadable.localDestination, destination)
            XCTAssertEqual(downloadable, Downloadable(
                url: source,
                name: "App Data (\(source.lastPathComponent))",
                localDestination: destination
            ), "Changing directory policy must preserve the single-source descriptor identity")
        }
    }

    @MainActor
    func testConfiguredCatalogDownloadUsesAppGroupWithoutInjectedDataRoot() throws {
        let groupRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try withCatalogConfiguration(dataRoot: nil, appGroupRoot: groupRoot) {
            let source = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID().uuidString).opml"))
            LibraryConfiguration.opmlURLs = [source]

            let downloadable = try XCTUnwrap(LibraryConfiguration.configuredDownloadables.first)
            XCTAssertEqual(downloadable.localDestination,
                           groupRoot.appendingPathComponent("catalog-fixture", isDirectory: true)
                               .appendingPathComponent(source.lastPathComponent))
        }
    }

    @MainActor
    func testConfiguredCatalogReusesAssuredDownloadAfterDirectoryChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try withCatalogConfiguration(dataRoot: root, appGroupRoot: nil) {
            let source = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID().uuidString).opml"))
            let previousDestination = root.appendingPathComponent("previous/catalog.opml")
            let existing = Downloadable(
                url: source,
                name: "Existing catalog",
                localDestination: previousDestination
            )
            let controller = DownloadController.shared
            controller.assuredDownloads.insert(existing)
            defer { controller.assuredDownloads.remove(existing) }
            LibraryConfiguration.opmlURLs = [source, source]

            let downloadables = LibraryConfiguration.configuredDownloadables
            XCTAssertEqual(downloadables.count, 1)
            let selected = try XCTUnwrap(downloadables.first)
            XCTAssertTrue(selected === existing)
            XCTAssertEqual(selected.localDestination, previousDestination)
        }
    }

    @MainActor
    private func withCatalogConfiguration(
        dataRoot: URL?,
        appGroupRoot: URL?,
        _ body: () throws -> Void
    ) rethrows {
        let rootKey = "JVIDS_MANABI_DATA_ROOT"
        let groupKey = "MANABI_TEST_APP_GROUP_DIR"
        let previousRoot = ProcessInfo.processInfo.environment[rootKey]
        let previousGroupRoot = ProcessInfo.processInfo.environment[groupKey]
        let previousGroup = LibraryConfiguration.securityApplicationGroupIdentifier
        let previousDirectory = LibraryConfiguration.downloadstDirectoryName
        let previousURLs = LibraryConfiguration.opmlURLs
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
            if let previousGroupRoot { setenv(groupKey, previousGroupRoot, 1) } else { unsetenv(groupKey) }
            LibraryConfiguration.securityApplicationGroupIdentifier = previousGroup
            LibraryConfiguration.downloadstDirectoryName = previousDirectory
            LibraryConfiguration.opmlURLs = previousURLs
        }

        if let dataRoot { setenv(rootKey, dataRoot.path, 1) } else { unsetenv(rootKey) }
        if let appGroupRoot { setenv(groupKey, appGroupRoot.path, 1) } else { unsetenv(groupKey) }
        LibraryConfiguration.securityApplicationGroupIdentifier = "group.manabi.fixture-only"
        LibraryConfiguration.downloadstDirectoryName = "catalog-fixture"
        LibraryConfiguration.opmlURLs = []
        try body()
    }
#endif
}
