import Foundation

final class MessagesHandler {
    private let imsgPath: String

    init(imsgPath: String = ProcessInfo.processInfo.environment["AGENT_BRIDGE_IMSG_PATH"] ?? "/opt/homebrew/bin/imsg") {
        self.imsgPath = imsgPath
    }

    func handle(mode: String, params: [String: Any]) throws -> Any {
        let action = (params["action"] as? String ?? "").lowercased()
        if action == "capabilities" {
            return try ProcessRunner.json(imsgPath, ["status", "--json"])
        }
        if mode == "read" {
            return try read(action: action, params: params)
        }
        if params["dryRun"] as? Bool == true {
            return ["dryRun": true, "preview": preview(action: action, params: params)]
        }
        return try write(action: action, params: params)
    }

    private func read(action: String, params: [String: Any]) throws -> Any {
        let limit = min(max(params["limit"] as? Int ?? 50, 1), 200)
        let cursorText = params["cursor"] as? String ?? "0"
        guard let offset = Int(cursorText), offset >= 0, offset < 200 else {
            throw BridgeError("invalid_cursor", "Messages cursor must be an integer from 0 through 199")
        }
        let fetchLimit = min(offset + limit + 1, 200)
        let filters = params["filters"] as? [String: Any] ?? [:]
        var args: [String]
        switch action {
        case "chats":
            args = ["chats", "--limit", String(fetchLimit), "--json"]
            if filters["unreadOnly"] as? Bool == true { args.append("--unread-only") }
        case "history":
            args = ["history", "--limit", String(fetchLimit), "--json"]
            appendTarget(params, to: &args)
            if params["includeAttachments"] as? Bool == true { args.append("--attachments") }
            if let start = filters["start"] as? String { args += ["--start", start] }
            if let end = filters["end"] as? String { args += ["--end", end] }
        case "search":
            guard let query = params["query"] as? String, !query.isEmpty else {
                throw BridgeError("invalid_query", "Messages search query is required")
            }
            args = ["search", "--query", query, "--limit", String(fetchLimit), "--json"]
        case "group":
            args = ["group", "--json"]
            appendTarget(params, to: &args)
            return try ProcessRunner.json(imsgPath, args)
        default:
            throw BridgeError("unsupported_action", "unsupported Messages read action")
        }
        let rows = try ProcessRunner.jsonRecords(imsgPath, args)
        let page = Array(rows.dropFirst(offset).prefix(limit))
        let next = offset + page.count < rows.count ? String(offset + page.count) : nil
        let nextCursor: Any = next.map { $0 as Any } ?? NSNull()
        return [
            "items": page,
            "nextCursor": nextCursor,
        ]
    }

    private func write(action: String, params: [String: Any]) throws -> Any {
        let target = params["target"] as? [String: Any] ?? [:]
        let content = params["content"] as? [String: Any] ?? [:]
        try OutboundGuard.validateMessage(params: params)
        try requireCapability(for: action)
        var args: [String]
        switch action {
        case "send":
            args = ["send"]
            appendTarget(target, to: &args)
            if let text = content["text"] as? String { args += ["--text", text] }
            if let file = content["file"] as? String { args += ["--file", file] }
            if let service = content["service"] as? String { args += ["--service", service] }
            if content["text"] == nil && content["file"] == nil {
                throw BridgeError("invalid_content", "message text or an attachment is required")
            }
        case "react":
            args = ["react"]
            guard let chatID = target["chatId"] else {
                throw BridgeError("invalid_target", "chatId is required for the UI-automation reaction")
            }
            args += ["--chat-id", String(describing: chatID)]
            guard let reaction = content["reaction"] as? String else {
                throw BridgeError("invalid_content", "reaction is required")
            }
            args += ["--reaction", reaction]
        case "tapback":
            args = ["tapback"]
            try appendAdvancedTarget(target, to: &args)
            guard let messageId = target["messageId"] as? String,
                  let reaction = content["reaction"] as? String else {
                throw BridgeError("invalid_content", "messageId and reaction are required")
            }
            args += ["--message", messageId, "--kind", reaction]
            if let part = content["part"] { args += ["--part", String(describing: part)] }
            if content["remove"] as? Bool == true { args.append("--remove") }
        case "edit":
            args = ["edit"]
            try appendAdvancedTarget(target, to: &args)
            guard let messageId = target["messageId"] as? String,
                  let text = content["text"] as? String else {
                throw BridgeError("invalid_content", "messageId and text are required")
            }
            args += ["--message", messageId, "--new-text", text]
            if let part = content["part"] { args += ["--part", String(describing: part)] }
        case "unsend", "delete-message":
            args = [action]
            try appendAdvancedTarget(target, to: &args)
            guard let messageId = target["messageId"] as? String else {
                throw BridgeError("invalid_target", "messageId is required")
            }
            args += ["--message", messageId]
            if action == "unsend", let part = content["part"] { args += ["--part", String(describing: part)] }
        case "chat-name":
            args = ["chat-name"]
            try appendAdvancedTarget(target, to: &args)
            guard let name = content["name"] as? String else { throw BridgeError("invalid_content", "chat name is required") }
            args += ["--name", name]
        case "chat-photo":
            args = ["chat-photo"]
            try appendAdvancedTarget(target, to: &args)
            if let file = content["file"] as? String { args += ["--file", file] }
        case "chat-add-member", "chat-remove-member":
            args = [action]
            try appendAdvancedTarget(target, to: &args)
            guard let member = content["member"] as? String else { throw BridgeError("invalid_content", "member is required") }
            args += ["--address", member]
        case "chat-leave", "chat-delete":
            args = [action]
            try appendAdvancedTarget(target, to: &args)
        case "poll":
            args = ["poll", "send"]
            try appendPollTarget(target, to: &args)
            guard let question = content["question"] as? String,
                  let options = content["options"] as? [String], options.count >= 2 else {
                throw BridgeError("invalid_content", "poll question and at least two options are required")
            }
            args += ["--question", question]
            if let comment = content["comment"] as? String { args += ["--comment", comment] }
            if let replyTo = target["replyTo"] as? String { args += ["--reply-to", replyTo] }
            for option in options { args += ["--option", option] }
        default:
            throw BridgeError("unsupported_action", "unsupported Messages write action")
        }
        args.append("--json")
        return try ProcessRunner.json(imsgPath, args)
    }

    private func requireCapability(for action: String) throws {
        if action == "react" { return }
        guard let status = try ProcessRunner.json(imsgPath, ["status", "--json"]) as? [String: Any] else {
            throw BridgeError("capability_unavailable", "imsg capability status was unavailable")
        }
        if action == "send", status["basic_features"] as? Bool == true { return }
        let requiredMethod: [String: String] = [
            "tapback": "tapback",
            "edit": "message.edit",
            "unsend": "message.unsend",
            "delete-message": "message.delete",
            "chat-name": "group.rename",
            "chat-photo": "group.setIcon",
            "chat-add-member": "group.addParticipant",
            "chat-remove-member": "group.removeParticipant",
            "chat-leave": "group.leave",
            "chat-delete": "chats.delete",
            "poll": "poll.send",
        ]
        guard status["advanced_features"] as? Bool == true,
              status["v2_ready"] as? Bool == true,
              let method = requiredMethod[action],
              (status["rpc_methods"] as? [String])?.contains(method) == true else {
            throw BridgeError("capability_unavailable", "imsg does not currently support \(action)")
        }
    }

    private func appendAdvancedTarget(_ target: [String: Any], to args: inout [String]) throws {
        guard let guid = target["chatGuid"] as? String, !guid.isEmpty else {
            throw BridgeError("invalid_target", "chatGuid is required for this Messages action")
        }
        args += ["--chat", guid]
    }

    private func appendPollTarget(_ target: [String: Any], to args: inout [String]) throws {
        if let id = target["chatId"] { args += ["--chat-id", String(describing: id)] }
        else if let guid = target["chatGuid"] as? String { args += ["--chat", guid] }
        else { throw BridgeError("invalid_target", "chatId or chatGuid is required for a poll") }
    }

    private func appendTarget(_ params: [String: Any], to args: inout [String]) {
        if let id = params["id"] as? String { args += ["--chat-id", id] }
        let target = params["target"] as? [String: Any] ?? params
        if let id = target["chatId"] { args += ["--chat-id", String(describing: id)] }
        else if let guid = target["chatGuid"] as? String { args += ["--chat-guid", guid] }
        else if let identifier = target["chatIdentifier"] as? String { args += ["--chat-identifier", identifier] }
        else if let handle = target["handle"] as? String { args += ["--to", handle] }
    }

    private func preview(action: String, params: [String: Any]) -> [String: Any] {
        [
            "action": action,
            "target": params["target"] ?? [:],
            "hasContent": params["content"] != nil,
            "approvalRequired": true,
        ]
    }
}
