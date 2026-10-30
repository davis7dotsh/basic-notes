import Foundation

/// Watches one file that the notes-folder watcher doesn't cover (a symlinked note's target): writes in place (vnode events
/// on the file) and atomic replaces / creates / deletes (vnode events on its directory, not recursive). `onChange` runs on
/// the main actor, coalesced (~50ms), and only when the file itself changed — identity, size, modification or status-change
/// time — not for other files coming and going in its directory. Call `stop()` when done.
final class FileWatcher {
    let path: String
    private let onChange: () -> Void
    private var directory: DispatchSourceFileSystemObject?
    private var file: DispatchSourceFileSystemObject?
    /// Identity of the watched file: an atomic save replaces it, and the new one must be watched instead.
    private var fileID: (dev_t, ino_t)?
    /// The file as last reported (nil: missing): events that leave it unchanged (siblings churning) aren't reported.
    private var fingerprint: Fingerprint?
    private var scheduled = false
    private var stopped = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        directory = Self.source((path as NSString).deletingLastPathComponent, [.write, .rename, .delete]) { [weak self] in self?.changed() }
        fingerprint = Self.fingerprint(path)
        armFile()
    }

    private struct Fingerprint: Equatable {
        var dev: dev_t, ino: ino_t, size: off_t
        var mtime: timespec, ctime: timespec

        static func == (a: Self, b: Self) -> Bool {
            a.dev == b.dev && a.ino == b.ino && a.size == b.size && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
                && a.ctime.tv_sec == b.ctime.tv_sec && a.ctime.tv_nsec == b.ctime.tv_nsec
        }
    }

    private static func fingerprint(_ path: String) -> Fingerprint? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Fingerprint(dev: st.st_dev, ino: st.st_ino, size: st.st_size, mtime: st.st_mtimespec, ctime: st.st_ctimespec)
    }

    func stop() {
        stopped = true
        directory?.cancel()
        file?.cancel()
        directory = nil
        file = nil
    }

    private func armFile() {
        var st = stat()
        guard stat(path, &st) == 0 else {
            file?.cancel()
            file = nil
            fileID = nil
            return
        }
        if file != nil, let id = fileID, id == (st.st_dev, st.st_ino) { return }
        file?.cancel()
        fileID = (st.st_dev, st.st_ino)
        file = Self.source(path, [.write, .extend, .delete, .rename, .attrib, .link, .revoke]) { [weak self] in self?.changed() }
    }

    private func changed() {
        guard !scheduled, !stopped else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.scheduled = false
                self.armFile()
                let now = Self.fingerprint(self.path)
                guard now != self.fingerprint else { return }
                self.fingerprint = now
                self.onChange()
            }
        }
    }

    private static func source(_ path: String, _ mask: DispatchSource.FileSystemEvent, _ handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
