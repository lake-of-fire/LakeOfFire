import Foundation

public extension URL {
    var isEBookURL: Bool {
        let path = URLComponents(url: self, resolvingAgainstBaseURL: false)?.path ?? self.path
        let pathExtension = NSString(string: path).pathExtension
        return (isFileURL || scheme == "https" || scheme == "http" || scheme == "ebook" || scheme == "ebook-url")
            && pathExtension.lowercased() == "epub"
    }
}
