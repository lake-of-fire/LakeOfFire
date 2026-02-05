import SwiftUI
import LakeOfFireCore
import LakeOfFireAdblock
//import SwiftyMonaco

public struct CodeEditor: View {
    @Binding var text: String
    var isWordWrapping = true

    @ScaledMetric(relativeTo: .body) private var fontSize = 10

    public var body: some View {
//#if os(iOS)
        TextEditor(text: $text)
//#else
//        SwiftyMonaco(text: $text)
//            .minimap(false)
//            .wordWrap(isWordWrapping)
//            .fontSize(Int(fontSize))
//            .syntaxHighlight(.javascript)
//            .clipShape(RoundedRectangle(cornerRadius: 4))
//#endif
    }

    public init(text: Binding<String>, isWordWrapping: Bool) {
        _text = text
        self.isWordWrapping = isWordWrapping
    }
}
