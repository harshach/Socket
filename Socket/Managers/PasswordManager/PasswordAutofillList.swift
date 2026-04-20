//
//  PasswordAutofillList.swift
//  Socket
//
//  SwiftUI list of credential suggestions, hosted inside
//  `PasswordAutofillPopover`.
//

import SwiftUI

struct PasswordAutofillList: View {
    let suggestions: [CredentialSuggestion]
    let onSelect: (CredentialSuggestion) -> Void
    let onManage: () -> Void

    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)
            if suggestions.isEmpty {
                emptyState
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.element.ref) { index, suggestion in
                    Button(action: { onSelect(suggestion) }) {
                        row(for: suggestion, index: index)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
                    }
                }
            }
            Divider().opacity(0.6)
            Button(action: onManage) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                    Text("Manage Passwords…")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No saved passwords for this site")
                .font(.system(size: 12, weight: .medium))
            Text("Sign in once and Socket will offer to save. You can also import from 1Password via the Settings → Passwords pane.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 11, weight: .semibold))
            Text("Sign in with Socket")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func row(for suggestion: CredentialSuggestion, index: Int) -> some View {
        HStack(spacing: 10) {
            initialsBadge(for: suggestion.username)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.username.isEmpty ? "(no username)" : suggestion.username)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(suggestion.host)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    providerBadge(for: suggestion.provider)
                }
            }
            Spacer(minLength: 0)
            if hoveredIndex == index {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredIndex == index ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }

    private func providerBadge(for provider: PasswordProviderID) -> some View {
        HStack(spacing: 3) {
            Image(systemName: provider.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(provider.displayName)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.08))
        )
    }

    private func initialsBadge(for username: String) -> some View {
        let letters = username
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
            Text(letters.isEmpty ? "•" : letters)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 26, height: 26)
    }
}
