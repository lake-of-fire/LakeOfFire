import Foundation
import XCTest
@testable import LakeOfFireContent

/// Actual fingerprint, snapshot, package decoder and registry. File copying is
/// the existing immutable-fixture seam; Apple coordination is covered separately.
final class ReaderEBookServingSessionTests: XCTestCase {
    private let sourceURL = URL(string: "ebook://ebook/load/local/Books/book.epub")!
    private func bytes(_ text: String = "Original", name: String = "OPS/chapter.xhtml") -> Data {
        let files: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='OPS/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"),
            ("OPS/book.opf", "<package><spine/></package>"), (name, text),
        ]
        return EBookZIPPathFixture.archive(files.map {
            EBookZIPPathFixture.File(name: Data($0.0.utf8), bytes: Data($0.1.utf8))
        })
    }
    private func package(_ text: String = "Original", name: String = "OPS/chapter.xhtml",
                         sourceURL: URL? = nil) throws -> ReaderEBookServingPackage {
        try EBookZIPPathFixture.withFile(bytes(text, name: name)) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            return try .init(sourceURL: sourceURL ?? self.sourceURL, snapshot: snapshot, packageDocumentPath: "OPS/book.opf")
        }
    }
    func testServesTheSameResourcesAsTheStrictFingerprint() throws {
        let package = try package()
        let store = ReaderEBookServingSessionStore()
        let lease = try store.install(package)
        XCTAssertEqual(Set(package.entries.map(\.path)), Set(package.fingerprint.resources.map(\.path)))
        XCTAssertEqual(try lease.readEntry(subpath: "OPS/chapter.xhtml"), Data("Original".utf8))
        XCTAssertEqual(try lease.metadata(subpath: "OPS/chapter.xhtml", data: Data("Original".utf8)).mimeType, "application/xhtml+xml")
    }
    func testSameURLDifferentRevisionKeepsBothSnapshotsIndependent() throws {
        let store = ReaderEBookServingSessionStore()
        let first = try store.install(package("First")), second = try store.install(package("Second"))
        XCTAssertNotEqual(first.generationID, second.generationID)
        XCTAssertNotEqual(first.package.fileVersionToken, second.package.fileVersionToken)
        XCTAssertEqual(try store.capture(sourceURL: sourceURL, sessionID: first.id)?.readEntry(subpath: "OPS/chapter.xhtml"), Data("First".utf8))
        XCTAssertEqual(try store.capture(sourceURL: sourceURL, sessionID: second.id)?.readEntry(subpath: "OPS/chapter.xhtml"), Data("Second".utf8))
    }
    func testUnchangedReopenDoesNotChangeThePersistentContentObservation() throws {
        let store = ReaderEBookServingSessionStore()
        let first = try store.install(package()), second = try store.install(package())
        XCTAssertEqual(first.package.fileVersionToken, second.package.fileVersionToken)
        XCTAssertEqual(first.package.fingerprint, second.package.fingerprint)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.generationID, second.generationID)
        XCTAssertNoThrow(try first.validate())
    }
    func testAnUnboundReaderRetainsItsExplicitLegacyPath() throws {
        let store = ReaderEBookServingSessionStore()
        XCTAssertNil(try store.capture(sourceURL: sourceURL, sessionID: nil))
        XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: UUID().uuidString.lowercased()))
    }
    func testBoundReaderNeverFallsBackAfterCapabilityOmissionOrWithdrawal() throws {
        let store = ReaderEBookServingSessionStore()
        let lease = try store.install(package())
        XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: nil))
        store.withdraw(lease)
        XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: lease.id))
        XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: nil))
        XCTAssertThrowsError(try lease.readEntry(subpath: "OPS/chapter.xhtml"))
    }
    func testForeignStoreCannotWithdrawAnotherReadersLease() throws {
        let owner = ReaderEBookServingSessionStore(), unrelated = ReaderEBookServingSessionStore()
        let lease = try owner.install(package())
        unrelated.withdraw(lease)
        XCTAssertNoThrow(try lease.validate())
        XCTAssertTrue(try owner.capture(sourceURL: sourceURL, sessionID: lease.id) === lease)
    }
    func testWithdrawingOneLeaseDoesNotInvalidateAnotherOwnerOfTheSamePackage() throws {
        let store = ReaderEBookServingSessionStore(), package = try package()
        let first = try store.install(package), second = try store.install(package)
        store.withdraw(first)
        XCTAssertThrowsError(try first.validate())
        XCTAssertEqual(try second.readEntry(subpath: "OPS/chapter.xhtml"), Data("Original".utf8))
    }
    func testWrongSourceOrGenerationCannotBorrowAValidCapability() throws {
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package())
        XCTAssertThrowsError(try store.capture(sourceURL: URL(string: "ebook://ebook/load/local/other.epub")!, sessionID: lease.id))
        XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: lease.id, generationID: "g1-" + String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: lease.id.uppercased()))
        XCTAssertTrue(try store.capture(sourceURL: sourceURL, sessionID: lease.id, generationID: lease.generationID) === lease)
    }
    func testCapacityRejectsRatherThanEvictingAnOpenDocument() throws {
        let store = ReaderEBookServingSessionStore(maximumSessions: 1), package = try package()
        let lease = try store.install(package)
        XCTAssertThrowsError(try store.install(package))
        XCTAssertNoThrow(try lease.validate())
        store.withdraw(lease)
        XCTAssertNoThrow(try store.install(package))
    }
    func testCloseRevokesCapturedWorkAndCannotBeReopenedImplicitly() throws {
        let store = ReaderEBookServingSessionStore(), package = try package()
        let lease = try store.install(package)
        store.close()
        XCTAssertThrowsError(try lease.validate())
        XCTAssertThrowsError(try store.install(package))
        XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: nil))
    }
    func testSourceRemovalDoesNotChangeTheOwnedRevision() throws {
        // package() removes its original fixture before returning; no original
        // URL or current-source cache participates in this read.
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package("Kept"))
        XCTAssertEqual(try lease.readEntry(subpath: "OPS/chapter.xhtml"), Data("Kept".utf8))
    }
    func testLiteralPercentPathIsNotAnAliasForAnotherResource() throws {
        let store = ReaderEBookServingSessionStore()
        let lease = try store.install(package("Literal", name: "OPS/%2F日本語.xhtml"))
        XCTAssertEqual(try lease.readEntry(subpath: "OPS/%2F日本語.xhtml"), Data("Literal".utf8))
        XCTAssertThrowsError(try lease.readEntry(subpath: "OPS//日本語.xhtml"))
        XCTAssertThrowsError(try lease.readEntry(subpath: "OPS/%252F日本語.xhtml"))
    }
    func testCanonicalUnicodeURLSpellingDoesNotRetargetThePhysicalBinding() throws {
        let first = URL(string: "ebook://ebook/load/local/caf%C3%A9.epub")!
        let other = URL(string: "ebook://ebook/load/local/cafe%CC%81.epub")!
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package(sourceURL: first))
        XCTAssertThrowsError(try store.capture(sourceURL: other, sessionID: lease.id))
    }
    func testChangedPrivateSnapshotRejectsInsteadOfReturningOtherBytes() throws {
        try EBookZIPPathFixture.withFile(bytes()) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: "OPS/book.opf")
            let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.packageURL.path)
            try bytes("Replacement").write(to: snapshot.packageURL, options: .atomic)
            XCTAssertThrowsError(try lease.readEntry(subpath: "OPS/chapter.xhtml"))
            XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: lease.id))
        }
    }
    func testSnapshotIsRetainedUntilTheLastPackageOwnerLeaves() throws {
        var retainedPackage: ReaderEBookServingPackage?
        var snapshotURL: URL!
        try EBookZIPPathFixture.withFile(bytes()) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            snapshotURL = snapshot.packageURL
            retainedPackage = try .init(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: "OPS/book.opf")
        }
        var store: ReaderEBookServingSessionStore? = ReaderEBookServingSessionStore()
        var lease: ReaderEBookServingLease? = try store!.install(retainedPackage!)
        retainedPackage = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        store = nil
        XCTAssertThrowsError(try lease!.validate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        lease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }
    func testCancelledReadDoesNotSucceedAgainstAnOtherwiseValidLease() async throws {
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package())
        let rejected = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try lease.readEntry(subpath: "OPS/chapter.xhtml"); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(rejected)
        XCTAssertNoThrow(try lease.validate())
    }
    func testLegacyCaptureCannotOutliveActivationOfBoundServing() throws {
        let store = ReaderEBookServingSessionStore(), binding = ReaderEBookServingSessionBinding(store: store)
        let old = try binding.capture(sourceURL: sourceURL, sessionID: nil)
        XCTAssertNoThrow(try old.validate())
        _ = try store.install(package())
        XCTAssertThrowsError(try old.validate())
    }
    func testReplacingOneReadersRegistrationDoesNotCloseAnotherReadersStore() throws {
        let shared = ReaderEBookServingSessionStore(), lease = try shared.install(package())
        let first = ReaderEBookServingSessionBinding(store: shared), other = ReaderEBookServingSessionBinding(store: shared)
        let old = try first.capture(sourceURL: sourceURL, sessionID: lease.id)
        let unaffected = try other.capture(sourceURL: sourceURL, sessionID: lease.id)
        first.replace(with: ReaderEBookServingSessionStore())
        XCTAssertThrowsError(try old.validate())
        XCTAssertNoThrow(try unaffected.validate())
    }
    func testReapplyingSameStoreDoesNotRevokeAnUnchangedReader() throws {
        let store = ReaderEBookServingSessionStore(), lease = try store.install(package())
        let binding = ReaderEBookServingSessionBinding(store: store)
        let captured = try binding.capture(sourceURL: sourceURL, sessionID: lease.id)
        binding.replace(with: store)
        XCTAssertNoThrow(try captured.validate())
    }

}
