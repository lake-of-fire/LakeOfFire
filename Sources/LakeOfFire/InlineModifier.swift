import SwiftUI

struct InlineModifier<R: View>: ViewModifier {
    private let block: (Content) -> R
    
    public init(@ViewBuilder _ block: @escaping (Content) -> R) {
        self.block = block
    }
    
    public func body(content: Content) -> some View {
        block(content)
    }
}

extension View {
    func modifier<T: View>(@ViewBuilder _ block: @escaping (AnyView) -> T) -> some View {
        self.modifier(InlineModifier<T>({ (content: InlineModifier<T>.Content) in
            block(AnyView(content))
        }))
    }
}
