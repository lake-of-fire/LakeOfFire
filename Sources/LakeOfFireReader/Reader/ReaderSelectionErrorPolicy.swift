import Foundation
import LakeOfFireContent

/// Shared with the selection catch boundary so errors are tested independently of WebKit transport.
enum ReaderSelectionErrorPolicy {
    static func message(for error: Error, requestIsCurrent: Bool) -> String? {
        ReaderFileOperationMessageMapper.openMessage(for: error) ?? error.localizedDescription
    }
}
