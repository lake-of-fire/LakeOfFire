import Foundation
import XCTest
@testable import LakeOfFireContent

/// Real filesystem metadata checks. These do not emulate iCloud eviction or
/// prove a provider cannot change after an eligibility observation.
final class ReaderEBookLocalAvailabilityTests: XCTestCase {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    func testLocalPackageWithHiddenResourceIsEligible() throws {
        try withRoot { root in
            try Data("fixture".utf8).write(to: root.appendingPathComponent(".hidden.xhtml"))
            XCTAssertTrue(try ReaderEBookLocalAvailability.isAlreadyReadable(at: root, location: .local))
        }
    }
    func testMissingItemIsNotReadOrCreated() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(try ReaderEBookLocalAvailability.isAlreadyReadable(at: url, location: .local))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testSymlinkResourceDoesNotQualifyThePackage() throws {
        try withRoot { root in
            let file = root.appendingPathComponent("real.xhtml")
            try Data("content".utf8).write(to: file)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.xhtml"), withDestinationURL: file)
            XCTAssertThrowsError(try ReaderEBookLocalAvailability.isAlreadyReadable(at: root, location: .local))
        }
    }
    func testEnumerationLimitCannotProduceACompleteReadableResult() throws {
        try withRoot { root in
            for index in 0..<3 { try Data().write(to: root.appendingPathComponent("\(index).xhtml")) }
            XCTAssertThrowsError(try ReaderEBookLocalAvailability.isAlreadyReadable(at: root, location: .local, maximumEntries: 2))
            XCTAssertTrue(try ReaderEBookLocalAvailability.isAlreadyReadable(at: root, location: .local, maximumEntries: 3))
        }
    }
    func testRegularLocalFileIsEligibleWithoutReadingItsPayload() throws {
        try withRoot { root in
            let file = root.appendingPathComponent("book.epub")
            try Data("arbitrary bytes; not a validity test".utf8).write(to: file)
            XCTAssertTrue(try ReaderEBookLocalAvailability.isAlreadyReadable(at: file, location: .local))
        }
    }

    func testValidatedLocalRootDoesNotRequireInapplicableICloudMetadata() {
        XCTAssertTrue(ReaderEBookLocalAvailability.allowsReading(location: .local,
            isUbiquitous: nil, downloadingStatus: nil, isDownloading: nil))
    }
    func testICloudRootNeverDefaultsMissingMetadataToCurrent() {
        for membership: Bool? in [nil, false, true] {
            XCTAssertFalse(ReaderEBookLocalAvailability.allowsReading(location: .iCloud,
                isUbiquitous: membership, downloadingStatus: nil, isDownloading: nil))
        }
    }
    func testICloudCurrentRequiresExplicitSettledState() {
        XCTAssertTrue(ReaderEBookLocalAvailability.allowsReading(location: .iCloud,
            isUbiquitous: true, downloadingStatus: .current, isDownloading: false))
        for downloading: Bool? in [nil, true] {
            XCTAssertFalse(ReaderEBookLocalAvailability.allowsReading(location: .iCloud,
                isUbiquitous: true, downloadingStatus: .current, isDownloading: downloading))
        }
    }
    func testStaleOrNotDownloadedCloudCopiesStayIneligible() {
        for status in [URLUbiquitousItemDownloadingStatus.notDownloaded, .downloaded] {
            XCTAssertFalse(ReaderEBookLocalAvailability.allowsReading(location: .iCloud,
                isUbiquitous: true, downloadingStatus: status, isDownloading: false))
        }
    }
    func testUbiquitousItemInsideLocalRootStillRequiresCloudObservation() {
        XCTAssertFalse(ReaderEBookLocalAvailability.allowsReading(location: .local,
            isUbiquitous: true, downloadingStatus: nil, isDownloading: nil))
        XCTAssertTrue(ReaderEBookLocalAvailability.allowsReading(location: .local,
            isUbiquitous: true, downloadingStatus: .current, isDownloading: false))
    }
}
