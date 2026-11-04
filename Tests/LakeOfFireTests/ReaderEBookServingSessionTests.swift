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

    private var idpfTestKey: [UInt8] {
        // Independent SHA-1 vector for UTF-8 "A\u{a0}B" (NBSP is significant).
        [0x62, 0xb5, 0x76, 0x6f, 0x8e, 0x0c, 0xe1, 0xa7, 0x90, 0x53,
         0x5d, 0x24, 0x6c, 0xac, 0xd1, 0x58, 0xdd, 0x55, 0x9a, 0x6a]
    }
    private var fontOPF: String {
        """
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="chosen">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="first">wrong identifier</dc:identifier>
        <dc:identifier id="chosen"> \tA&#160;B\r\n </dc:identifier>
        </metadata><spine/></package>
        """
    }
    private func encryptionReference(_ uri: String, algorithm: String = "http://www.idpf.org/2008/embedding") -> String {
        """
        <e:EncryptedData><e:EncryptionMethod Algorithm="\(algorithm)"/>
        <e:CipherData><e:CipherReference URI="\(uri)"/></e:CipherData></e:EncryptedData>
        """
    }
    private func encryptionDocument(_ references: String) -> String {
        """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
        xmlns:e="http://www.w3.org/2001/04/xmlenc#">\(references)</encryption>
        """
    }
    private func fontArchive(opfs: [(String, String)]? = nil, encryption: String,
                             resources: [(String, Data)]) -> Data {
        let opfs = opfs ?? [("OPS/book.opf", fontOPF)]
        let rootfiles = opfs.map { "<rootfile full-path='\($0.0)' media-type='application/oebps-package+xml'/>" }.joined()
        let container = "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles>\(rootfiles)</rootfiles></container>"
        let files = [("mimetype", Data("application/epub+zip".utf8)),
                     ("META-INF/container.xml", Data(container.utf8)),
                     ("META-INF/encryption.xml", Data(encryption.utf8))]
            + opfs.map { ($0.0, Data($0.1.utf8)) } + resources
        return EBookZIPPathFixture.archive(files.map { .init(name: Data($0.0.utf8), bytes: $0.1) })
    }
    private func fontPackage(_ archive: Data, selectedPath: String = "OPS/book.opf") throws -> ReaderEBookServingPackage {
        try EBookZIPPathFixture.withFile(archive) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 4_000_000)
            return try .init(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: selectedPath)
        }
    }
    private func xorFont(_ plain: Data, key: [UInt8], length: Int = 1040) -> Data {
        Data(plain.enumerated().map { offset, byte in offset < length ? byte ^ key[offset % key.count] : byte })
    }

    func testIDPFFontNativeReadDecodesOnly1040BytesAndKeepsRawEntry() throws {
        for count in [0, 17, 1400] {
            let plain = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 7) })
            let raw = xorFont(plain, key: idpfTestKey)
            let archive = fontArchive(encryption: encryptionDocument(encryptionReference("OPS/font.otf")),
                                      resources: [("OPS/font.otf", raw)])
            let store = ReaderEBookServingSessionStore(), lease = try store.install(fontPackage(archive))
            XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/font.otf"), plain)
            XCTAssertEqual(try lease.readEntry(subpath: "OPS/font.otf"), raw)
            XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/font.otf"), plain)
        }
    }

    func testAdobeFontNativeReadUsesCaseInsensitiveUUIDAnd1024BytePrefix() throws {
        let opf = fontOPF.replacingOccurrences(of: "</metadata>", with:
            "<dc:identifier>URN:UUID:00112233-4455-6677-8899-AABBCCDDEEFF</dc:identifier></metadata>")
        let key: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        for count in [13, 1400] {
            let plain = Data(repeating: 0xa5, count: count), raw = xorFont(plain, key: key, length: 1024)
            let archive = fontArchive(opfs: [("OPS/book.opf", opf)],
                encryption: encryptionDocument(encryptionReference("OPS/font.otf", algorithm: "http://ns.adobe.com/pdf/enc#RC")),
                resources: [("OPS/font.otf", raw)])
            let store = ReaderEBookServingSessionStore(), lease = try store.install(fontPackage(archive))
            XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/font.otf"), plain)
            XCTAssertEqual(try lease.readEntry(subpath: "OPS/font.otf"), raw)
        }
    }

    func testFontEncryptionReferencesDecodeComponentsOnceFromContainerRoot() throws {
        let plain = Data(repeating: 0x37, count: 1100), raw = xorFont(plain, key: idpfTestKey)
        let references = encryptionReference("OPS/Fonts/My%20%E6%97%A5%E6%9C%AC.otf")
            + encryptionReference("OPS/Fonts/A%252FB.otf")
            + encryptionReference("OPS/Fonts/A%2fB.otf")
            + encryptionReference("OPS/Fonts/A%5CB.otf")
            + encryptionReference("/OPS/Fonts/Root%20Font.otf")
            + encryptionReference("OPS/./Fonts/../Fonts/Normalized.otf")
        let archive = fontArchive(encryption: encryptionDocument(references), resources: [
            ("OPS/Fonts/My 日本.otf", raw), ("OPS/Fonts/A%2FB.otf", raw),
            ("OPS/Fonts/A/B.otf", raw), ("META-INF/OPS/Fonts/My 日本.otf", raw),
            ("OPS/Fonts/Root Font.otf", raw), ("OPS/Fonts/Normalized.otf", raw),
        ])
        let store = ReaderEBookServingSessionStore(), lease = try store.install(fontPackage(archive))
        XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/Fonts/My 日本.otf"), plain)
        XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/Fonts/A%2FB.otf"), plain)
        XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/Fonts/A/B.otf"), raw)
        XCTAssertEqual(try lease.readNativeResource(subpath: "META-INF/OPS/Fonts/My 日本.otf"), raw)
        XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/Fonts/Root Font.otf"), plain)
        XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/Fonts/Normalized.otf"), plain)
    }

    func testUnsupportedOrConflictingFontEncryptionDoesNotTransformOtherResources() throws {
        let plain = Data(repeating: 0x54, count: 1100), raw = xorFont(plain, key: idpfTestKey)
        let references = encryptionReference("OPS/good.otf")
            + encryptionReference("OPS/unsupported.otf", algorithm: "urn:unsupported")
            + encryptionReference("OPS/conflict.otf")
            + encryptionReference("OPS/conflict.otf", algorithm: "urn:unsupported")
            + encryptionReference("OPS/reverse.otf", algorithm: "urn:unsupported")
            + encryptionReference("OPS/reverse.otf")
        let paths = ["OPS/good.otf", "OPS/unsupported.otf", "OPS/conflict.otf", "OPS/reverse.otf", "OPS/unlisted.otf"]
        let archive = fontArchive(encryption: encryptionDocument(references), resources: paths.map { ($0, raw) })
        let store = ReaderEBookServingSessionStore(), lease = try store.install(fontPackage(archive))
        XCTAssertEqual(try lease.readNativeResource(subpath: paths[0]), plain)
        for path in paths.dropFirst() { XCTAssertEqual(try lease.readNativeResource(subpath: path), raw) }
    }

    func testFontDecoderUsesCapturedRenditionAndPackageRevision() throws {
        let otherOPF = fontOPF.replacingOccurrences(of: " \tA&#160;B\r\n ", with: "other")
        let plain = Data(repeating: 0x66, count: 1100), raw = xorFont(plain, key: idpfTestKey)
        let archive = fontArchive(opfs: [("OPS/other.opf", otherOPF), ("OPS/book.opf", fontOPF)],
            encryption: encryptionDocument(encryptionReference("OPS/font.otf")), resources: [("OPS/font.otf", raw)])
        let store = ReaderEBookServingSessionStore()
        let selected = try store.install(fontPackage(archive))
        let other = try store.install(fontPackage(archive, selectedPath: "OPS/other.opf"))
        XCTAssertEqual(try selected.readNativeResource(subpath: "OPS/font.otf"), plain)
        XCTAssertNotEqual(try other.readNativeResource(subpath: "OPS/font.otf"), plain)
        let otherKey: [UInt8] = [0xd0, 0x94, 0x1e, 0x68, 0xda, 0x8f, 0x38, 0x15, 0x1f, 0xf8,
                                 0x6a, 0x61, 0xfc, 0x59, 0xf7, 0xc5, 0xcf, 0x9f, 0xca, 0xa2]
        let revisionBytes = fontArchive(opfs: [("OPS/book.opf", otherOPF)],
            encryption: encryptionDocument(encryptionReference("OPS/font.otf")),
            resources: [("OPS/font.otf", xorFont(plain, key: otherKey))])
        let revision = try store.install(fontPackage(revisionBytes))
        XCTAssertEqual(try revision.readNativeResource(subpath: "OPS/font.otf"), plain)
        XCTAssertEqual(try selected.readNativeResource(subpath: "OPS/font.otf"), plain)
        store.withdraw(selected)
        XCTAssertThrowsError(try selected.readNativeResource(subpath: "OPS/font.otf"))
        XCTAssertNoThrow(try other.readNativeResource(subpath: "OPS/font.otf"))
    }

    func testChangedFontSnapshotIsRejectedBeforeNativeDecoding() throws {
        let plain = Data(repeating: 0x77, count: 1100), raw = xorFont(plain, key: idpfTestKey)
        let encryption = encryptionDocument(encryptionReference("OPS/font.otf"))
        let archive = fontArchive(encryption: encryption, resources: [("OPS/font.otf", raw)])
        try EBookZIPPathFixture.withFile(archive) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot, packageDocumentPath: "OPS/book.opf")
            let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
            XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/font.otf"), plain)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.packageURL.path)
            // Replacement contains already decoded bytes; these must not be accepted or XORed.
            try fontArchive(encryption: encryption, resources: [("OPS/font.otf", plain)])
                .write(to: snapshot.packageURL, options: .atomic)
            XCTAssertThrowsError(try lease.readNativeResource(subpath: "OPS/font.otf"))
            XCTAssertThrowsError(try lease.readEntry(subpath: "OPS/font.otf"))
        }
    }

    func testFontDecoderMetadataIsPreparedOnceAndBounded() throws {
        let raw = Data(repeating: 0x18, count: 1200)
        let files = ["META-INF/encryption.xml": Data(encryptionDocument(encryptionReference("OPS/font.otf")).utf8),
                     "OPS/book.opf": Data(fontOPF.utf8), "OPS/font.otf": raw]
        let entries = files.map { ReaderPackageEntryMetadata(path: $0.key, size: $0.value.count) }
        var reads: [String] = []
        let decoder = try ReaderEBookFontObfuscation.prepare(entries: entries, packageDocumentPath: "OPS/book.opf") { path in
            reads.append(path)
            return try XCTUnwrap(files[path])
        }
        let decoded = try decoder.decode(raw, subpath: "OPS/font.otf")
        XCTAssertNotEqual(decoded, raw)
        XCTAssertEqual(try decoder.decode(raw, subpath: "OPS/font.otf"), decoded)
        XCTAssertEqual(reads, ["META-INF/encryption.xml", "OPS/book.opf"])
        reads = []
        let oversized = [ReaderPackageEntryMetadata(path: "META-INF/encryption.xml", size: 1_048_577)]
        let skipped = try ReaderEBookFontObfuscation.prepare(entries: oversized, packageDocumentPath: "OPS/book.opf") { path in
            reads.append(path); return Data()
        }
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(try skipped.decode(raw, subpath: "OPS/font.otf"), raw)
    }

    func testMalformedFontMetadataAndMissingKeysLeaveResourcesRaw() throws {
        let raw = Data(repeating: 0x88, count: 1100)
        let documents = ["<encryption>",
            "<!DOCTYPE encryption [<!ENTITY key 'secret'>]>" + encryptionDocument(encryptionReference("OPS/font.otf"))]
        for document in documents {
            let archive = fontArchive(encryption: document, resources: [("OPS/font.otf", raw)])
            let store = ReaderEBookServingSessionStore(), lease = try store.install(fontPackage(archive))
            XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/font.otf"), raw)
        }
        let missingKey = fontOPF.replacingOccurrences(of: "unique-identifier=\"chosen\"", with: "unique-identifier=\"absent\"")
        let references = encryptionReference("OPS/font.otf")
            + encryptionReference("OPS/adobe.otf", algorithm: "http://ns.adobe.com/pdf/enc#RC")
        let archive = fontArchive(opfs: [("OPS/book.opf", missingKey)], encryption: encryptionDocument(references),
            resources: [("OPS/font.otf", raw), ("OPS/adobe.otf", raw)])
        let store = ReaderEBookServingSessionStore(), lease = try store.install(fontPackage(archive))
        XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/font.otf"), raw)
        XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/adobe.otf"), raw)
    }

    func testCancelledNativeFontReadDoesNotSucceed() async throws {
        let plain = Data(repeating: 0x99, count: 1200), raw = xorFont(plain, key: idpfTestKey)
        let archive = fontArchive(encryption: encryptionDocument(encryptionReference("OPS/font.otf")),
                                  resources: [("OPS/font.otf", raw)])
        let store = ReaderEBookServingSessionStore(), lease = try store.install(fontPackage(archive))
        let rejected = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try lease.readNativeResource(subpath: "OPS/font.otf"); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(rejected)
        XCTAssertEqual(try lease.readNativeResource(subpath: "OPS/font.otf"), plain)
    }

#if DEBUG
    func testLegacyCacheOwnsFontDecoderAndKeepsRawSourceReads() async throws {
        let plain = Data(repeating: 0x42, count: 1200), raw = xorFont(plain, key: idpfTestKey)
        let archive = fontArchive(encryption: encryptionDocument(encryptionReference("OPS/font.otf")),
                                  resources: [("OPS/font.otf", raw)])
        let snapshot = try EBookZIPPathFixture.withFile(archive) { url in
            try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
        }
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "diagnosticLocalFilePath", value: snapshot.packageURL.path)]
        let readerURL = try XCTUnwrap(components.url)
        let cache = ReaderPackageEntrySourceCache(), manager = ReaderFileManager()
        let first = try await cache.cachedSource(forPackageURL: readerURL, readerFileManager: manager)
        let reused = try await cache.cachedSource(forPackageURL: readerURL, readerFileManager: manager)
        XCTAssertEqual(first.generationID, reused.generationID)
        XCTAssertEqual(try first.readNativeResource(subpath: "OPS/font.otf"), plain)
        XCTAssertEqual(try reused.readNativeResource(subpath: "OPS/font.otf"), plain)
        XCTAssertEqual(try reused.source.readEntry(subpath: "OPS/font.otf"), raw)
        // Keep the owned fixture alive through every legacy pathname read.
        try snapshot.validateObservation(snapshot.observationToken)
    }
#endif

}
