import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryObserverRealmPortTests: XCTestCase {
    override func tearDown() {
        LibraryDataManager.observesDownloadController = true
        super.tearDown()
    }

    func testScriptObserverStaysBoundToRealmCapturedAtSubscription() async throws {
        let original = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = original }
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
        defer {
            Task { @RealmBackgroundActor in
                manager.realmCancellables.forEach { $0.cancel() }
            }
        }

        XCTAssertTrue(try await eventually { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: observed,
                actor: RealmBackgroundActor.shared
            )
            return realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: ids.0
            )?.userScriptIDs.contains(ids.1) == true
        })

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

        XCTAssertTrue(try await eventually { @RealmBackgroundActor in
            let realm = try await Realm(
                configuration: observed,
                actor: RealmBackgroundActor.shared
            )
            return realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: ids.0
            )?.userScriptIDs.contains(nextID) == true
        })

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
        defer { LibraryDataManager.realmConfiguration = original }
        LibraryDataManager.observesDownloadController = false

        let configuration = makeConfiguration()
        LibraryDataManager.realmConfiguration = configuration
        let manager = LibraryDataManager()
        defer {
            Task { @RealmBackgroundActor in
                manager.realmCancellables.forEach { $0.cancel() }
            }
        }

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

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = [
            LibraryConfiguration.self,
            FeedCategory.self,
            UserScript.self,
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
