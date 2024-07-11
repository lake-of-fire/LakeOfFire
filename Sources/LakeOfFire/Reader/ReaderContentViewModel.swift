import SwiftUI

public class ReaderContentViewModel: ObservableObject {
    @Published public var content: (any ReaderContentModel) = ReaderContentLoader.unsavedHome

    public init() { }
}
