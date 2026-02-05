import Foundation
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

public extension URL {
    /// Canonicalizes a reader URL so loader trampoline URLs and their underlying content URLs
    /// compare equal when tracking reader-mode state.
    ///
    /// - If `self` is a reader loader URL (`internal://local/load/reader?...`), this returns the
    ///   decoded `reader-url` target when available.
    /// - Otherwise returns `self`.
    func canonicalReaderContentURL() -> URL {
        guard isReaderURLLoaderURL else { return self }
        return ReaderContentLoader.getContentURL(fromLoaderURL: self) ?? self
    }
}

