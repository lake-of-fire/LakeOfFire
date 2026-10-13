import Foundation

/// Shared native admission for a persisted EPUB restore locator.
///
/// Presence and numeric validity are separate: zero is a real beginning-of-book
/// position. If a stored fraction is present but malformed, the entire restore
/// request is rejected instead of quietly degrading to CFI-only success.
public enum ReaderEBookInitialRestorePolicy {
    public static func shouldRequestRestore(
        cfi: String,
        fractionalCompletion: Float?
    ) -> Bool {
        if let fractionalCompletion {
            guard fractionalCompletion.isFinite,
                  (0...1).contains(fractionalCompletion) else {
                return false
            }
        }
        return !cfi.isEmpty || fractionalCompletion != nil
    }
}
