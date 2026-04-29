import Foundation

internal enum ReaderHTTPErrorRecoveryPolicy {
    internal struct ReaderModeFlags: Equatable {
        var isReaderModeByDefault: Bool
        var isReaderModeAvailable: Bool
        var isReaderModeOfferHidden: Bool
    }

    internal struct ReaderModeFlagUpdate: Equatable {
        var flags: ReaderModeFlags
        var didChange: Bool
    }

    internal static func isHTTPErrorStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return statusCode >= 400
    }

    internal static func shouldPreserveReaderState(
        isMainFrame: Bool,
        statusCode: Int?
    ) -> Bool {
        isMainFrame && isHTTPErrorStatus(statusCode)
    }

    internal static func showOriginalFlagUpdate(
        currentFlags: ReaderModeFlags,
        hasCapturedReadabilityContent: Bool,
        hasStoredFullContent: Bool = false
    ) -> ReaderModeFlagUpdate {
        var flags = currentFlags
        var didChange = false

        if flags.isReaderModeByDefault {
            flags.isReaderModeByDefault = false
            didChange = true
        }

        if hasCapturedReadabilityContent || hasStoredFullContent {
            if !flags.isReaderModeAvailable {
                flags.isReaderModeAvailable = true
                didChange = true
            }
            if !flags.isReaderModeOfferHidden {
                flags.isReaderModeOfferHidden = true
                didChange = true
            }
        }

        return ReaderModeFlagUpdate(flags: flags, didChange: didChange)
    }
}
