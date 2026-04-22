//
//  PasswordManager.swift
//  Socket
//
//  Native password manager: form-aware, multi-window safe. Routes saves +
//  autofill across multiple providers (Keychain, 1Password CLI). The Keychain
//  provider is always available; 1Password shows up only when the `op` CLI is
//  installed and signed in.
//

import AppKit
import Foundation
import OSLog
import WebKit

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

@MainActor
final class PasswordManager: ObservableObject {

    // MARK: - Message payloads (JS ↔ Swift)

    struct FormSubmittedPayload {
        let host: String
        let username: String
        let password: String

        init?(_ body: Any?) {
            guard let dict = body as? [String: Any] else { return nil }
            let host = (dict["host"] as? String) ?? ""
            let password = (dict["password"] as? String) ?? ""
            guard !host.isEmpty, !password.isEmpty else { return nil }
            self.host = host
            self.username = (dict["username"] as? String) ?? ""
            self.password = password
        }
    }

    struct FormDetectedPayload {
        let host: String
        let frameURL: String
        let fields: [DetectedField]

        init?(_ body: Any?) {
            guard let dict = body as? [String: Any] else { return nil }
            let host = (dict["host"] as? String) ?? ""
            guard !host.isEmpty else { return nil }
            self.host = host
            self.frameURL = (dict["frameURL"] as? String) ?? ""
            let rawFields = (dict["fields"] as? [[String: Any]]) ?? []
            self.fields = rawFields.compactMap(DetectedField.init)
        }
    }

    struct DetectedField {
        let usernameFid: String?
        let passwordFid: String
        let rect: CGRect

        init?(_ raw: [String: Any]) {
            guard let pwFid = raw["passwordFid"] as? String, !pwFid.isEmpty else { return nil }
            self.passwordFid = pwFid
            self.usernameFid = raw["usernameFid"] as? String
            let r = (raw["rect"] as? [String: Any]) ?? [:]
            let x = (r["x"] as? Double) ?? 0
            let y = (r["y"] as? Double) ?? 0
            let w = (r["width"] as? Double) ?? 0
            let h = (r["height"] as? Double) ?? 0
            self.rect = CGRect(x: x, y: y, width: w, height: h)
        }
    }

    struct AutofillRequestPayload {
        /// Where the autofill request came from. `focus` is the implicit path
        /// (password field got focus and Swift had hints); `icon` is the
        /// user explicitly clicking the inline key icon. Icon-triggered
        /// requests always open the popover, even with zero suggestions,
        /// so the click isn't silent.
        enum Trigger: String {
            case focus
            case icon
        }

        let host: String
        let frameURL: String
        let usernameFid: String?
        let passwordFid: String
        let rect: CGRect
        let trigger: Trigger

        init?(_ body: Any?) {
            guard let dict = body as? [String: Any] else { return nil }
            let host = (dict["host"] as? String) ?? ""
            let pwFid = (dict["passwordFid"] as? String) ?? ""
            guard !host.isEmpty, !pwFid.isEmpty else { return nil }
            self.host = host
            self.frameURL = (dict["frameURL"] as? String) ?? ""
            self.usernameFid = dict["usernameFid"] as? String
            self.passwordFid = pwFid
            let r = (dict["rect"] as? [String: Any]) ?? [:]
            let x = (r["x"] as? Double) ?? 0
            let y = (r["y"] as? Double) ?? 0
            let w = (r["width"] as? Double) ?? 0
            let h = (r["height"] as? Double) ?? 0
            self.rect = CGRect(x: x, y: y, width: w, height: h)
            self.trigger = Trigger(rawValue: (dict["trigger"] as? String) ?? "focus") ?? .focus
        }
    }

    // MARK: - State

    private weak var browserManager: BrowserManager?
    private let store: PasswordCredentialStore
    let onePassword: OnePasswordCLI
    @Published private(set) var onePasswordStatus: OnePasswordCLI.Status = .init(
        binaryURL: nil, signedIn: false, account: nil, email: nil,
        hasAccountsConfigured: false, lastError: nil
    )
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Socket",
                                category: "Passwords")

    init(store: PasswordCredentialStore? = nil,
         onePassword: OnePasswordCLI? = nil) {
        self.store = store ?? PasswordCredentialStore()
        self.onePassword = onePassword ?? OnePasswordCLI()
    }

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
        Task { await self.refreshOnePasswordStatus() }
    }

    /// Probe the `op` CLI for state. Called at attach + before each save dialog.
    func refreshOnePasswordStatus() async {
        onePassword.refreshBinary()
        onePasswordStatus = await onePassword.status()
    }

    // MARK: - Exclusion list

    func isHostExcluded(_ host: String, profile: UUID) -> Bool {
        guard let settings = browserManager?.socketSettings else { return false }
        let list = settings.passwordSaveDisabledHosts[profile.uuidString] ?? []
        return list.contains(host.lowercased())
    }

    func addHostToExclusionList(_ host: String, profile: UUID) {
        guard let settings = browserManager?.socketSettings else { return }
        let key = profile.uuidString
        var list = settings.passwordSaveDisabledHosts[key] ?? []
        let normalized = host.lowercased()
        guard !list.contains(normalized) else { return }
        list.append(normalized)
        settings.passwordSaveDisabledHosts[key] = list
    }

    // MARK: - Script-message entry points

    func handleFormDetected(_ body: Any?, tab: Tab) {
        guard let payload = FormDetectedPayload(body) else { return }
        guard let profile = currentProfile(), !profile.isEphemeral else { return }

        // Gather keychain-local usernames synchronously; 1Password is async so
        // we kick off a task and extend the hint list in place.
        let socketHits = store.fetchAll(for: payload.host,
                                        profile: profile.id,
                                        includePassword: false)
        let systemHits = store.fetchSystemKeychain(for: payload.host)
        let keychainUsernames = mergeUnique(primary: socketHits, system: systemHits)
            .map { $0.username }
        pushHints(tab: tab, usernames: keychainUsernames)

        if onePasswordStatus.signedIn {
            Task { [weak self] in
                guard let self else { return }
                let items = await self.onePassword.logins(for: payload.host)
                let combined = keychainUsernames + items.compactMap { $0.username }
                self.pushHints(tab: tab, usernames: combined)
            }
        }
    }

    /// Socket-owned records first, then system-Keychain records that don't
    /// duplicate a Socket entry (same host + username + persistentRef).
    private func mergeUnique(primary: [PasswordCredentialStore.Record],
                             system: [PasswordCredentialStore.Record]) -> [PasswordCredentialStore.Record] {
        var seenRefs = Set<Data>(primary.map { $0.persistentRef })
        var seenKeys = Set<String>(primary.map { "\($0.host)\u{1F}\($0.username)" })
        var out = primary
        for rec in system {
            if seenRefs.contains(rec.persistentRef) { continue }
            let key = "\(rec.host)\u{1F}\(rec.username)"
            if seenKeys.contains(key) { continue }
            seenRefs.insert(rec.persistentRef)
            seenKeys.insert(key)
            out.append(rec)
        }
        return out
    }

    private func pushHints(tab: Tab, usernames: [String]) {
        let hints = usernames.map { ["username": $0] }
        guard let webView = tab.activeWebView as WKWebView?,
              let data = try? JSONSerialization.data(withJSONObject: hints),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__socketPasswordHints = \(json);",
                                   completionHandler: nil)
    }

    func handleAutofillRequest(_ body: Any?,
                               tab: Tab,
                               reply: @escaping ([[String: Any]]?, String?) -> Void) {
        guard let payload = AutofillRequestPayload(body) else {
            reply([], nil)
            return
        }
        guard let profile = currentProfile(), !profile.isEphemeral else {
            reply([], nil)
            return
        }

        // Keychain source — Socket's own records PLUS anything Safari /
        // iCloud Keychain / System Settings have stored for this host.
        // System entries may trigger a one-time macOS "allow access"
        // prompt; Always Allow makes it silent after that.
        let socketRecords = store.fetchAll(for: payload.host,
                                           profile: profile.id,
                                           includePassword: false)
        let systemRecords = store.fetchSystemKeychain(for: payload.host)
        let keychainRecords = mergeUnique(primary: socketRecords, system: systemRecords)
        let keychainSuggestions: [CredentialSuggestion] = keychainRecords.map { record in
            CredentialSuggestion(provider: .keychain,
                                 ref: record.persistentRef.base64EncodedString(),
                                 host: record.host,
                                 username: record.username)
        }

        // 1Password source (async). We reply with Keychain results immediately
        // and then present the popover once 1Password responds (or with only
        // Keychain if 1Password is unavailable).
        let keychainReply = keychainSuggestions.map { $0.asScriptReply }
        reply(keychainReply, nil)

        if onePasswordStatus.signedIn {
            Task { [weak self] in
                guard let self else { return }
                let items = await self.onePassword.logins(for: payload.host)
                let onePasswordSuggestions: [CredentialSuggestion] = items.map { item in
                    CredentialSuggestion(provider: .onePassword,
                                         ref: item.id,
                                         host: payload.host,
                                         username: item.username ?? "")
                }
                let merged = keychainSuggestions + onePasswordSuggestions
                // Icon clicks always surface the popover (even when empty) so
                // the user sees something in response. Focus-triggered
                // requests stay silent when nothing matches.
                if !merged.isEmpty || payload.trigger == .icon {
                    self.presentAutofillPopover(tab: tab,
                                                payload: payload,
                                                suggestions: merged)
                }
            }
        } else if !keychainSuggestions.isEmpty || payload.trigger == .icon {
            presentAutofillPopover(tab: tab,
                                   payload: payload,
                                   suggestions: keychainSuggestions)
        }
    }

    // MARK: - Autofill UI presentation

    private var autofillPopover: PasswordAutofillPopover?

    private func presentAutofillPopover(tab: Tab,
                                        payload: AutofillRequestPayload,
                                        suggestions: [CredentialSuggestion]) {
        guard let webView = tab.activeWebView as WKWebView? else { return }
        let popover = autofillPopover ?? PasswordAutofillPopover()
        autofillPopover = popover
        popover.show(
            for: webView,
            anchorRect: payload.rect,
            suggestions: suggestions,
            onSelect: { [weak self] chosen in
                guard let self else { return }
                self.injectAutofill(tab: tab,
                                    usernameFid: payload.usernameFid,
                                    passwordFid: payload.passwordFid,
                                    suggestion: chosen)
            },
            onManage: { [weak self] in
                self?.browserManager?.showPasswordsSettings()
            }
        )
    }

    // MARK: - Credential injection

    func injectAutofill(tab: Tab,
                        usernameFid: String?,
                        passwordFid: String,
                        suggestion: CredentialSuggestion) {
        Task { [weak self] in
            guard let self else { return }
            let password: String?
            switch suggestion.provider {
            case .keychain:
                password = self.fetchKeychainPassword(base64Ref: suggestion.ref)
            case .onePassword:
                password = await self.fetchOnePasswordPassword(itemId: suggestion.ref)
            }
            guard let password, !password.isEmpty else {
                self.logger.error("Autofill fetch returned empty for provider=\(suggestion.provider.rawValue, privacy: .public)")
                return
            }
            self.performInjection(tab: tab,
                                  usernameFid: usernameFid,
                                  passwordFid: passwordFid,
                                  username: suggestion.username,
                                  password: password)
        }
    }

    private func fetchKeychainPassword(base64Ref: String) -> String? {
        guard let data = Data(base64Encoded: base64Ref) else { return nil }
        switch store.fetchPassword(ref: data) {
        case .success(let pw): return pw
        case .failure: return nil
        }
    }

    private func fetchOnePasswordPassword(itemId: String) async -> String? {
        do {
            return try await onePassword.fetchPassword(itemId: itemId)
        } catch {
            logger.error("1Password fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func performInjection(tab: Tab,
                                  usernameFid: String?,
                                  passwordFid: String,
                                  username: String,
                                  password: String) {
        guard let webView = tab.activeWebView as WKWebView? else { return }
        // React's controlled inputs ignore raw `.value =` writes — use the
        // native property setter from HTMLInputElement.prototype and dispatch
        // input+change events so virtual-DOM state stays consistent.
        let jsUser = jsonEscape(username)
        let jsPass = jsonEscape(password)
        let jsUserFid = jsonEscape(usernameFid ?? "")
        let jsPassFid = jsonEscape(passwordFid)
        let script = """
        (function() {
          var u = \(jsUserFid).length
            ? document.querySelector('[data-socket-fid-user="' + \(jsUserFid) + '"]')
            : null;
          var p = document.querySelector('[data-socket-fid="' + \(jsPassFid) + '"]');
          if (!p) { return false; }
          var nativeSet = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          if (u) { nativeSet.call(u, \(jsUser)); }
          nativeSet.call(p, \(jsPass));
          ['input','change'].forEach(function(e) {
            if (u) { u.dispatchEvent(new Event(e, {bubbles:true})); }
            p.dispatchEvent(new Event(e, {bubbles:true}));
          });
          return true;
        })()
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
        autofillPopover?.dismiss()
    }

    private func jsonEscape(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: []))
            ?? Data("[\"\"]".utf8)
        guard let outer = String(data: data, encoding: .utf8),
              outer.count >= 4 else { return "\"\"" }
        // outer is `["..."]` — drop the brackets.
        let start = outer.index(after: outer.startIndex)
        let end = outer.index(before: outer.endIndex)
        return String(outer[start..<end])
    }

    func handleFormSubmitted(_ body: Any?, tab: Tab) {
        guard let payload = FormSubmittedPayload(body) else { return }
        guard let profile = currentProfile() else { return }

        // Never prompt in incognito.
        if profile.isEphemeral {
            logger.debug("Skip save in ephemeral profile")
            return
        }

        // Respect exclusion list.
        if isHostExcluded(payload.host, profile: profile.id) {
            logger.debug("Host in exclusion list; skip save")
            return
        }

        // Skip if we already have this exact (host, username, password) in Keychain.
        // (For 1Password-saved creds we'd have to query the CLI; accept the dupe.)
        let existing = store.fetchAll(for: payload.host,
                                      profile: profile.id,
                                      includePassword: true)
        if let match = existing.first(where: { $0.username == payload.username }),
           match.password == payload.password {
            return
        }

        promptSave(host: payload.host,
                   username: payload.username,
                   password: payload.password,
                   profile: profile,
                   existing: existing)
    }

    // MARK: - Save flow

    private func promptSave(host: String,
                            username: String,
                            password: String,
                            profile: Profile,
                            existing: [PasswordCredentialStore.Record]) {
        guard let manager = browserManager else { return }

        let prefilled = existing.first(where: { $0.username == username })
        let defaultSync = manager.socketSettings?.syncPasswordsToICloud ?? true
        let defaultDest = resolvedDefaultDestination()
        let model = PasswordSaveDialogModel(
            host: host,
            username: username,
            password: password,
            syncToICloud: defaultSync,
            isUpdate: prefilled != nil,
            destination: defaultDest,
            onePasswordAvailable: isOnePasswordAvailable
        )

        var closed = false
        let closeOnce: () -> Void = { [weak manager] in
            guard !closed else { return }
            closed = true
            manager?.dialogManager.closeDialog()
        }

        let dialog = PasswordSaveDialog(
            model: model,
            onSave: { [weak self] username, password, sync, destination in
                defer { closeOnce() }
                guard let self else { return }
                NSApp.mainWindow?.makeFirstResponder(nil)
                self.commitSave(host: host,
                                username: username,
                                password: password,
                                sync: sync,
                                destination: destination,
                                profile: profile.id)
            },
            onNever: { [weak self] in
                defer { closeOnce() }
                NSApp.mainWindow?.makeFirstResponder(nil)
                self?.addHostToExclusionList(host, profile: profile.id)
            },
            onCancel: {
                defer { closeOnce() }
                NSApp.mainWindow?.makeFirstResponder(nil)
            }
        )

        manager.dialogManager.showDialog(
            dialog,
            primaryAction: {
                let m = dialog.model
                NSApp.mainWindow?.makeFirstResponder(nil)
                dialog.onSave(m.username, m.password, m.syncToICloud, m.destination)
            },
            cancelAction: {
                NSApp.mainWindow?.makeFirstResponder(nil)
                dialog.onCancel()
            }
        )
    }

    /// Resolves the user's configured destination and falls back to Keychain
    /// when 1Password is unreachable.
    private func resolvedDefaultDestination() -> PasswordProviderID {
        let raw = browserManager?.socketSettings?.defaultPasswordDestination ?? PasswordProviderID.keychain.rawValue
        let preferred = PasswordProviderID(rawValue: raw) ?? .keychain
        if preferred == .onePassword, !isOnePasswordAvailable {
            return .keychain
        }
        return preferred
    }

    var isOnePasswordAvailable: Bool {
        onePasswordStatus.signedIn
    }

    private func commitSave(host: String,
                            username: String,
                            password: String,
                            sync: Bool,
                            destination: PasswordProviderID,
                            profile: UUID) {
        switch destination {
        case .keychain:
            let result = store.save(host: host,
                                    username: username,
                                    password: password,
                                    sync: sync,
                                    profile: profile)
            switch result {
            case .success:
                logger.notice("Saved to Keychain host=\(host, privacy: .private(mask: .hash))")
            case .failure(let err):
                logger.error("Keychain save failed: \(String(describing: err), privacy: .public)")
                showSaveError("Couldn't save to Keychain.", detail: String(describing: err))
            }
        case .onePassword:
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.onePassword.saveLogin(
                        host: host,
                        url: "https://\(host)",
                        username: username,
                        password: password
                    )
                    self.logger.notice("Saved to 1Password host=\(host, privacy: .private(mask: .hash))")
                } catch {
                    self.logger.error("1Password save failed: \(String(describing: error), privacy: .public)")
                    self.showSaveError("Couldn't save to 1Password.",
                                       detail: "\(error)")
                }
            }
        }
    }

    private func showSaveError(_ title: String, detail: String) {
        guard let manager = browserManager else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
        _ = manager
    }

    // MARK: - Settings surface

    func fetchAllForSettings() -> [PasswordCredentialStore.Record] {
        guard let profile = currentProfile() else { return [] }
        // Combine Socket-owned records (service-scoped to this profile)
        // with every other `kSecClassInternetPassword` entry in the user's
        // Keychain (Safari, iCloud, System Settings → Passwords, other
        // apps). Socket entries take precedence on dedup; same-host+user
        // system duplicates fall through.
        let socketRecords = store.fetchAllForProfile(profile.id)
        let systemRecords = store.fetchAllSystemKeychain()
        return mergeUnique(primary: socketRecords, system: systemRecords)
    }

    func delete(_ ref: Data) {
        _ = store.delete(ref: ref)
    }

    /// Touch-ID / biometric-gated password reveal.
    func reveal(_ ref: Data) async throws -> String {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var authError: NSError?
        let canBiometric = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                 error: &authError)
        let canOwner = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError)
        guard canBiometric || canOwner else {
            throw PasswordCredentialStore.StoreError.unhandled(-25291)
        }
        let ok = try await ctx.evaluatePolicy(
            canBiometric ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication,
            localizedReason: "Reveal your saved password")
        guard ok else { throw PasswordCredentialStore.StoreError.unhandled(-128) }
        switch store.fetchPassword(ref: ref, context: ctx) {
        case .success(let pw): return pw
        case .failure(let err): throw err
        }
        #else
        switch store.fetchPassword(ref: ref, context: nil) {
        case .success(let pw): return pw
        case .failure(let err): throw err
        }
        #endif
    }

    // MARK: - Helpers

    private func currentProfile() -> Profile? {
        browserManager?.currentProfile
    }
}
