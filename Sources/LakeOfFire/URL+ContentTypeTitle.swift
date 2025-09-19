import Foundation

public extension URL {
    var contentTypeTitle: String? {
        guard !isNativeReaderView else {
            return nil
        }
        if isEBookURL {
            return "This Book"
        } else if isFileURL {
            return "This File"
        } else if isSnippetURL {
            return "This Snippet"
        }
        return "This Webpage"
    }

    var hostContentTypeTitle: String? {
        guard !isNativeReaderView else {
            return nil
        }
        if isEBookURL {
            return "All Books"
        } else if isFileURL {
            return "All Files"
        } else if isSnippetURL {
            return "All Snippets"
        }
        guard let hostDisplayName = hostDisplayName else {
            return "All Webpages"
        }
        return "All Pages on \(hostDisplayName)"
    }
}

private extension URL {
    var hostDisplayName: String? {
        guard let host else { return nil }
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }
}
