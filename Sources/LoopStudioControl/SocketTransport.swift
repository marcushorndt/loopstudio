import Foundation

/// The MCP server over a Unix socket: the running app listens here, so an agent reaches the open project
/// through `loopstudio mcp`, which forwards its stdin and stdout to this socket. One JSON message per line,
/// as on stdio. Every connection gets its own thread; the server handles the messages of one connection
/// in order.
public final class SocketTransport: @unchecked Sendable {
    /// Where the app listens: `LOOPSTUDIO_SOCKET`, else the app's Application Support folder.
    public static var defaultPath: String {
        if let env = ProcessInfo.processInfo.environment["LOOPSTUDIO_SOCKET"], !env.isEmpty { return env }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoopStudio", isDirectory: true)
        return support.appendingPathComponent("mcp.sock").path
    }

    private let server: MCPServer
    public let path: String
    private var listener: Int32 = -1

    public init(server: MCPServer, path: String = SocketTransport.defaultPath) {
        self.server = server
        self.path = path
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Binds the socket and accepts connections on a background thread. A socket file left by an earlier
    /// run is replaced. Only the user may connect (mode 600).
    public func start() throws {
        guard path.utf8.count < 100 else { throw Failure(description: "socket path too long: \(path)") }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        // A socket that still answers belongs to a running instance: it keeps the agents. Only a dead file goes.
        if FileManager.default.fileExists(atPath: path), SocketClient(path: path) != nil {
            throw Failure(description: "another LoopStudio already serves \(path)")
        }
        unlink(path)
        // A client that hangs up before its answer arrives must not end the app: the write then fails with EPIPE.
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) { bytes in
                _ = path.withCString { strncpy(bytes, $0, MemoryLayout.size(ofValue: tuple.pointee) - 1) }
            }
        }
        // The file is private from its first moment: no window between bind and chmod.
        let oldMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0 else {
            let reason = String(cString: strerror(errno)); close(fd)
            throw Failure(description: "bind \(path): \(reason)")
        }
        chmod(path, 0o600)
        var info = stat()
        if stat(path, &info) == 0 { ownInode = info.st_ino }
        guard listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno)); close(fd); unlink(path)
            throw Failure(description: "listen: \(reason)")
        }
        listener = fd
        let thread = Thread { [self] in
            while true {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { break }
                let worker = Thread { [self] in serve(connection) }
                worker.name = "loopstudio.mcp.connection"
                worker.start()
            }
        }
        thread.name = "loopstudio.mcp.listener"
        thread.start()
    }

    public func stop() {
        if listener >= 0 { close(listener); listener = -1 }
        // Only the own socket file goes; a newer instance's file stays.
        var info = stat()
        if stat(path, &info) == 0, info.st_ino == ownInode { unlink(path) }
    }

    /// The inode of the socket file this transport made, so `stop` never removes another instance's file.
    private var ownInode: ino_t = 0
    /// The longest line a client may send before the connection is dropped.
    private static let maxLine = 16 * 1024 * 1024

    private final class Box: @unchecked Sendable { var data: Data? }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(connection, &chunk, chunk.count)
            guard n > 0 else { break }
            pending.append(chunk, count: n)
            guard pending.count <= Self.maxLine else { break } // a client that never ends its line
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                guard !line.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) else { continue }
                // The server is async; this thread waits for its answer, so the messages stay in order.
                let box = Box()
                let done = DispatchSemaphore(value: 0)
                let server = server
                Task.detached { box.data = await server.handle(line); done.signal() }
                done.wait()
                guard var response = box.data else { continue } // a notification gets no answer
                response.append(10)
                var sent = 0
                while sent < response.count {
                    let wrote = response.withUnsafeBytes { write(connection, $0.baseAddress! + sent, response.count - sent) }
                    guard wrote > 0 else { return }
                    sent += wrote
                }
            }
        }
    }
}

/// The client side: connects to the app's socket and forwards messages. `loopstudio mcp` uses it to turn
/// its stdio into the app's socket.
public final class SocketClient: @unchecked Sendable {
    private let fd: Int32
    private var pending = Data()

    /// nil when nothing listens at the path.
    public init?(path: String = SocketTransport.defaultPath) {
        guard path.utf8.count < 100, FileManager.default.fileExists(atPath: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) { bytes in
                _ = path.withCString { strncpy(bytes, $0, MemoryLayout.size(ofValue: tuple.pointee) - 1) }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); return nil }
        self.fd = fd
    }

    deinit { close(fd) }

    /// Sends one message. A request (with an id) waits for its answer; a notification returns nil at once.
    public func send(_ line: String) -> String? {
        var data = Data(line.utf8)
        data.append(10)
        var sent = 0
        while sent < data.count {
            let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, data.count - sent) }
            guard wrote > 0 else { return nil }
            sent += wrote
        }
        guard Self.isRequest(line) else { return nil }
        return readLine()
    }

    /// A message with an id expects an answer.
    public static func isRequest(_ line: String) -> Bool {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), case .object(let o) = value else { return true }
        return o["id"] != nil
    }

    private func readLine() -> String? {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            pending.append(chunk, count: n)
        }
    }
}
