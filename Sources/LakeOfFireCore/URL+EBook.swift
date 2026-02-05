import Foundation

public extension URL {
    var isEBookURL: Bool {
        return (isFileURL || scheme == "https" || scheme == "http" || scheme == "ebook" || scheme == "ebook-url")
            && pathExtension.lowercased() == "epub"
    }
}
