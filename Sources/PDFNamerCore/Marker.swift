import Darwin
import Foundation

/// A hidden mark (extended attribute) on every file PDF Namer renamed or filed, holding its
/// previous name. Unlike the "AAAA-MM-JJ - …" prefix, it survives an undated name, a name
/// edited by hand, and moves; copies through a cloud drive or a mail may drop it.
public enum Marker {
    public static let attribute = "com.github.czj.pdf-namer.renamed"

    public static func set(_ url: URL, originalName: String) {
        let value = Array(originalName.utf8)
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { setxattr($0, attribute, value, value.count, 0, XATTR_NOFOLLOW) }
        }
    }

    public static func clear(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in path.map { removexattr($0, attribute, XATTR_NOFOLLOW) } }
    }

    /// The name the file had before PDF Namer touched it, nil if unmarked.
    public static func originalName(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard getxattr(path, attribute, &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    public static func isMarked(_ url: URL) -> Bool { originalName(url) != nil }
}
