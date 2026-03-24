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

    enum ContentKind {
        case webpage
        case book
        case file
        case snippet
    }

    var contentKind: ContentKind {
        if isEBookURL {
            return .book
        } else if isFileURL {
            return .file
        } else if isSnippetURL {
            return .snippet
        }
        return .webpage
    }

    var hostDisplayName: String? {
        guard let host else { return nil }
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    var isHTTP: Bool {
        guard let scheme else { return false }
        let lowered = scheme.lowercased()
        return lowered == "http" || lowered == "https"
    }
}
