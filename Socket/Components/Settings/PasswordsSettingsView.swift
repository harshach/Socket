//
//  PasswordsSettingsView.swift
//  Socket
//
//  Saved-password management: default destination picker, 1Password CLI
//  status, Keychain list w/ Touch-ID reveal, iCloud sync, exclusion list.
//

import SwiftUI
import AppKit

struct PasswordsSettingsView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(\.socketSettings) var socketSettings

    @State private var search: String = ""
    @State private var records: [PasswordCredentialStore.Record] = []
    @State private var revealed: [Data: String] = [:]
    @State private var errorMessage: String?

    enum Section: String, CaseIterable, Identifiable {
        case keychain = "Keychain"
        case onePassword = "1Password"
        var id: String { rawValue }
    }

    @State private var section: Section = .keychain

    var body: some View {
        @Bindable var settings = socketSettings

        VStack(alignment: .leading, spacing: 16) {
            header
            defaultDestinationCard(settings: settings)
            sectionPicker
            switch section {
            case .keychain:
                keychainSection(settings: settings)
            case .onePassword:
                onePasswordSection
            }
        }
        .onAppear {
            reload()
            Task { await browserManager.passwordManager.refreshOnePasswordStatus() }
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private func keychainSection(settings: SocketSettingsService) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField
            credentialsList
            Divider()
            iCloudSyncCard(settings: settings)
            exclusionListCard(settings: settings)
        }
    }

    @ViewBuilder
    private var onePasswordSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            onePasswordStatusCard
            Text("1Password entries are managed in the 1Password app. Socket reads them via the `op` CLI when you sign in to a website, and routes saves via `op item create` when you choose 1Password as the destination.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saved Passwords")
                .font(.headline)
            Text("Socket can save passwords to the macOS Keychain or to 1Password. Keychain entries live in System Settings → Passwords; 1Password entries live in your 1Password vault.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Destination picker

    private func defaultDestinationCard(settings: SocketSettingsService) -> some View {
        let onePasswordAvailable = browserManager.passwordManager.isOnePasswordAvailable
        let binding = Binding<PasswordProviderID>(
            get: {
                PasswordProviderID(rawValue: settings.defaultPasswordDestination) ?? .keychain
            },
            set: { settings.defaultPasswordDestination = $0.rawValue }
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text("Default save destination")
                .font(.system(size: 13, weight: .semibold))
            Picker("", selection: binding) {
                Label("Keychain", systemImage: "key.horizontal")
                    .tag(PasswordProviderID.keychain)
                Label("1Password", systemImage: "lock.shield")
                    .tag(PasswordProviderID.onePassword)
                    .disabled(!onePasswordAvailable)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if !onePasswordAvailable {
                Text("Install and sign in to the 1Password CLI to enable the 1Password option.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("You can still change the destination per-save in the save dialog.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - 1Password status

    private var onePasswordStatusCard: some View {
        let status = browserManager.passwordManager.onePasswordStatus
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                Text("1Password integration")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    Task { await browserManager.passwordManager.refreshOnePasswordStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-detect 1Password CLI")
            }
            if status.binaryURL == nil {
                Text("The `op` CLI isn't installed. Run `brew install 1password-cli`, or see 1Password's installation guide.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !status.signedIn {
                VStack(alignment: .leading, spacing: 8) {
                    if status.hasAccountsConfigured {
                        // Accounts known to `op`, but no reachable session.
                        // Most likely cause on a GUI-spawned op: the user's
                        // OP_SESSION env var lives in an interactive shell
                        // Socket can't inherit, and Desktop App Integration
                        // isn't enabled.
                        Text("1Password accounts are configured but Socket can't see an active session. This usually means Desktop App Integration isn't enabled.")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Text("Fix in 1Password → Settings → Developer: enable **Integrate with 1Password CLI** and **Use biometric unlock for 1Password CLI**. Then click refresh here.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Open 1Password") {
                                NSWorkspace.shared.launchApplication("1Password")
                            }
                            .controlSize(.small)
                            Button("1Password Docs") {
                                if let url = URL(string: "https://developer.1password.com/docs/cli/app-integration/") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Text("CLI found. Enable biometric CLI unlock in 1Password → Settings → Developer, or run `op signin` in Terminal to connect an account.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let url = status.account {
                        Text(url)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.9))
                            .textSelection(.enabled)
                    }
                    if let err = status.lastError, !err.isEmpty {
                        DisclosureGroup("Diagnostic details") {
                            Text(err)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.primary.opacity(0.05))
                                )
                        }
                        .font(.system(size: 10))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let email = status.email {
                        Text("Signed in as \(email)")
                            .font(.system(size: 12))
                    }
                    if let account = status.account {
                        Text(account)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - Search + list

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Keychain entries by site or user name", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button(action: { search = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var filtered: [PasswordCredentialStore.Record] {
        guard !search.isEmpty else { return records }
        let needle = search.lowercased()
        return records.filter {
            $0.host.lowercased().contains(needle) ||
            $0.username.lowercased().contains(needle)
        }
    }

    @ViewBuilder
    private var credentialsList: some View {
        if records.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No Keychain-saved passwords yet")
                    .font(.system(size: 13, weight: .semibold))
                Text("Sign in to a website and Socket will offer to save the password. Entries you save to 1Password are managed in the 1Password app.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.03))
            )
        } else {
            VStack(spacing: 0) {
                ForEach(filtered) { record in
                    row(for: record)
                    if record.id != filtered.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.03))
            )
        }
    }

    private func row(for record: PasswordCredentialStore.Record) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.host)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(record.username)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let pw = revealed[record.persistentRef] {
                Text(pw)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
            Button {
                toggleReveal(record)
            } label: {
                Image(systemName: revealed[record.persistentRef] != nil ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed[record.persistentRef] != nil ? "Hide password" : "Reveal with Touch ID")

            Menu {
                Button("Copy Username") { copyToPasteboard(record.username) }
                Button("Copy Password") { copyPassword(record) }
                Divider()
                Button("Delete", role: .destructive) { delete(record) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - iCloud + exclusions

    private func iCloudSyncCard(settings: SocketSettingsService) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { settings.syncPasswordsToICloud },
                set: { settings.syncPasswordsToICloud = $0 }
            )) {
                Text("Sync new Keychain passwords to iCloud Keychain")
                    .font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)
            Text("Only affects passwords saved to Keychain. 1Password entries sync through 1Password's own infrastructure.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func exclusionListCard(settings: SocketSettingsService) -> some View {
        let profileId = browserManager.currentProfile?.id
        let hosts: [String] = {
            guard let id = profileId else { return [] }
            return settings.passwordSaveDisabledHosts[id.uuidString] ?? []
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Text("Never save for")
                .font(.system(size: 13, weight: .semibold))
            if hosts.isEmpty {
                Text("No exclusions. Socket will offer to save every new password you type.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(hosts, id: \.self) { host in
                        HStack {
                            Text(host)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                removeExclusion(host)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        if host != hosts.last {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - Actions

    private func reload() {
        records = browserManager.passwordManager.fetchAllForSettings()
    }

    private func toggleReveal(_ record: PasswordCredentialStore.Record) {
        if revealed[record.persistentRef] != nil {
            revealed[record.persistentRef] = nil
            return
        }
        Task { @MainActor in
            do {
                let pw = try await browserManager.passwordManager.reveal(record.persistentRef)
                revealed[record.persistentRef] = pw
            } catch {
                errorMessage = "Unable to reveal password."
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(value, forType: .string)
    }

    private func copyPassword(_ record: PasswordCredentialStore.Record) {
        Task { @MainActor in
            if let pw = try? await browserManager.passwordManager.reveal(record.persistentRef) {
                copyToPasteboard(pw)
            }
        }
    }

    private func delete(_ record: PasswordCredentialStore.Record) {
        browserManager.passwordManager.delete(record.persistentRef)
        revealed[record.persistentRef] = nil
        reload()
    }

    private func removeExclusion(_ host: String) {
        guard let id = browserManager.currentProfile?.id else { return }
        var list = socketSettings.passwordSaveDisabledHosts[id.uuidString] ?? []
        list.removeAll { $0 == host }
        socketSettings.passwordSaveDisabledHosts[id.uuidString] = list
    }
}
