import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftUIDownloads
import XCTest
@testable import LakeOfFireContent

@MainActor
final class LibraryObserverRealmPortTests: XCTestCase {
    func testScriptObserverStaysBoundToRealmCapturedAtSubscription() async throws {
        try await verifyObserver(changesLibraryConfiguration: false)
    }

    func testConfigurationObserverStaysBoundToRealmCapturedAtSubscription() async throws {
        try await verifyObserver(changesLibraryConfiguration: true)
    }

    private func verifyObserver(changesLibraryConfiguration: Bool) async throws {
        try XCTSkipUnless(DownloadController.shared.finishedDownloads.isEmpty,
            "Requires isolated qualification with no finished downloads; preserve unrelated shared downloads")
        let observed = Self.configuration()
        let replacement = Self.configuration()
        let notifications = await LibraryObserverNotifications()
        let fixture = LibraryObserverFixture(observed: observed, replacement: replacement,
                                             notifications: notifications)
        addTeardownBlock { await fixture.close() }
        let initial = try await Self.installLibrary(in: observed)
        try fixture.start()
        let installed = try await eventually {
            guard let manager = fixture.manager, manager.cancellables.count == 1 else { return false }
            return await { @RealmBackgroundActor in manager.realmCancellables.count == 2 }()
        }
        guard installed else { XCTFail("The actual three subscriptions must install"); return }
        fixture.stopDownloadObservation()

        // Count completed production refreshes, including their owned writes,
        // then drain trailing initial/configuration notifications. An initial
        // callback must not mask a broken subscription after the global switch.
        let settled = try await eventually { await fixture.recorder.isQuiescent(minimum: 2) }
        guard settled else { XCTFail("Initial actual observer refreshes did not settle"); return }
        let baseline = await fixture.recorder.snapshot()
        XCTAssertTrue(baseline.failures.isEmpty, "\(baseline.failures)")
        XCTAssertEqual(Set(baseline.configurations), [observed.inMemoryIdentifier!])
        let initialState = try await Self.state(id: initial.libraryID, in: observed)
        XCTAssertEqual(initialState.scriptIDs, [initial.scriptID])

        let unrelated = try await Self.installLibrary(in: replacement)
        let replacementBefore = try await Self.state(id: unrelated.libraryID, in: replacement)
        XCTAssertTrue(replacementBefore.scriptIDs.isEmpty)
        XCTAssertNil(replacementBefore.generation)

        let ready = expectation(description: "Chosen source collection initial notification delivered")
        let changed = expectation(description: "Chosen A collection delivers its actual update")
        changed.assertForOverFulfill = false
        try await notifications.install(configuration: observed, libraryID: initial.libraryID,
            changesLibraryConfiguration: changesLibraryConfiguration,
            ready: { ready.fulfill() }, changed: { changed.fulfill() })
        await fulfillment(of: [ready], timeout: 5)
        LibraryDataManager.realmConfiguration = replacement
        let expectedID = try await notifications.mutate(configuration: observed,
            libraryID: initial.libraryID, initialScriptID: initial.scriptID,
            changesLibraryConfiguration: changesLibraryConfiguration)
        await fulfillment(of: [changed], timeout: 5)

        let refreshed = try await eventually {
            await fixture.recorder.isQuiescent(minimum: baseline.completed + 1)
        }
        guard refreshed else { XCTFail("Chosen actual subscription did not finish a new refresh"); return }
        let after = await fixture.recorder.snapshot()
        XCTAssertTrue(after.failures.isEmpty, "\(after.failures)")
        XCTAssertEqual(Set(after.configurations.dropFirst(baseline.completed)),
                       [observed.inMemoryIdentifier!],
                       "An A subscriber must never forward the mutable B configuration")
        let observedAfter = try await Self.state(id: initial.libraryID, in: observed)
        XCTAssertTrue(observedAfter.scriptIDs.contains(expectedID), "The actual callback must repair A")
        XCTAssertNotNil(observedAfter.generation)
        let replacementAfter = try await Self.state(id: unrelated.libraryID, in: replacement)
        XCTAssertEqual(replacementAfter, replacementBefore,
                       "An A notification must not reconcile, create a library, or journal B")
    }

    private func eventually(timeout: TimeInterval = 8,
                            condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await condition()
    }

    private static func configuration() -> Realm.Configuration {
        var value = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        value.objectTypes = [LibraryConfiguration.self, FeedCategory.self,
                             UserScript.self, UserScriptAllowedDomain.self]
        configureLakeOfFireMutationTrackingForTesting(&value)
        return value
    }

    @RealmBackgroundActor
    private static func installLibrary(in configuration: Realm.Configuration) async throws
        -> (libraryID: UUID, scriptID: UUID) {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let library = LibraryConfiguration()
        let script = UserScript()
        // Leave an actionable, unjournaled orphan: the wrong-Realm callback
        // cannot pass by finding an already reconciled replacement library.
        try await realm.asyncWritePreservingOwnership { realm.add([library, script]) }
        return (library.id, script.id)
    }

    private struct LibraryState: Equatable, Sendable {
        let scriptIDs: [UUID]
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
        let generation: String?
        let journalChangedAt: Date?
        let activeLibraryIDs: [UUID]
        let journalCount: Int
    }

    @RealmBackgroundActor
    private static func state(id: UUID, in configuration: Realm.Configuration) async throws -> LibraryState {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        await realm.asyncRefresh()
        let library = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: id))
        let mutation = realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: library.objectSchema.className + "." + String(describing: library.id))
        return LibraryState(scriptIDs: Array(library.userScriptIDs), modifiedAt: library.modifiedAt,
            explicitlyModifiedAt: library.explicitlyModifiedAt, generation: mutation?.generation,
            journalChangedAt: mutation?.changedAt,
            activeLibraryIDs: realm.objects(LibraryConfiguration.self).where { !$0.isDeleted }
                .map(\.id).sorted { $0.uuidString < $1.uuidString },
            journalCount: realm.objects(BigSyncPendingMutation.self).count)
    }
}

private actor LibraryObserverRecorder {
    struct Snapshot: Sendable {
        let completed: Int
        let configurations: [String]
        let failures: [String]
    }
    private var inFlight = 0
    private var configurations: [String] = []
    private var failures: [String] = []
    private var lastActivity = Date()
    func begin() { inFlight += 1; lastActivity = Date() }
    func finish(configuration: String, failure: String? = nil) {
        inFlight -= 1
        configurations.append(configuration)
        if let failure { failures.append(failure) }
        lastActivity = Date()
    }
    func snapshot() -> Snapshot {
        Snapshot(completed: configurations.count, configurations: configurations, failures: failures)
    }
    func isQuiescent(minimum: Int) -> Bool {
        // Shipping publishers debounce for 0.3 seconds: actual completions and
        // no start/finish for more than two periods, rather than a bare sleep.
        inFlight == 0 && configurations.count >= minimum
            && Date().timeIntervalSince(lastActivity) >= 0.7
    }
}

// Test-only override delegates to production and records completion via an actor.
private final class LibraryObservedDataManager: LibraryDataManager {
    let recorder: LibraryObserverRecorder
    init(recorder: LibraryObserverRecorder) {
        self.recorder = recorder
        super.init(observesChanges: true)
    }
    @RealmBackgroundActor
    override func refreshScripts(realmConfiguration: Realm.Configuration) async throws {
        await recorder.begin()
        let identity = realmConfiguration.inMemoryIdentifier ?? "unexpected non-fixture Realm"
        do {
            try await super.refreshScripts(realmConfiguration: realmConfiguration)
            await recorder.finish(configuration: identity)
        } catch {
            await recorder.finish(configuration: identity, failure: String(describing: error))
            throw error
        }
    }
}

@RealmBackgroundActor
private final class LibraryObserverNotifications {
    private var token: NotificationToken?
    func install(configuration: Realm.Configuration, libraryID: UUID,
                 changesLibraryConfiguration: Bool, ready: @escaping @Sendable () -> Void,
                 changed: @escaping @Sendable () -> Void) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        if changesLibraryConfiguration {
            token = await realm.objects(LibraryConfiguration.self).where { $0.id == libraryID }.observe(on: RealmBackgroundActor.shared) { _, change in
                switch change {
                case .initial: ready()
                case .update(_, _, _, let modifications): if !modifications.isEmpty { changed() }
                case .error(let error): XCTFail("Source notification failed: \(error)"); ready()
                }
            }
        } else {
            token = await realm.objects(UserScript.self).observe(on: RealmBackgroundActor.shared) { _, change in
                switch change {
                case .initial: ready()
                case .update(_, _, let insertions, _): if !insertions.isEmpty { changed() }
                case .error(let error): XCTFail("Source notification failed: \(error)"); ready()
                }
            }
        }
    }
    func mutate(configuration: Realm.Configuration, libraryID: UUID, initialScriptID: UUID,
                changesLibraryConfiguration: Bool) async throws -> UUID {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        if changesLibraryConfiguration {
            let library = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID))
            try await realm.asyncWritePreservingOwnership {
                library.userScriptIDs.removeAll()
                library.refreshChangeMetadata(explicitlyModified: true)
            }
            return initialScriptID
        }
        let script = UserScript()
        try await realm.asyncWritePreservingOwnership { realm.add(script) }
        return script.id
    }
    func cancel() { token?.invalidate(); token = nil }
}

@MainActor
private final class LibraryObserverFixture {
    let recorder = LibraryObserverRecorder()
    private(set) var manager: LibraryObservedDataManager?
    private weak var retiringManager: LibraryObservedDataManager?
    private let observed: Realm.Configuration
    private let replacement: Realm.Configuration
    private let original: Realm.Configuration
    private let notifications: LibraryObserverNotifications
    private var didStart = false
    init(observed: Realm.Configuration, replacement: Realm.Configuration,
         notifications: LibraryObserverNotifications) {
        self.observed = observed
        self.replacement = replacement
        self.notifications = notifications
        original = LibraryDataManager.realmConfiguration
    }
    func start() throws {
        // Recheck without suspension immediately before subscribing: fixture
        // Realm setup above may have yielded to another owner.
        try XCTSkipUnless(DownloadController.shared.finishedDownloads.isEmpty,
            "Requires isolated qualification with no finished downloads; preserve unrelated shared downloads")
        // Entry requires the real shared download snapshot to be empty. Never
        // erase or restore that publisher, which could notify unrelated owners.
        LibraryDataManager.realmConfiguration = observed
        didStart = true
        manager = LibraryObservedDataManager(recorder: recorder)
    }
    func stopDownloadObservation() {
        manager?.cancellables.forEach { $0.cancel() }
        manager?.cancellables.removeAll()
    }
    func close() async {
        await notifications.cancel()
        stopDownloadObservation()
        if let manager {
            await { @RealmBackgroundActor in
                manager.realmCancellables.forEach { $0.cancel() }
                manager.realmCancellables.removeAll()
            }()
            retiringManager = manager
        }
        manager = nil
        let deadline = Date().addingTimeInterval(8)
        while retiringManager != nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if didStart { LibraryDataManager.realmConfiguration = original }
        guard retiringManager == nil else {
            XCTFail("Observer did not retire; do not evict a Realm with live callback writers")
            return
        }
        await RealmBackgroundActor.shared.removeCachedRealm(for: observed)
        await RealmBackgroundActor.shared.removeCachedRealm(for: replacement)
    }
}
