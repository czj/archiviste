import Foundation
import OSLog
import PDFNamerCore

/// Reports files that newly arrive in a folder, once their size has settled (a scanner or
/// a download may still be writing). Files present at start are left alone, and so are those
/// `accepts` turns down (wrong type, already handled by PDF Namer).
final class FolderWatcher {
    private let url: URL
    private let accepts: (URL) -> Bool
    private let onNew: ([URL]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String>
    private var pending: [String: Int] = [:]  // path → last seen size
    private var settling: Task<Void, Never>?

    /// `since`: when this folder was last watched. Files added after it (while the app was not
    /// running) are taken like new arrivals; without it, everything already there is left alone.
    init(_ url: URL, since: Date? = nil, accepts: @escaping (URL) -> Bool, onNew: @escaping ([URL]) -> Void) {
        self.url = url
        self.accepts = accepts
        self.onNew = onNew
        let present = Self.files(in: url)
        let missed = since.map { since in present.filter { (Self.added($0) ?? .distantPast) > since } } ?? []
        known = Set(present.map(\.path)).subtracting(missed.map(\.path))
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            Logger(subsystem: "com.github.czj.pdf-namer", category: "watch")
                .error("Impossible de surveiller \(url.path, privacy: .private)")
            return
        }
        // Dispatch sources predate Swift concurrency; the handler runs on the main queue.
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        if !missed.isEmpty { scan() }  // catch up: they settle and go out like arrivals
    }

    isolated deinit {
        source?.cancel()
        settling?.cancel()
    }

    func ignore(_ file: URL) { known.insert(file.path) }

    /// When the file entered this folder (Finder's "Date Added"), else its creation.
    private static func added(_ file: URL) -> Date? {
        let values = try? file.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate
    }

    private static func files(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: .skipsHiddenFiles)) ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    private func scan() {
        known = known.filter { FileManager.default.fileExists(atPath: $0) }  // forget files that left
        for file in Self.files(in: url) where !known.contains(file.path) && pending[file.path] == nil && accepts(file) {
            pending[file.path] = -1
        }
        guard !pending.isEmpty, settling == nil else { return }
        settling = Task { [weak self] in
            while let self, !self.pending.isEmpty {
                try? await Task.sleep(for: .seconds(1.5))
                self.check()
            }
            self?.settling = nil
        }
    }

    /// Emit files whose size did not change since the last look.
    private func check() {
        var ready: [URL] = []
        for (path, last) in pending {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else {
                pending[path] = nil  // gone (moved, deleted, renamed by the download)
                continue
            }
            if size > 0 && size == last {
                pending[path] = nil
                known.insert(path)
                ready.append(URL(fileURLWithPath: path))
            } else {
                pending[path] = size
            }
        }
        if !ready.isEmpty { onNew(ready.sorted { $0.path < $1.path }) }
    }
}
