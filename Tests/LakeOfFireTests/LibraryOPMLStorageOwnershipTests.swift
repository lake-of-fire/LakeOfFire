import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private struct OPMLStorageConfigurationState: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let categoryIDs: [UUID]
    let scriptIDs: [UUID]
    let isDeleted: Bool
    let modifiedAt: Date
    let explicitlyModifiedAt: Date?
}

private struct OPMLStorageSnapshot: Equatable, Sendable {
    let configurations: [OPMLStorageConfigurationState]
    let categoryTitles: [UUID: String]
    let scriptSources: [UUID: String]
    let generations: [String: String]
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LibraryOPMLStorageOwnershipTests: XCTestCase, @unchecked Sendable {
    private struct DiskStores: Sendable {
        let current: Realm.Configuration
        let replacement: Realm.Configuration
        let retired: Realm.Configuration
    }

    private struct Fixture: Sendable {
        let stores: DiskStores
        let original: OPMLStorageSnapshot
        let replacement: OPMLStorageSnapshot
    }

    private func configured(_ input: Realm.Configuration) -> Realm.Configuration {
        var configuration = input
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func initializeSharedDataManagerAwayFromFixture() {
        let previousConfiguration = LibraryDataManager.realmConfiguration
        let previousDownloadObservation = LibraryDataManager.observesDownloadController
        defer {
            LibraryDataManager.realmConfiguration = previousConfiguration
            LibraryDataManager.observesDownloadController = previousDownloadObservation
        }
        // Keep shared away from these unique disk paths even with companions
        // that retain Realm subscriptions while downloads are disabled. If
        // already initialized, shared also predates these fixture paths.
        LibraryDataManager.realmConfiguration = configured(
            Realm.Configuration(inMemoryIdentifier: "opml-observer-isolation-\(UUID())")
        )
        LibraryDataManager.observesDownloadController = false
        _ = LibraryDataManager.shared
    }

    private func makeDiskStores() throws -> DiskStores {
        initializeSharedDataManagerAwayFromFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opml-storage-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = configured(
            Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm"))
        )
        var replacement = current
        replacement.fileURL = directory.appendingPathComponent("replacement.realm")
        var retired = current
        retired.fileURL = directory.appendingPathComponent("retired.realm")
        BigSyncMutationTracking.install(
            configurations: [current, replacement],
            excludedClassNames: []
        )
        let stores = DiskStores(current: current, replacement: replacement, retired: retired)
        addTeardownBlock {
            await Self.releaseDiskCaches(stores)
            try? FileManager.default.removeItem(at: directory)
        }
        return stores
    }

    private func makeFixture() throws -> Fixture {
        let stores = try makeDiskStores()
        let configurationIDs = [UUID(), UUID()]
        let categoryIDs = [UUID(), UUID()]
        let scriptIDs = [UUID(), UUID()]
        for (configuration, label) in [(stores.current, "Original"), (stores.replacement, "Replacement")] {
            try autoreleasepool {
                let realm = try Realm(configuration: configuration)
                defer { realm.invalidate() }
                try realm.write {
                    for index in 0..<2 {
                        let category = FeedCategory()
                        category.id = categoryIDs[index]
                        category.createdAt = Date(timeIntervalSinceReferenceDate: Double(100 + index))
                        category.title = "\(label) category \(index)"
                        category.backgroundImageUrl = URL(string: "about:blank")!
                        realm.add(category)
                        category.refreshChangeMetadata(explicitlyModified: true)

                        let script = UserScript()
                        script.id = scriptIDs[index]
                        script.createdAt = Date(timeIntervalSinceReferenceDate: Double(200 + index))
                        script.title = "\(label) script \(index)"
                        script.script = "console.log('\(label) \(index)')"
                        realm.add(script)
                        script.refreshChangeMetadata(explicitlyModified: true)

                        let library = LibraryConfiguration()
                        library.id = configurationIDs[index]
                        library.createdAt = Date(timeIntervalSinceReferenceDate: Double(300 + index))
                        library.categoryIDs.append(category.id)
                        library.userScriptIDs.append(script.id)
                        realm.add(library)
                        library.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
        }
        return Fixture(
            stores: stores,
            original: try diskSnapshot(stores.current),
            replacement: try diskSnapshot(stores.replacement)
        )
    }

    private func diskSnapshot(_ configuration: Realm.Configuration) throws -> OPMLStorageSnapshot {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            defer { realm.invalidate() }
            let configurations = Array(realm.objects(LibraryConfiguration.self))
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map {
                    OPMLStorageConfigurationState(
                        id: $0.id, createdAt: $0.createdAt,
                        categoryIDs: Array($0.categoryIDs), scriptIDs: Array($0.userScriptIDs),
                        isDeleted: $0.isDeleted, modifiedAt: $0.modifiedAt,
                        explicitlyModifiedAt: $0.explicitlyModifiedAt
                    )
                }
            return OPMLStorageSnapshot(
                configurations: configurations,
                categoryTitles: Dictionary(uniqueKeysWithValues: realm.objects(FeedCategory.self).map {
                    ($0.id, $0.title)
                }),
                scriptSources: Dictionary(uniqueKeysWithValues: realm.objects(UserScript.self).map {
                    ($0.id, $0.script)
                }),
                generations: Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
                    ($0.recordName, $0.generation)
                })
            )
        }
    }

    private func manager(_ configuration: Realm.Configuration) -> LibraryManagerViewModel {
        let previous = LibraryDataManager.realmConfiguration
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = previous }
        return LibraryManagerViewModel(observesRealm: false)
    }

    private func replaceDiskFile(_ stores: DiskStores) throws {
        let current = try XCTUnwrap(stores.current.fileURL)
        let replacement = try XCTUnwrap(stores.replacement.fileURL)
        let retired = try XCTUnwrap(stores.retired.fileURL)
        try FileManager.default.moveItem(at: current, to: retired)
        do {
            try FileManager.default.moveItem(at: replacement, to: current)
        } catch {
            try? FileManager.default.moveItem(at: retired, to: current)
            throw error
        }
    }

    @RealmBackgroundActor
    private static func releaseDiskCaches(_ stores: DiskStores) {
        let paths = Set([stores.current, stores.replacement, stores.retired].compactMap(\.fileURL))
        let actor = RealmBackgroundActor.shared
        let keys = actor.cachedRealms.keys.filter {
            actor.cachedRealms[$0]?.configuration.fileURL.map(paths.contains) == true
        }
        for key in keys {
            guard let realm = actor.cachedRealms[key], !realm.isInWriteTransaction else { continue }
            actor.cachedRealms.removeValue(forKey: key)
            realm.invalidate()
        }
    }

    @RealmBackgroundActor
    private static func beginFixtureWrite(_ configuration: Realm.Configuration) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try realm.beginWrite()
    }

    @RealmBackgroundActor
    private static func fixtureWriteIsOpen(_ configuration: Realm.Configuration) -> Bool {
        RealmBackgroundActor.shared.cachedRealms.values.contains {
            $0.configuration.fileURL == configuration.fileURL && $0.isInWriteTransaction
        }
    }

    @RealmBackgroundActor
    @discardableResult
    private static func cancelFixtureWrite(_ configuration: Realm.Configuration) -> Bool {
        // Resolve the existing fixture handle by its configured path. Opening
        // that path after replacement would obtain B and strand A's writer.
        guard let realm = RealmBackgroundActor.shared.cachedRealms.values.first(where: {
            $0.configuration.fileURL == configuration.fileURL && $0.isInWriteTransaction
        }) else { return false }
        realm.cancelWrite()
        return true
    }

    func testDefaultExportRejectsReplacementBeforeOpeningWithoutConsolidatingEitherStore() async throws {
        let fixture = try makeFixture()
        let model = manager(fixture.stores.current)
        try replaceDiskFile(fixture.stores)
        var writeAttempts = 0
        model.writeOPMLFile = { data, url in
            writeAttempts += 1
            try data.write(to: url, options: [.atomic])
        }
        defer { model.invalidateOPMLExport() }
        await model.refreshOPMLExport().value
        XCTAssertTrue(model.opmlExportFailed)
        XCTAssertNil(model.exportedOPML)
        XCTAssertNil(model.exportedOPMLFileURL)
        XCTAssertNil(model.exportedOPMLShareItem)
        XCTAssertEqual(writeAttempts, 0)
        await Self.releaseDiskCaches(fixture.stores)
        XCTAssertEqual(try diskSnapshot(fixture.stores.current), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.stores.retired), fixture.original)
    }

    func testQueuedExportRechecksStoreBeforeConsolidationMembershipAndTombstoneWrites() async throws {
        let fixture = try makeFixture()
        let configuration = fixture.stores.current
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        try await Self.beginFixtureWrite(configuration)
        addTeardownBlock { _ = await Self.cancelFixtureWrite(configuration) }
        let submitted = expectation(description: "Consolidation submitted its own SDK begin ticket")
        let operation = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                _ = try await LibraryDataManager.shared.exportUserOPML(
                    realmConfiguration: configuration,
                    storageAdmission: admission
                )
            }
        }
        addTeardownBlock {
            operation.cancel()
            _ = await Self.cancelFixtureWrite(configuration)
            _ = await operation.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        // This actor turn follows the synchronous willSubmit/beginAsyncWrite
        // boundary, proving the ticket was queued before the physical swap.
        let writerRemainsOpen = await Self.fixtureWriteIsOpen(configuration)
        XCTAssertTrue(writerRemainsOpen)
        try replaceDiskFile(fixture.stores)
        let releasedFixtureWriter = await Self.cancelFixtureWrite(configuration)
        XCTAssertTrue(releasedFixtureWriter)
        do {
            try await operation.value
            XCTFail("An admitted consolidation must reject the retired physical store")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        await Self.releaseDiskCaches(fixture.stores)
        XCTAssertEqual(try diskSnapshot(fixture.stores.current), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.stores.retired), fixture.original)
    }

    func testDefaultExportCreatesMissingStoreAndReusesItsAdvancedAdmissionWithoutRejournaling() async throws {
        let stores = try makeDiskStores()
        let currentURL = try XCTUnwrap(stores.current.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
        let model = manager(stores.current)
        var writeCount = 0
        model.writeOPMLFile = { data, url in
            try data.write(to: url, options: [.atomic])
            writeCount += 1
        }
        defer { model.invalidateOPMLExport() }
        // The returned task includes publication or failure settlement on MainActor.
        await model.refreshOPMLExport().value
        XCTAssertFalse(model.opmlExportFailed)
        let firstURL = try XCTUnwrap(model.exportedOPMLFileURL)
        XCTAssertEqual(model.exportedOPMLShareItem?.data, try Data(contentsOf: firstURL))
        XCTAssertTrue(try String(contentsOf: firstURL, encoding: .utf8).contains("User Scripts"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
        let created = try diskSnapshot(stores.current)
        XCTAssertEqual(created.configurations.count, 1)
        XCTAssertFalse(try XCTUnwrap(created.configurations.first).isDeleted)
        XCTAssertNotNil(try XCTUnwrap(created.configurations.first).explicitlyModifiedAt)
        XCTAssertEqual(created.generations.count, 1)

        await model.refreshOPMLExport().value
        XCTAssertFalse(model.opmlExportFailed)
        let secondURL = try XCTUnwrap(model.exportedOPMLFileURL)
        XCTAssertNotEqual(secondURL, firstURL)
        XCTAssertEqual(model.exportedOPMLShareItem?.data, try Data(contentsOf: secondURL))
        XCTAssertEqual(try diskSnapshot(stores.current), created)
        XCTAssertEqual(writeCount, 2)
    }

    func testReplacementAfterFileWriteRejectsPublicationAndRemovesTheUnpublishedArtifact() async throws {
        let fixture = try makeFixture()
        let model = manager(fixture.stores.current)
        var attemptedURL: URL?
        var committedOriginal: OPMLStorageSnapshot?
        var writtenXML: String?
        model.writeOPMLFile = { [self] data, url in
            try data.write(to: url, options: [.atomic])
            attemptedURL = url
            writtenXML = String(data: data, encoding: .utf8)
            committedOriginal = try diskSnapshot(fixture.stores.current)
            try replaceDiskFile(fixture.stores)
        }
        defer { model.invalidateOPMLExport() }
        await model.refreshOPMLExport().value
        XCTAssertTrue(model.opmlExportFailed)
        XCTAssertNil(model.exportedOPML)
        XCTAssertNil(model.exportedOPMLFileURL)
        XCTAssertNil(model.exportedOPMLShareItem)
        let url = try XCTUnwrap(attemptedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try XCTUnwrap(writtenXML).contains("Original script"))
        XCTAssertFalse(try XCTUnwrap(writtenXML).contains("Replacement script"))
        let committed = try XCTUnwrap(committedOriginal)
        XCTAssertNotEqual(committed, fixture.original, "The real exporter consolidated A before the swap")
        XCTAssertEqual(committed.configurations.filter(\.isDeleted).count, 1)
        XCTAssertEqual(committed.configurations.first(where: { !$0.isDeleted })?.categoryIDs.count, 2)
        XCTAssertEqual(committed.configurations.first(where: { !$0.isDeleted })?.scriptIDs.count, 2)
        await Self.releaseDiskCaches(fixture.stores)
        XCTAssertEqual(try diskSnapshot(fixture.stores.current), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.stores.retired), committed)
    }
}
