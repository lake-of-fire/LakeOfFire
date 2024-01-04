import Foundation
import RealmSwift
import RealmSwiftGaps

public class ContentFile: Bookmark {
    @Persisted public var mimeType = "application/octet-stream"
    
    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
    }
}

extension ContentFile: DeletableReaderContent {
    public var deleteActionTitle: String {
        "Delete File"
    }
    
    @MainActor
    public func delete(readerFileManager: ReaderFileManager) async throws {
        try await readerFileManager.delete(readerFileURL: url)
    }
}
