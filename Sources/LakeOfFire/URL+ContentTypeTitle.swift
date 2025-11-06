import Foundation

public extension URL {
    var contentTypeTitle: String? {
        guard !isNativeReaderView else {
            return nil
        }
        switch contentKind {
        case .book:
            return "This Book"
        case .file:
            return "This File"
        case .snippet:
            return "This Snippet"
        case .webpage:
            return "This Webpage"
        }
    }

    var hostContentTypeTitle: String? {
        guard !isNativeReaderView else {
            return nil
        }
        switch contentKind {
        case .book:
            return "All Books"
        case .file:
            return "All Files"
        case .snippet:
            return "All Snippets"
        case .webpage:
            guard let hostDisplayName = hostDisplayName else {
                return "All Webpages"
            }
            return "All Pages on \(hostDisplayName)"
        }
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
        }
        if isFileURL {
            return .file
        }
        if isSnippetURL {
            return .snippet
        }
        return .webpage
    }

    var contentKindTitle: String {
        switch contentKind {
        case .webpage:
            return "Webpage"
        case .book:
            return "Book"
        case .file:
            return "File"
        case .snippet:
            return "Snippet"
        }
    }

    func contentKindCollectionTitle(pluralize: Bool = true) -> String {
        let base = contentKindTitle
        guard pluralize else { return base }
        switch contentKind {
        case .webpage:
            return "Webpages"
        case .book:
            return "Books"
        case .file:
            return "Files"
        case .snippet:
            return "Snippets"
        }
    }

    var contentMenuSubtitle: String {
        switch contentKind {
        case .webpage:
            return hostDisplayName ?? contentKindTitle
        case .book, .file, .snippet:
            return contentKindTitle
        }
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
