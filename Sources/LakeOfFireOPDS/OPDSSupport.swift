//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension String {
    var dateFromISO8601: Date? {
        var value = self
        if let fractionalRange = value.range(of: "[.][0-9]+", options: .regularExpression) {
            value.replaceSubrange(fractionalRange, with: "")
        }
        return DateFormatter.iso8601Formatter(for: value).date(from: value)
    }
}

private extension DateFormatter {
    static func iso8601Formatter(for string: String) -> DateFormatter {
        let formats = [
            4: "yyyy",
            7: "yyyy-MM",
            10: "yyyy-MM-dd",
            11: "yyyy-MM-ddZ",
            16: "yyyy-MM-ddZZZZZ",
            19: "yyyy-MM-dd'T'HH:mm:ss",
            24: "yyyy-MM-dd'T'HH:mm:ssZ",
            25: "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        ]

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = formats[string.count] ?? "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }
}
