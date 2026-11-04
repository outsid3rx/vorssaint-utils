// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone IPC integration test. VORSSAINT_MCP_TEST gives this process its
// own socket directory; it never contacts a running Vorssaint instance.
import Foundation
import Darwin

func fail(_ message: String) -> Never {
    fputs("IPC test failed: \(message)\n", stderr)
    exit(1)
}

let directory = "/tmp/vorssaint-mcp-test-\(getuid())-\(getpid())"
let socketPath = directory + "/control.sock"
var handled = 0
let server = MCPIPCServer { request in
    handled += 1
    return MCPIPCResponse(ok: request.command == "status", active: true)
}

do { try server.start() } catch { fail("start: \(error)") }
let duplicate = MCPIPCServer { _ in MCPIPCResponse(ok: true) }
do {
    try duplicate.start()
    fail("a second listener acquired the same socket")
} catch { }

DispatchQueue.global().async {
    do {
        let response = try MCPIPCClient.call(MCPIPCRequest(command: "status"))
        guard response.ok && response.active == true else { fail("incorrect response") }
        do {
            _ = try MCPIPCClient.call(MCPIPCRequest(command: String(repeating: "x", count: 16385)))
            fail("oversized request accepted")
        } catch MCPIPCError.invalidMessage { } catch { fail("unexpected oversized request error: \(error)") }

        // A malformed request must be closed without invoking the handler.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("test socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { fail("malformed request connect") }
        let invalid = Data("not json\n".utf8)
        _ = invalid.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        var byte: UInt8 = 0
        guard Darwin.read(fd, &byte, 1) == 0 else { fail("malformed request was not closed") }
        close(fd)

        DispatchQueue.main.async {
            guard handled == 1 else { fail("invalid request reached handler") }
            server.stop()
            do { try server.start() } catch { fail("restart: \(error)") }
            DispatchQueue.global().async {
                do {
                    let restarted = try MCPIPCClient.call(MCPIPCRequest(command: "status"))
                    guard restarted.ok else { fail("response after restart") }
                    DispatchQueue.main.async {
                        guard handled == 2 else { fail("unexpected handler calls") }
                        server.stop()
                        unlink(directory + "/lock")
                        rmdir(directory)
                        print("MCP IPC integration tests passed")
                        exit(0)
                    }
                } catch { fail("call after restart: \(error)") }
            }
        }
    } catch { fail("call: \(error)") }
}
dispatchMain()
