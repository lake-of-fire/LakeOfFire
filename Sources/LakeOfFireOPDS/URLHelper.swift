//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

enum URLHelper {
    // Preserve URI delimiters and existing percent escapes. This fallback also
    // supports IRIs on older Foundation versions whose URL initializer is strict.
    private static let referenceCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    static func resolve(href: String?, base: URL?) -> URL? {
        guard let href else { return nil }
        if href.isEmpty {
            guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: true),
                  components.scheme != nil else { return nil }
            components.fragment = nil
            return components.url
        }
        let encoded = href.addingPercentEncoding(withAllowedCharacters: referenceCharacters)
        guard let url = (URL(string: href, relativeTo: base)
            ?? encoded.flatMap { URL(string: $0, relativeTo: base) })?.absoluteURL,
              url.scheme != nil else { return nil }
        return url
    }

    static func resolveTemplate(_ template: String, base: URL?) -> String? {
        // Hide complete literal parameters while resolving the surrounding URI:
        // an optional parameter's '?' must not become the URI query separator.
        // Existing %7B/%7D escapes remain literal data, not template parameters.
        var marker = "_OPDS_TEMPLATE_"
        while template.contains(marker) || base?.absoluteString.contains(marker) == true {
            marker += "_"
        }
        var protected = ""
        var parameters: [(token: String, value: String)] = []
        var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{" {
                guard let end = template[cursor...].firstIndex(of: "}"),
                      !template[template.index(after: cursor)..<end].contains("{") else { return nil }
                let token = marker + String(parameters.count) + "_"
                parameters.append((token, String(template[cursor...end])))
                protected += token
                cursor = template.index(after: end)
            } else {
                guard template[cursor] != "}" else { return nil }
                protected.append(template[cursor])
                cursor = template.index(after: cursor)
            }
        }
        guard var resolved = getAbsolute(href: protected, base: base) else { return nil }
        for parameter in parameters {
            resolved = resolved.replacingOccurrences(of: parameter.token, with: parameter.value)
        }
        return resolved
    }

    static func isAbsolute(href: String) -> Bool {
        resolve(href: href, base: nil) != nil
    }

    static func getAbsolute(href: String?, base: URL?) -> String? {
        resolve(href: href, base: base)?.absoluteString
    }
}
