// SocketListener.swift — Unix domain socket server.
//
// Sidecar creates the socket on launch; daemon connects as client.
// One client at a time — daemon respawn means a new connection.
//
// Reads NDJSON, decodes via IncomingMessage, submits to Mailbox.
// On disconnect, an `onDisconnect` callback fires (used by main.swift
// to start the 10s idle-exit timer).

import Foundation
import Darwin

public protocol SocketListenerDelegate: AnyObject, Sendable {
    /// Called on the listener's queue. Forward to main for rendering.
    func didReceive(_ message: IncomingMessage)
    /// Called on the listener's queue. Client EOF / EPIPE.
    func didDisconnect()
    /// Called once a client connects.
    func didConnect()
}

public final class SocketListener {
    public let socketPath: String
    public weak var delegate: SocketListenerDelegate?

    private let queue = DispatchQueue(label: "myna.karaoke.socket", qos: .userInitiated)
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let lineBuffer = LineBuffer()
    private var stopping = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Bind, listen, and start accepting on the background queue.
    /// Errors thrown only on bind/listen failure (programmer-fixable);
    /// runtime client errors fire `didDisconnect`.
    public func start() throws {
        try bindAndListen()
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = true
            if self.clientFd >= 0 { Darwin.close(self.clientFd); self.clientFd = -1 }
            if self.listenFd >= 0 { Darwin.close(self.listenFd); self.listenFd = -1 }
            unlink(self.socketPath)
        }
    }

    // MARK: - Setup

    private func bindAndListen() throws {
        // Remove any stale socket first — common after a previous sidecar
        // crash. unlink() succeeds whether or not the path exists.
        unlink(socketPath)

        // Ensure parent directory exists with 0700.
        let parent = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        if listenFd < 0 { throw SocketError.socketCreate(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        // sockaddr_un.sun_path is 104 bytes on macOS.
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxPath else {
            Darwin.close(listenFd); listenFd = -1
            throw SocketError.pathTooLong(length: pathBytes.count, max: maxPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: maxPath) { ptr in
                for (i, byte) in pathBytes.enumerated() { ptr[i] = byte }
            }
        }

        // Close the TOCTOU window: bind() creates the socket file with
        // perms (0o777 & ~umask). Default umask (typically 022) yields a
        // world-readable/connectable socket for a sub-microsecond window
        // until the chmod 0600 below lands. A same-uid attacker racing
        // the chmod could connect() in that window and start receiving
        // utterances. Forcing umask to 0o077 makes bind() create the
        // socket file as 0o700 (effectively 0o600 for a SOCK_STREAM
        // node) up-front, eliminating the race.
        let oldMask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                Darwin.bind(listenFd, ptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        if bindResult < 0 {
            let err = errno
            Darwin.close(listenFd); listenFd = -1
            throw SocketError.bind(errno: err)
        }

        // Belt-and-braces: enforce 0600 owner-only even if the umask
        // dance is undone by some future refactor.
        chmod(socketPath, 0o600)

        if Darwin.listen(listenFd, 1) < 0 {
            let err = errno
            Darwin.close(listenFd); listenFd = -1
            throw SocketError.listen(errno: err)
        }
    }

    // MARK: - Accept / read loop

    private func acceptLoop() {
        while !stopping && listenFd >= 0 {
            let fd = Darwin.accept(listenFd, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if stopping { return }
                // Listen socket closed unexpectedly.
                return
            }
            clientFd = fd
            delegate?.didConnect()
            readLoop(fd: fd)
            // Tear down client side, but keep listen socket open for the
            // next daemon respawn.
            Darwin.close(fd)
            clientFd = -1
            lineBuffer.reset()
            delegate?.didDisconnect()
        }
    }

    private func readLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stopping {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n == 0 { return }          // EOF
            if n < 0 {
                if errno == EINTR { continue }
                return                    // EPIPE / ECONNRESET / etc.
            }
            let chunk = Data(buffer[0..<n])
            for line in lineBuffer.append(chunk) {
                do {
                    if let message = try IncomingMessage.decode(line: line) {
                        delegate?.didReceive(message)
                    }
                } catch {
                    // Malformed JSON — log to stderr, continue.
                    // (No real logging facility wired into the sidecar yet.)
                    FileHandle.standardError.write(
                        Data("karaoke: bad json line: \(error)\n".utf8)
                    )
                }
            }
        }
    }

    public enum SocketError: Error {
        case socketCreate(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case pathTooLong(length: Int, max: Int)
    }
}
