import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryOPMLImportOutcomeTests: XCTestCase {
    func testLocalImportPreservesOrderedOutcomesAndCommitsOnlyValidFiles() async throws {
        let configuration = makeConfiguration()

        let firstScriptID = UUID()
        let secondScriptID = UUID()
        let firstFileURL = temporaryOPMLFileURL()
        let malformedFileURL = temporaryOPMLFileURL()
        let secondFileURL = temporaryOPMLFileURL()
        defer {
            try? FileManager.default.removeItem(at: firstFileURL)
            try? FileManager.default.removeItem(at: malformedFileURL)
            try? FileManager.default.removeItem(at: secondFileURL)
        }

        try makeUserScriptOPMLData(
            title: "First valid script",
            id: firstScriptID
        ).write(to: firstFileURL)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0"><body>
              <outline text="User Scripts" isUserScriptList="true">
                <outline text="Must not persist" uuid="\(UUID().uuidString)"
            """.utf8
        ).write(to: malformedFileURL)
        try makeUserScriptOPMLData(
            title: "Second valid script",
            id: secondScriptID
        ).write(to: secondFileURL)

        let result = await LibraryDataManager.shared.importOPML(
            fileURLs: [firstFileURL, malformedFileURL, secondFileURL],
            realmConfiguration: configuration
        )

        XCTAssertEqual(result.outcomes.count, 3)
        XCTAssertEqual(result.outcomes[0], .committed(fileURL: firstFileURL))
        XCTAssertEqual(result.outcomes[2], .committed(fileURL: secondFileURL))
        guard case .failed(let failedFileURL, let errorDescription) = result.outcomes[1] else {
            return XCTFail("Expected the malformed file to produce a failed outcome")
        }
        XCTAssertEqual(failedFileURL, malformedFileURL)
        XCTAssertFalse(errorDescription.isEmpty)
        XCTAssertEqual(result.succeededFileURLs, [firstFileURL, secondFileURL])
        XCTAssertEqual(result.failedFiles.map(\.fileURL), [malformedFileURL])
        XCTAssertEqual(result.failedFiles.map(\.errorDescription), [errorDescription])

        let snapshot = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let configuration = try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
            let scripts = realm.objects(UserScript.self)
            let secondScript = try XCTUnwrap(
                realm.object(ofType: UserScript.self, forPrimaryKey: secondScriptID)
            )
            let configurationMutation = try XCTUnwrap(
                pendingMutation(for: configuration, in: realm)
            )
            let secondScriptMutation = try XCTUnwrap(
                pendingMutation(for: secondScript, in: realm)
            )
            return (
                Array(configuration.userScriptIDs),
                scripts.map(\.title).sorted(),
                realm.object(ofType: UserScript.self, forPrimaryKey: firstScriptID) != nil,
                realm.object(ofType: UserScript.self, forPrimaryKey: secondScriptID) != nil,
                realm.object(
                    ofType: LibraryOPMLImportLease.self,
                    forPrimaryKey: LibraryOPMLImportLease.singletonID
                ) != nil,
                realm.objects(BigSyncPendingMutation.self).count,
                Set(realm.objects(BigSyncPendingMutation.self).map(\.entityType)),
                configurationMutation.changedAt,
                secondScriptMutation.changedAt
            )
        }()

        XCTAssertEqual(snapshot.0, [firstScriptID, secondScriptID])
        XCTAssertEqual(snapshot.1, ["First valid script", "Second valid script"])
        XCTAssertTrue(snapshot.2)
        XCTAssertTrue(snapshot.3)
        XCTAssertTrue(snapshot.4)
        XCTAssertEqual(snapshot.5, 3)
        XCTAssertEqual(
            snapshot.6,
            Set([LibraryConfiguration.className(), UserScript.className()])
        )
        XCTAssertEqual(snapshot.7, snapshot.8)
    }

    func testCancelledBatchDoesNotAcquireLeaseOrStartFiles() async throws {
        let configuration = makeConfiguration()
        let fileURLs = [temporaryOPMLFileURL(), temporaryOPMLFileURL()]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LibraryDataManager.shared.importOPML(
                fileURLs: fileURLs,
                realmConfiguration: configuration
            )
        }
        let result = await task.value
        XCTAssertEqual(result.outcomes, fileURLs.map { .notStarted(fileURL: $0) })
        let snapshot = try await importSnapshot(configuration: configuration)
        XCTAssertTrue(snapshot.scriptIDs.isEmpty)
        XCTAssertEqual(snapshot.configurationCount, 0)
        XCTAssertEqual(snapshot.mutationCount, 0)
        XCTAssertEqual(snapshot.leaseCount, 0)
    }

    func testCancellationAfterCommitPreservesCommittedPrefix() async throws {
        let configuration = makeConfiguration()
        let firstScriptID = UUID()
        let secondScriptID = UUID()
        let firstFileURL = temporaryOPMLFileURL()
        let secondFileURL = temporaryOPMLFileURL()
        defer {
            try? FileManager.default.removeItem(at: firstFileURL)
            try? FileManager.default.removeItem(at: secondFileURL)
        }
        try makeUserScriptOPMLData(title: "Committed", id: firstScriptID).write(to: firstFileURL)
        try makeUserScriptOPMLData(title: "Not started", id: secondScriptID).write(to: secondFileURL)

        let task = Task {
            await LibraryDataManager.shared.importOPML(
                fileURLs: [firstFileURL, secondFileURL],
                realmConfiguration: configuration,
                afterImportingFile: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        let result = await task.value
        XCTAssertEqual(result.outcomes, [
            .committed(fileURL: firstFileURL),
            .notStarted(fileURL: secondFileURL),
        ])
        let snapshot = try await importSnapshot(configuration: configuration)
        XCTAssertEqual(snapshot.scriptIDs, [firstScriptID])
        XCTAssertEqual(snapshot.membershipIDs, [firstScriptID])
        XCTAssertEqual(snapshot.mutationCount, 2)
    }

    func testNewerBatchPreservesOldCommitAndSupersedesRemainingFiles() async throws {
        let configuration = makeConfiguration()
        let firstScriptID = UUID()
        let skippedScriptID = UUID()
        let newerScriptID = UUID()
        let firstFileURL = temporaryOPMLFileURL()
        let skippedFileURL = temporaryOPMLFileURL()
        let newerFileURL = temporaryOPMLFileURL()
        defer {
            try? FileManager.default.removeItem(at: firstFileURL)
            try? FileManager.default.removeItem(at: skippedFileURL)
            try? FileManager.default.removeItem(at: newerFileURL)
        }
        try makeUserScriptOPMLData(title: "Old committed", id: firstScriptID).write(to: firstFileURL)
        try makeUserScriptOPMLData(title: "Old skipped", id: skippedScriptID).write(to: skippedFileURL)
        try makeUserScriptOPMLData(title: "New committed", id: newerScriptID).write(to: newerFileURL)

        let result = await LibraryDataManager.shared.importOPML(
            fileURLs: [firstFileURL, skippedFileURL],
            realmConfiguration: configuration,
            afterImportingFile: { _ in
                let newerResult = await LibraryDataManager.shared.importOPML(
                    fileURLs: [newerFileURL],
                    realmConfiguration: configuration
                )
                XCTAssertEqual(newerResult.outcomes, [.committed(fileURL: newerFileURL)])
            }
        )
        XCTAssertEqual(result.outcomes, [
            .committed(fileURL: firstFileURL),
            .notStarted(fileURL: skippedFileURL),
        ])
        let snapshot = try await importSnapshot(configuration: configuration)
        XCTAssertEqual(Set(snapshot.scriptIDs), Set([firstScriptID, newerScriptID]))
        XCTAssertEqual(snapshot.membershipIDs, [firstScriptID, newerScriptID])
        XCTAssertEqual(snapshot.mutationCount, 3)
    }

    func testCancellationInsideTransactionRollsBackGraphAndJournal() async throws {
        let configuration = makeConfiguration()
        let firstFileURL = temporaryOPMLFileURL()
        let secondFileURL = temporaryOPMLFileURL()
        defer {
            LibraryDataManager.opmlImportTransactionTestHook = nil
            try? FileManager.default.removeItem(at: firstFileURL)
            try? FileManager.default.removeItem(at: secondFileURL)
        }
        try makeUserScriptOPMLData(title: "Rolled back", id: UUID()).write(to: firstFileURL)
        try makeUserScriptOPMLData(title: "Not started", id: UUID()).write(to: secondFileURL)
        LibraryDataManager.opmlImportTransactionTestHook = { throw CancellationError() }

        let result = await LibraryDataManager.shared.importOPML(
            fileURLs: [firstFileURL, secondFileURL],
            realmConfiguration: configuration
        )
        XCTAssertEqual(result.outcomes, [
            .cancelled(fileURL: firstFileURL),
            .notStarted(fileURL: secondFileURL),
        ])
        let snapshot = try await importSnapshot(configuration: configuration)
        XCTAssertTrue(snapshot.scriptIDs.isEmpty)
        XCTAssertEqual(snapshot.configurationCount, 0)
        XCTAssertEqual(snapshot.mutationCount, 0)
        XCTAssertEqual(snapshot.leaseCount, 1)
    }

    func testStaleLeaseCannotCommitImportedGraph() async throws {
        let configuration = makeConfiguration()
        let staleToken = try await LibraryDataManager.acquireOPMLImportLease(
            realmConfiguration: configuration
        )
        _ = try await LibraryDataManager.acquireOPMLImportLease(realmConfiguration: configuration)
        do {
            try await LibraryDataManager.importOPMLForTesting(
                data: makeUserScriptOPMLData(title: "Stale", id: UUID()),
                realmConfiguration: configuration,
                leaseToken: staleToken
            )
            XCTFail("A stale lease must reject the import")
        } catch LibraryOPMLImportCommandError.superseded {
            // Expected rejection before any imported graph is committed.
        }
        let snapshot = try await importSnapshot(configuration: configuration)
        XCTAssertTrue(snapshot.scriptIDs.isEmpty)
        XCTAssertEqual(snapshot.configurationCount, 0)
        XCTAssertEqual(snapshot.mutationCount, 0)
        XCTAssertEqual(snapshot.leaseCount, 1)
    }

    @RealmBackgroundActor
    private func importSnapshot(configuration: Realm.Configuration) async throws -> (
        scriptIDs: [UUID],
        membershipIDs: [UUID],
        configurationCount: Int,
        mutationCount: Int,
        leaseCount: Int
    ) {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        return (
            Array(realm.objects(UserScript.self).map(\.id)),
            realm.objects(LibraryConfiguration.self).first.map { Array($0.userScriptIDs) } ?? [],
            realm.objects(LibraryConfiguration.self).count,
            realm.objects(BigSyncPendingMutation.self).count,
            realm.objects(LibraryOPMLImportLease.self).count
        )
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
            FeedCategory.self,
            FeedDirectory.self,
            Feed.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func temporaryOPMLFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).opml")
    }

    private func makeUserScriptOPMLData(title: String, id: UUID) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <body>
                <outline text="User Scripts" isUserScriptList="true">
                  <outline text="\(title)" uuid="\(id.uuidString)" script="window.test%20%3D%20true%3B" />
                </outline>
              </body>
            </opml>
            """.utf8
        )
    }

    @RealmBackgroundActor
    private func pendingMutation(
        for object: Object,
        in realm: Realm
    ) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let objectIdentifier = String(describing: object[primaryKey]!)
        return realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + objectIdentifier
        )
    }
}
