import Foundation
import XCTest
import RealmSwift
import LakeOfFireContent

final class MediaTranscriptIdentityTests: XCTestCase {
    private let originalVTT = "WEBVTT\n\n00:00.000 --> 00:01.000\nOriginal\n"

    private func makeTranscript() throws -> MediaTranscript {
        let row = MediaTranscript()
        row.contentURL = URL(string: "https://example.com/video")!
        row.stableMediaIdentity = "url:https://example.com/media.mp4"
        row.languageCode = "ja"
        try row.setWebVTT(originalVTT, isGenerated: false, transcriptLocale: "ja", sourceDuration: 10)
        return row
    }

    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [MediaTranscript.self]
        return try Realm(configuration: configuration)
    }

    func testUnmanagedIdentityIsComputedAndCanBeRecomputed() throws {
        let row = try makeTranscript()
        let oldKey = row.compoundKey
        row.languageCode = "en"
        row.updateCompoundKey()
        XCTAssertNotEqual(row.compoundKey, oldKey)
        XCTAssertEqual(row.compoundKey, MediaTranscript.makeCompoundKey(
            contentURL: row.contentURL, stableMediaIdentity: row.stableMediaIdentity, languageCode: "en"
        ))
    }

    func testManagedPayloadUpdateDoesNotAssignPrimaryKey() throws {
        let realm = try makeRealm()
        let row = try makeTranscript()
        let key = row.compoundKey
        try realm.write { realm.add(row) }
        let replacement = "WEBVTT\n\n00:00.000 --> 00:01.000\nReplacement\n"
        try realm.write {
            try row.setWebVTT(replacement, isGenerated: true, transcriptLocale: "ja", sourceDuration: 11)
        }
        XCTAssertEqual(row.compoundKey, key)
        XCTAssertEqual(try row.webVTTString(), replacement)
        XCTAssertTrue(row.isGenerated)
        XCTAssertEqual(realm.objects(MediaTranscript.self).count, 1)
    }

    func testManagedUpdateCompoundKeyIsNoOpEvenAfterIdentityFieldEdit() throws {
        let realm = try makeRealm()
        let row = try makeTranscript()
        let key = row.compoundKey
        try realm.write { realm.add(row) }
        try realm.write {
            row.languageCode = "en"
            row.updateCompoundKey()
        }
        XCTAssertEqual(row.compoundKey, key)
    }

    func testManagedMismatchedIdentityRejectsBeforePayloadOrMetadataChanges() throws {
        let realm = try makeRealm()
        let row = try makeTranscript()
        try realm.write { realm.add(row) }
        let key = row.compoundKey
        let originalContent = row.content
        let originalVersion = row.generatorVersion
        try realm.write {
            row.languageCode = "en"
            XCTAssertThrowsError(try row.setWebVTT(
                "replacement", isGenerated: true, transcriptLocale: "en",
                sourceDuration: 20, mediaFingerprint: "new", generatorVersion: 99
            )) { error in
                guard case MediaTranscriptCodecError.immutableIdentity = error else {
                    return XCTFail("Expected identity rejection, got \(error)")
                }
            }
        }
        XCTAssertEqual(row.compoundKey, key)
        XCTAssertEqual(row.content, originalContent)
        XCTAssertFalse(row.isGenerated)
        XCTAssertEqual(row.transcriptLocale, "ja")
        XCTAssertEqual(row.sourceDuration, 10)
        XCTAssertNil(row.mediaFingerprint)
        XCTAssertEqual(row.generatorVersion, originalVersion)
    }
}
