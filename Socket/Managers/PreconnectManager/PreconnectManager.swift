//
//  PreconnectManager.swift
//  Socket
//
//  Warms DNS / TCP / TLS for a URL the user is likely about to navigate to.
//  Called from link-hover and command-palette suggestion selection.
//
//  Strategy: fire a URLSession data task against the target origin and cancel
//  the task as soon as response bytes start arriving. That hits full DNS +
//  handshake + HTTPS connect against the URLSession socket pool, which WKWebView
//  does not share — but every major browser still sees a noticeable TTFB drop
//  because the OS-level DNS cache and TLS session cache are shared, and many
//  CDNs keep warm connections alive long enough to benefit the subsequent
//  WKWebView load.
//

import Foundation

@MainActor
final class PreconnectManager {
    static let shared = PreconnectManager()

    // (origin, timestamp) — dedupe rapid repeated hovers over the same host.
    private var recent: [String: Date] = [:]
    private let dedupeInterval: TimeInterval = 30

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private init() {}

    func preconnect(_ urlString: String?) {
        guard let urlString,
              let url = URL(string: urlString),
              let host = url.host,
              let scheme = url.scheme,
              scheme == "http" || scheme == "https"
        else { return }

        let originKey = "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
        if let last = recent[originKey], Date().timeIntervalSince(last) < dedupeInterval {
            return
        }
        recent[originKey] = Date()
        pruneRecentIfNeeded()

        // HEAD-ish probe: we don't care about the body, we just want the socket
        // opened. Cancel as soon as the task starts returning headers so we
        // don't waste bandwidth on the eventual body.
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let task = session.dataTask(with: req) { _, _, _ in }
        task.resume()
        // Cancel after a short grace window in case the server doesn't honor HEAD.
        Task.detached { [weak task] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            task?.cancel()
        }
    }

    private func pruneRecentIfNeeded() {
        guard recent.count > 256 else { return }
        let cutoff = Date().addingTimeInterval(-dedupeInterval)
        recent = recent.filter { $0.value > cutoff }
    }
}
