//
//  ShieldsURLBarButton.swift
//  Socket
//
//  Created by Codex on 14/04/2026.
//

import SwiftUI

struct ShieldsURLBarButton: View {
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @State private var showingShieldsPopover: Bool = false
    @State private var isHovering: Bool = false

    var body: some View {
        let currentTab = browserManager.currentTab(for: windowState)
        let siteState = browserManager.trackingProtectionManager.siteProtectionState(for: currentTab)
        let tint = shieldsTint(for: siteState)

        Button {
            showingShieldsPopover.toggle()
        } label: {
            Image(systemName: siteState?.effectiveShieldIcon ?? "shield")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? tint.opacity(0.12) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isHovering ? tint.opacity(0.14) : .clear, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(shieldsHelpText(for: siteState, stats: siteState?.stats))
        .onHoverTracking { hovering in
            isHovering = hovering
        }
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

    private func shieldsTint(for state: SiteProtectionState?) -> Color {
        guard let state else { return .secondary }
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
}

struct ShieldsPopoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: SiteProtectionState?
    let tab: Tab?
    let onToggleSite: () -> Void
    let onRelaxTemporarily: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void

    private var hostLabel: String {
        state?.host ?? tab?.webView?.url?.host ?? tab?.url.host ?? "Current Site"
    }

    private var stats: PageBlockStats {
        state?.stats
            ?? PageBlockStats(
                networkRuleCount: 0,
                cosmeticRuleCount: 0,
                hiddenElementCount: 0,
                scriptletActionCount: 0,
                thirdPartyStorageRestricted: false,
                temporaryRelaxed: false,
                allowlisted: false
            )
    }

    private var shieldsAreActiveForSite: Bool {
        guard let state else { return false }
        return state.isGlobalProtectionEnabled
            && !state.isAllowlisted
            && !state.isTemporarilyRelaxed
    }

    private var canToggleSiteProtection: Bool {
        !(state?.host?.isEmpty ?? true) && !(state?.isTemporarilyRelaxed ?? false)
    }

    private var engagedProtectionCount: Int {
        stats.networkRuleCount
            + stats.cosmeticRuleCount
            + stats.hiddenElementCount
            + stats.scriptletActionCount
    }

    private var headerAccent: Color {
        if state?.isTemporarilyRelaxed == true {
            return .orange
        }
        return iconTint
    }

    private var panelFill: Color {
        colorScheme == .dark
            ? Color(red: 0.115, green: 0.115, blue: 0.125)
            : Color(nsColor: .windowBackgroundColor)
    }

    private var sectionFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.035)
    }

    private var sectionBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusCard
            metricsSection
            actionSection

            if state?.isTemporarilyRelaxed == true {
                Text("Temporary sign-in relaxation expires automatically after a short time.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 356)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 18, y: 8)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(headerAccent.opacity(colorScheme == .dark ? 0.16 : 0.10))
                    .frame(width: 46, height: 46)

                if let tab {
                    tab.favicon
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 21, height: 21)
                } else {
                    Image(systemName: state?.effectiveShieldIcon ?? "globe")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(headerAccent)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(headerAccent.opacity(0.18), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(hostLabel)
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .lineLimit(1)
                    .textSelection(.enabled)

                Text(headerSubtitle)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(engagedProtectionCount)")
                    .font(.system(size: 26, weight: .semibold, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                Text("active")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label(primaryTitle, systemImage: primarySymbol)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)

                Text(primaryDescription)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Group {
                if canToggleSiteProtection {
                    Button(action: onToggleSite) {
                        ShieldsCapsuleToggle(isOn: shieldsAreActiveForSite, tint: headerAccent, isEnabled: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    ShieldsCapsuleToggle(isOn: shieldsAreActiveForSite, tint: headerAccent, isEnabled: false)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(sectionFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Protection Details",
                systemImage: "slider.horizontal.3"
            )

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ShieldsMetricCard(
                    title: "Network Rules",
                    value: "\(stats.networkRuleCount)",
                    systemImage: "bolt.horizontal.fill"
                )
                ShieldsMetricCard(
                    title: "Cosmetic Rules",
                    value: "\(stats.cosmeticRuleCount)",
                    systemImage: "eye.slash"
                )
                ShieldsMetricCard(
                    title: "Elements Hidden",
                    value: "\(stats.hiddenElementCount)",
                    systemImage: "sparkles.rectangle.stack"
                )
                ShieldsMetricCard(
                    title: "Third-Party Storage",
                    value: state?.thirdPartyStorageRestricted == true ? "Restricted" : "Relaxed",
                    systemImage: "externaldrive.badge.icloud"
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(sectionFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Quick Actions",
                systemImage: "line.3.horizontal.decrease.circle"
            )

            ShieldsActionRow(
                title: "Temporarily Relax for Sign-In",
                subtitle: state?.isTemporarilyRelaxed == true
                    ? "Temporary compatibility mode is already active for this tab."
                    : "Use this if an auth flow or embedded account page feels blocked.",
                systemImage: "clock.badge.exclamationmark",
                tint: .orange,
                isEnabled: tab != nil,
                action: onRelaxTemporarily
            )

            ShieldsActionRow(
                title: "Refresh Lists",
                subtitle: "Reload filter subscriptions and recompile the local ruleset.",
                systemImage: "arrow.clockwise",
                tint: .blue,
                action: onRefresh
            )

            ShieldsActionRow(
                title: "Open Privacy Settings",
                subtitle: "Adjust global blocking, subscriptions, and site exceptions.",
                systemImage: "gearshape",
                tint: .secondary,
                action: onOpenSettings
            )
        }
    }

    private func sectionHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(headerAccent)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
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

    private var headerSubtitle: String {
        if state?.isTemporarilyRelaxed == true {
            return "Sign-in compatibility mode is temporarily active for this tab."
        }
        if state?.isAllowlisted == true {
            return "Site-level exception active. Socket is stepping back on this domain."
        }
        if state?.isGlobalProtectionEnabled == false {
            return "Global shields are currently turned off."
        }
        if engagedProtectionCount > 0 {
            return "Socket is actively filtering trackers, ads, and storage access here."
        }
        return "Shields are ready and monitoring this page."
    }

    private var primaryTitle: String {
        guard let state else { return "No page selected" }
        if !state.isGlobalProtectionEnabled {
            return "Shields are disabled globally"
        }
        if state.isTemporarilyRelaxed {
            return "Temporary relaxation is active"
        }
        if state.isAllowlisted {
            return "Shields are down for this site"
        }
        return "Shields are up for this site"
    }

    private var primaryDescription: String {
        guard let state else { return "Open a page to inspect tracker and ad blocking." }
        if !state.isGlobalProtectionEnabled {
            return "Turn global privacy protections back on in Privacy Settings to restore filtering."
        }
        if state.isTemporarilyRelaxed {
            return "This tab was relaxed for compatibility. The exception will expire automatically."
        }
        if state.isAllowlisted {
            return "Tap the switch to restore normal protections for this domain."
        }
        return "Tap the switch if this page needs a site-level exception."
    }

    private var primarySymbol: String {
        guard let state else { return "shield" }
        if !state.isGlobalProtectionEnabled {
            return "shield.slash"
        }
        if state.isTemporarilyRelaxed {
            return "clock.badge.exclamationmark"
        }
        if state.isAllowlisted {
            return "shield.lefthalf.filled.slash"
        }
        return "checkmark.shield.fill"
    }
}

private struct ShieldsMetricCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String
    let systemImage: String

    private var cardFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.black.opacity(0.03)
    }

    private var cardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.07)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
    }
}

private struct ShieldsActionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering: Bool = false

    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var isEnabled: Bool = true
    let action: () -> Void

    private var rowFill: Color {
        if !isEnabled {
            return colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)
        }
        if isHovering {
            return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
        }
        return colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.03)
    }

    private var rowBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.07)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(rowBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.6)
        .onHoverTracking { hovering in
            isHovering = hovering
        }
    }
}

private struct ShieldsCapsuleToggle: View {
    let isOn: Bool
    let tint: Color
    let isEnabled: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(trackColor)
                .frame(width: 56, height: 32)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )

            Circle()
                .fill(knobColor)
                .frame(width: 24, height: 24)
                .padding(4)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .overlay(
                    Image(systemName: isOn ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isOn ? tint : .secondary)
                )
        }
        .opacity(isEnabled ? 1.0 : 0.7)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isOn)
    }

    private var trackColor: Color {
        if !isEnabled {
            return Color.secondary.opacity(0.18)
        }
        return isOn ? tint.opacity(0.28) : Color.secondary.opacity(0.24)
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color.secondary.opacity(0.14)
        }
        return isOn ? tint.opacity(0.35) : Color.secondary.opacity(0.20)
    }

    private var knobColor: Color {
        isEnabled ? Color.white.opacity(0.96) : Color.white.opacity(0.82)
    }
}
