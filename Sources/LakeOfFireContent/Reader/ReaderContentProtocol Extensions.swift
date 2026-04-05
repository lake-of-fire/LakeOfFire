import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
import LakeOfFireCore
import LakeOfFireAdblock

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

    func isHome() -> Bool {
        return url.absoluteString == "about:blank"
    }

    @MainActor
    func writeAllRelatedAsync(_ block: @escaping (Realm, any ReaderContentProtocol) -> Void) async throws {
        let targetURL = url

        try await { @RealmBackgroundActor in
            try await ReaderContentLoader.updateContent(url: targetURL) { object in
                guard let realm = object.realm else { return false }
                block(realm, object)
                return true
            }
        }()
    }
}
