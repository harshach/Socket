//
//  SocketShimRouter.swift
//  Socket
//
//  Central dispatcher for the chrome.* shim layer. Each shim registers as
//  `Shim` and advertises the namespace strings it owns. The router dispatches
//  incoming `ShimRequest`s to the right shim; shims return any JSON-encodable
//  `Any?` (or throw).
//

import Foundation
import os

/// Protocol implemented by every shim (ManagementShim, SidePanelShim, ...).
/// Keep methods narrow — the router owns envelope parsing and error formatting.
@MainActor
protocol Shim: AnyObject {
    /// Namespace strings this shim owns (e.g. `"management"`). Router uses
    /// these to route requests.
    var namespaces: Set<String> { get }

    /// Handle one request. Throw `ShimError` for expected failures; any other
    /// error is wrapped as `.internalError`.
    func handle(_ request: ShimRequest) async throws -> Any?
}

/// Routes shim envelopes from `SocketShimBridge` to individual `Shim`
/// implementations. Lives as a singleton so the bridge (per-webview) can reach
/// it without plumbing references through every `WKWebViewConfiguration.copy()`.
@MainActor
final class SocketShimRouter {
    static let shared = SocketShimRouter()

    private static let logger = Logger(subsystem: "com.socket.browser", category: "SocketShim")

    private var shims: [Shim] = []
    private var namespaceIndex: [String: Shim] = [:]

    private init() {}

    /// Install a shim. Registers each namespace it owns. Later registrations
    /// for the same namespace win (used only in tests).
    func register(_ shim: Shim) {
        shims.append(shim)
        for namespace in shim.namespaces {
            namespaceIndex[namespace] = shim
        }
        Self.logger.info("Registered shim for namespaces: \(shim.namespaces.sorted().joined(separator: ", "), privacy: .public)")
    }

    /// Dispatch a request. Always returns a response (success or failure) —
    /// the bridge always replies to JS.
    func dispatch(_ request: ShimRequest) async -> ShimResponse {
        guard let shim = namespaceIndex[request.namespace] else {
            ExtensionTelemetry.shared.record(
                .shimCallFailed,
                severity: .warning,
                extensionId: request.extensionId,
                message: "unknown namespace",
                context: ["namespace": request.namespace, "method": request.method])
            return .failure(requestId: request.requestId,
                            error: ShimError.unknownNamespace(request.namespace).description)
        }

        do {
            let result = try await shim.handle(request)
            return .success(requestId: request.requestId, result: result)
        } catch let error as ShimError {
            ExtensionTelemetry.shared.record(
                .shimCallFailed,
                severity: .warning,
                extensionId: request.extensionId,
                message: error.description,
                context: ["namespace": request.namespace, "method": request.method])
            return .failure(requestId: request.requestId, error: error.description)
        } catch {
            ExtensionTelemetry.shared.record(
                .shimCallFailed,
                severity: .error,
                extensionId: request.extensionId,
                message: error.localizedDescription,
                context: ["namespace": request.namespace, "method": request.method])
            return .failure(requestId: request.requestId,
                            error: ShimError.internalError(error.localizedDescription).description)
        }
    }

    /// The set of namespaces the router currently knows about. Used by the
    /// JS installer to decide whether to skip shim installation on a page.
    var registeredNamespaces: [String] {
        Array(namespaceIndex.keys).sorted()
    }
}
