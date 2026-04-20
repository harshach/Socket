//
//  OnePasswordCLI.swift
//  Socket
//
//  Thin wrapper around the `op` CLI. All calls are async and non-interactive.
//  Requires the user to have set up 1Password desktop-app integration or
//  Touch-ID CLI unlock; Socket does not drive `op signin`.
//
//  Save uses a temp-file template so the password does NOT appear in the
//  process's argv (visible via `ps`). Read calls use argv (item id only).
//

import Foundation
import OSLog

@MainActor
final class OnePasswordCLI {

    struct OnePasswordItem: Hashable {
        let id: String             // 1Password item UUID
        let title: String          // usually the host
        let username: String?
        let urls: [String]
    }

    struct Status: Equatable {
        let binaryURL: URL?
        let signedIn: Bool
        let account: String?
        let email: String?
    }

    enum CLIError: Error {
        case binaryNotFound
        case notSignedIn
        case invocationFailed(exitCode: Int32, stderr: String)
        case decodingFailed
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Socket",
                                category: "OnePasswordCLI")

    /// Cached `op` binary URL (derived from `detectBinary()`).
    private(set) var binaryURL: URL?

    /// Cached login list from last refresh + timestamp for TTL.
    private var cachedLogins: [OnePasswordItem] = []
    private var cachedLoginsAt: Date = .distantPast
    private let loginCacheTTL: TimeInterval = 60

    init() {
        self.binaryURL = Self.detectBinary()
    }

    static func detectBinary() -> URL? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/op",
            "/usr/local/bin/op",
            "/usr/bin/op"
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        // Fall back to PATH search.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir))
                    .appendingPathComponent("op")
                if fm.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Re-probe the filesystem in case the user just installed the CLI.
    func refreshBinary() {
        binaryURL = Self.detectBinary()
    }

    var isInstalled: Bool { binaryURL != nil }

    // MARK: - Status

    func status() async -> Status {
        guard let binary = binaryURL else {
            return Status(binaryURL: nil, signedIn: false, account: nil, email: nil)
        }
        switch await run(binary: binary, args: ["whoami", "--format=json"]) {
        case .success(let stdout):
            let parsed = Self.parseWhoami(stdout)
            return Status(binaryURL: binary,
                          signedIn: parsed.signedIn,
                          account: parsed.account,
                          email: parsed.email)
        case .failure:
            return Status(binaryURL: binary, signedIn: false, account: nil, email: nil)
        }
    }

    /// Pure parser for `op whoami --format=json` output. Testable without
    /// shelling out. Returns signedIn=false on unparseable or empty input.
    static func parseWhoami(_ stdout: String) -> (signedIn: Bool, account: String?, email: String?) {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, nil, nil)
        }
        let account = json["url"] as? String ?? json["account_uuid"] as? String
        let email = json["email"] as? String
        return (true, account, email)
    }

    // MARK: - List logins (cached)

    func logins(for host: String) async -> [OnePasswordItem] {
        let now = Date()
        if now.timeIntervalSince(cachedLoginsAt) > loginCacheTTL {
            cachedLogins = await refreshLogins()
            cachedLoginsAt = now
        }
        let needle = host.lowercased()
        return cachedLogins.filter { item in
            item.urls.contains(where: { Self.matchesHost($0, host: needle) })
        }
    }

    /// Exposed for unit tests. `needle` must already be lowercased.
    static func matchesHost(_ urlString: String, host needle: String) -> Bool {
        guard let url = URL(string: urlString), let itemHost = url.host?.lowercased() else {
            return urlString.lowercased().contains(needle)
        }
        // Loose match: exact host OR itemHost is a parent domain (e.g. 1P has
        // `example.com` and the page is `login.example.com`).
        if itemHost == needle { return true }
        if needle.hasSuffix("." + itemHost) { return true }
        if itemHost.hasSuffix("." + needle) { return true }
        return false
    }

    func invalidateCache() {
        cachedLoginsAt = .distantPast
        cachedLogins = []
    }

    private func refreshLogins() async -> [OnePasswordItem] {
        guard let binary = binaryURL else { return [] }
        switch await run(binary: binary, args: ["item", "list",
                                                 "--categories=Login",
                                                 "--format=json"]) {
        case .success(let stdout):
            return Self.parseLoginList(stdout)
        case .failure(let err):
            logger.error("op item list failed: \(String(describing: err), privacy: .public)")
            return []
        }
    }

    /// Pure parser for `op item list --categories=Login --format=json` output.
    /// Testable without shelling out. Silently drops items missing required
    /// fields (`id`, `title`).
    static func parseLoginList(_ stdout: String) -> [OnePasswordItem] {
        guard let data = stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { raw in
            guard let id = raw["id"] as? String,
                  let title = raw["title"] as? String else { return nil }
            let username = raw["additional_information"] as? String
            var urls: [String] = []
            if let urlsArray = raw["urls"] as? [[String: Any]] {
                urls = urlsArray.compactMap { $0["href"] as? String }
            }
            return OnePasswordItem(id: id,
                                   title: title,
                                   username: username,
                                   urls: urls)
        }
    }

    // MARK: - Read password

    func fetchPassword(itemId: String) async throws -> String {
        guard let binary = binaryURL else { throw CLIError.binaryNotFound }
        // `--reveal` returns the concealed value in plaintext; `--fields=password`
        // scopes output to just the password field.
        switch await run(binary: binary, args: [
            "item", "get", itemId,
            "--fields", "password",
            "--reveal",
            "--format=json"
        ]) {
        case .success(let stdout):
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // `--format=json` returns an object: {"id":"password","value":"..."}
            // `--fields=X` without --format returns the raw value.
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = obj["value"] as? String {
                return value
            }
            if !trimmed.isEmpty {
                return trimmed
            }
            throw CLIError.decodingFailed
        case .failure(let err):
            throw err
        }
    }

    // MARK: - Save

    func saveLogin(host: String,
                   url: String,
                   username: String,
                   password: String,
                   vault: String? = nil) async throws {
        guard let binary = binaryURL else { throw CLIError.binaryNotFound }

        // Build the item template. Writing the password through stdin (via a
        // temp file with 0600 perms) keeps it out of `ps -eo args`.
        let template: [String: Any] = [
            "title": host,
            "category": "LOGIN",
            "fields": [
                ["id": "username", "type": "STRING", "value": username, "label": "username"],
                ["id": "password", "type": "CONCEALED", "value": password, "label": "password"]
            ],
            "urls": [["label": "website", "href": url]]
        ]

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("socket-op-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let data = try JSONSerialization.data(withJSONObject: template, options: [])
        FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )

        var args = ["item", "create", "--template=\(tempURL.path)", "--format=json"]
        if let vault = vault, !vault.isEmpty {
            args.append("--vault=\(vault)")
        }

        switch await run(binary: binary, args: args) {
        case .success:
            invalidateCache()
        case .failure(let err):
            throw err
        }
    }

    // MARK: - Process invocation

    private enum RunResult {
        case success(String)
        case failure(CLIError)
    }

    private func run(binary: URL, args: [String]) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = args

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(
                        .invocationFailed(exitCode: -1, stderr: "\(error)")
                    ))
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(out))
                } else {
                    let lowered = err.lowercased()
                    if lowered.contains("not signed in") || lowered.contains("session expired") {
                        continuation.resume(returning: .failure(.notSignedIn))
                    } else {
                        continuation.resume(returning: .failure(
                            .invocationFailed(exitCode: process.terminationStatus, stderr: err)
                        ))
                    }
                }
            }
        }
    }
}
