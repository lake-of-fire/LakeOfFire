import SwiftUI

public struct ReaderFileManagerSetupModifier: ViewModifier {
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    let updateHandler: (ReaderFileManager) -> Void
    
    public func body(content: Content) -> some View {
        content.task(id: readerFileManager.ubiquityContainerIdentifier) { @MainActor in
            updateHandler(readerFileManager)
        }
    }
}

public extension View {
    @ViewBuilder
    func readerFileManagerSetup(_ updateHandler: @escaping (ReaderFileManager) -> Void) -> some View {
        modifier(ReaderFileManagerSetupModifier(updateHandler: updateHandler))
    }
}
