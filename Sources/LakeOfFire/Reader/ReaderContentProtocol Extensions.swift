import Foundation
import RealmSwift
import RealmSwiftGaps

public extension ReaderContentProtocol {
    func isHome(categorySelection: String?) -> Bool {
        return url.absoluteString == "about:blank" && (categorySelection ?? "home") == "home"
    }
    
    @MainActor
    private func updateImageUrl(imageURL: URL) {
        if let content = self as? Bookmark {
            let contentRef = ThreadSafeReference(to: content)
            guard let config = content.realm?.configuration else { return }
            Task.detached { @RealmBackgroundActor in
                try await Realm.asyncWrite(contentRef, configuration: config) { _, content in
                    content.imageUrl = imageURL
                }
            }
        } else if let content = self as? HistoryRecord {
            let contentRef = ThreadSafeReference(to: content)
            guard let config = content.realm?.configuration else { return }
            Task.detached { @RealmBackgroundActor in
                try await Realm.asyncWrite(contentRef, configuration: config) { _, content in
                    content.imageUrl = imageURL
                }
            }
        }
    }
    
}
