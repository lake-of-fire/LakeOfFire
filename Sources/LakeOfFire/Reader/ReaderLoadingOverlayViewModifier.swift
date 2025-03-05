import SwiftUI

// TODO: Instead of layering this across eg Reader and ManabiReader, have it once and use environment to set its activation (or similar)
public struct ReaderLoadingOverlayViewModifier: ViewModifier {
    let isLoading: Bool
    
    public init(isLoading: Bool) {
        self.isLoading = isLoading
    }
    
    @Environment(\.colorScheme) private var colorScheme
    
    public func body(content: Content) -> some View {
        content
            .overlay {
                if isLoading {
                    ZStack {
                        Rectangle()
                            .fill(colorScheme == .dark ? .black.opacity(0.7) : .white.opacity(0.7))
                        Rectangle()
                            .fill(.ultraThickMaterial)
                        ProgressView()
                        //                            .controlSize(.small)
                            .delayedAppearance()
                    }
                    .ignoresSafeArea(.all)
                }
            }
    }
}
