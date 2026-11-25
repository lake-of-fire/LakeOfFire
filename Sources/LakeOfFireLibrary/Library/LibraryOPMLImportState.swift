import Foundation
import LakeOfFireContent

enum LibraryOPMLImportState: Equatable {
    case idle
    case importing(id: UUID, isCancelling: Bool)
    case finished(id: UUID, result: OPMLImportResult)

    var isImporting: Bool {
        if case .importing = self { return true }
        return false
    }
}
