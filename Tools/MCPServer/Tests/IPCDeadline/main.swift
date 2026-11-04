// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises deadlines and bounded concurrent local connections.
import Foundation
import Darwin

func fail(_ message: String) -> Never { fputs("IPC deadline test failed: \(message)\n", stderr); exit(1) }
let directory = "/tmp/vorssaint-mcp-test-\(getuid())-\(getpid())"
let path = directory + "/control.sock"
var handled = 0
let server = MCPIPCServer(maxConnections: 1, requestTimeout: 0.3) { _ in
    handled += 1
    return MCPIPCResponse(ok: true)
}
do { try server.start() } catch { fail("start: \(error)") }

func connectSocket() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { fail("connect") }
    return fd
}

DispatchQueue.global().async {
    // Keep one connection occupied with an incomplete request. The second
    // must be refused instead of allocating another blocked worker.
    let first = connectSocket()
    _ = Darwin.write(first, "{", 1)
    usleep(100_000)
    do {
        _ = try MCPIPCClient.call(MCPIPCRequest(command: "status"))
        fail("connection limit was not enforced")
    } catch { }
    usleep(400_000)
    var byte: UInt8 = 0
    guard Darwin.read(first, &byte, 1) == 0 else { fail("incomplete request did not expire") }
    close(first)

    // Once a complete request is sent, hold the main queue beyond its
    // deadline. The handler must not run after the caller's timeout.
    let ready = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        ready.signal()
        usleep(800_000)
    }
    ready.wait()
    do {
        let response = try MCPIPCClient.call(MCPIPCRequest(command: "status"))
        guard !response.ok && response.error == "request_expired" else { fail("expired request response") }
    } catch { fail("expired request: \(error)") }
    DispatchQueue.main.async {
        guard handled == 0 else { fail("expired request executed") }
        server.stop()
        unlink(directory + "/lock")
        rmdir(directory)
        print("MCP IPC deadline and connection limit tests passed")
        exit(0)
    }
}
dispatchMain()
