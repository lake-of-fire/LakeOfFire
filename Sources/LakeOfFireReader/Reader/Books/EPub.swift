import Foundation
import ZIPFoundation

struct EPub {
    // Forked from https://github.com/hbowie/NotenikLib/blob/master/Sources/NotenikLib/transform/WebBookMaker.swift#L934
    static func zipToEPub(directoryURL: URL) -> Data? {
        guard let archive = Archive(accessMode: .create) else {
            print("New EPUB archive could not be created at \(directoryURL)")
            return nil
        }
        addEpubEntry(archive: archive, directoryURL: directoryURL, relativePath: "mimetype")
        addEpubFolder(archive: archive, directoryURL: directoryURL, relativePath: "")
//        if let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
//            try? archive.data?.write(to: f.appendingPathComponent("test3.epub"))
//        }
        return archive.data
    }
    
    static func addEpubFolder(archive: Archive, directoryURL: URL, relativePath: String) {
        let folderURL: URL
        if relativePath.isEmpty {
            folderURL = directoryURL
        } else {
            guard let relativeFolderURL = URL(string: relativePath, relativeTo: directoryURL) else {
                print("Could not create a URL for folder at \(relativePath)")
                return
            }
            folderURL = relativeFolderURL
        }
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles)
            for entry in contents {
                if entry.lastPathComponent == "mimetype" { continue }
                let newRelPath = joinPaths(path1: relativePath, path2: entry.lastPathComponent)
                if entry.hasDirectoryPath {
                    addEpubFolder(archive: archive, directoryURL: directoryURL, relativePath: newRelPath)
                } else {
                    addEpubEntry(archive: archive, directoryURL: directoryURL, relativePath: newRelPath)
                }
            }
        } catch {
            print("Could not read directory at \(folderURL)")
        }
    }
    
    static func addEpubEntry(archive: Archive, directoryURL: URL, relativePath: String) {
        do {
            try archive.addEntry(
                with: relativePath,
                relativeTo: directoryURL,
                compressionMethod: relativePath == "mimetype" ? .none : .deflate)
        } catch {
            print("Unable to add \(relativePath) to epub archive: \(error)")
        }
    }
    
    /// Join two path Strings, ensuring one and only one slash between the two.
    ///
    /// - Parameters:
    ///   - path1: A string containing the beginning of a file path.
    ///   - path2: A string containing a continuation of a file path.
    /// - Returns: A combination of the two.
    static func joinPaths(path1: String, path2: String) -> String {
        if path1 == "" || path1 == " " {
            return path2
        }
        if path2 == "" || path2 == " " {
            return path1
        }
        if path2.starts(with: path1) {
            return path2
        }
        var e1 = path1.endIndex
        if path1.hasSuffix("/") {
            e1 = path1.index(path1.startIndex, offsetBy: path1.count - 1)
        }
        let sub1 = path1[..<e1]
        var s2 = path2.startIndex
        if path2.hasPrefix("/") {
            s2 = path2.index(path2.startIndex, offsetBy: 1)
        }
        let sub2 = path2[s2..<path2.endIndex]
        return sub1 + "/" + sub2
    }
}
