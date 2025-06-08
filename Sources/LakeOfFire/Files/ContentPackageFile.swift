import Foundation
import RealmSwift
import RealmSwiftGaps
import ZIPFoundation

public class ContentPackageFile: Bookmark {
    @Persisted public var packageContentFileID: String?
    
//    public var systemFileURL: URL {
//        get throws {
//            try ReaderFileManager.shared.localFileURL(forReaderFileURL: url)
//        }
//    }
    
    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
    }
}
