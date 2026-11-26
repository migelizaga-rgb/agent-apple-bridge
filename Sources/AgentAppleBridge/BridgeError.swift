import Foundation

struct BridgeError: LocalizedError {
    var errorDescription: String? { "\(code): \(message)" }
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

func bridgeResponse(success: Bool, result: Any? = nil, error: BridgeError? = nil) -> [String: Any] {
    var response: [String: Any] = [
        "success": success,
        "version": 1,
    ]
    if let result {
        response["result"] = result
    }
    if let error {
        response["code"] = error.code
        response["error"] = error.message
    }
    return response
}
