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

public func loadModuleFile(name: String, extension fileExtension: String, subdirectory: String?) throws -> String {
    guard let fileURL = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory) else {
        throw FileLoadingError.InvalidPath
    }
    
    return try String(contentsOf: fileURL)
}
