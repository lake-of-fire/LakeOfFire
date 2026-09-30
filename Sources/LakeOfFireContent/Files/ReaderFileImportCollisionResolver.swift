import Foundation

/// Forward-ports the hotfix retry loop. The copy callback MUST refuse replacement
/// of an occupied destination; the preceding inspection is not a reservation.
@MainActor
enum ReaderFileImportCollisionResolver {
    enum Destination: Sendable {
        case missing
        case identical
        case different
    }

    static func install(
        originalName: String,
        collisionName: @MainActor (Int) async throws -> String,
        inspect: @MainActor (String) async throws -> Destination,
        copyExclusively: @MainActor (String) async throws -> Void
    ) async throws -> String {
        var candidate = originalName
        var collision = 0
        while true {
            try Task.checkCancellation()
            let destination = try await inspect(candidate)
            try Task.checkCancellation()
            switch destination {
            case .identical:
                return candidate
            case .different:
                break
            case .missing:
                do {
                    try await copyExclusively(candidate)
                    // Copy success is the storage commit point. A late cancellation
                    // must not remove the installed item or retry another copy.
                    return candidate
                } catch {
                    let nsError = error as NSError
                    guard nsError.domain == NSCocoaErrorDomain,
                          nsError.code == CocoaError.fileWriteFileExists.rawValue else {
                        throw error
                    }
                    try Task.checkCancellation()
                    // Another importer may have won after the absence check.
                    let winner = try await inspect(candidate)
                    try Task.checkCancellation()
                    if case .identical = winner { return candidate }
                }
            }
            try Task.checkCancellation()
            guard collision < Int.max else { throw CocoaError(.fileWriteFileExists) }
            collision += 1
            candidate = try await collisionName(collision)
        }
    }
}
