import Foundation
import XCTest
import LakeOfFireCore
import LakeOfFireContent

@MainActor
final class ReaderTranscriptRegistryOwnershipTests: XCTestCase {
    private let source = URL(string: "https://example.com/article")!
    private func asset(_ key: String, documentID: String = "first", stableKey: String? = nil) -> TranscriptPageAsset {
        let owner = ReaderMediaPlaybackOwner(canonicalContentURL: source,
            resourceIdentity: "media", documentID: documentID, playbackInstanceID: "player")
        return .fromWebVTT(key: key, canonicalContentURL: source, title: key,
            webVTT: "WEBVTT\n\n00:00.000 --> 00:01.000\n\(key)\n",
            stableContentKey: stableKey, languageIdentifier: "ja-JP", playbackOwner: owner)
    }

    func testRetainedOwnersKeepSeparateRoutesForOneStableContentIdentity() async throws {
        let registry = TranscriptPageRegistry()
        let stableKey = String(repeating: "a", count: 64)
        let first = asset("first", stableKey: stableKey)
        let second = asset("second", documentID: "second", stableKey: stableKey)
        let registeredFirst = await registry.register(first)
        let registeredSecond = await registry.register(second)
        XCTAssertTrue(registeredFirst)
        XCTAssertTrue(registeredSecond)
        await registry.retain(key: first.key, forDocumentID: "first")
        await registry.retain(key: second.key, forDocumentID: "second")
        let firstURL = try XCTUnwrap(first.pageURL)
        let secondURL = try XCTUnwrap(second.pageURL)
        let firstContent = await registry.makeReaderContent(for: firstURL)
        let secondContent = await registry.makeReaderContent(for: secondURL)
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(firstContent?.url, secondContent?.url)
        XCTAssertEqual(firstContent?.url, URL.transcriptContentIdentityURL(key: stableKey))
        XCTAssertNotEqual(firstContent?.url, source)
        await registry.release(documentID: "first")
        let retired = await registry.htmlData(for: firstURL)
        let surviving = await registry.htmlData(for: secondURL)
        XCTAssertNil(retired)
        XCTAssertEqual(surviving, Data(second.html.utf8))
    }

    func testAtomicAdmissionProtectsAcceptedRoutesUnderCapacityPressure() async throws {
        let registry = TranscriptPageRegistry(maximumAssetCount: 2)
        let existing = asset("existing")
        let first = asset("first-new", documentID: "first-new")
        let competitor = asset("competitor", documentID: "competitor")
        let admittedExisting = await registry.registerAndRetain(existing)
        let admittedFirst = await registry.registerAndRetain(first)
        let admittedCompetitor = await registry.registerAndRetain(competitor)

        XCTAssertTrue(admittedExisting)
        XCTAssertTrue(admittedFirst)
        XCTAssertFalse(admittedCompetitor)
        try await assertServing(existing, in: registry)
        try await assertServing(first, in: registry)

        await registry.release(documentID: "first-new")
        let retried = await registry.registerAndRetain(competitor)
        XCTAssertTrue(retried)
        try await assertServing(existing, in: registry)
        try await assertServing(competitor, in: registry)
        let retired = await registry.asset(forKey: first.key)
        XCTAssertNil(retired)
    }

    func testRemovingUnpublishedReplacementKeepsPriorRouteForTheSameDocument() async throws {
        let registry = TranscriptPageRegistry(maximumAssetCount: 2)
        let prior = asset("prior")
        let replacement = asset("replacement")
        let admittedPrior = await registry.registerAndRetain(prior)
        let admittedReplacement = await registry.registerAndRetain(replacement)
        XCTAssertTrue(admittedPrior)
        XCTAssertTrue(admittedReplacement)
        try await assertServing(prior, in: registry)
        try await assertServing(replacement, in: registry)

        await registry.remove(key: replacement.key)
        let rolledBack = await registry.asset(forKey: replacement.key)
        XCTAssertNil(rolledBack)
        try await assertServing(prior, in: registry)
    }

    func testRetainedServingKeyCannotBeReboundToAnotherOwner() async {
        let registry = TranscriptPageRegistry()
        let first = asset("shared")
        let admitted = await registry.registerAndRetain(first)
        XCTAssertTrue(admitted)
        let replacement = asset("shared", documentID: "replacement")
        let accepted = await registry.registerAndRetain(replacement)
        XCTAssertFalse(accepted)
        let surviving = await registry.asset(forKey: first.key)
        XCTAssertEqual(surviving, first)
    }

    func testAtomicAdmissionRejectsUnownedMismatchedAndOversizedRoutes() async throws {
        let existing = asset("existing")
        let webVTT = try XCTUnwrap(existing.webVTT)
        let byteLimit = 2 * (existing.html.utf8.count + webVTT.utf8.count)
        let registry = TranscriptPageRegistry(maximumAssetCount: 2, maximumBytes: byteLimit)
        let admitted = await registry.registerAndRetain(existing)
        XCTAssertTrue(admitted)
        let ownerless = TranscriptPageAsset(key: "ownerless", canonicalContentURL: source,
            title: "Ownerless", html: existing.html, webVTT: webVTT)
        let wrongSource = URL(string: "https://example.com/other")!
        let mismatched = TranscriptPageAsset(key: "mismatched", canonicalContentURL: wrongSource,
            title: "Mismatched", html: existing.html, webVTT: webVTT, playbackOwner: existing.playbackOwner)
        let oversized = TranscriptPageAsset(key: "oversized", canonicalContentURL: source,
            title: "Oversized", html: String(repeating: "x", count: byteLimit + 1), webVTT: webVTT,
            playbackOwner: existing.playbackOwner)

        for candidate in [ownerless, mismatched, oversized] {
            let accepted = await registry.registerAndRetain(candidate)
            let rejected = await registry.asset(forKey: candidate.key)
            XCTAssertFalse(accepted, candidate.title)
            XCTAssertNil(rejected, candidate.title)
        }
        try await assertServing(existing, in: registry)
    }

    func testOversizedAndInvalidTranscriptCannotEnterRegistry() async {
        let valid = asset("valid")
        let registry = TranscriptPageRegistry(maximumBytes: valid.html.utf8.count + valid.webVTT!.utf8.count - 1)
        let oversized = await registry.register(valid)
        XCTAssertFalse(oversized)
        let malformed = TranscriptPageAsset(key: "invalid", canonicalContentURL: source,
            title: "Invalid", html: "<p>invalid</p>", webVTT: "WEBVTT")
        let invalid = await TranscriptPageRegistry().register(malformed)
        XCTAssertFalse(invalid)
    }

    private func assertServing(
        _ asset: TranscriptPageAsset, in registry: TranscriptPageRegistry,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let html = await registry.htmlData(for: try XCTUnwrap(asset.pageURL, file: file, line: line))
        let vtt = await registry.webVTTData(for: try XCTUnwrap(asset.webVTTURL, file: file, line: line))
        XCTAssertEqual(html, Data(asset.html.utf8), file: file, line: line)
        XCTAssertEqual(vtt, Data(try XCTUnwrap(asset.webVTT, file: file, line: line).utf8), file: file, line: line)
    }
}
