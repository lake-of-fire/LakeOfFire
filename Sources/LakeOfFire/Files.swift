import Foundation

public enum FileLoadingError: Error {
    case InvalidPath
}

public func loadFile(name: String, type: String) throws -> String {
    guard let filePath = Bundle.main.path(forResource: name, ofType: type) else {
        throw FileLoadingError.InvalidPath
    }
    
    return try String(contentsOfFile: filePath)
}
