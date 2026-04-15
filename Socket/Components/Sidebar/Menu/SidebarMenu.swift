//
//  SidebarMenu.swift
//  Socket
//
//  Created by Maciek Bagiński on 23/09/2025.
//

import SwiftUI

enum Tabs {
    case history
    case downloads
    case shortcuts
}

public enum SidebarPosition: String, CaseIterable, Identifiable {
    case left
    case right
    public var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
    
    var icon: String {
        switch self {
        case .left: return "sidebar.left"
        case .right: return "sidebar.right"
        }
    }
}

struct SidebarMenu: View {
    @State private var selectedTab: Tabs = .history
    @Environment(BrowserWindowState.self) private var windowState
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(\.socketSettings) var socketSettings

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if socketSettings.sidebarPosition == .left{
                tabs
            }
            VStack {
                switch selectedTab {
                case .history:
                    SidebarMenuHistoryTab()
                case .downloads:
                    SidebarMenuDownloadsTab()
                case .shortcuts:
                    SidebarMenuShortcutsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if socketSettings.sidebarPosition == .right{
                tabs
            }
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .openSidebarMenuHistory)) { _ in
            selectedTab = .history
            windowState.isSidebarMenuVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSidebarMenuDownloads)) { _ in
            selectedTab = .downloads
            windowState.isSidebarMenuVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSidebarMenuShortcuts)) { _ in
            selectedTab = .shortcuts
            windowState.isSidebarMenuVisible = true
        }
    }
    
    var tabs: some View{
        VStack {
            HStack {
                MacButtonsView()
                    .frame(width: 70, height: 20)
                    .padding(8)
                Spacer()
            }
            
            Spacer()
            VStack(spacing: 20) {
                SidebarMenuTab(
                    image: "clock",
                    activeImage: "clock.fill",
                    title: "History",
                    isActive: selectedTab == .history,
                    action: {
                        selectedTab = .history
                    }
                )
                SidebarMenuTab(
                    image: "arrow.down.circle",
                    activeImage: "arrow.down.circle.fill",
                    title: "Downloads",
                    isActive: selectedTab == .downloads,
                    action: {
                        selectedTab = .downloads
                    }
                )
                SidebarMenuTab(
                    image: "keyboard",
                    activeImage: "keyboard.fill",
                    title: "Shortcuts",
                    isActive: selectedTab == .shortcuts,
                    action: {
                        selectedTab = .shortcuts
                    }
                )
            }
            
            Spacer()
            HStack {
                Button("Back", systemImage: "arrow.backward") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        windowState.isSidebarMenuVisible = false
                        let restoredWidth = windowState.savedSidebarWidth
                        windowState.sidebarWidth = restoredWidth
                        windowState.sidebarContentWidth = max(restoredWidth - 16, 0)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(NavButtonStyle())
                .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.bottom, 8)
        }
        .padding(8)
        .frame(width: 110)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.2))
    }
}

extension Notification.Name {
    static let openSidebarMenuHistory = Notification.Name("openSidebarMenuHistory")
    static let openSidebarMenuDownloads = Notification.Name("openSidebarMenuDownloads")
    static let openSidebarMenuShortcuts = Notification.Name("openSidebarMenuShortcuts")
}
