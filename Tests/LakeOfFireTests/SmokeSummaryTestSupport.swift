import Foundation
import XCTest

func extractSmokeSummary(from output: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    let marker = "smoke.summary: "
    guard let markerRange = output.range(of: marker, options: .backwards) else {
        XCTFail("Missing smoke.summary marker", file: file, line: line)
        return [:]
    }
    let jsonStart = markerRange.upperBound
    guard let objectStart = output[jsonStart...].firstIndex(of: "{") else {
        XCTFail("Missing JSON object after smoke.summary marker", file: file, line: line)
        return [:]
    }

    var depth = 0
    var inString = false
    var isEscaped = false
    var objectEnd: String.Index?
    var index = objectStart

    while index < output.endIndex {
        let character = output[index]
        if inString {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                inString = false
            }
        } else {
            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    objectEnd = output.index(after: index)
                    break
                }
            }
        }
        index = output.index(after: index)
    }

    guard let objectEnd else {
        XCTFail("Unterminated JSON object after smoke.summary marker", file: file, line: line)
        return [:]
    }

    let jsonString = String(output[objectStart..<objectEnd])
    let jsonData = try XCTUnwrap(jsonString.data(using: .utf8), file: file, line: line)
    let object = try JSONSerialization.jsonObject(with: jsonData)
    return try XCTUnwrap(object as? [String: Any], file: file, line: line)
}

func smokeSummaryValue(at path: [String], in object: [String: Any]) -> Any? {
    var current: Any? = object
    for key in path {
        guard let dictionary = current as? [String: Any] else { return nil }
        current = dictionary[key]
    }
    return current
}

func smokeSummaryBool(at path: [String], in object: [String: Any]) -> Bool? {
    smokeSummaryValue(at: path, in: object) as? Bool
}

func smokeSummaryString(at path: [String], in object: [String: Any]) -> String? {
    smokeSummaryValue(at: path, in: object) as? String
}

func smokeSummaryDictionary(at path: [String], in object: [String: Any]) -> [String: Any]? {
    smokeSummaryValue(at: path, in: object) as? [String: Any]
}

func smokeSummaryInt(at path: [String], in object: [String: Any]) -> Int {
    if let intValue = smokeSummaryValue(at: path, in: object) as? Int {
        return intValue
    }
    if let numberValue = smokeSummaryValue(at: path, in: object) as? NSNumber {
        return numberValue.intValue
    }
    return 0
}

func smokeSummaryNumber(at path: [String], in object: [String: Any]) -> Double? {
    if let numberValue = smokeSummaryValue(at: path, in: object) as? NSNumber {
        return numberValue.doubleValue
    }
    if let doubleValue = smokeSummaryValue(at: path, in: object) as? Double {
        return doubleValue
    }
    if let intValue = smokeSummaryValue(at: path, in: object) as? Int {
        return Double(intValue)
    }
    return nil
}
