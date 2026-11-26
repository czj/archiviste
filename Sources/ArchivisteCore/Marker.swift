import Darwin
import Foundation

/// A hidden mark (extended attribute) on every file Archiviste renamed or filed, holding its
/// previous name. Unlike the "AAAA-MM-JJ - …" prefix, it survives an undated name and a name
/// edited by hand; copies through a cloud drive or a mail may drop it.
///
/// The mark holds only in the folder where the file was handled: a second attribute keeps the
/// file's "Date Added" there, which a rename in place leaves alone but any move changes. A file
/// taken out and put back (in the same folder or another) is new again, and handled again.
public enum Marker {
    /// Named after the app's first name, PDF Namer, and kept so: thousands of files already carry
    /// it, and a new name would make them look untouched.
    public static let attribute = "com.github.czj.pdf-namer.renamed"
    /// The file's Date Added when it was marked, in seconds since 1970.
    public static let addedAttribute = "com.github.czj.archiviste.added"
    /// Marks set before Date Added was kept (no second attribute): they hold for a file that came
    /// into its folder before this, and not for one that arrived since, which an older version
    /// marked elsewhere (2026-11-25 00:00 UTC).
    static let undatedUntil = Date(timeIntervalSince1970: 1_795_564_800)

    public static func set(_ url: URL, originalName: String) {
        write(attribute, Array(originalName.utf8), url)
        if let added = dateAdded(url) { write(addedAttribute, Array(String(added.timeIntervalSince1970).utf8), url) }
    }

    public static func clear(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map {
                removexattr($0, attribute, XATTR_NOFOLLOW)
                removexattr($0, addedAttribute, XATTR_NOFOLLOW)
            }
        }
    }

    /// The name the file had before Archiviste touched it, nil if never marked. Kept after the
    /// file moves: it still tells where the file came from, and rules may match on it.
    public static func originalName(_ url: URL) -> String? {
        read(attribute, url).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Handled by Archiviste in the folder it is in now: left alone. False once it has moved.
    public static func isMarked(_ url: URL) -> Bool {
        guard originalName(url) != nil else { return false }
        guard let added = dateAdded(url) else { return true }  // can't tell: keep the mark
        guard let raw = read(addedAttribute, url), let stamp = Double(String(decoding: raw, as: UTF8.self)) else {
            return added <= undatedUntil
        }
        return abs(added.timeIntervalSince1970 - stamp) < 1
    }

    /// When the file entered its folder (Finder's "Date Added"), read afresh.
    static func dateAdded(_ url: URL) -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
    }

    private static func write(_ name: String, _ value: [UInt8], _ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { setxattr($0, name, value, value.count, 0, XATTR_NOFOLLOW) }
        }
    }

    private static func read(_ name: String, _ url: URL) -> [UInt8]? {
        url.withUnsafeFileSystemRepresentation { path -> [UInt8]? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
            return buffer
        }
    }
}
