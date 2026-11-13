import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

private enum CloudDriveStatusFixtureError: Error {
    case unavailable
}

/// Only the I/O boundary is controlled; the production model owns all polling,
/// task cancellation, replacement admission and status publication.
private actor CloudDriveStatusProbe {
    private var immediateResult: CloudDriveSyncStatus?
    private var requestedURLs: [URL] = []
    private var reads: [Int: CheckedContinuation<CloudDriveSyncStatus, Error>] = [:]
    private var observers: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completedCancellation: [Int: Bool] = [:]

    init(immediateResult: CloudDriveSyncStatus? = nil) {
        self.immediateResult = immediateResult
    }

    func read(_ url: URL) async throws -> CloudDriveSyncStatus {
        let index = requestedURLs.count
        requestedURLs.append(url)
        defer { completedCancellation[index] = Task.isCancelled }
        if let immediateResult {
            for observer in observers.removeValue(forKey: index) ?? [] {
                observer.resume()
            }
            return immediateResult
        }
        // Intentionally noncooperative, like a file-coordination operation that
        // completes successfully after its task was cancelled.
        return try await withCheckedThrowingContinuation { continuation in
            reads[index] = continuation
            for observer in observers.removeValue(forKey: index) ?? [] {
                observer.resume()
            }
        }
    }

    func waitForRequest(_ index: Int) async {
        if requestedURLs.count > index { return }
        await withCheckedContinuation { continuation in
            observers[index, default: []].append(continuation)
        }
    }

    func succeed(_ index: Int, with status: CloudDriveSyncStatus) {
        reads.removeValue(forKey: index)?.resume(returning: status)
    }

    func fail(_ index: Int) {
        reads.removeValue(forKey: index)?.resume(throwing: CloudDriveStatusFixtureError.unavailable)
    }

    func returnImmediatelyForFutureReads(with status: CloudDriveSyncStatus) {
        immediateResult = status
    }

    func urls() -> [URL] { requestedURLs }
    func wasCancelled(_ index: Int) -> Bool? { completedCancellation[index] }
}

private actor CloudDriveRefreshDelay {
    private var starts = 0
    private var delays: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func wait() async {
        let index = starts
        starts += 1
        await withCheckedContinuation { continuation in
            delays[index] = continuation
            for observer in observers.removeValue(forKey: index) ?? [] {
                observer.resume()
            }
        }
    }

    func waitUntilStarted(_ index: Int) async {
        if starts > index { return }
        await withCheckedContinuation { continuation in
            observers[index, default: []].append(continuation)
        }
    }

    func resume(_ index: Int) {
        delays.removeValue(forKey: index)?.resume()
    }
}

@MainActor
private final class CloudDriveStatusFixture {
    let realm: Realm
    let file: ContentFile

    init() throws {
        let realm = try Realm(configuration: Realm.Configuration(
            inMemoryIdentifier: "CloudDriveStatus-\(UUID().uuidString)",
            objectTypes: [ContentFile.self]
        ))
        let file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/status.epub")!
        file.updateCompoundKey()
        try realm.write { realm.add(file) }
        self.realm = realm
        self.file = file
    }
}

@MainActor
final class CloudDriveSyncStatusModelTests: XCTestCase {
    private func makeModel(
        probe: CloudDriveStatusProbe,
        delay: CloudDriveRefreshDelay = CloudDriveRefreshDelay()
    ) -> CloudDriveSyncStatusModel {
        CloudDriveSyncStatusModel(
            readStatus: { try await probe.read($0) },
            waitBeforeRefresh: { await delay.wait() }
        )
    }

    func testAlreadyInvalidatedRowDoesNotStartStatusIO() async throws {
        let fixture = try CloudDriveStatusFixture()
        try fixture.realm.write { fixture.realm.delete(fixture.file) }
        let probe = CloudDriveStatusProbe(immediateResult: .availableLocally)
        let model = makeModel(probe: probe)

        await model.refreshAsync(item: fixture.file)

        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
        XCTAssertTrue(model.status == .loadingStatus)
    }

    func testAlreadyTombstonedRowDoesNotStartStatusIO() async throws {
        let fixture = try CloudDriveStatusFixture()
        try fixture.realm.write { fixture.file.isDeleted = true }
        XCTAssertFalse(fixture.file.isInvalidated)
        let probe = CloudDriveStatusProbe(immediateResult: .availableLocally)
        let model = makeModel(probe: probe)

        await model.refreshAsync(item: fixture.file)

        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
        XCTAssertTrue(model.status == .loadingStatus)
    }

    func testTombstonedNotificationDoesNotReplaceLiveRefresh() async throws {
        let live = try CloudDriveStatusFixture()
        let removed = try CloudDriveStatusFixture()
        try removed.realm.write { removed.file.isDeleted = true }
        XCTAssertFalse(removed.file.isInvalidated)
        let probe = CloudDriveStatusProbe()
        let model = makeModel(probe: probe)
        let current = try XCTUnwrap(model.requestRefresh(item: live.file))
        await probe.waitForRequest(0)

        let rejected = model.requestRefresh(
            item: removed.file,
            matchingBackingURLString: "reader-file://file/load/local/status.epub"
        )
        XCTAssertNil(rejected)
        // If entry admission regresses, cancel its returned handle before it
        // can start controlled I/O. The original request's cancellation and
        // publication below still expose the regression without hanging.
        rejected?.cancel()
        await rejected?.value
        await probe.succeed(0, with: .availableLocally)
        await current.value

        let urls = await probe.urls()
        let wasCancelled = await probe.wasCancelled(0)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(wasCancelled, false)
        XCTAssertTrue(model.status == .availableLocally)
    }

    func testInvalidatedNotificationDoesNotReadManagedURLOrStartIO() async throws {
        let fixture = try CloudDriveStatusFixture()
        try fixture.realm.write { fixture.realm.delete(fixture.file) }
        let probe = CloudDriveStatusProbe(immediateResult: .availableLocally)
        let model = makeModel(probe: probe)

        let request = model.requestRefresh(
            item: fixture.file,
            matchingBackingURLString: "reader-file://file/load/local/status.epub"
        )

        let urls = await probe.urls()
        XCTAssertNil(request)
        XCTAssertEqual(urls, [])
        XCTAssertTrue(model.status == .loadingStatus)
    }

    func testNonmatchingNotificationDoesNotReplaceCurrentRefresh() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        let model = makeModel(probe: probe)
        let current = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)

        let rejected = model.requestRefresh(
            item: fixture.file,
            matchingBackingURLString: "reader-file://file/load/local/different.epub"
        )
        XCTAssertNil(rejected)
        await probe.succeed(0, with: .availableLocally)
        await current.value

        let urls = await probe.urls()
        let wasCancelled = await probe.wasCancelled(0)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(wasCancelled, false)
        XCTAssertTrue(model.status == .availableLocally)
    }

    func testMatchingNotificationUsesCanonicalBackingIdentity() async throws {
        let fixture = try CloudDriveStatusFixture()
        let contentURL = URL(string: "ebook://ebook/load/local/status.epub?subpath=chapter.xhtml#section")!
        try fixture.realm.write { fixture.file.url = contentURL }
        let probe = CloudDriveStatusProbe()
        let model = makeModel(probe: probe)

        let request = try XCTUnwrap(model.requestRefresh(
            item: fixture.file,
            matchingBackingURLString: "reader-file://file/load/local/status.epub"
        ))
        await probe.waitForRequest(0)
        await probe.succeed(0, with: .availableLocally)
        await request.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [contentURL])
        XCTAssertTrue(model.status == .availableLocally)
    }

    func testPreCancelledRequestDoesNotStartStatusIO() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe(immediateResult: .availableLocally)
        let model = makeModel(probe: probe)
        let request = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.refreshAsync(item: fixture.file)
        }

        await request.value

        let urls = await probe.urls()
        XCTAssertTrue(request.isCancelled)
        XCTAssertEqual(urls, [])
        XCTAssertTrue(model.status == .loadingStatus)
    }

    func testOlderNoncooperativeReadCannotReplaceNewerStatus() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        let model = makeModel(probe: probe)
        let older = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)
        let newer = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(1)

        await probe.succeed(1, with: .availableLocally)
        await newer.value
        await probe.succeed(0, with: .cloudOnly)
        await older.value

        let oldWasCancelled = await probe.wasCancelled(0)
        let newWasCancelled = await probe.wasCancelled(1)
        XCTAssertEqual(oldWasCancelled, true)
        XCTAssertEqual(newWasCancelled, false)
        XCTAssertTrue(model.status == .availableLocally)
    }

    func testCallerCancellationReachesPendingIOAndSuppressesPublication() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        let model = makeModel(probe: probe)
        let request = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)

        request.cancel()
        await probe.succeed(0, with: .availableLocally)
        await request.value

        let wasCancelled = await probe.wasCancelled(0)
        XCTAssertEqual(wasCancelled, true)
        XCTAssertTrue(model.status == .loadingStatus)
    }

    func testNotificationRefreshDoesNotRetainRetiredModelWhileIOIsSuspended() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        var model: CloudDriveSyncStatusModel? = makeModel(probe: probe)
        weak var retiredModel = model
        let request = try XCTUnwrap(model?.requestRefresh(item: fixture.file))
        await probe.waitForRequest(0)

        model = nil
        XCTAssertNil(retiredModel)
        await probe.succeed(0, with: .availableLocally)
        await request.value

        let wasCancelled = await probe.wasCancelled(0)
        XCTAssertEqual(wasCancelled, true)
    }

    func testLateCancellationAndSettlementOfOldCallerLeaveSuccessorRunning() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        let model = makeModel(probe: probe)
        let older = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)
        let newer = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(1)

        older.cancel()
        await probe.fail(0)
        await older.value
        await probe.succeed(1, with: .availableLocally)
        await newer.value

        let newWasCancelled = await probe.wasCancelled(1)
        XCTAssertEqual(newWasCancelled, false)
        XCTAssertTrue(model.status == .availableLocally)
    }

    private func assertReadRejectedAfterRowChange(
        _ change: (CloudDriveStatusFixture) throws -> Void
    ) async throws {
        let fixture = try CloudDriveStatusFixture()
        let originalURL = fixture.file.url
        let probe = CloudDriveStatusProbe()
        let model = makeModel(probe: probe)
        let request = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)

        try change(fixture)
        await probe.succeed(0, with: .availableLocally)
        await request.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [originalURL])
        XCTAssertTrue(model.status == .loadingStatus)
    }

    func testChangedURLRejectsOriginalStatusResponse() async throws {
        try await assertReadRejectedAfterRowChange { fixture in
            try fixture.realm.write {
                fixture.file.url = URL(string: "reader-file://file/load/local/replacement.epub")!
            }
        }
    }

    func testTombstoneRejectsPendingStatusResponse() async throws {
        try await assertReadRejectedAfterRowChange { fixture in
            try fixture.realm.write { fixture.file.isDeleted = true }
            XCTAssertFalse(fixture.file.isInvalidated)
        }
    }

    func testChangedCreationIdentityRejectsOriginalStatusResponse() async throws {
        try await assertReadRejectedAfterRowChange { fixture in
            try fixture.realm.write {
                fixture.file.createdAt = fixture.file.createdAt.addingTimeInterval(1)
            }
        }
    }

    func testPhysicalReplacementWithSameKeyAndDateCannotAdoptOldResponse() async throws {
        try await assertReadRejectedAfterRowChange { fixture in
            let replacement = ContentFile()
            replacement.compoundKey = fixture.file.compoundKey
            replacement.url = fixture.file.url
            replacement.createdAt = fixture.file.createdAt
            try fixture.realm.write {
                fixture.realm.delete(fixture.file)
                fixture.realm.add(replacement)
            }
            XCTAssertTrue(fixture.file.isInvalidated)
            XCTAssertFalse(replacement.isInvalidated)
        }
    }

    func testCancelledPollingStopsAfterNoncooperativeDelay() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        let delay = CloudDriveRefreshDelay()
        let model = makeModel(probe: probe, delay: delay)
        let request = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)
        await probe.succeed(0, with: .downloading)
        await delay.waitUntilStarted(0)

        request.cancel()
        await delay.resume(0)
        await request.value

        let urls = await probe.urls()
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(model.status == .downloading)
    }

    func testDeletedRowStopsBeforeTheNextPollingRead() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        let delay = CloudDriveRefreshDelay()
        let model = makeModel(probe: probe, delay: delay)
        let request = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)
        await probe.succeed(0, with: .downloading)
        await delay.waitUntilStarted(0)

        try fixture.realm.write { fixture.realm.delete(fixture.file) }
        await delay.resume(0)
        await request.value

        let urls = await probe.urls()
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(model.status == .downloading)
    }

    func testTombstonedRowStopsBeforeTheNextPollingRead() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        let delay = CloudDriveRefreshDelay()
        let model = makeModel(probe: probe, delay: delay)
        let request = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)
        await probe.succeed(0, with: .downloading)
        await delay.waitUntilStarted(0)

        try fixture.realm.write { fixture.file.isDeleted = true }
        XCTAssertFalse(fixture.file.isInvalidated)
        // A regressed second read completes instead of hanging in the I/O
        // fixture. Its extra request and publication both fail below.
        await probe.returnImmediatelyForFutureReads(with: .availableLocally)
        await delay.resume(0)
        await request.value

        let urls = await probe.urls()
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(model.status == .downloading)
    }

    func testCurrentFailureAllowsRetryForTheSameFile() async throws {
        let fixture = try CloudDriveStatusFixture()
        let probe = CloudDriveStatusProbe()
        let model = makeModel(probe: probe)
        let failed = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)
        await probe.fail(0)
        await failed.value
        XCTAssertTrue(model.status == .loadingStatus)

        let retry = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(1)
        await probe.succeed(1, with: .availableLocally)
        await retry.value

        XCTAssertTrue(model.status == .availableLocally)
    }

    func testCurrentPollingKeepsCapturedURLAndPublishesCompletion() async throws {
        let fixture = try CloudDriveStatusFixture()
        let originalURL = fixture.file.url
        let probe = CloudDriveStatusProbe()
        let delay = CloudDriveRefreshDelay()
        let model = makeModel(probe: probe, delay: delay)
        let request = Task { @MainActor in await model.refreshAsync(item: fixture.file) }
        await probe.waitForRequest(0)
        await probe.succeed(0, with: .downloading)
        await delay.waitUntilStarted(0)
        XCTAssertTrue(model.status == .downloading)

        await delay.resume(0)
        await probe.waitForRequest(1)
        await probe.succeed(1, with: .availableLocally)
        await request.value

        let urls = await probe.urls()
        XCTAssertEqual(urls, [originalURL, originalURL])
        XCTAssertTrue(model.status == .availableLocally)
    }
}
