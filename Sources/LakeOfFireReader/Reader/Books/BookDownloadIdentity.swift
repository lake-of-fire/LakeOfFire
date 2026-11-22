import Foundation

/// A row can keep its publication identity while its acquisition format changes.
/// Resolve the download again for any new locator, title, or declared type.
struct BookDownloadIdentity: Equatable {
    let url: URL?
    let name: String
    let mediaType: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Signed locators must retain their original query escaping and order.
        lhs.url?.absoluteString == rhs.url?.absoluteString
            && lhs.name == rhs.name
            && lhs.mediaType == rhs.mediaType
    }
}
