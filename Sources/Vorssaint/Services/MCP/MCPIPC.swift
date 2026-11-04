// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Darwin

struct MCPIPCRequest: Codable, Sendable {
    let command: String
    let minutes: Int?
    let id: String?
    let value: Double?
    let action: String?
    let muted: Bool?
    let offset: Int?
    let outputOffset: Int?
    init(command: String, minutes: Int? = nil, id: String? = nil, value: Double? = nil,
         action: String? = nil, muted: Bool? = nil, offset: Int? = nil, outputOffset: Int? = nil) {
        self.command = command; self.minutes = minutes; self.id = id; self.value = value
        self.action = action; self.muted = muted; self.offset = offset; self.outputOffset = outputOffset
    }
}

struct MCPIPCResponse: Codable, Sendable {
    let ok: Bool
    var available: Bool? = nil
    var active: Bool? = nil
    var endDate: String? = nil
    var sessionTrigger: String? = nil
    var error: String? = nil
    var payload: String? = nil
}

enum MCPIPCError: Error, LocalizedError {
    case unavailable, invalidMessage, system(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Vorssaint MCP control is unavailable."
        case .invalidMessage: return "Invalid IPC message."
        case .system(let message): return message
        }
    }
}

private enum MCPIPCSocket {
    static let limit = 16384
    static func deadline(seconds: Double) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, seconds) * 1_000_000_000)
    }
    static func expired(_ deadline: UInt64) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }
    static var directory: String {
        #if VORSSAINT_MCP_TEST
        return "/tmp/vorssaint-mcp-test-\(getuid())-\(getpid())"
        #elseif VORSSAINT_DEVELOPMENT
        return "/tmp/vorssaint-mcp-\(getuid())-dev"
        #else
        return "/tmp/vorssaint-mcp-\(getuid())"
        #endif
    }
    static var path: String { directory + "/control.sock" }

    static func address() throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw MCPIPCError.unavailable }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }
    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
    static func readMessage(_ fd: Int32, deadline: UInt64) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= limit {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw MCPIPCError.unavailable }
            let remaining = deadline - now
            let millis = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, millis)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw MCPIPCError.unavailable }
            let n = Darwin.read(fd, &byte, 1)
            guard n == 1 else { throw MCPIPCError.invalidMessage }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw MCPIPCError.invalidMessage
    }
    static func writeMessage<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw MCPIPCError.invalidMessage }
        data.append(10)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
                guard n > 0 else { throw MCPIPCError.unavailable }
                sent += n
            }
        }
    }
}

/// Access is deliberately scoped to the current macOS user, not a particular
/// agent. Enabling control authorizes other processes running as that user.
enum MCPIPCClient {
    static func call(_ request: MCPIPCRequest) throws -> MCPIPCResponse {
        let deadline = MCPIPCSocket.deadline(seconds: 5)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPIPCError.unavailable }
        defer { close(fd) }
        MCPIPCSocket.configure(fd)
        var addr = try MCPIPCSocket.address()
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, MCPIPCSocket.sameUser(fd) else { throw MCPIPCError.unavailable }
        try MCPIPCSocket.writeMessage(request, to: fd)
        return try JSONDecoder().decode(MCPIPCResponse.self, from: MCPIPCSocket.readMessage(fd, deadline: deadline))
    }
}

// Lifecycle methods are called on the main thread; the immutable handler is
// invoked on that same thread. The listener queue only accepts connections.
final class MCPIPCServer: @unchecked Sendable {
    private let handler: (MCPIPCRequest) -> MCPIPCResponse
    private let queue = DispatchQueue(label: "com.vorssaint.mcp.ipc")
    private let connectionSlots: DispatchSemaphore
    private let requestTimeout: Double
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var socketFD: Int32 = -1
    init(maxConnections: Int = 16, requestTimeout: Double = 4,
         handler: @escaping (MCPIPCRequest) -> MCPIPCResponse) {
        precondition(maxConnections > 0 && requestTimeout > 0)
        self.connectionSlots = DispatchSemaphore(value: maxConnections)
        self.requestTimeout = requestTimeout
        self.handler = handler
    }

    func start() throws {
        guard source == nil else { return }
        let directory = MCPIPCSocket.directory
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw MCPIPCError.unavailable }
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw MCPIPCError.unavailable }
        let lock = open(directory + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw MCPIPCError.unavailable }
        guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw MCPIPCError.unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); throw MCPIPCError.unavailable }
        do {
            // Only remove a stale endpoint while holding the per-user lock.
            if lstat(MCPIPCSocket.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid(),
                      unlink(MCPIPCSocket.path) == 0 else { throw MCPIPCError.unavailable }
            } else if errno != ENOENT { throw MCPIPCError.unavailable }
            var addr = try MCPIPCSocket.address()
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw MCPIPCError.unavailable }
            guard chmod(MCPIPCSocket.path, 0o600) == 0, listen(fd, 8) == 0 else {
                unlink(MCPIPCSocket.path); throw MCPIPCError.unavailable
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            lockFD = lock
            socketFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients(fd) }
            self.source = source
            source.resume()
        } catch {
            close(fd); close(lock); throw error
        }
    }

    func stop() {
        guard let source = source else { return }
        source.cancel()
        self.source = nil
        // Drain the listener's event queue before closing descriptors.
        queue.sync {}
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        unlink(MCPIPCSocket.path)
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }
    deinit { stop() }

    private func acceptClients(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { return }
            guard MCPIPCSocket.sameUser(fd) else { close(fd); continue }
            guard connectionSlots.wait(timeout: .now()) == .success else { close(fd); continue }
            _ = fcntl(fd, F_SETFL, 0)
            MCPIPCSocket.configure(fd)
            let deadline = MCPIPCSocket.deadline(seconds: requestTimeout)
            let slots = connectionSlots
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { close(fd); slots.signal(); return }
                do {
                    let request = try JSONDecoder().decode(MCPIPCRequest.self, from: MCPIPCSocket.readMessage(fd, deadline: deadline))
                    DispatchQueue.main.async {
                        let response = MCPIPCSocket.expired(deadline)
                            ? MCPIPCResponse(ok: false, error: "request_expired")
                            : self.handler(request)
                        DispatchQueue.global(qos: .utility).async {
                            try? MCPIPCSocket.writeMessage(response, to: fd)
                            close(fd)
                            slots.signal()
                        }
                    }
                } catch { close(fd); slots.signal() }
            }
        }
    }
}
