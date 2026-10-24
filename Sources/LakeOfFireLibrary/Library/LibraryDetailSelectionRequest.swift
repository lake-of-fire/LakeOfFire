import Foundation

/// A post-assignment presentation request, including equal-row selections.
/// Only value identities cross a deferred SwiftUI callback.
@available(iOS 16.0, macOS 13.0, *)
struct LibraryDetailSelectionRequest: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case none
        case libraryRoot
        case feed(id: UUID, createdAt: Date, categoryID: UUID, categoryCreatedAt: Date)
        case script(id: UUID, createdAt: Date)
        case navigation
    }

    let id = UUID()
    let target: Target

    var contentRoute: ContentPaneRoute? {
        switch target {
        case .none, .libraryRoot, .navigation:
            return nil
        case .feed(_, _, let categoryID, _):
            return .contentCategory(categoryID)
        case .script:
            return .userScripts
        }
    }
}
