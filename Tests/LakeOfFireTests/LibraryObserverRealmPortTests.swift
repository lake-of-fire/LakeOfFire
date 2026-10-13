import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryObserverRealmPortTests: XCTestCase {
    func testScriptObserverStaysBoundToRealmCapturedAtSubscription() async throws {
        let original = LibraryDataManager.realmConfiguration
        let originallyObservedDownloads = LibraryDataManager.observesDownloadController
        defer {
            LibraryDataManager.realmConfiguration = original
            LibraryDataManager.observesDownloadController = originallyObservedDownloads
        }
        LibraryDataManager.observesDownloadController = false

        let observed = makeConfiguration()
        let replacement = makeConfiguration()
        LibraryDataManager.realmConfiguration = observed

        let ids = try await Task { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: observed,
                actor: RealmBackgroundActor.shared
            )
            let library = LibraryConfiguration()
            let initial = UserScript()
            try await realm.asyncWrite {
                realm.add([library, initial])
            }
            return (library.id, initial.id)
        }.value

        let manager = LibraryDataManager()
        addTeardownBlock {
            await Task { @RealmBackgroundActor in
                manager.realmCancellables.forEach { $0.cancel() }
                manager.realmCancellables.removeAll()
            }.value
        }
        let observersInstalled = try await eventually { @RealmBackgroundActor in
            manager.realmCancellables.count == 2
        }
        XCTAssertTrue(observersInstalled, "The real Realm observers must be installed")

        let initialReconciled = try await eventually { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: observed,
                actor: RealmBackgroundActor.shared
            )
            return realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: ids.0
            )?.userScriptIDs.contains(ids.1) == true
        }
        XCTAssertTrue(initialReconciled)

        let replacementIDs = try await Task { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: replacement,
                actor: RealmBackgroundActor.shared
            )
            let library = LibraryConfiguration()
            let orphan = UserScript()
            try await realm.asyncWrite {
                realm.add([library, orphan])
            }
            return (library.id, orphan.id)
        }.value

        LibraryDataManager.realmConfiguration = replacement

        let nextID = try await Task { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: observed,
                actor: RealmBackgroundActor.shared
            )
            let script = UserScript()
            try await realm.asyncWrite {
                realm.add(script)
            }
            return script.id
        }.value

        let nextReconciled = try await eventually { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: observed,
                actor: RealmBackgroundActor.shared
            )
            return realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: ids.0
            )?.userScriptIDs.contains(nextID) == true
        }
        XCTAssertTrue(nextReconciled)

        let replacementIDsAfter = try await Task { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: replacement,
                actor: RealmBackgroundActor.shared
            )
            return Array(
                realm.object(
                    ofType: LibraryConfiguration.self,
                    forPrimaryKey: replacementIDs.0
                )?.userScriptIDs ?? List<UUID>()
            )
        }.value
        XCTAssertTrue(replacementIDsAfter.isEmpty)
    }

    func testInitialEmptyObserverDoesNotCreateLibraryConfiguration() async throws {
        let original = LibraryDataManager.realmConfiguration
        let originallyObservedDownloads = LibraryDataManager.observesDownloadController
        defer {
            LibraryDataManager.realmConfiguration = original
            LibraryDataManager.observesDownloadController = originallyObservedDownloads
        }
        LibraryDataManager.observesDownloadController = false

        let configuration = makeConfiguration()
        LibraryDataManager.realmConfiguration = configuration
        let manager = LibraryDataManager()
        addTeardownBlock {
            await Task { @RealmBackgroundActor in
                manager.realmCancellables.forEach { $0.cancel() }
                manager.realmCancellables.removeAll()
            }.value
        }
        let observersInstalled = try await eventually { @RealmBackgroundActor in
            manager.realmCancellables.count == 2
        }
        XCTAssertTrue(observersInstalled, "The real Realm observers must be installed")

        try await Task.sleep(nanoseconds: 700_000_000)

        let counts = try await Task { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: configuration,
                actor: RealmBackgroundActor.shared
            )
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
        let configuration = makeConfiguration()
        LibraryDataManager.realmConfiguration = configuration

        let ids = try await Task { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: configuration,
                actor: RealmBackgroundActor.shared
            )
            let library = LibraryConfiguration()
            let script = UserScript()
            script.script = "window.manabiObserverFixture = true"
            library.userScriptIDs.append(script.id)
            try await realm.asyncWrite { realm.add([library, script]) }
            return (library.id, script.id)
        }.value
        let manager = LibraryDataManager()
        addTeardownBlock {
            await Task { @RealmBackgroundActor in
                manager.realmCancellables.forEach { $0.cancel() }
                manager.realmCancellables.removeAll()
            }.value
        }
        let observersInstalled = try await eventually { @RealmBackgroundActor in
            manager.realmCancellables.count == 2
        }
        XCTAssertTrue(observersInstalled)

        for isDisabled in [true, false] {
            try await Task { @RealmBackgroundActor in
                let realm = try await Realm(
                    configuration: configuration,
                    actor: RealmBackgroundActor.shared
                )
                let script = try XCTUnwrap(realm.object(
                    ofType: UserScript.self, forPrimaryKey: ids.1
                ))
                try await realm.asyncWrite { script.isArchived = isDisabled }
            }.value

            // Exercise the actual debounced collection observers. Observe a
            // settled interval longer than two 0.3-second debounce periods.
            try await Task.sleep(nanoseconds: 700_000_000)
            let before = try await Task { @RealmBackgroundActor in
                let realm = try await Realm(
                    configuration: configuration,
                    actor: RealmBackgroundActor.shared
                )
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
                return (library.modifiedAt, library.explicitlyModifiedAt)
            }.value
            try await Task.sleep(nanoseconds: 700_000_000)
            try await Task { @RealmBackgroundActor in
                let realm = try await Realm(
                    configuration: configuration,
                    actor: RealmBackgroundActor.shared
                )
                let library = try XCTUnwrap(realm.object(
                    ofType: LibraryConfiguration.self, forPrimaryKey: ids.0
                ))
                XCTAssertEqual(Array(library.userScriptIDs), [ids.1])
                XCTAssertEqual(library.modifiedAt, before.0)
                XCTAssertEqual(library.explicitlyModifiedAt, before.1)
            }.value
        }
    }

    private func makeConfiguration() -> Realm.Configuration {
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

    private func eventually(
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
