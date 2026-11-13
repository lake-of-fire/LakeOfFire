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

    func testFullRetainedBudgetRejectsNewAssetWithoutEviction() async throws {
        let registry = TranscriptPageRegistry(maximumAssetCount: 2)
        let first = asset("first")
        let second = asset("second", documentID: "second")
        let third = asset("third", documentID: "third")
        _ = await registry.register(first)
        _ = await registry.register(second)
        await registry.retain(key: first.key, forDocumentID: "first")
        await registry.retain(key: second.key, forDocumentID: "second")
        let rejected = await registry.register(third)
        XCTAssertFalse(rejected)
        let retainedFirst = await registry.asset(forKey: first.key)
        let retainedSecond = await registry.asset(forKey: second.key)
        XCTAssertEqual(retainedFirst, first)
        XCTAssertEqual(retainedSecond, second)
        await registry.release(documentID: "first")
        let retry = await registry.register(third)
        XCTAssertTrue(retry)
        let surviving = await registry.asset(forKey: second.key)
        XCTAssertEqual(surviving, second)
    }

    func testRetainedServingKeyCannotBeReboundToAnotherOwner() async {
        let registry = TranscriptPageRegistry()
        let first = asset("shared")
        _ = await registry.register(first)
        await registry.retain(key: first.key, forDocumentID: "first")
        let replacement = asset("shared", documentID: "replacement")
        let accepted = await registry.register(replacement)
        XCTAssertFalse(accepted)
        let surviving = await registry.asset(forKey: first.key)
        XCTAssertEqual(surviving, first)
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
}
