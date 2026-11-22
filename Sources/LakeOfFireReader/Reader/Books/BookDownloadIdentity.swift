import Foundation

/// Reprepare a row when its resource, display name, or declared format changes.
struct BookDownloadIdentity: Equatable {
    let url: URL?
    let name: String
    let mediaType: String?
}
