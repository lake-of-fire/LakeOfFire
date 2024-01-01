import Foundation

public extension URL {
    var isReaderFileURL: Bool {
        return scheme == "reader-file"
    }
}
