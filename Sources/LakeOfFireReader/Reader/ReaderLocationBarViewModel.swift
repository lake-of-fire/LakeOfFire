import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore

@MainActor
public class ReaderLocationBarViewModel: ObservableObject {
    @Published public var locationBarShouldGainFocusOnAppearance = false
    @Published public var isLocationBarEditing = false
    @Published public var dismissLocationBarRequestID = 0
    
    public init() { }

    /// Appearance and focus callbacks can agree on the current state. Avoid
    /// invalidating every toolbar observer when that state has not changed.
    public func setEditing(_ isEditing: Bool) {
        guard isLocationBarEditing != isEditing else { return }
        isLocationBarEditing = isEditing
    }

    public func requestDismissLocationBar() {
        locationBarShouldGainFocusOnAppearance = false
        dismissLocationBarRequestID &+= 1
        setEditing(false)
    }
}
