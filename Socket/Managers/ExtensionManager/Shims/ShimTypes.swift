//
//  ShimTypes.swift
//  Socket
//
//  Shared envelope + error types for the chrome.* shim layer. Shims speak
//  JSON over a WKScriptMessageHandlerWithReply channel; envelopes are decoded
//  into `ShimRequest` and responses go out as `ShimResponse`.
//

import Foundation

/// Inbound request from the JS shim installer. Must match the envelope
/// emitted by `SocketShimBridge.installerJS`.
struct ShimRequest {
    let namespace: String   // "management", "sidePanel", "tabGroups", ...
    let method: String      // "getAll", "setOptions", ...
    let args: [Any]         // positional arguments, JSON-decodable
    let extensionId: String?   // best-effort: taken from `chrome.runtime.id` in JS
    let requestId: String      // opaque correlation id, echoed back in response

    /// Parse a raw `postMessage` body into a `ShimRequest`. Returns nil when
    /// the body is not a shim envelope (not our message) so the caller can
    /// cleanly ignore.
    static func decode(_ body: Any) -> ShimRequest? {
        guard let dict = body as? [String: Any] else { return nil }
        guard let namespace = dict["namespace"] as? String, !namespace.isEmpty else { return nil }
        guard let method = dict["method"] as? String, !method.isEmpty else { return nil }
        guard let requestId = dict["requestId"] as? String else { return nil }

        let args = (dict["args"] as? [Any]) ?? []
        let extensionId = dict["extensionId"] as? String
        return ShimRequest(
            namespace: namespace,
            method: method,
            args: args,
            extensionId: extensionId,
            requestId: requestId
        )
    }
}

/// Error types produced by the shim layer. The raw message flows back to JS
/// so keep these user-readable but non-revealing.
enum ShimError: Error, CustomStringConvertible {
    case unknownNamespace(String)
    case unknownMethod(namespace: String, method: String)
    case invalidArgument(String)
    case notSupported(String)
    case notFound(String)
    case permissionDenied(String)
    case internalError(String)

    var description: String {
        switch self {
        case .unknownNamespace(let ns):
            return "chrome.\(ns) is not supported in Socket"
        case .unknownMethod(let ns, let m):
            return "chrome.\(ns).\(m) is not supported in Socket"
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .notSupported(let msg):
            return "Not supported: \(msg)"
        case .notFound(let msg):
            return "Not found: \(msg)"
        case .permissionDenied(let msg):
            return "Permission denied: \(msg)"
        case .internalError(let msg):
            return "Internal error: \(msg)"
        }
    }
}

/// A single outbound response envelope. JS side resolves its pending promise
/// from this. On error, `error` is set and `result` is nil.
struct ShimResponse {
    let requestId: String
    let result: Any?
    let error: String?

    static func success(requestId: String, result: Any?) -> ShimResponse {
        ShimResponse(requestId: requestId, result: result, error: nil)
    }

    static func failure(requestId: String, error: String) -> ShimResponse {
        ShimResponse(requestId: requestId, result: nil, error: error)
    }

    var jsonObject: [String: Any] {
        var out: [String: Any] = ["requestId": requestId]
        if let result { out["result"] = result }
        if let error { out["error"] = error }
        return out
    }
}
