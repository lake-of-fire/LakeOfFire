import Foundation
import LakeOfFireContent

public func nativeRestoreJSONFixtures() throws -> Data {
    let inputs: [(String, String?, Float?)] = [
        ("missing", nil, nil),
        ("zero", nil, 0),
        ("negativeZero", "", -0.0),
        ("end", "", 1),
        ("fraction", "", 0.25),
        ("cfiOnly", "epubcfi(/6/4[日本語]!/4/2:0)", nil),
        ("cfiHistoricalZero", "epubcfi(/6/4!)", 0),
        ("invalidWithCFI", "epubcfi(/6/4!)", .nan),
        ("invalidWithoutCFI", nil, .infinity),
    ]
    var result: [[String: Any]] = []
    for (name, cfi, fraction) in inputs {
        do {
            let value = try ReaderContentEbookInitialRestore(validatingCFI: cfi, fractionalCompletion: fraction)
            let request = try ReaderEBookInitialRestoreBridgeRequest(restore: value)
            result.append(["name": name, "rejected": false,
                "initialRestore": request?.javaScriptArgument as Any? ?? NSNull()])
        } catch {
            result.append(["name": name, "rejected": true])
        }
    }
    return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
}
