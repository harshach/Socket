//
//  SidebarHoverOverlayView.swift
//  Socket
//
//  Created by Jonathan Caudill on 2025-09-13.
//

import SwiftUI
import UniversalGlass
import AppKit

struct SidebarHoverOverlayView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var hoverManager: HoverSidebarManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.socketSettings) var socketSettings

    private let cornerRadius: CGFloat = 12
    private let horizontalInset: CGFloat = 7
    private let verticalInset: CGFloat = 7

    var body: some View {
        let isActiveWindow = windowRegistry.activeWindow?.id == windowState.id
        let canRenderOverlay = isActiveWindow
            && !windowState.isSidebarVisible
            && !windowState.isFocusModeEnabled
            && !windowState.isSidebarMenuVisible
            && !windowState.isSidebarAIChatVisible
            && !windowState.isCommandPaletteVisible

        // Only render overlay plumbing when the real sidebar is collapsed.
        if canRenderOverlay {
            ZStack(alignment: socketSettings.sidebarPosition == .left ? .leading : .trailing) {
                // Edge hover hotspot
                Color.clear
                    .frame(width: hoverManager.triggerWidth)
                    .contentShape(Rectangle())
                    .onHover { isIn in
                        if isIn {
                            hoverManager.revealFromHotspot()
                        } else {
                            hoverManager.refreshVisibility()
                        }
                        NSCursor.arrow.set()
                    }

                if hoverManager.isOverlayVisible {
                    SpacesSideBarView()
                        .frame(width: windowState.sidebarWidth)
                        .environmentObject(browserManager)
                        .environment(windowState)
                        .environment(commandPalette)
                        .environmentObject(browserManager.gradientColorManager)
                        .frame(maxHeight: .infinity)
                        .background{
                            
                            
                            SpaceGradientBackgroundView()
                                .environmentObject(browserManager)
                                .environmentObject(browserManager.gradientColorManager)
                                .environment(windowState)
                                .clipShape(.rect(cornerRadius: cornerRadius))
                            
                                Rectangle()
                                    .fill(Color.clear)
                                    .universalGlassEffect(.regular.tint(Color(.windowBackgroundColor).opacity(0.35)), in: .rect(cornerRadius: cornerRadius))
                        }
                        .alwaysArrowCursor()
                        .padding(socketSettings.sidebarPosition == .left ? .leading : .trailing, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .transition(
                            .move(edge: socketSettings.sidebarPosition == .left ? .leading : .trailing)
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: socketSettings.sidebarPosition == .left ? .topLeading : .topTrailing)
            // Container remains passive; only overlay/hotspot intercept
            .onAppear {
                hoverManager.refreshVisibility()
            }
            .onDisappear {
                hoverManager.dismissOverlay()
            }
            .onChange(of: windowRegistry.activeWindow?.id) { _, _ in
                hoverManager.refreshVisibility()
            }
            .onChange(of: windowState.isSidebarVisible) { _, isVisible in
                if isVisible {
                    hoverManager.dismissOverlay()
                } else {
                    hoverManager.refreshVisibility()
                }
            }
            .onChange(of: windowState.isFocusModeEnabled) { _, _ in
                hoverManager.refreshVisibility()
            }
            .onChange(of: windowState.isSidebarMenuVisible) { _, _ in
                hoverManager.refreshVisibility()
            }
            .onChange(of: windowState.isSidebarAIChatVisible) { _, _ in
                hoverManager.refreshVisibility()
            }
            .onChange(of: windowState.isCommandPaletteVisible) { _, _ in
                hoverManager.refreshVisibility()
            }
        }
    }
}
