import Foundation
import LakeOfFireCore

public enum ReaderFileAccessError: LocalizedError {
    case downloadInProgress
    case notAvailableOffline

    public var errorDescription: String? {
        userFacingMessage
    }

    public var userFacingMessage: String {
        switch self {
        case .downloadInProgress:
            return "Downloading from iCloud. Try opening again when the download finishes."
        case .notAvailableOffline:
            return "This book is in iCloud and isn’t available offline yet."
        }
    }
}

public enum ReaderFileDeleteEligibility: Sendable, Equatable {
    case allowed
    case blockedCloudOnly
    case blockedLoadingStatus
}

public enum ReaderFileDeleteError: LocalizedError {
    case blockedCloudOnly
    case blockedLoadingStatus
    case removeFailed(underlyingDescription: String? = nil)

    public var errorDescription: String? {
        switch self {
        case .blockedCloudOnly:
            return "Download this iCloud file first, then delete it."
        case .blockedLoadingStatus:
            return "iCloud status is still loading. Try again in a moment."
        case .removeFailed(let underlyingDescription):
            if let underlyingDescription, !underlyingDescription.isEmpty {
                return "Couldn't delete the iCloud file. \(underlyingDescription)"
            }
            return "Couldn't delete the iCloud file. Try again when connected."
        }
    }
}

public enum ReaderFileOperationMessageMapper {
    public static func openMessage(for error: Error) -> String? {
        if let accessError = error as? ReaderFileAccessError {
            return accessError.userFacingMessage
        }
        return nil
    }

    public static func deleteAlert(for error: Error) -> (title: String, message: String)? {
        guard let deleteError = error as? ReaderFileDeleteError,
              let message = deleteError.errorDescription else {
            return nil
        }
        return ("Delete Failed", message)
    }
}
