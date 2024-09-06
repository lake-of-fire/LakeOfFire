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
    func updateImageUrl(imageURL: URL) async throws {
        let contents = try await ReaderContentLoader.loadAll(url: url)
        try await { @RealmBackgroundActor in
            for content in contents {
                guard content.imageUrl == nil else { continue }
                guard let config = content.realm?.configuration else { return }
                try await Realm(configuration: config, actor: RealmBackgroundActor.shared).writeAsync {
                    content.imageUrl = imageURL
                }
            }
        }()
    }
}
