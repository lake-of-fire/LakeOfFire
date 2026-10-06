import Foundation

/// A read-only saved locator. Its presence does not authorize any Realm write.
public struct ReaderContentEbookInitialRestore: Sendable {
    public let cfi: String
    public let fractionalCompletion: Float?

    /// Retained for source compatibility. The bridge revalidates values from
    /// callers that construct a value without the checked initializer.
    public init(cfi: String, fractionalCompletion: Float?) {
        self.cfi = cfi
        self.fractionalCompletion = fractionalCompletion
    }

    /// nil means no saved locator; invalid saved data throws instead of being
    /// mistaken for a new book. In particular, zero is a present locator.
    public init?(validatingCFI cfi: String?, fractionalCompletion: Float?) throws {
        let cfi = cfi ?? ""
        guard ReaderEBookInitialRestorePolicy.shouldRequestRestore(
            cfi: cfi, fractionalCompletion: fractionalCompletion
        ) else {
            if fractionalCompletion != nil {
                throw ReaderEBookInitialRestoreError.invalidFraction
            }
            return nil
        }
        self.init(cfi: cfi, fractionalCompletion: fractionalCompletion)
    }
}

public enum ReaderEBookInitialRestoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidFraction

    public var errorDescription: String? {
        switch self {
        case .invalidFraction:
            // Do not include stored CFI, URLs or other reading data in errors.
            return "The saved reading position is invalid. The book was not opened at a different position."
        }
    }
}
