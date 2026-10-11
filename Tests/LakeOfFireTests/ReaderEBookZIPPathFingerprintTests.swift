import Foundation
import XCTest
@testable import LakeOfFireContent

/// Same real package fixtures run with both supported dependency references.
/// Matching metadata must not change v1; competing namespaces cannot enroll.
final class ReaderEBookZIPPathFingerprintTests: XCTestCase {
    private func files(prefix: String = "", flags: UInt64 = 0x0800) -> [EBookZIPPathFixture.File] {
        [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container><rootfiles><rootfile full-path='OPS/book.opf'/></rootfiles></container>"),
            ("OPS/book.opf", "<package><spine/></package>"),
            ("OPS/日本語.xhtml", "<html><body>日本語の本文。</body></html>")
        ].map { .init(name: Data((prefix + $0.0).utf8), bytes: Data($0.1.utf8), flags: flags) }
    }
    private func fingerprint(_ files: [EBookZIPPathFixture.File]) throws -> ReaderEBookPackageFingerprint {
        try EBookZIPPathFixture.withFile(EBookZIPPathFixture.archive(files)) {
            try ReaderEBookPackageFingerprint.readSnapshot(at: $0, packageDocumentPath: "OPS/book.opf")
        }
    }

    func testRedundantUnicodeMetadataKeepsTheExactPackageFingerprint() throws {
        let original = files()
        var redundant = original
        for index in redundant.indices {
            redundant[index].localExtra = EBookZIPPathFixture.unicode(redundant[index].name)
            redundant[index].centralExtra = redundant[index].localExtra
        }
        XCTAssertEqual(try fingerprint(redundant), try fingerprint(original))
    }

    func testASCIIUnflaggedMetadataDoesNotChangeResources() throws {
        var original = files()
        original[3] = .init(name: Data("OPS/chapter.xhtml".utf8), bytes: original[3].bytes, flags: 0)
        var redundant = original
        redundant[3].localExtra = EBookZIPPathFixture.unicode(redundant[3].name)
        XCTAssertEqual(try fingerprint(redundant), try fingerprint(original))
    }

    func testUnicodeRenameCannotProduceAnotherAcceptedRevision() {
        var changed = files()
        changed[3].localExtra = EBookZIPPathFixture.unicode(changed[3].name,
            alternate: Data("OPS/different.xhtml".utf8))
        XCTAssertThrowsError(try fingerprint(changed))
    }

    func testLocalAndCentralUnicodeDisagreementCannotBeIgnored() {
        var changed = files()
        changed[3].localExtra = EBookZIPPathFixture.unicode(changed[3].name)
        changed[3].centralExtra = EBookZIPPathFixture.unicode(changed[3].name,
            alternate: Data("OPS/different.xhtml".utf8))
        XCTAssertThrowsError(try fingerprint(changed))
    }

    func testMalformedMetadataRejectsWithoutEnteringUnsafeExtractor() throws {
        var changed = files()
        changed[3].localExtra = EBookZIPPathFixture.field(Data([1]))
        try EBookZIPPathFixture.withFile(EBookZIPPathFixture.archive(changed)) { url in
            do {
                _ = try ReaderEBookZIPDirectory.validate(url, maximumEntryCount: 10)
                XCTFail("Do not enter the dependency parser when its required bounds were not checked")
                return
            } catch is ReaderEBookFingerprintError {
            }
            XCTAssertThrowsError(try ReaderEBookPackageFingerprint.readSnapshot(at: url,
                packageDocumentPath: "OPS/book.opf"))
        }
    }

    func testRejectedMetadataDoesNotRemoveOrRewriteUserPackage() throws {
        var changed = files()
        changed[3].localExtra = EBookZIPPathFixture.unicode(changed[3].name, version: 2)
        let original = EBookZIPPathFixture.archive(changed)
        try EBookZIPPathFixture.withFile(original) { url in
            XCTAssertThrowsError(try ReaderEBookPackageFingerprint.readSnapshot(at: url,
                packageDocumentPath: "OPS/book.opf"))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testFoundationEnvelopeKeepsConsistentUnflaggedUTF8Metadata() throws {
        let rootName = "日本語.epub"
        var envelope = files(prefix: rootName + "/", flags: 0)
        for index in envelope.indices {
            envelope[index].localExtra = EBookZIPPathFixture.unicode(envelope[index].name)
        }
        let expected = try fingerprint(files())
        try EBookZIPPathFixture.withFile(EBookZIPPathFixture.archive(envelope)) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            let converted = try ReaderEBookDirectorySnapshotArchive.retainContents(of: snapshot,
                rootName: rootName, maximumBytes: 1_000_000)
            XCTAssertEqual(try converted.fingerprint(packageDocumentPath: "OPS/book.opf"), expected)
        }
    }

    func testFoundationEnvelopeCannotRenameItsResourcesViaMetadata() throws {
        let rootName = "日本語.epub"
        var envelope = files(prefix: rootName + "/", flags: 0)
        envelope[3].localExtra = EBookZIPPathFixture.unicode(envelope[3].name,
            alternate: Data((rootName + "/OPS/other.xhtml").utf8))
        try EBookZIPPathFixture.withFile(EBookZIPPathFixture.archive(envelope)) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            XCTAssertThrowsError(try ReaderEBookDirectorySnapshotArchive.retainContents(of: snapshot,
                rootName: rootName, maximumBytes: 1_000_000))
            XCTAssertEqual(try Data(contentsOf: url), EBookZIPPathFixture.archive(envelope))
        }
    }
}
