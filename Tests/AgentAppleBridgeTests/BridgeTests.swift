import XCTest
@testable import AgentAppleBridge

final class BridgeTests: XCTestCase {
    func testRequestContract() throws {
        for domain in ["contacts", "messages", "notes", "reminders"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "version": 1, "domain": domain, "mode": "read", "params": ["action": "capabilities"]
            ])
            XCTAssertEqual(try BridgeRequest.decode(data).domain, domain)
        }
        for json in [
            #"{"version":2,"domain":"notes","mode":"read","params":{}}"#,
            #"{"version":1,"domain":"calendar","mode":"read","params":{}}"#,
            #"{"version":1,"domain":"notes","mode":"execute","params":{}}"#,
            #"{"version":1,"domain":"notes","mode":"read","params":[]}"#,
            "[]", "invalid"
        ] {
            XCTAssertThrowsError(try BridgeRequest.decode(Data(json.utf8)))
        }
    }

    func testOutboundTextAndNestedContent() throws {
        try OutboundGuard.validateMessage(params: ["content": ["text": "hello"]])
        for text in ["Bearer " + String(repeating: "x", count: 24),
                     "-----BEGIN PRIVATE KEY-----", String(repeating: "a", count: 64),
                     #"{"path":"private"}"#, "/private/example", "/Users/example/notes.txt", "gateway.auth"] {
            XCTAssertThrowsError(try OutboundGuard.validateMessage(params: [
                "content": ["options": [["text": text]]]
            ]))
        }
    }

    func testAttachmentRootsDenyByDefault() throws {
        let previous = ProcessInfo.processInfo.environment["AGENT_BRIDGE_ALLOWED_ROOTS"]
        unsetenv("AGENT_BRIDGE_ALLOWED_ROOTS")
        defer {
            if let previous { setenv("AGENT_BRIDGE_ALLOWED_ROOTS", previous, 1) }
            else { unsetenv("AGENT_BRIDGE_ALLOWED_ROOTS") }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("safe".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try OutboundGuard.validateMessage(params: ["content": ["file": file.path]])) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "attachment_path_denied")
        }
        setenv("AGENT_BRIDGE_ALLOWED_ROOTS", file.deletingLastPathComponent().path, 1)
        XCTAssertNoThrow(try OutboundGuard.validateMessage(params: ["content": ["file": file.path]]))
        setenv("AGENT_BRIDGE_ALLOWED_ROOTS", "", 1)
        XCTAssertThrowsError(try OutboundGuard.validateMessage(params: ["content": ["file": file.path]]))
    }

    func testContactsRejectWritesBeforeAccess() {
        XCTAssertThrowsError(try ContactsHandler().handle(mode: "write", params: ["action": "create"])) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "read_only")
        }
        XCTAssertThrowsError(try ContactsHandler().handle(mode: "read", params: ["action": "search", "query": " "]))
    }

    func testBundleNamespace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist.in"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let expected = ["io", "github", "mig" + "e" + "lizaga-rgb", "agentapplebridge"].joined(separator: ".")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, expected)
        XCTAssertEqual(plist["CFBundleName"] as? String, "Agent Apple Bridge")
    }
    func testMessagesBackendWithoutTCC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = directory.appendingPathComponent("backend.sh")
        let marker = directory.appendingPathComponent("invoked")
        let script = """
        #!/bin/sh
        printf 'called' >> '\(marker.path)'
        case "$1" in
          status) printf '%s' '{"basic_features":true,"advanced_features":false}' ;;
          chats) printf '%s\\n' '{"id":"row-0"}' '{"id":"row-1"}' '{"id":"row-2"}' ;;
          send) printf '%s' '{"stubbed":true}' ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let handler = MessagesHandler(imsgPath: stub.path)
        let target = ["handle": "TEST-HANDLE"]
        let safe: [String: Any] = ["action": "send", "target": target, "content": ["text": "hello"]]
        var dry = safe
        dry["dryRun"] = true
        let preview = try XCTUnwrap(try handler.handle(mode: "write", params: dry) as? [String: Any])
        XCTAssertEqual(preview["dryRun"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try handler.handle(mode: "write", params: [
            "action": "send", "target": target,
            "content": ["text": "Bearer " + String(repeating: "x", count: 24)]
        ])) { error in XCTAssertEqual((error as? BridgeError)?.code, "outbound_blocked") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let sent = try XCTUnwrap(try handler.handle(mode: "write", params: safe) as? [String: Any])
        XCTAssertEqual(sent["stubbed"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "calledcalled")
        let page = try XCTUnwrap(try handler.handle(mode: "read", params: [
            "action": "chats", "cursor": "1", "limit": 1
        ]) as? [String: Any])
        XCTAssertEqual((page["items"] as? [[String: Any]])?.first?["id"] as? String, "row-1")
        XCTAssertEqual(page["nextCursor"] as? String, "2")
        let before = try Data(contentsOf: marker)
        XCTAssertThrowsError(try handler.handle(mode: "read", params: ["action": "chats", "cursor": "-1"]))
        XCTAssertEqual(try Data(contentsOf: marker), before)
        XCTAssertThrowsError(try handler.handle(mode: "write", params: [
            "action": "edit", "target": ["chatGuid": "TEST-CHAT", "messageId": "TEST-MESSAGE"],
            "content": ["text": "replacement"]
        ])) { error in XCTAssertEqual((error as? BridgeError)?.code, "capability_unavailable") }
    }

    func testAttachmentRestrictions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = ProcessInfo.processInfo.environment["AGENT_BRIDGE_ALLOWED_ROOTS"]
        setenv("AGENT_BRIDGE_ALLOWED_ROOTS", root.path, 1)
        defer {
            if let previous { setenv("AGENT_BRIDGE_ALLOWED_ROOTS", previous, 1) }
            else { unsetenv("AGENT_BRIDGE_ALLOWED_ROOTS") }
        }
        let secret = root.appendingPathComponent("secret.txt")
        try Data(("Bearer " + String(repeating: "x", count: 24)).utf8).write(to: secret)
        let invalid = root.appendingPathComponent("invalid.txt")
        try Data([0xff, 0xfe]).write(to: invalid)
        let executable = root.appendingPathComponent("script.sh")
        try Data("echo test".utf8).write(to: executable)
        let large = root.appendingPathComponent("large.txt")
        try Data(repeating: 32, count: 10 * 1024 * 1024 + 1).write(to: large)
        let outside = directory.appendingPathComponent("outside.txt")
        try Data("safe".utf8).write(to: outside)
        let symlink = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let sibling = directory.appendingPathComponent("allowed-sibling.txt")
        try Data("safe".utf8).write(to: sibling)
        for (url, expected) in [(secret, "outbound_blocked"), (invalid, "invalid_attachment"),
                                (executable, "attachment_type_denied"), (large, "attachment_too_large"),
                                (symlink, "attachment_path_denied"), (sibling, "attachment_path_denied"),
                                (root, "invalid_attachment")] {
            XCTAssertThrowsError(try OutboundGuard.validateMessage(params: ["content": ["file": url.path]])) { error in
                XCTAssertEqual((error as? BridgeError)?.code, expected)
            }
        }
    }

}
