import Foundation

// Live reload: watches the config file and re-arms itself when the file is
// replaced. Editors do not write in place - they write a temp file and
// rename it over the original, which makes the old inode (and this source)
// dead, so a plain "watch once" stops firing after the first save.
//
// Extracted from start(), where it was a recursive local function whose
// DispatchSource had to be kept alive by a stray `_ =` at the bottom.
final class ConfigWatcher {
    private let path: String
    // One source per watched file: the main config plus every include the
    // last successful load read. niri reloads on any of the config set;
    // watching only config.kdl left edits to an included file
    // (gestures.kdl, dms/windowrules.kdl) silently un-applied until an
    // unrelated save of the main file.
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var onChange: (@MainActor () -> Void)?

    init(path: String) {
        self.path = path
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        arm(path)
    }

    // Called after every load with the files it actually read. Newly
    // included files gain a watcher, dropped ones lose theirs; the main
    // config's stays either way.
    func watch(files: [String]) {
        let wanted = Set(files + [path])
        for (p, source) in sources where !wanted.contains(p) {
            source.cancel()
            sources.removeValue(forKey: p)
        }
        for p in wanted where sources[p] == nil { arm(p) }
    }

    private func arm(_ watchedPath: String) {
        let fd = open(watchedPath, O_EVTONLY)
        guard fd >= 0 else {
            // The file may not exist yet (or is mid-rename): retry rather
            // than silently giving up on live reload for the session.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { self.arm(watchedPath) }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let event = source.data
                self.onChange?()
                if event.contains(.delete) || event.contains(.rename) {
                    // The inode this source watches is gone: close it and watch
                    // the new file at the same path (editors save atomically -
                    // temp file renamed over the original).
                    source.cancel()
                    self.sources.removeValue(forKey: watchedPath)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated { self.arm(watchedPath) }
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources[watchedPath] = source
    }
}
