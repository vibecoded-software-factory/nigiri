import Foundation

// The control FIFO (/tmp/nigiri-cmd): one action per line, routed through
// the same performAction as the config binds - one vocabulary, two input
// surfaces. Owning the fd and the line buffer here keeps them out of
// start()'s captured locals, where the buffer was invisible to the rest of
// the engine and only kept alive by a `_ = commandSource` at the end.
final class CommandPipe {
    private let path: String
    private var source: DispatchSourceRead?
    private var pending = Data()

    init(path: String = "/tmp/nigiri-cmd") {
        self.path = path
    }

    // Returns false (and says so) when the pipe could not be created: a
    // leftover regular file at that path used to disable every script and
    // automation with no diagnostic at all.
    @discardableResult
    func start(onLine: @escaping @MainActor (String) -> Void) -> Bool {
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else {
            print("[fifo] could not create \(path): \(String(cString: strerror(errno)))")
            return false
        }
        // O_RDWR, not O_RDONLY: keeps the FIFO open when writers come and go,
        // instead of hitting EOF after the first one disconnects.
        let fd = open(path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else {
            print("[fifo] could not open \(path): \(String(cString: strerror(errno)))")
            return false
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &chunk, 4096)
                guard n > 0 else { return }
                self.pending.append(contentsOf: chunk[0..<n])
                for line in Self.takeLines(from: &self.pending) { onLine(line) }
            }
        }
        source.resume()
        self.source = source
        return true
    }

    // Split off every complete line, leaving any partial tail in the buffer.
    // Static and pure so the framing is testable without a real pipe.
    static func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
