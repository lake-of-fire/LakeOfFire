import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryObserverRealmPortTests: XCTestCase {
    func testScriptObserverStaysBoundToRealmCapturedAtSubscription() async throws {
        try await verifyObserverStaysBoundToCapturedRealm(changesLibraryConfiguration: false)
    }

    func testConfigurationObserverStaysBoundToRealmCapturedAtSubscription() async throws {
        try await verifyObserverStaysBoundToCapturedRealm(changesLibraryConfiguration: true)
    }

    private func verifyObserverStaysBoundToCapturedRealm(
        changesLibraryConfiguration: Bool
    ) async throws {
        let original = LibraryDataManager.realmConfiguration
        let originallyObservedDownloads = LibraryDataManager.observesDownloadController
        defer {
            LibraryDataManager.realmConfiguration = original
            LibraryDataManager.observesDownloadController = originallyObservedDownloads
        }
        LibraryDataManager.observesDownloadController = false

        let observed = Self.makeConfiguration()
        let replacement = Self.makeConfiguration()
        LibraryDataManager.realmConfiguration = observed

        let ids = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: observed)
            let library = LibraryConfiguration()
            let initial = UserScript()
            try await realm.asyncWritePreservingOwnership {
                realm.add([library, initial])
            }
            return (library.id, initial.id)
        }.value

        let manager = LibraryDataManager()
        addObserverTeardown(manager, configurations: [observed, replacement])
        let observersInstalled = try await Self.eventually { @RealmBackgroundActor in
            manager.realmCancellables.count == 2
        }
        XCTAssertTrue(observersInstalled, "The real Realm observers must be installed")

        let initialReconciled = try await Self.eventually { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: observed)
            return realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: ids.0
            )?.userScriptIDs.contains(ids.1) == true
        }
        XCTAssertTrue(initialReconciled)

        let replacementIDs = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: replacement)
            let library = LibraryConfiguration()
            let orphan = UserScript()
            try await realm.asyncWritePreservingOwnership {
                realm.add([library, orphan])
            }
            return (library.id, orphan.id)
        }.value

        LibraryDataManager.realmConfiguration = replacement

        let nextID = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: observed)
            if changesLibraryConfiguration {
                let library = try XCTUnwrap(realm.object(
                    ofType: LibraryConfiguration.self, forPrimaryKey: ids.0
                ))
                try await realm.asyncWritePreservingOwnership {
                    library.userScriptIDs.removeAll()
                    library.refreshChangeMetadata(explicitlyModified: true)
                }
                return ids.1
            }
            let script = UserScript()
            try await realm.asyncWritePreservingOwnership {
                realm.add(script)
            }
            return script.id
        }.value

        let nextReconciled = try await Self.eventually { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: observed)
            return realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: ids.0
            )?.userScriptIDs.contains(nextID) == true
        }
        XCTAssertTrue(nextReconciled)

        let replacementIDsAfter = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: replacement)
            let library = try XCTUnwrap(realm.object(
                ofType: LibraryConfiguration.self, forPrimaryKey: replacementIDs.0
            ))
            XCTAssertNil(Self.pendingMutation(for: library, in: realm))
            return Array(library.userScriptIDs)
        }.value
        XCTAssertTrue(replacementIDsAfter.isEmpty)
    }

    func testEmptyObserverRefreshDoesNotCreateLibraryConfiguration() async throws {
        let original = LibraryDataManager.realmConfiguration
        let originallyObservedDownloads = LibraryDataManager.observesDownloadController
        defer {
            LibraryDataManager.realmConfiguration = original
            LibraryDataManager.observesDownloadController = originallyObservedDownloads
        }
        LibraryDataManager.observesDownloadController = false

        let configuration = Self.makeConfiguration()
        LibraryDataManager.realmConfiguration = configuration
        let manager = LibraryDataManager()
        addObserverTeardown(manager, configurations: [configuration])
        let observersInstalled = try await Self.eventually { @RealmBackgroundActor in
            manager.realmCancellables.count == 2
        }
        XCTAssertTrue(observersInstalled, "The real Realm observers must be installed")

        // Await the real production refresh, rather than inferring completion
        // from a sleep while asserting that no row appeared.
        try await manager.refreshScripts(realmConfiguration: configuration)

        let counts = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            return (
                realm.objects(LibraryConfiguration.self).count,
                realm.objects(UserScript.self).count
            )
        }.value
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testDisabledScriptObserverSettlesAndAllowsReenable() async throws {
        let original = LibraryDataManager.realmConfiguration
        let originallyObservedDownloads = LibraryDataManager.observesDownloadController
        defer {
            LibraryDataManager.realmConfiguration = original
            LibraryDataManager.observesDownloadController = originallyObservedDownloads
        }
        LibraryDataManager.observesDownloadController = false
        let configuration = Self.makeConfiguration()
        LibraryDataManager.realmConfiguration = configuration

        let ids = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let library = LibraryConfiguration()
            let script = UserScript()
            script.script = "window.manabiObserverFixture = true"
            library.userScriptIDs.append(script.id)
            try await realm.asyncWritePreservingOwnership {
                realm.add([library, script])
                library.refreshChangeMetadata(explicitlyModified: true)
            }
            return (library.id, script.id)
        }.value
        let manager = LibraryDataManager()
        addObserverTeardown(manager, configurations: [configuration])
        let observersInstalled = try await Self.eventually { @RealmBackgroundActor in
            manager.realmCancellables.count == 2
        }
        XCTAssertTrue(observersInstalled)

        for isDisabled in [true, false] {
            try await Task { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let script = try XCTUnwrap(realm.object(
                    ofType: UserScript.self, forPrimaryKey: ids.1
                ))
                try await realm.asyncWritePreservingOwnership {
                    script.isArchived = isDisabled
                    script.refreshChangeMetadata(explicitlyModified: true)
                }
            }.value

            // Exercise the actual debounced collection observers. Observe a
            // settled interval longer than two 0.3-second debounce periods.
            try await Task.sleep(nanoseconds: 700_000_000)
            let before = try await Task { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let library = try XCTUnwrap(realm.object(
                    ofType: LibraryConfiguration.self, forPrimaryKey: ids.0
                ))
                XCTAssertEqual(Array(library.userScriptIDs), [ids.1])
                let visible = try XCTUnwrap(library.getUserScripts()?.first)
                XCTAssertEqual(visible.id, ids.1)
                XCTAssertEqual(visible.isArchived, isDisabled)
                XCTAssertEqual(
                    library.getActiveWebViewUserScriptDescriptors()?.map(\.id),
                    isDisabled ? [] : [ids.1]
                )
                let mutation = try XCTUnwrap(Self.pendingMutation(for: library, in: realm))
                return (
                    library.modifiedAt, library.explicitlyModifiedAt,
                    mutation.generation, mutation.changedAt
                )
            }.value
            try await Task.sleep(nanoseconds: 700_000_000)
            try await Task { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let library = try XCTUnwrap(realm.object(
                    ofType: LibraryConfiguration.self, forPrimaryKey: ids.0
                ))
                XCTAssertEqual(Array(library.userScriptIDs), [ids.1])
                XCTAssertEqual(library.modifiedAt, before.0)
                XCTAssertEqual(library.explicitlyModifiedAt, before.1)
                let mutation = try XCTUnwrap(Self.pendingMutation(for: library, in: realm))
                XCTAssertEqual(mutation.generation, before.2)
                XCTAssertEqual(mutation.changedAt, before.3)
            }.value
        }
    }

    @RealmBackgroundActor
    func testUncommittedScriptDoesNotAuthorizeAnObserverRefresh() async throws {
        let original = LibraryDataManager.realmConfiguration
        let originallyObservedDownloads = LibraryDataManager.observesDownloadController
        defer {
            LibraryDataManager.realmConfiguration = original
            LibraryDataManager.observesDownloadController = originallyObservedDownloads
        }
        LibraryDataManager.observesDownloadController = false
        let configuration = Self.makeConfiguration()
        LibraryDataManager.realmConfiguration = configuration
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let manager = LibraryDataManager()
        addObserverTeardown(manager, configurations: [configuration])
        let installed = try await Self.eventually { @RealmBackgroundActor in
            manager.realmCancellables.count == 2
        }
        XCTAssertTrue(installed)
        // The other tests exercise automatic delivery. Isolate the actual
        // refresh boundary here so an initial publisher event cannot own it.
        manager.realmCancellables.forEach { $0.cancel() }
        manager.realmCancellables.removeAll()
        try await manager.refreshScripts(realmConfiguration: configuration)

        try realm.beginWrite()
        defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
        realm.add(UserScript())

        let completed = expectation(description: "empty committed snapshot returns without waiting for a write")
        let refresh = Task { @RealmBackgroundActor in
            defer { completed.fulfill() }
            try await manager.refreshScripts(realmConfiguration: configuration)
        }
        await fulfillment(of: [completed], timeout: 2)
        // If admission regresses, cancel its queued ticket before releasing the
        // fixture's transaction, so failure cannot hang the test or commit it.
        refresh.cancel()
        if case .failure(let error) = await refresh.result {
            XCTFail("Unexpected refresh error: \(error)")
        }
        XCTAssertTrue(realm.isInWriteTransaction)
        if realm.isInWriteTransaction { realm.cancelWrite() }
        XCTAssertTrue(realm.objects(LibraryConfiguration.self).isEmpty)
        XCTAssertTrue(realm.objects(UserScript.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private func addObserverTeardown(
        _ manager: LibraryDataManager,
        configurations: [Realm.Configuration]
    ) {
        addTeardownBlock {
            await Task { @RealmBackgroundActor in
                manager.realmCancellables.forEach { $0.cancel() }
                manager.realmCancellables.removeAll()
                for configuration in configurations {
                    await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
                }
            }.value
        }
    }

    @RealmBackgroundActor
    private static func pendingMutation(
        for library: LibraryConfiguration,
        in realm: Realm
    ) -> BigSyncPendingMutation? {
        realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: library.objectSchema.className + "." + String(describing: library.id)
        )
    }

    private static func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = [
            LibraryConfiguration.self,
            FeedCategory.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    @RealmBackgroundActor
    private static func eventually(
        timeout: TimeInterval = 8,
        condition: @escaping @RealmBackgroundActor () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await condition()
    }
}
