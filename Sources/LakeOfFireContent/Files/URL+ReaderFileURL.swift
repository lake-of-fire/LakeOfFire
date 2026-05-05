import Foundation
import LakeOfFireCore

public extension URL {
    var isReaderFileURL: Bool {
        return scheme == "reader-file"
    }
}
