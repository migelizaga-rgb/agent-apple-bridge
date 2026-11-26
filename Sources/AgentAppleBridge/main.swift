import CryptoKit
import Foundation

if CommandLine.arguments.contains("--self-test") {
    do {
        let request = try BridgeRequest.decode(Data(#"{"version":1,"domain":"notes","mode":"read","params":{"action":"list"}}"#.utf8))
        guard request.version == 1, request.domain == "notes", request.mode == "read" else {
            throw BridgeError("self_test_failed", "decoded request did not match")
        }
        let contactsRequest = try BridgeRequest.decode(Data(#"{"version":1,"domain":"contacts","mode":"read","params":{"action":"search","query":"Sample"}}"#.utf8))
        guard contactsRequest.version == 1, contactsRequest.domain == "contacts", contactsRequest.mode == "read" else {
            throw BridgeError("self_test_failed", "contacts read request did not match")
        }
        do {
            _ = try BridgeRequest.decode(Data(#"{"version":1,"domain":"calendar","mode":"read","params":{}}"#.utf8))
            throw BridgeError("self_test_failed", "bogus domain was accepted")
        } catch let error as BridgeError where error.code == "invalid_domain" {
            // Expected.
        }
        print(#"{"ok":true,"test":"bridge-request-contract"}"#)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
        exit(1)
    }
}

let serviceEnabled = ["1", "true", "yes", "on"].contains(
    (ProcessInfo.processInfo.environment["AGENT_BRIDGE_ENABLED"] ?? "").lowercased()
)
if !serviceEnabled {
    // A disabled bridge must not bind its privileged same-user socket or prompt
    // for TCC access. The service exits successfully without requesting access.
    exit(0)
}

// Optional SHA-1 leaf certificate pin for a locally issued signing identity.
private let defaultPinnedLeafCertificateHash = ""

private let unsignedDebugTestBypassEnabled: Bool = {
#if DEBUG
    return ProcessInfo.processInfo.environment["AGENT_BRIDGE_ALLOW_UNSIGNED_TEST"] == "1"
#else
    return false
#endif
}()

if !unsignedDebugTestBypassEnabled {
    do {
        guard let executable = Bundle.main.executableURL?.path else {
            throw BridgeError("signing_check_failed", "bridge executable path is unavailable")
        }
        let verification = try ProcessRunner.run(
            "/usr/bin/codesign",
            ["--verify", "--strict", executable],
            timeout: 10
        )
        let signature = try ProcessRunner.run("/usr/bin/codesign", ["-d", "-r-", executable], timeout: 10)
        // `codesign -d -r-` prints the designated requirement on stdout and only the
        // "Executable=" banner on stderr. Reading stderr alone left this string empty,
        // so the gate rejected every signature regardless of its certificate. Join both
        // streams so the check survives codesign moving output between them.
        let requirement = [signature.stdout, signature.stderr]
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        // A locally issued identity never chains to Apple's root, so `anchor apple
        // generic` can never appear in its designated requirement. Pinning the exact
        // leaf certificate is the stricter test for this same-user socket: it admits
        // one specific certificate instead of every Apple-anchored developer. Accept
        // either, so moving to a Developer ID identity later needs no code change.
        let pinnedLeaf = (
            ProcessInfo.processInfo.environment["AGENT_BRIDGE_PINNED_LEAF"]
                ?? defaultPinnedLeafCertificateHash
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let signedByAppleAnchor = requirement.contains("anchor apple generic")
        let signedByPinnedLeaf = !pinnedLeaf.isEmpty
            && requirement.lowercased().contains("certificate leaf = h\"\(pinnedLeaf)\"")
        guard verification.status == 0,
              signature.status == 0,
              requirement.contains("identifier \"io.github.mig\u{65}lizaga-rgb.agentapplebridge\""),
              signedByAppleAnchor || signedByPinnedLeaf else {
            throw BridgeError("persistent_signing_required", "enabled service requires an Apple-anchored identity or the pinned leaf certificate")
        }
    } catch {
        FileHandle.standardError.write(Data("AgentAppleBridge signing gate: \(error.localizedDescription)\n".utf8))
        exit(78)
    }
}

private final class AuditLogger {
    private let url: URL
    private let queue = DispatchQueue(label: "io.github.mig\u{65}lizaga-rgb.agentapplebridge.audit")

    init() {
        if let configured = ProcessInfo.processInfo.environment["AGENT_BRIDGE_AUDIT_PATH"],
           !configured.isEmpty {
            url = URL(fileURLWithPath: configured)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AgentAppleBridge", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        url = directory.appendingPathComponent("apple-bridge-audit.jsonl")
    }

    func append(request: BridgeRequest, success: Bool) {
        queue.sync {
            let requestEnvelope: [String: Any] = [
                "version": request.version,
                "domain": request.domain,
                "mode": request.mode,
                "params": request.params,
            ]
            let serialized = (try? JSONSerialization.data(withJSONObject: requestEnvelope, options: [.sortedKeys])) ?? Data()
            let digest = SHA256.hash(data: serialized).map { String(format: "%02x", $0) }.joined()
            let row: [String: Any] = [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "domain": request.domain,
                "mode": request.mode,
                "action": request.params["action"] as? String ?? "unknown",
                "success": success,
                "payloadHash": digest,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([0x0A]))
        }
    }
}

nonisolated(unsafe) private let reminders = RemindersHandler()
nonisolated(unsafe) private let notes = NotesHandler()
nonisolated(unsafe) private let messages = MessagesHandler()
nonisolated(unsafe) private let contacts = ContactsHandler()
nonisolated(unsafe) private let audit = AuditLogger()

private func route(_ request: BridgeRequest) throws -> Any {
    do {
        let result: Any
        switch request.domain {
        case "reminders":
            result = try reminders.handle(mode: request.mode, params: request.params)
        case "notes":
            result = try notes.handle(mode: request.mode, params: request.params)
        case "messages":
            result = try messages.handle(mode: request.mode, params: request.params)
        case "contacts":
            result = try contacts.handle(mode: request.mode, params: request.params)
        default:
            throw BridgeError("invalid_domain", "unsupported Apple bridge domain")
        }
        audit.append(request: request, success: true)
        return result
    } catch {
        audit.append(request: request, success: false)
        throw error
    }
}

let defaultSocket = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/AgentAppleBridge/apple-bridge.sock").path
let socketPath = ProcessInfo.processInfo.environment["AGENT_BRIDGE_SOCKET"] ?? defaultSocket

// The accept loop blocks, so it runs off the main thread. The main run loop
// stays free to deliver EventKit change notifications.
let serverThread = Thread {
    do {
        try UnixSocketServer(socketPath: socketPath, handler: route).run()
    } catch {
        fputs("AgentAppleBridge fatal: \(error.localizedDescription)\n", stderr)
    }
    exit(1)
}
serverThread.name = "apple-bridge-socket"
serverThread.start()

// A run loop with no sources returns at once; the timer keeps it parked.
RunLoop.main.add(Timer(timeInterval: 86_400, repeats: true) { _ in }, forMode: .default)
RunLoop.main.run()
