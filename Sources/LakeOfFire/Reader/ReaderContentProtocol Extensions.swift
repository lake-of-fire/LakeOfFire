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
        } else if ["http", "https"].contains(url.scheme?.lowercased()) {
            return url.host
        } else {
            return titleForDisplay
        }
    }

    func isHome(categorySelection: String?) -> Bool {
        return url.absoluteString == "about:blank" && (categorySelection ?? "home") == "home"
    }
}
