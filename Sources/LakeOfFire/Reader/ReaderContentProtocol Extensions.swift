import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit

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
            let relatedObjects = try await ReaderContentLoader.loadAll(url: targetURL)

            for case let object as (Object & ReaderContentProtocol) in relatedObjects {
                guard let realm = object.realm else { continue }

                let configuration = realm.configuration
                let compoundKey = object.compoundKey
                let objectType = type(of: object)

                let backgroundRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                guard let resolved = backgroundRealm.object(ofType: objectType, forPrimaryKey: compoundKey) as? (Object & ReaderContentProtocol) else { continue }

                try await backgroundRealm.asyncWrite {
                    block(backgroundRealm, resolved)
                }

                try await backgroundRealm.asyncRefresh()
            }
        }()
    }
}
