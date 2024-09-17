import Foundation

public extension URL {
    var contentTypeTitle: String {
        if isEBookURL {
            return "Ebook"
        } else if isFileURL {
            return "File"
        } else if isSnippetURL {
            return "Snippet"
        }
        return "Webpage"
    }
}
