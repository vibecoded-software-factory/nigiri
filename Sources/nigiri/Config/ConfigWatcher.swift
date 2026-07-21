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
    private var source: DispatchSourceFileSystemObject?
    private var onChange: (@MainActor () -> Void)?

    init(path: String) {
        self.path = path
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        arm()
    }

    private func arm() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // The file may not exist yet (or is mid-rename): retry rather
            // than silently giving up on live reload for the session.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { self.arm() }
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
                    // the new file at the same path.
                    source.cancel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated { self.arm() }
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
}
