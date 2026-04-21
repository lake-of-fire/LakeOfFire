import Foundation

public extension URL {
    var isReaderBookURL: Bool {
        isEBookURL || scheme?.lowercased() == "ttsu"
    }
}
