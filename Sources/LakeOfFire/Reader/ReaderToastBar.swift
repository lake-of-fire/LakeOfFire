import SwiftUI
import LakeKit

/// Capsule-shaped toast container reused by multiple bars.
public struct ReaderToastBar<Content: View>: View {
    private let isPresented: () -> Bool
    private let onDismiss: (() -> Void)?
    private let content: Content

    public init(
        isPresented: @escaping () -> Bool,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isPresented = isPresented
        self.onDismiss = onDismiss
        self.content = content()
    }
    
    public var body: some View {
        if isPresented() {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    content
                        .padding(.leading, 8)
                        .padding(.trailing, onDismiss == nil ? 8 : 16)

                    if let onDismiss {
                        Spacer(minLength: 0)
                        DismissButton(.xMark) {
                            onDismiss()
                        }
                    }
                }
                .padding(2)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(radius: 4)
                Spacer(minLength: 0)
            }
        }
    }
}
