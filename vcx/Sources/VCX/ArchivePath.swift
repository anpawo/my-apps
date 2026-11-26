import Foundation
import Darwin

// Foundation folds /private/var back to /var; ownership checks need POSIX paths.
func canonicalArchiveRoot(_ directory: URL) throws -> URL {
    var ancestor = directory.standardizedFileURL, missing: [String] = []
    var value = stat()
    while lstat(ancestor.path, &value) != 0 {
        guard errno == ENOENT, ancestor.path != "/" else { throw VCXError(message: "Archive root could not be resolved.") }
        missing.append(ancestor.lastPathComponent)
        ancestor.deleteLastPathComponent()
    }
    guard let canonical = realpath(ancestor.path, nil) else { throw VCXError(message: "Archive root could not be resolved.") }
    defer { free(canonical) }
    return missing.reversed().reduce(URL(fileURLWithPath: String(cString: canonical))) { $0.appendingPathComponent($1) }
}
