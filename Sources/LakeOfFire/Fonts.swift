import SwiftUI
#if canImport(AppKit)
import AppKit

public extension NSFont {
  class func preferredFont(from font: Font) -> NSFont {
      let style: NSFont.TextStyle
      switch font {
        case .largeTitle:  style = .largeTitle
        case .title:       style = .title1
        case .title2:      style = .title2
        case .title3:      style = .title3
        case .headline:    style = .headline
        case .subheadline: style = .subheadline
        case .callout:     style = .callout
        case .caption:     style = .caption1
        case .caption2:    style = .caption2
        case .footnote:    style = .footnote
        case .body: fallthrough
        default:           style = .body
     }
     return  NSFont.preferredFont(forTextStyle: style)
   }
}

extension NSFont.TextStyle {
    internal init(
        fromSwiftUIFontTextStyle textStyle: Font.TextStyle
    ) {
        switch textStyle {
        case .largeTitle:
            self = .largeTitle
        case .title:
            self = .title1
        case .title2:
            self = .title2
        case .title3:
            self = .title3
        case .headline:
            self = .headline
        case .subheadline:
            self = .subheadline
        case .body:
            self = .body
        case .callout:
            self = .callout
        case .footnote:
            self = .footnote
        case .caption:
            self = .caption1
        case .caption2:
            self = .caption2
        @unknown default:
            self = .body
        }
    }
}

public extension Font {
    static func pointSize(for textStyle: Font.TextStyle) -> CGFloat {
        NSFont.preferredFont(
            forTextStyle: NSFont.TextStyle(fromSwiftUIFontTextStyle: textStyle)
        )
        .pointSize
    }
}

#elseif canImport(UIKit)
import UIKit

public extension UIFont {
  class func preferredFont(from font: Font) -> UIFont {
      let style: UIFont.TextStyle
      switch font {
        case .largeTitle:  style = .largeTitle
        case .title:       style = .title1
        case .title2:      style = .title2
        case .title3:      style = .title3
        case .headline:    style = .headline
        case .subheadline: style = .subheadline
        case .callout:     style = .callout
        case .caption:     style = .caption1
        case .caption2:    style = .caption2
        case .footnote:    style = .footnote
        case .body: fallthrough
        default:           style = .body
     }
     return  UIFont.preferredFont(forTextStyle: style)
   }
}

extension UIFont.TextStyle {
    
    init(
        fromSwiftUIFontTextStyle textStyle: Font.TextStyle
    ) {
        switch textStyle {
        case .largeTitle:
            self = .largeTitle
        case .title:
            self = .title1
        case .title2:
            self = .title2
        case .title3:
            self = .title3
        case .headline:
            self = .headline
        case .subheadline:
            self = .subheadline
        case .body:
            self = .body
        case .callout:
            self = .callout
        case .footnote:
            self = .footnote
        case .caption:
            self = .caption1
        case .caption2:
            self = .caption2
        @unknown default:
            self = .body
        }
    }
}

extension Font {
    public static func pointSize(for textStyle: Font.TextStyle) -> CGFloat {
        UIFont.preferredFont(
            forTextStyle: UIFont.TextStyle(fromSwiftUIFontTextStyle: textStyle)
        )
        .pointSize
    }
}

#endif

struct SerifFontModifier: ViewModifier {
    let font: Font
    
    func body(content: Content) -> some View {
        if #available(iOS 16.1, macOS 13.0, *) {
            content
                .font(font)
                .fontDesign(.serif)
        } else {
            content
                .font(font)
        }
    }
}

public extension View {
    func serifFont(_ font: Font) -> some View {
        modifier(SerifFontModifier(font: font))
    }
}
