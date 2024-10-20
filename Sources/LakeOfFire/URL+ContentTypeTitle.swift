import Foundation

public extension URL {
    var contentTypeTitle: String {
        if isEBookURL {
            return "ebook"
        } else if isFileURL {
            return "file"
        } else if isSnippetURL {
            return "snippet"
        }
        return "webpage"
    }
}
