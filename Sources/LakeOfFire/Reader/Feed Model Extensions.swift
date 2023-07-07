import Foundation
import LakeKit

public extension Feed {
    @MainActor
    func fetch() async throws {
        try await fetch(realmConfiguration: SharedRealmConfigurer.configuration)
    }
}
