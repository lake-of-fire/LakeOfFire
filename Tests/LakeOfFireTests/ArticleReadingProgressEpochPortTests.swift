import RealmSwift
import XCTest
@testable import LakeOfFireReader

final class ArticleReadingProgressEpochPortTests: XCTestCase {
    func testEpochPointerDefaultsToLegacyNilAndPersistsExactValue() throws {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = UUID().uuidString
        configuration.objectTypes = [ArticleReadingProgress.self]
        let realm = try Realm(configuration: configuration)

        let article = ArticleReadingProgress()
        article.id = "article"
        article.url = URL(string: "https://example.invalid/article")!
        XCTAssertNil(article.readAuthorityEpochID)

        let epoch = "epoch-cafe\u{301}"
        try realm.write {
            realm.add(article)
            article.readAuthorityEpochID = epoch
        }

        let reopened = try XCTUnwrap(
            realm.object(ofType: ArticleReadingProgress.self, forPrimaryKey: "article")
        )
        XCTAssertEqual(Data(try XCTUnwrap(reopened.readAuthorityEpochID).utf8), Data(epoch.utf8))
    }

    func testEpochPointerDoesNotChangePrimaryKeyOrReadingState() throws {
        let article = ArticleReadingProgress()
        article.id = "stable-id"
        article.url = URL(string: "ebook://ebook/load/local/Books/a.epub")!
        article.ebookCFI = "epubcfi(/6/4!/4/2:17)"
        article.fractionalCompletion = 0.25
        article.readAuthorityEpochID = "epoch"

        XCTAssertEqual(article.id, "stable-id")
        XCTAssertEqual(article.ebookCFI, "epubcfi(/6/4!/4/2:17)")
        XCTAssertEqual(article.fractionalCompletion, 0.25)
    }
}
