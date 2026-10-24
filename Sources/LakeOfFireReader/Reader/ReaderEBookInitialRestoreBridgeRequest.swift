import Foundation
import LakeOfFireContent

/// Value conversion only. Native document ownership is still enforced by the
/// caller; a request ID correlates a result and is not a document capability.
struct ReaderEBookInitialRestoreBridgeRequest: Sendable {
    let requestID: String
    let cfi: String
    let fractionalCompletion: Double?
    let requestedLocator: String

    init?(restore: ReaderContentEbookInitialRestore?, requestID: String = UUID().uuidString) throws {
        guard let restore,
              let validated = try ReaderContentEbookInitialRestore(
                validatingCFI: restore.cfi,
                fractionalCompletion: restore.fractionalCompletion
              ) else { return nil }
        self.requestID = requestID
        cfi = validated.cfi
        fractionalCompletion = validated.fractionalCompletion.map(Double.init)
        requestedLocator = cfi.isEmpty ? "fraction" : "cfi"
    }

    /// Run in the native handler's task. A failed/cancelled read is not an
    /// absent locator, including when a non-cooperative provider returns nil.
    @MainActor
    static func prepare(
        requestID: String = UUID().uuidString,
        loadSavedPosition: @MainActor () async throws -> ReaderContentEbookInitialRestore?
    ) async throws -> Self? {
        try Task.checkCancellation()
        let restore = try await loadSavedPosition()
        try Task.checkCancellation()
        return try Self(restore: restore, requestID: requestID)
    }

    var javaScriptArgument: [String: any Sendable] {
        var argument: [String: any Sendable] = [
            "requestID": requestID,
            "requestedLocator": requestedLocator,
            "cfi": cfi,
        ]
        if let fractionalCompletion {
            argument["fractionalCompletion"] = fractionalCompletion
        }
        return argument
    }
}
