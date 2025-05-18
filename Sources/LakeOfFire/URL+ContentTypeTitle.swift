import Foundation

public extension URL {
    var contentTypeTitle: String? {
        guard !isNativeReaderView else {
            return nil
        }
        if isEBookURL {
            return "book"
        } else if isFileURL {
            return "file"
        } else if isSnippetURL {
            return "snippet"
        }
        return "webpage"
    }
}
