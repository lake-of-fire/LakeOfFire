import Foundation
import RealmSwift
import RealmSwiftGaps

public class ContentFile: Bookmark {
    @Persisted public var mimeType = "application/octet-stream"
    
    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
    }
}
