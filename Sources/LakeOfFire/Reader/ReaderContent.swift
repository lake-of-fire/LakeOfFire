import SwiftUI

public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol) = ReaderContentLoader.unsavedHome

    public init() { }
}
