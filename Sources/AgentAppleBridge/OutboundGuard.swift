import Foundation

enum OutboundGuard {
    private static let maximumAttachmentBytes: UInt64 = 10 * 1024 * 1024
    private static let allowedExtensions: Set<String> = [
        "pdf", "docx", "xlsx", "txt", "csv", "md", "json",
        "png", "jpg", "jpeg", "gif", "webp",
    ]
    private static let textExtensions: Set<String> = ["txt", "csv", "md", "json"]
    private static let blockedPatterns: [(String, NSRegularExpression)] = GeneratedSecretRedactionPatterns.blocked + [
        ("raw tool-call JSON", try! NSRegularExpression(pattern: #"\{\s*"(?:path|query|offset)"\s*:"#)),
        ("internal path", try! NSRegularExpression(pattern: #"(?:/Users/|/private/|/var/|/home/)"#)),
        ("agent config", try! NSRegularExpression(pattern: #"\b(?:gateway\.auth|tools\.allow|tools\.exec)\b"#)),
    ]

    static func validateMessage(params: [String: Any]) throws {
        let content = params["content"] as? [String: Any] ?? [:]
        for (key, value) in content {
            if key == "file", let file = value as? String {
                try validateAttachment(file)
                continue
            }
            for text in strings(in: value) {
                try validateText(text)
            }
        }
    }

    private static func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let values = value as? [Any] { return values.flatMap(strings) }
        if let values = value as? [String: Any] { return values.values.flatMap(strings) }
        return []
    }

    private static func validateText(_ text: String) throws {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (label, pattern) in blockedPatterns where pattern.firstMatch(in: text, range: range) != nil {
            throw BridgeError("outbound_blocked", "message content failed the \(label) pre-send check")
        }
    }

    private static func validateAttachment(_ rawPath: String) throws {
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
        let roots = allowedRoots()
        guard roots.contains(where: { contains(url.path, root: $0) }) else {
            throw BridgeError("attachment_path_denied", "attachment is outside the owner allow-roots")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw BridgeError("invalid_attachment", "attachment must be a regular file")
        }
        guard let size = values.fileSize, UInt64(size) <= maximumAttachmentBytes else {
            throw BridgeError("attachment_too_large", "attachment exceeds 10 MB")
        }
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw BridgeError("attachment_type_denied", "attachment extension is not allowed")
        }
        if textExtensions.contains(ext) {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let text = String(data: data, encoding: .utf8) else {
                throw BridgeError("invalid_attachment", "text attachment is not valid UTF-8")
            }
            try validateText(text)
        }
    }

    private static func allowedRoots() -> [String] {
        let configured = ProcessInfo.processInfo.environment["AGENT_BRIDGE_ALLOWED_ROOTS"]
        let rawRoots = configured?.split(separator: ":").map(String.init)
            ?? []
        return rawRoots.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
    }

    private static func contains(_ candidate: String, root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
