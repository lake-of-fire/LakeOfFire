import Foundation
import SwiftSoup

public extension Document {
    func isEbook() -> Bool {
        let isEbook = try? (
            body()?.getAttributes()?.contains(where: { $0.getKey() == "epub:type" }) ?? false
            || select("html").hasAttr("xmlns:epub"))
        return isEbook ?? false
    }
    
    func ebookSectionType() -> String? {
        return try? body()?.attr("epub:type")
    }
}
