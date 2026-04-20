//
//  PasswordSaveDialog.swift
//  Socket
//
//  Prompts the user to save (or update) a form-based password. The user
//  picks a destination (Keychain or 1Password, when available). Mirrors
//  BasicAuthDialog's structure.
//

import SwiftUI
import Observation

@Observable
final class PasswordSaveDialogModel {
    let host: String
    var username: String
    var password: String
    var syncToICloud: Bool
    var isPasswordRevealed: Bool
    let isUpdate: Bool
    var destination: PasswordProviderID
    let onePasswordAvailable: Bool

    init(host: String,
         username: String,
         password: String,
         syncToICloud: Bool,
         isUpdate: Bool,
         destination: PasswordProviderID,
         onePasswordAvailable: Bool) {
        self.host = host
        self.username = username
        self.password = password
        self.syncToICloud = syncToICloud
        self.isPasswordRevealed = false
        self.isUpdate = isUpdate
        self.destination = destination
        self.onePasswordAvailable = onePasswordAvailable
    }
}

struct PasswordSaveDialog: DialogPresentable {
    @Bindable var model: PasswordSaveDialogModel
    let onSave: (String, String, Bool, PasswordProviderID) -> Void
    let onNever: () -> Void
    let onCancel: () -> Void

    func dialogHeader() -> DialogHeader {
        let title = model.isUpdate
            ? "Update password for \(model.host)?"
            : "Save password for \(model.host)?"
        let subtitle = model.isUpdate
            ? "This will replace your saved password."
            : "Socket will fill this in next time you sign in."
        return DialogHeader(
            icon: "key.horizontal",
            title: title,
            subtitle: subtitle
        )
    }

    @ViewBuilder
    func dialogContent() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.onePasswordAvailable {
                destinationPicker
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("User name")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                SocketTextField(
                    text: $model.username,
                    placeholder: "Enter user name",
                    iconName: "person"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Password")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Group {
                        if model.isPasswordRevealed {
                            TextField("Enter password", text: $model.password)
                                .textFieldStyle(PlainTextFieldStyle())
                        } else {
                            SecureField("Enter password", text: $model.password)
                                .textFieldStyle(PlainTextFieldStyle())
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button(action: {
                        model.isPasswordRevealed.toggle()
                    }) {
                        Image(systemName: model.isPasswordRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(model.isPasswordRevealed ? "Hide password" : "Show password")
                }
            }

            if model.destination == .keychain {
                Toggle(isOn: $model.syncToICloud) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync to iCloud Keychain")
                        Text("Appears in System Settings → Passwords and on your other Apple devices.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .padding(.horizontal, 4)
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save to")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Picker("", selection: $model.destination) {
                ForEach(PasswordProviderID.allCases) { pid in
                    Label(pid.displayName, systemImage: pid.symbolName)
                        .tag(pid)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    func dialogFooter() -> DialogFooter {
        let canSubmit = !model.username.isEmpty && !model.password.isEmpty
        let primaryText = model.isUpdate ? "Update" : "Save"

        return DialogFooter(
            leftButton: DialogButton(
                text: "Never for this site",
                variant: .secondary,
                action: onNever
            ),
            rightButtons: [
                DialogButton(
                    text: "Not now",
                    variant: .secondary,
                    keyboardShortcut: .escape,
                    action: onCancel
                ),
                DialogButton(
                    text: primaryText,
                    iconName: "checkmark.circle",
                    variant: .primary,
                    keyboardShortcut: .return,
                    isEnabled: canSubmit,
                    action: {
                        onSave(model.username, model.password, model.syncToICloud, model.destination)
                    }
                )
            ]
        )
    }
}
