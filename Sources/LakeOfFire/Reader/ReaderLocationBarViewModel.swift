import SwiftUI

@MainActor
public class ReaderLocationBarViewModel: ObservableObject {
    @Published public var locationBarShouldGainFocusOnAppearance = false
    
    public init() { }
}
