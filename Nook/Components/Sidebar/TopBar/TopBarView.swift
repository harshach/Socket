//
//  TopBarView.swift
//  Nook
//
//  Created by Assistant on 23/09/2025.
//

import AppKit
import SwiftUI

enum TopBarMetrics {
    static let height: CGFloat = 40
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 5
}

struct TopBarView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.nookSettings) var nookSettings
    @StateObject private var tabWrapper = ObservableTabWrapper()
    @State private var isHovering: Bool = false
    @State private var previousTabId: UUID? = nil
    @State private var showingShieldsPopover: Bool = false

    var body: some View {
        let cornerRadius: CGFloat = {
            if #available(macOS 26.0, *) {
                return 8
            } else {
                return 8
            }
        }()

        let currentTab = browserManager.currentTab(for: windowState)
        let hasPiPControl =
            currentTab?.hasVideoContent == true
            || browserManager.currentTabHasPiPActive()

        ZStack {
            // Main content
            ZStack {
                HStack(spacing: 8) {
                    navigationControls

                    if hasPiPControl, let tab = currentTab {
                        pipButton(for: tab)
                    }

                    urlBar

                    Spacer()

                    extensionsView

                    shieldsView

                    sigmaToolbox

                    if browserManager.nookSettings?.showAIAssistant ?? false
                        && !windowState.isSidebarAIChatVisible
                    {
                        ChatButton(navButtonColor: navButtonColor)
                    }

                }

            }
            .padding(.horizontal, TopBarMetrics.horizontalPadding)
            .padding(.vertical, TopBarMetrics.verticalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: TopBarMetrics.height)
            .background(topBarBackgroundColor)
            .animation(
                shouldAnimateColorChange ? .easeInOut(duration: 0.3) : nil,
                value: topBarBackgroundColor
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: cornerRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: cornerRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .bottom) {
                // 1px bottom border - lighter when dark, darker when light
                Rectangle()
                    .fill(bottomBorderColor)
                    .frame(height: 1)
                    .animation(
                        shouldAnimateColorChange
                            ? .easeInOut(duration: 0.3) : nil,
                        value: bottomBorderColor
                    )
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(
                        key: URLBarFramePreferenceKey.self,
                        value: geometry.frame(in: .named("WindowSpace"))
                    )
            }
        )
        .onAppear {
            tabWrapper.setContext(
                browserManager: browserManager,
                windowState: windowState
            )
            updateCurrentTab()
            // Initialize previousTabId to current tab so first color change doesn't animate
            previousTabId = browserManager.currentTab(for: windowState)?.id
        }
        .onChange(of: browserManager.currentTab(for: windowState)?.id) {
            oldId,
            newId in
            previousTabId = oldId
            updateCurrentTab()
            // Update previousTabId after a brief delay so next color change within this tab will animate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                previousTabId = newId
            }
        }
        .onChange(
            of: browserManager.currentTab(for: windowState)?.pageBackgroundColor
        ) { _, _ in
            // Color changes will trigger animations automatically via computed properties
        }
        .onChange(
            of: browserManager.currentTab(for: windowState)?
                .topBarBackgroundColor
        ) { _, _ in
            // Top bar color changes will trigger animations automatically via computed properties
        }
        .onReceive(
            Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
        ) { _ in
            updateCurrentTab()
        }
    }

    private var extensionsView: some View {
        HStack(spacing: 4) {
            if let extensionManager = browserManager.extensionManager {
                ExtensionActionView(
                    extensions: extensionManager.installedExtensions
                )
                .environmentObject(browserManager)
            }

        }


    }

    private var shieldsView: some View {
        let currentTab = browserManager.currentTab(for: windowState)
        let siteState = browserManager.trackingProtectionManager.siteProtectionState(for: currentTab)
        let stats = siteState?.stats

        return Button {
            showingShieldsPopover.toggle()
        } label: {
            Image(systemName: siteState?.effectiveShieldIcon ?? "shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(shieldsTint(for: siteState))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(shieldsTint(for: siteState).opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(shieldsTint(for: siteState).opacity(0.20), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(currentTab == nil)
        .help(shieldsHelpText(for: siteState, stats: stats))
        .popover(isPresented: $showingShieldsPopover, arrowEdge: .bottom) {
            ShieldsPopoverView(
                state: siteState,
                tab: currentTab,
                onToggleSite: {
                    guard let host = siteState?.host, !host.isEmpty else { return }
                    browserManager.trackingProtectionManager.allowDomain(
                        host,
                        allowed: !(siteState?.isAllowlisted ?? false)
                    )
                },
                onRelaxTemporarily: {
                    guard let currentTab else { return }
                    browserManager.trackingProtectionManager.disableTemporarily(
                        for: currentTab,
                        duration: 15 * 60
                    )
                },
                onRefresh: {
                    browserManager.refreshShieldsLists()
                },
                onOpenSettings: {
                    browserManager.showPrivacySettings()
                }
            )
            .environmentObject(browserManager)
        }
    }

    private var sigmaToolbox: some View {
        HStack(spacing: 4) {
            toolboxButton(
                systemName: "viewfinder.circle",
                help: windowState.isFocusModeEnabled ? "Exit Focus Mode" : "Enter Focus Mode",
                isActive: windowState.isFocusModeEnabled
            ) {
                browserManager.toggleFocusMode(for: windowState)
            }

            toolboxButton(
                systemName: splitManagerActive ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                help: splitManagerActive ? "Close Split Mode" : "Open Split Mode",
                isActive: splitManagerActive
            ) {
                browserManager.toggleSplitMode(for: windowState)
            }
            
            if splitManagerActive {
                toolboxButton(
                    systemName: "arrow.left.to.line",
                    help: "Close Left Panel"
                ) {
                    browserManager.promoteSplitPageToMain(in: windowState)
                }

                toolboxButton(
                    systemName: "xmark",
                    help: "Close Split Page"
                ) {
                    browserManager.closeSplitPage(in: windowState)
                }
            }

            toolboxButton(
                systemName: "keyboard",
                help: "Open Shortcut Cheat Sheet"
            ) {
                browserManager.showShortcutsSettings()
            }
        }
    }

    private var splitManagerActive: Bool {
        browserManager.splitManager.isSplit(for: windowState.id)
    }

    private func toolboxButton(
        systemName: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(navButtonColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(toolboxButtonBackgroundColor(isActive: isActive))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(navButtonColor.opacity(isActive ? 0.25 : 0.12), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toolboxButtonBackgroundColor(isActive: Bool) -> Color {
        if isActive {
            return navButtonColor.opacity(0.14)
        }
        return navButtonColor.opacity(0.07)
    }

    private func shieldsTint(for state: SiteProtectionState?) -> Color {
        guard let state else { return navButtonColor.opacity(0.8) }
        if !state.isGlobalProtectionEnabled {
            return .secondary
        }
        if state.isAllowlisted || state.isTemporarilyRelaxed {
            return .orange
        }
        return .green
    }

    private func shieldsHelpText(for state: SiteProtectionState?, stats: PageBlockStats?) -> String {
        guard let state else { return "Page Shields" }
        if !state.isGlobalProtectionEnabled {
            return "Shields are disabled globally"
        }
        if state.isAllowlisted {
            return "Shields are off for \(state.host ?? "this site")"
        }
        if state.isTemporarilyRelaxed {
            return "Shields are temporarily relaxed for this tab"
        }
        let blockedCount = (stats?.networkRuleCount ?? 0) + (stats?.hiddenElementCount ?? 0)
        return blockedCount > 0
            ? "Shields active, \(blockedCount) protections applied"
            : "Shields active"
    }

    private var navigationControls: some View {
        HStack(spacing: 4) {
            Button("Go Back", systemImage: "chevron.backward", action: goBack)
                .labelStyle(.iconOnly)
                .buttonStyle(NavButtonStyle())
                .foregroundStyle(navButtonColor)
                .animation(
                    shouldAnimateColorChange ? .easeInOut(duration: 0.3) : nil,
                    value: navButtonColor
                )
                .disabled(!tabWrapper.canGoBack)
                .opacity(tabWrapper.canGoBack ? 1.0 : 0.4)
                .contextMenu {
                    NavigationHistoryContextMenu(
                        historyType: .back,
                        windowState: windowState
                    )
                }

            Button(
                "Go Forward",
                systemImage: "chevron.right",
                action: goForward
            )
            .labelStyle(.iconOnly)
            .buttonStyle(NavButtonStyle())
            .foregroundStyle(navButtonColor)
            .animation(
                shouldAnimateColorChange ? .easeInOut(duration: 0.3) : nil,
                value: navButtonColor
            )
            .disabled(!tabWrapper.canGoForward)
            .opacity(tabWrapper.canGoForward ? 1.0 : 0.4)
            .contextMenu {
                NavigationHistoryContextMenu(
                    historyType: .forward,
                    windowState: windowState
                )
            }

            Button(
                "Reload",
                systemImage: "arrow.clockwise",
                action: refreshCurrentTab
            )
            .labelStyle(.iconOnly)
            .buttonStyle(NavButtonStyle())
            .foregroundStyle(navButtonColor)
            .animation(
                shouldAnimateColorChange ? .easeInOut(duration: 0.3) : nil,
                value: navButtonColor
            )
        }
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            if browserManager.currentTab(for: windowState) != nil {
                Text(displayURL)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(urlBarTextColor)
                    .tracking(-0.1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            } else {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(urlBarBackgroundColor)
        .animation(
            shouldAnimateColorChange ? .easeInOut(duration: 0.3) : nil,
            value: urlBarBackgroundColor
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            if let currentTab = browserManager.currentTab(for: windowState) {
                commandPalette.openWithCurrentURL(currentTab.url)
            } else {
                commandPalette.open()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func updateCurrentTab() {
        tabWrapper.updateTab(browserManager.currentTab(for: windowState))
    }

    private func goBack() {
        if let tab = tabWrapper.tab,
            let webView = browserManager.getWebView(
                for: tab.id,
                in: windowState.id
            )
        {
            webView.goBack()
        } else {
            tabWrapper.tab?.goBack()
        }
    }

    private func goForward() {
        if let tab = tabWrapper.tab,
            let webView = browserManager.getWebView(
                for: tab.id,
                in: windowState.id
            )
        {
            webView.goForward()
        } else {
            tabWrapper.tab?.goForward()
        }
    }

    private func refreshCurrentTab() {
        tabWrapper.tab?.refresh()
    }

    // Determine if we should animate color changes (within same tab) or snap (tab switch)
    private var shouldAnimateColorChange: Bool {
        let currentTabId = browserManager.currentTab(for: windowState)?.id
        return currentTabId == previousTabId
    }

    // Top bar background color - matches top-right pixel of webview
    private var topBarBackgroundColor: Color {
        if let currentTab = browserManager.currentTab(for: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            return Color(nsColor: topBarColor)
        }
        // Fallback to page background color if top bar color not available yet
        if let currentTab = browserManager.currentTab(for: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            return Color(nsColor: pageColor)
        }
        // Fallback to system theme colors when no tab or color available
        // This ensures the top bar has a proper background even before page loads
        return Color(nsColor: .windowBackgroundColor)
    }

    // Nav button color - light on dark backgrounds, dark on light backgrounds
    private var navButtonColor: Color {
        if let currentTab = browserManager.currentTab(for: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            return topBarColor.isPerceivedDark
                ? Color.white.opacity(0.9) : Color.black.opacity(0.8)
        }
        // Fallback to page background color
        if let currentTab = browserManager.currentTab(for: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            return pageColor.isPerceivedDark
                ? Color.white.opacity(0.9) : Color.black.opacity(0.8)
        }

        // Fallback
        return browserManager.gradientColorManager.isDark
            ? Color.white.opacity(0.9) : Color.black.opacity(0.8)
    }

    // URL bar background color - slightly adjusted for visual distinction
    private var urlBarBackgroundColor: Color {
        if let currentTab = browserManager.currentTab(for: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            let baseColor = Color(nsColor: topBarColor)
            if isHovering {
                // Slightly lighter/darker on hover
                return adjustColorBrightness(
                    baseColor,
                    factor: topBarColor.isPerceivedDark ? 1.15 : 0.95
                )
            } else {
                // Slightly darker/lighter for subtle distinction from top bar
                //                return adjustColorBrightness(baseColor, factor: topBarColor.isPerceivedDark ? 1.1 : 0.98)
                return .clear
            }
        }
        // Fallback to page background color
        if let currentTab = browserManager.currentTab(for: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            let baseColor = Color(nsColor: pageColor)
            if isHovering {
                // Slightly lighter/darker on hover
                return adjustColorBrightness(
                    baseColor,
                    factor: pageColor.isPerceivedDark ? 1.15 : 0.95
                )
            } else {
                // Slightly darker/lighter for subtle distinction from top bar
                return adjustColorBrightness(
                    baseColor,
                    factor: pageColor.isPerceivedDark ? 1.1 : 0.98
                )
            }
        }
        // Fallback to original AppColors when no webview color available
        if isHovering {
            return browserManager.gradientColorManager.isDark
                ? AppColors.pinnedTabHoverDark : AppColors.pinnedTabHoverLight
        } else {
            return browserManager.gradientColorManager.isDark
                ? AppColors.pinnedTabIdleDark : AppColors.pinnedTabIdleLight
        }
    }

    // Text color for URL bar - ensures proper contrast
    private var urlBarTextColor: Color {
        if let currentTab = browserManager.currentTab(for: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            return topBarColor.isPerceivedDark
                ? Color.white.opacity(0.55) : Color.black.opacity(0.8)
        }
        // Fallback to page background color
        if let currentTab = browserManager.currentTab(for: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            return pageColor.isPerceivedDark
                ? Color.white.opacity(0.55) : Color.black.opacity(0.8)
        }
        // Fallback to original text color logic
        return browserManager.gradientColorManager.isDark
            ? AppColors.spaceTabTextDark : AppColors.spaceTabTextLight
    }

    // Bottom border color - lighter when dark, darker when light
    private var bottomBorderColor: Color {
        if let currentTab = browserManager.currentTab(for: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            let baseColor = Color(nsColor: topBarColor)
            // Make lighter if dark, darker if light
            return adjustColorBrightness(
                baseColor,
                factor: topBarColor.isPerceivedDark ? 1.2 : 0.85
            )
        }
        // Fallback to page background color
        if let currentTab = browserManager.currentTab(for: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            let baseColor = Color(nsColor: pageColor)
            return adjustColorBrightness(
                baseColor,
                factor: pageColor.isPerceivedDark ? 1.2 : 0.85
            )
        }
        // Fallback to system separator color
        return Color(nsColor: .separatorColor)
    }

    // Helper to adjust color brightness
    private func adjustColorBrightness(_ color: Color, factor: CGFloat) -> Color
    {
        #if canImport(AppKit)
            guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else {
                return color
            }
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)

            // Clamp values between 0 and 1
            r = min(1.0, max(0.0, r * factor))
            g = min(1.0, max(0.0, g * factor))
            b = min(1.0, max(0.0, b * factor))

            return Color(
                nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            )
        #else
            return color
        #endif
    }

    private var displayURL: AttributedString {
        guard let currentTab = browserManager.currentTab(for: windowState)
        else {
            return ""
        }

        return formatURL(
            currentTab.url,
            title: currentTab.name,
            isHovering: isHovering
        )
    }

    private func formatURL(_ url: URL, title: String?, isHovering: Bool)
        -> AttributedString
    {
        if isHovering {
            guard let host = url.host else {
                return AttributedString(url.absoluteString)
            }

            let cleanHost =
                host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

            let hostString = AttributedString(cleanHost)

            var pathString = AttributedString()

            if !url.path.isEmpty {
                pathString += AttributedString(url.path)
            }

            if let query = url.query {
                pathString += AttributedString("?" + query)
            }

            pathString.foregroundColor = urlBarTextColor.opacity(0.35)

            return hostString + pathString
        }

        guard let host = url.host else {
            return AttributedString(url.absoluteString)
        }

        let cleanHost =
            host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        if url.path.isEmpty || url.path == "/" {
            return AttributedString(cleanHost)
        } else {
            let displayTitle = title ?? cleanHost
            var result = AttributedString(cleanHost)
            var titlePart = AttributedString(" / " + displayTitle)
            titlePart.foregroundColor = urlBarTextColor.opacity(0.35)
            result.append(titlePart)
            return result
        }
    }

    private func pipButton(for tab: Tab) -> some View {
        Button(action: {
            tab.requestPictureInPicture()
        }) {
            Image(
                systemName: browserManager.currentTabHasPiPActive()
                    ? "pip.exit" : "pip.enter"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(urlBarTextColor)
            .animation(
                shouldAnimateColorChange ? .easeInOut(duration: 0.3) : nil,
                value: urlBarTextColor
            )
            .frame(width: 16, height: 16)
            .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ChatButton: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovered: Bool = false

    var navButtonColor: Color
    



    var body: some View {
        Button {
            browserManager.toggleAISidebar(for: windowState)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "message.fill")
                Text("Chat")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(navButtonColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(backgroundColor)
            .clipShape(
                RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { state in
            isHovered = state
        }

    }
    
    private var backgroundColor: Color {
        let isDark = browserManager.tabManager.currentTab?.topBarBackgroundColor?.isPerceivedDark == true
        if isHovered {
            return isDark ? .white.opacity(0.15) : .black.opacity(0.1)
        } else {
            return isDark ? .white.opacity(0.1) : .black.opacity(0.05)
        }
    }
}

private struct ShieldsPopoverView: View {
    @EnvironmentObject private var browserManager: BrowserManager

    let state: SiteProtectionState?
    let tab: Tab?
    let onToggleSite: () -> Void
    let onRelaxTemporarily: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void

    private var hostLabel: String {
        state?.host ?? tab?.webView?.url?.host ?? tab?.url.host ?? "Current Site"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state?.effectiveShieldIcon ?? "shield")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(iconTint.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Shields")
                        .font(.headline)
                    Text(hostLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }

            Text(statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                telemetryRow(
                    title: "Network rules active",
                    value: "\(state?.stats.networkRuleCount ?? 0)",
                    systemImage: "bolt.horizontal.fill"
                )
                telemetryRow(
                    title: "Cosmetic rules active",
                    value: "\(state?.stats.cosmeticRuleCount ?? 0)",
                    systemImage: "eye.slash"
                )
                telemetryRow(
                    title: "Elements hidden",
                    value: "\(state?.stats.hiddenElementCount ?? 0)",
                    systemImage: "trash.slash"
                )
                telemetryRow(
                    title: "Third-party storage",
                    value: (state?.thirdPartyStorageRestricted ?? false) ? "Restricted" : "Relaxed",
                    systemImage: "externaldrive.badge.icloud"
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button(state?.isAllowlisted == true ? "Block on This Site" : "Allow on This Site") {
                    onToggleSite()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state?.host?.isEmpty ?? true)

                Button("Temporarily Relax for Sign-In") {
                    onRelaxTemporarily()
                }
                .buttonStyle(.bordered)
                .disabled(tab == nil)

                HStack(spacing: 8) {
                    Button("Refresh Lists") {
                        onRefresh()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Privacy Settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var iconTint: Color {
        guard let state else { return .secondary }
        if !state.isGlobalProtectionEnabled {
            return .secondary
        }
        if state.isAllowlisted || state.isTemporarilyRelaxed {
            return .orange
        }
        return .green
    }

    private var statusText: String {
        guard let state else { return "No active page selected." }
        if !state.isGlobalProtectionEnabled {
            return "Shields are disabled globally."
        }
        if state.isAllowlisted {
            return "This site is allowlisted."
        }
        if state.isTemporarilyRelaxed {
            return "This tab is temporarily relaxed for sign-in."
        }
        return "Shields are active for this site."
    }

    @ViewBuilder
    private func telemetryRow(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 14, height: 14)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.caption.weight(.semibold))
        }
    }
}
