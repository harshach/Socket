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
        /// True when `op account list` returns at least one configured account,
        /// even if the active session is locked / unavailable. Distinguishes
        /// "never configured" from "configured but locked right now" in the UI.
        let hasAccountsConfigured: Bool
        /// Last diagnostic from a failed CLI invocation (trimmed stderr).
        /// Shown in Settings when detection doesn't pan out so users can
        /// self-serve (e.g. see "Enable biometric unlock" when relevant).
        let lastError: String?
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

    /// How we invoke `op`. GUI apps get a stripped environment — no
    /// `OP_SESSION_*`, no `OP_ACCOUNT`, no custom PATH. Running the command
    /// through the user's login shell picks up anything they've exported in
    /// `.zshenv` / `.zprofile` / `.bash_profile`, which is typically where
    /// `eval $(op signin)` and friends end up.
    private enum InvocationMode { case direct, loginShell }
    private var invocationMode: InvocationMode = .direct

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
            return Status(binaryURL: nil,
                          signedIn: false,
                          account: nil,
                          email: nil,
                          hasAccountsConfigured: false,
                          lastError: nil)
        }
        // Try direct invocation first (fast). If that fails, retry through the
        // user's login shell so we inherit `.zshenv` / `.zprofile` exports.
        // Record both outcomes so the diagnostic panel can show the actual
        // failure reason from each mode.
        invocationMode = .direct
        let directResult = await run(binary: binary, args: ["whoami", "--format=json"])
        var whoamiResult = directResult
        var shellDetail: String? = nil

        if case .failure = whoamiResult {
            invocationMode = .loginShell
            let shellResult = await run(binary: binary, args: ["whoami", "--format=json"])
            whoamiResult = shellResult
            if case .failure(let err) = shellResult {
                shellDetail = Self.describe(err)
            }
        }

        // Secondary: `op account list` reveals whether the user has ever run
        // `op account add` (or the desktop app auto-configured them). We do
        // this via the shell mode when available so we see the SAME account
        // set the user's terminal sees.
        var hasAccountsConfigured = false
        var fallbackAccount: String? = nil
        var accountListSummary: String? = nil
        var accounts: [OnePasswordAccount] = []
        if case .success(let listStdout) = await run(binary: binary,
                                                     args: ["account", "list", "--format=json"]) {
            accounts = Self.parseAccountList(listStdout)
            hasAccountsConfigured = !accounts.isEmpty
            fallbackAccount = accounts.first?.url
            if !accounts.isEmpty {
                let lines = accounts.map { acct -> String in
                    let url = acct.url ?? "(no url)"
                    let email = acct.email ?? "(no email)"
                    return "• \(email) — \(url)"
                }
                accountListSummary = "Accounts known to `op`:\n" + lines.joined(separator: "\n")
            }
        }

        // Tertiary: default whoami often fails on multi-account setups where
        // the default is locked but another account has an active session.
        // Probe each known account by URL so we surface any reachable one.
        if case .failure = whoamiResult {
            for account in accounts {
                guard let url = account.url, !url.isEmpty else { continue }
                let perAccount = await run(binary: binary,
                                           args: ["whoami", "--account=\(url)", "--format=json"])
                if case .success(let perAccountStdout) = perAccount {
                    let parsed = Self.parseWhoami(perAccountStdout)
                    if parsed.signedIn {
                        return Status(
                            binaryURL: binary,
                            signedIn: true,
                            account: parsed.account ?? url,
                            email: parsed.email ?? account.email,
                            hasAccountsConfigured: true,
                            lastError: nil
                        )
                    }
                }
            }
        }

        switch whoamiResult {
        case .success(let stdout):
            let parsed = Self.parseWhoami(stdout)
            if parsed.signedIn {
                return Status(binaryURL: binary,
                              signedIn: true,
                              account: parsed.account,
                              email: parsed.email,
                              hasAccountsConfigured: hasAccountsConfigured,
                              lastError: nil)
            }
            // Whoami succeeded (exit 0) but output didn't parse — treat as
            // unknown state. Surface the raw output so users can see what op
            // actually said.
            let rawHint = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.notice("op whoami returned unparseable output: \(rawHint, privacy: .public)")
            return Status(binaryURL: binary,
                          signedIn: false,
                          account: fallbackAccount,
                          email: nil,
                          hasAccountsConfigured: hasAccountsConfigured,
                          lastError: rawHint.isEmpty ? nil : rawHint)

        case .failure(let err):
            let primary = Self.describe(err)
            logger.notice("op whoami failed: \(primary, privacy: .public)")
            var parts: [String] = []
            parts.append("Direct invocation: \(Self.describe(Self.resultAsError(directResult)))")
            if let shellDetail { parts.append("Login-shell invocation: \(shellDetail)") }
            if let accountListSummary { parts.append(accountListSummary) }
            parts.append("SHELL=\(ProcessInfo.processInfo.environment["SHELL"] ?? "(unset)")")
            parts.append("Tip: if Desktop App Integration is on, ensure Socket is Developer-ID signed (ad-hoc/unsigned callers can be refused by the 1Password helper).")
            parts.append("Tip: `OP_SESSION_*` vars set in `.zshrc` are NOT inherited — move them to `.zshenv` or `.zprofile`.")
            let combined = parts.joined(separator: "\n\n")
            return Status(binaryURL: binary,
                          signedIn: false,
                          account: fallbackAccount,
                          email: nil,
                          hasAccountsConfigured: hasAccountsConfigured,
                          lastError: combined)
        }
    }

    /// Collapses a RunResult to its stderr/description. nil when it succeeded.
    private static func resultAsError(_ r: RunResult) -> CLIError {
        if case .failure(let err) = r { return err }
        return .invocationFailed(exitCode: 0, stderr: "(succeeded)")
    }

    /// Human-readable one-line summary of a `CLIError`.
    private static func describe(_ err: CLIError) -> String {
        switch err {
        case .invocationFailed(let code, let stderr):
            let s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? "exit \(code)" : "exit \(code): \(s)"
        case .notSignedIn:
            return "not signed in"
        case .binaryNotFound:
            return "op binary not found"
        case .decodingFailed:
            return "op output didn't parse"
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

    struct OnePasswordAccount: Equatable {
        let id: String
        let email: String?
        let url: String?
    }

    /// Pure parser for `op account list --format=json`. Returns one entry per
    /// configured account regardless of current unlock state.
    static func parseAccountList(_ stdout: String) -> [OnePasswordAccount] {
        guard let data = stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { raw in
            // op's schema has `account_uuid`, `user_uuid`, `email`, `url`, `shorthand`.
            let id = (raw["account_uuid"] as? String)
                ?? (raw["user_uuid"] as? String)
                ?? (raw["shorthand"] as? String)
            guard let uuid = id else { return nil }
            return OnePasswordAccount(
                id: uuid,
                email: raw["email"] as? String,
                url: raw["url"] as? String
            )
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
        let mode = invocationMode
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                switch mode {
                case .direct:
                    process.executableURL = binary
                    process.arguments = args
                case .loginShell:
                    // Run via `zsh -l -c "<escaped op + args>"` (or the user's
                    // $SHELL). `-l` sources login init files, which is where
                    // `OP_SESSION_*` / `OP_ACCOUNT` / PATH additions live in
                    // a typical setup.
                    let shell = ProcessInfo.processInfo.environment["SHELL"]
                        ?? "/bin/zsh"
                    let command = ([binary.path] + args)
                        .map(Self.shellEscape)
                        .joined(separator: " ")
                    process.executableURL = URL(fileURLWithPath: shell)
                    process.arguments = ["-l", "-c", command]
                }

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

    /// POSIX single-quote escape: wrap in `'...'`, escape embedded `'` as
    /// `'\''`. Bare alphanumerics pass through unquoted. `nonisolated` so it
    /// can be called from the background queue where we build the command.
    private nonisolated static func shellEscape(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.range(of: "[^A-Za-z0-9_./:-]", options: .regularExpression) == nil {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
