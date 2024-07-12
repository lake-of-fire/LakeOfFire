import Foundation
import RealmSwift
import RealmSwiftGaps

public extension ReaderContentProtocol {
    @MainActor
    public var locationShortName: String? {
        if url.absoluteString == "about:blank" {
            return "Home"
        } else if url.isNativeReaderView {
            return nil
        } else if url.isEBookURL || url.isSnippetURL {
            return titleForDisplay
        } else {
            return url.host
        }
    }

    func isHome(categorySelection: String?) -> Bool {
        return url.absoluteString == "about:blank" && (categorySelection ?? "home") == "home"
    }
    
    @MainActor
    func updateImageUrl(imageURL: URL) {
        if let content = self as? Bookmark {
            guard let config = content.realm?.configuration else { return }
            let contentRef = ThreadSafeReference(to: content)
            Task.detached { @RealmBackgroundActor in
                try await Realm.asyncWrite(contentRef, configuration: config) { _, content in
                    content.imageUrl = imageURL
                }
            }
        } else if let content = self as? HistoryRecord {
            guard let config = content.realm?.configuration else { return }
            let contentRef = ThreadSafeReference(to: content)
            Task.detached { @RealmBackgroundActor in
                try await Realm.asyncWrite(contentRef, configuration: config) { _, content in
                    content.imageUrl = imageURL
                }
            }
        }
    }
    
}
