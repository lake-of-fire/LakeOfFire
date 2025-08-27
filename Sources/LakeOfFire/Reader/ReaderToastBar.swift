import SwiftUI
import LakeKit

/// Capsule-shaped toast container reused by multiple bars.
public struct ReaderToastBar<Content: View>: View {
    @Binding private var isPresented: Bool
    private let onDismiss: (() -> Void)?
    private let content: Content
    
    public init(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self._isPresented = isPresented
        self.onDismiss = onDismiss
        self.content = content()
    }
    
    public var body: some View {
        if isPresented {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    content
#if os(macOS)
                        .padding(.leading, 8)
#elseif os(iOS)
                        .padding(.leading, 4)
#endif
                        .padding(.trailing, onDismiss == nil ? 4 : 4)
                    
                    if onDismiss != nil {
                        Spacer(minLength: 0)
                        DismissButton(.xMark, fill: true) {
                            withAnimation {
                                isPresented = false
                                onDismiss?()
                            }
                        }
                    }
                }
                .padding(2)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(radius: 2)
                Spacer(minLength: 0)
            }
#if os(iOS)
            .padding(.horizontal, 4)
#else
            .padding(.horizontal, 4)
#endif
            .padding(.vertical, 4)
        }
    }
}
