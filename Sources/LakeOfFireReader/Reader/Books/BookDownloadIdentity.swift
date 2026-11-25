import Foundation

/// Reprepare a row when its resource, display name, or declared format changes.
struct BookDownloadIdentity: Hashable {
    let url: URL?
    let name: String
    let mediaType: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url?.absoluteString == rhs.url?.absoluteString
            && lhs.name == rhs.name && lhs.mediaType == rhs.mediaType
    }

    func hash(into hasher: inout Hasher) {
        // The request and download slot preserve the exact signed URL spelling.
        hasher.combine(url?.absoluteString)
        hasher.combine(name)
        hasher.combine(mediaType)
    }
}
