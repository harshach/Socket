//
//  SidebarMenuShortcutsTab.swift
//  Socket
//
//  Created by Codex on 14/04/2026.
//

import SwiftUI

private struct ShortcutDrawerSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    let actions: [ShortcutAction]
}

private struct ShortcutDrawerRow: Identifiable {
    let action: ShortcutAction
    let bindings: [KeyboardShortcut]

    var id: String { action.rawValue }
}

struct SidebarMenuShortcutsTab: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(KeyboardShortcutManager.self) private var keyboardShortcutManager
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchHovering: Bool = false

    private let sections: [ShortcutDrawerSection] = [
        .init(
            id: "single-key",
            title: "Single-Key Navigation",
            icon: "command",
            actions: [
                .nextTab,
                .previousTab,
                .nextSpace,
                .previousSpace,
                .goBack,
                .goForward,
                .openCommandPalette,
                .createWorkspace,
                .closeTab,
                .toggleFocusMode,
                .enterInsertMode
            ]
        ),
        .init(
            id: "pages",
            title: "Pages",
            icon: "doc.on.doc",
            actions: [
                .newTab,
                .duplicateTab,
                .moveCurrentPageUp,
                .moveCurrentPageDown,
                .focusAddressBar,
                .findInPage,
                .refresh
            ]
        ),
        .init(
            id: "spaces",
            title: "Spaces",
            icon: "rectangle.3.group",
            actions: [
                .nextSpace,
                .previousSpace,
                .createWorkspace,
                .editCurrentWorkspace,
                .moveWorkspaceUp,
                .moveWorkspaceDown,
                .goToWorkspace1,
                .goToWorkspace2,
                .goToWorkspace3
            ]
        ),
        .init(
            id: "split-window",
            title: "Split & Window",
            icon: "square.split.2x1",
            actions: [
                .toggleSplitMode,
                .sendCurrentPageToSplit,
                .sendSplitPageToMain,
                .closeSplitPage,
                .toggleSidebar,
                .focusSplitScreen,
                .toggleSplitScreenFocus
            ]
        ),
        .init(
            id: "browser",
            title: "Browser & Tools",
            icon: "wrench.and.screwdriver",
            actions: [
                .viewHistory,
                .viewDownloads,
                .openExtensionsPanel,
                .toggleAIAssistant,
                .openDevTools,
                .copyCurrentURL
            ]
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField

            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(sections) { section in
                        let rows = rows(for: section)
                        if !rows.isEmpty {
                            ShortcutDrawerSectionView(
                                title: section.title,
                                icon: section.icon,
                                rows: rows
                            )
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            footer
        }
        .padding(8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Text("Tabs and spaces first, with single-key navigation surfaced at the top.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))

            TextField("Search shortcuts...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 40)
        .background(isSearchHovering ? .white.opacity(0.08) : .white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isSearchHovering)
        .onHover { isSearchHovering = $0 }
        .onTapGesture {
            isSearchFocused = true
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Single-key shortcuts work when Sigma Command Mode is enabled and you are not typing in a field. Alternate bindings still work even if only the primary one is shown here.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                browserManager.showShortcutsSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Customize Shortcuts")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func rows(for section: ShortcutDrawerSection) -> [ShortcutDrawerRow] {
        section.actions.compactMap { action in
            let bindings = bindings(for: action)
            guard !bindings.isEmpty else { return nil }

            if !searchText.isEmpty,
               !action.displayName.localizedCaseInsensitiveContains(searchText),
               !bindings.contains(where: { $0.keyCombination.displayString.localizedCaseInsensitiveContains(searchText) }) {
                return nil
            }

            return ShortcutDrawerRow(action: action, bindings: bindings)
        }
    }

    private func bindings(for action: ShortcutAction) -> [KeyboardShortcut] {
        keyboardShortcutManager.shortcuts
            .filter { $0.isEnabled && $0.action == action }
            .sorted { lhs, rhs in
                let lhsCount = lhs.keyCombination.modifiers.displayStrings.count
                let rhsCount = rhs.keyCombination.modifiers.displayStrings.count
                if lhsCount != rhsCount {
                    return lhsCount < rhsCount
                }
                return lhs.keyCombination.displayString < rhs.keyCombination.displayString
            }
    }
}

private struct ShortcutDrawerSectionView: View {
    let title: String
    let icon: String
    let rows: [ShortcutDrawerRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))

            VStack(spacing: 8) {
                ForEach(rows) { row in
                    ShortcutDrawerRowView(row: row)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ShortcutDrawerRowView: View {
    let row: ShortcutDrawerRow
    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.action.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))

                if row.bindings.count > 1 {
                    Text("+\(row.bindings.count - 1) alternate shortcut\(row.bindings.count > 2 ? "s" : "")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Spacer(minLength: 12)

            ShortcutBindingCapsuleView(binding: row.bindings[0].keyCombination)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovering ? .white.opacity(0.06) : .white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct ShortcutBindingCapsuleView: View {
    let binding: KeyCombination

    private var tokens: [String] {
        binding.displayString.components(separatedBy: " + ")
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tokens, id: \.self) { token in
                Text(token)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
