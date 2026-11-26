import Darwin
import Foundation

final class UnixSocketServer {
    private let socketPath: String
    private let handler: (BridgeRequest) throws -> Any
    private var serverFD: Int32 = -1

    init(socketPath: String, handler: @escaping (BridgeRequest) throws -> Any) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit {
        if serverFD >= 0 { close(serverFD) }
    }

    func run() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw BridgeError("socket_directory_denied", "socket directory must be owned by this user with mode 0700")
        }
        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid() else {
                throw BridgeError("socket_path_denied", "refusing to replace a non-socket or another user's socket")
            }
            unlink(socketPath)
        }

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw BridgeError("socket_failed", "could not create Unix socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BridgeError("socket_path_too_long", "Apple bridge socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let previousMask = umask(0o077)
        defer { umask(previousMask) }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, length) }
        }
        guard bindResult == 0 else { throw BridgeError("bind_failed", "could not bind Apple bridge socket") }
        guard chmod(socketPath, 0o600) == 0 else {
            throw BridgeError("socket_permissions_failed", "could not restrict socket permissions")
        }
        guard listen(serverFD, 16) == 0 else { throw BridgeError("listen_failed", "could not listen on Apple bridge socket") }

        while true {
            let client = accept(serverFD, nil, nil)
            if client < 0 { continue }
            autoreleasepool { handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            writeResponse(bridgeResponse(success: false, error: BridgeError("peer_denied", "socket peer uid is not authorized")), to: client)
            return
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= 8 * 1024 * 1024 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if data.last == 0x0A { break }
        }
        if data.count > 8 * 1024 * 1024 {
            writeResponse(bridgeResponse(success: false, error: BridgeError("request_too_large", "request exceeded 8 MiB")), to: client)
            return
        }
        do {
            let request = try BridgeRequest.decode(data)
            let result = try handler(request)
            writeResponse(bridgeResponse(success: true, result: result), to: client)
        } catch let error as BridgeError {
            writeResponse(bridgeResponse(success: false, error: error), to: client)
        } catch {
            writeResponse(bridgeResponse(success: false, error: BridgeError("bridge_failed", error.localizedDescription)), to: client)
        }
    }

    private func writeResponse(_ response: [String: Any], to client: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(client, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count <= 0 { break }
                offset += count
            }
        }
    }
}
