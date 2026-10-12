import Foundation

public enum AtomicFileError: Error, LocalizedError {
    case create(path: String, errno: Int32)
    case write(path: String, errno: Int32)
    case rename(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case let .create(path, code): "Could not create a temporary file next to \(path): \(String(cString: strerror(code)))"
        case let .write(path, code): "Could not write \(path): \(String(cString: strerror(code)))"
        case let .rename(path, code): "Could not replace \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Writes files by creating a temp file in the same directory and renaming it over the target.
public enum AtomicFile {
    /// Creates `directory` (and parents) with the given permissions if it does not exist yet.
    public static func ensureDirectory(_ directory: URL, permissions: Int = 0o700) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue { return }
        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
    }

    /// Atomically replaces `url` with `data`. The final file has exactly `permissions`.
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let tempPath = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path

        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw AtomicFileError.create(path: url.path, errno: errno) }

        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        // umask can strip bits from open(); set the mode explicitly.
        if failure == 0, fchmod(fd, permissions) != 0 { failure = errno }
        close(fd)
        if failure != 0 {
            unlink(tempPath)
            throw AtomicFileError.write(path: url.path, errno: failure)
        }
        if rename(tempPath, url.path) != 0 {
            let code = errno
            unlink(tempPath)
            throw AtomicFileError.rename(path: url.path, errno: code)
        }
    }
}
