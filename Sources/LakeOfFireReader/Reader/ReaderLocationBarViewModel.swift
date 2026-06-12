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
    
    public init() { }
}
