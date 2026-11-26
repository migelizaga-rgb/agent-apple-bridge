import Foundation

struct BridgeRequest {
    let version: Int
    let domain: String
    let mode: String
    let params: [String: Any]

    static func decode(_ data: Data) throws -> BridgeRequest {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError("invalid_request", "request must be a JSON object")
        }
        guard let version = object["version"] as? Int, version == 1 else {
            throw BridgeError("unsupported_version", "request version must be 1")
        }
        guard let domain = object["domain"] as? String,
              ["reminders", "notes", "messages", "contacts"].contains(domain) else {
            throw BridgeError("invalid_domain", "domain must be reminders, notes, messages, or contacts")
        }
        guard let mode = object["mode"] as? String, ["read", "write"].contains(mode) else {
            throw BridgeError("invalid_mode", "mode must be read or write")
        }
        guard let params = object["params"] as? [String: Any] else {
            throw BridgeError("invalid_params", "params must be an object")
        }
        return BridgeRequest(version: version, domain: domain, mode: mode, params: params)
    }
}
