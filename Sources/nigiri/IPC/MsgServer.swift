import Foundation

// niri's IPC socket (`niri msg`), macOS edition: a unix domain socket at
// /tmp/nigiri-msg.sock speaking a line protocol - one request line in,
// one JSON line back, connection closed; the special request
// "event-stream" instead keeps the connection open and receives a JSON
// line per state change. The FIFO stays for fire-and-forget actions;
// this exists for the things a FIFO can't do: ANSWER (state queries for
// scripts and status bars) and PUSH (events).
final class MsgServer {
    nonisolated static let socketPath = "/tmp/nigiri-msg.sock"

    private var listenSource: DispatchSourceRead?
    private var connectionSources: [Int32: DispatchSourceRead] = [:]
    private var streamFDs: Set<Int32> = []
    var onRequest: ((String) -> String)?

    nonisolated static func makeAddress() -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { cString in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                    strlcpy(dst, cString, 104)
                }
            }
        }
        return address
    }

    func start() {
        // A subscriber vanishing mid-write must not kill the whole window
        // manager - without this, the first write to a closed stream fd
        // raises SIGPIPE and takes the process down.
        signal(SIGPIPE, SIG_IGN)
        unlink(Self.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("[msg] socket() failed"); return }
        var address = Self.makeAddress()
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            print("[msg] bind/listen failed on \(Self.socketPath)")
            close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                // NON-BLOCKING from the start. macOS does not inherit O_NONBLOCK
                // across accept(2) and libdispatch does not set it on a read
                // source's fd either (measured: the accepted fd reported
                // O_NONBLOCK=false), so every write below was a BLOCKING write on
                // the main thread. Both users of that thread were mis-served: the
                // request path's bounded wait could never trigger (write never
                // returns EAGAIN, so its deadline and poll were dead code), and a
                // client that is alive but not draining - `nigiri msg windows`
                // piped into a pager nobody advances, a process stopped with
                // Ctrl+Z - would fill the socket buffer and then freeze the
                // animator, the Carbon binds, the mouse tap and every AX
                // notification until it went away.
                let flags = fcntl(connection, F_GETFL, 0)
                if flags != -1 { _ = fcntl(connection, F_SETFL, flags | O_NONBLOCK) }
                self?.serve(connection)
            }
        }
        source.resume()
        listenSource = source
    }

    private func serve(_ connection: Int32) {
        var buffer = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: connection, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = read(connection, &chunk, 4096)
                guard n > 0 else { self.drop(connection); return }
                buffer.append(contentsOf: chunk[0..<n])
                guard let newline = buffer.firstIndex(of: 0x0A) else { return }
                let request = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if request == "event-stream" {
                    self.streamFDs.insert(connection)
                    self.send(connection, "{\"event\":\"subscribed\"}")
                    // the read source stays alive: its EOF is how we learn the
                    // subscriber went away
                } else {
                    self.sendFully(connection, self.onRequest?(request) ?? "{\"error\":\"no handler\"}")
                    self.drop(connection)
                }
            }
        }
        source.setCancelHandler { close(connection) }
        source.resume()
        connectionSources[connection] = source
    }

    private func drop(_ connection: Int32) {
        streamFDs.remove(connection)
        connectionSources.removeValue(forKey: connection)?.cancel()
    }

    // A REQUEST's answer: written in full, with a short deadline. `nigiri msg
    // windows` on a busy session is well past the socket buffer
    // (net.local.stream.sendspace is 8192 here, measured), so a single
    // non-blocking write returned short and the client parsed a truncated
    // JSON document - with nothing logged on either side. The client is
    // reading right now by construction, so waiting for it is bounded and
    // safe; a stream subscriber is a different animal and keeps the
    // drop-the-slow-reader policy below.
    @discardableResult
    private func sendFully(_ fd: Int32, _ line: String, deadline: TimeInterval = 0.5) -> Bool {
        let text = Array((line + "\n").utf8)
        let started = Date()
        var sent = 0
        while sent < text.count {
            let n = text.withUnsafeBufferPointer { write(fd, $0.baseAddress! + sent, text.count - sent) }
            if n > 0 { sent += n; continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                print("[ipc] respuesta cortada a los \(sent)/\(text.count) bytes: errno \(errno)")
                return false
            }
            guard Date().timeIntervalSince(started) < deadline else {
                print("[ipc] el cliente dejo de leer: respuesta cortada a los \(sent)/\(text.count) bytes")
                return false
            }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&poller, 1, 20)
        }
        return true
    }

    @discardableResult
    private func send(_ fd: Int32, _ line: String) -> Bool {
        let text = line + "\n"
        // Non-blocking (set once, at accept), because this runs on the MAIN thread - the same one
        // driving every animation tick and hotkey. A subscriber that stops
        // draining (a status bar that hung, an `event-stream` left paused in
        // a terminal) fills the socket buffer within a few KB, and a
        // blocking write would then freeze the whole window manager until
        // that client died.
        return text.utf8CString.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress, buf.count - 1) == buf.count - 1  // -1: not the NUL
        }
    }

    func broadcast(_ line: String) {
        // A subscriber that can't keep up gets dropped rather than being
        // allowed to stall the engine: it never closed the socket, so its
        // read source's EOF path would never fire on its own.
        for fd in streamFDs where !send(fd, line) {
            print("[msg] event-stream subscriber \(fd) no drena - lo suelto")
            drop(fd)
        }
    }
}
