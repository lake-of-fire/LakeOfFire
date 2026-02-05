import Foundation
import LakeOfFireCore
import LakeOfFireAdblock

public extension URL {
    var isReaderFileURL: Bool {
        return scheme == "reader-file"
    }
}
