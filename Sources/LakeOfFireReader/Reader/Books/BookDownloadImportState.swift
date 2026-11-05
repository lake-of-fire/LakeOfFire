import Foundation
import LakeOfFireContent

/// Downloaded bytes are not proof of a committed library import. Cancellation
/// leaves the prior presentation alone; failed imports remain retryable.
struct BookDownloadImportIdentity: Equatable, Sendable {
    let remoteURL: URL
    let localDestination: URL
    let name: String
}

struct BookDownloadImportState {
    private(set) var identity: BookDownloadImportIdentity?
    private(set) var importedURL: URL?
    private(set) var errorMessage: String?

    var isImported: Bool { importedURL != nil }

    @discardableResult
    mutating func bind(to identity: BookDownloadImportIdentity) -> Bool {
        guard self.identity != identity else { return false }
        self.identity = identity
        importedURL = nil
        errorMessage = nil
        return true
    }

    @discardableResult
    mutating func receive(_ result: ReaderFileImportResult) -> Bool {
        switch result {
        case .imported(let url):
            importedURL = url
            errorMessage = nil
            return true
        case .failed(let message):
            importedURL = nil
            errorMessage = message
            return false
        case .cancelled:
            return false
        }
    }
}
