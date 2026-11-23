import Foundation

enum ReaderEBookStylesheetManifest {
    static func localPaths(in document: ReaderEBookPackageXML.Node?, packageDocumentPath: String) -> Set<Data> {
        let namespace = "http://www.idpf.org/2007/opf"
        guard let document, document.isElement("package", namespace) else { return [] }
        let manifests = document.children.filter { $0.isElement("manifest", namespace) }
        guard manifests.count == 1, let manifest = manifests.first else { return [] }

        let directory = packageDocumentPath.split(separator: "/").dropLast().map(String.init)
        let urlWhitespace = CharacterSet(charactersIn: " \t\r\n")
        var seen = Set<Data>()
        var stylesheets = Set<Data>()
        for item in manifest.children where item.isElement("item", namespace) {
            guard let href = item.attributes["href"]?.trimmingCharacters(in: urlWhitespace) else { continue }
            let reference = String(href.prefix { $0 != "?" && $0 != "#" })
            guard !reference.prefix(while: { $0 != "/" }).contains(":"),
                  let path = ReaderEBookPackageXML.resourcePath(reference, relativeTo: directory) else { continue }
            let key = Data(path.utf8)
            // Multiple declarations for one resolved resource are ambiguous,
            // including percent or relative aliases of the same exact path.
            guard seen.insert(key).inserted else {
                stylesheets.remove(key)
                continue
            }
            if item.attributes["media-type"]?.lowercased() == "text/css" {
                stylesheets.insert(key)
            }
        }
        return stylesheets
    }
}
