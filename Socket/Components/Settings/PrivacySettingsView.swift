//
//  PrivacySettingsView.swift
//  Socket
//
//  Created by Jonathan Caudill on 15/08/2025.
//

import SwiftUI
import WebKit

struct PrivacySettingsView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(\.socketSettings) var socketSettings
    @StateObject private var cookieManager = CookieManager()
    @StateObject private var cacheManager = CacheManager()
    @State private var showingCookieManager = false
    @State private var showingCacheManager = false
    @State private var isClearing = false
    @State private var isRefreshingShieldsLists = false
    @State private var privacyCardVersion = 0

    var body: some View {
        @Bindable var settings = socketSettings
        let trackingBinding = Binding(
            get: { settings.blockCrossSiteTracking },
            set: { enabled in
                settings.blockCrossSiteTracking = enabled
                browserManager.trackingProtectionManager.setEnabled(enabled)
                privacyCardVersion += 1
            }
        )

        return
        VStack(alignment: .leading, spacing: 20) {
            // Cookie Management Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Cookie Management")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    cookieStatsView
                    
                    HStack {
                        Button("Manage Cookies") {
                            showingCookieManager = true
                        }
                        .buttonStyle(.bordered)
                        
                        Menu("Clear Data") {
                            Button("Clear Expired Cookies") {
                                clearExpiredCookies()
                            }
                            
                            Button("Clear Third-Party Cookies") {
                                clearThirdPartyCookies()
                            }
                            
                            Button("Clear High-Risk Cookies") {
                                clearHighRiskCookies()
                            }
                            
                            Divider()
                            
                            Button("Clear All Cookies") {
                                clearAllCookies()
                            }
                            
                            Button("Privacy Cleanup") {
                                performCookiePrivacyCleanup()
                            }
                            
                            Divider()
                            
                            Button("Clear All Website Data", role: .destructive) {
                                clearAllWebsiteData()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isClearing)
                        
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // Cache Management Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Cache Management")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    cacheStatsView
                    
                    HStack {
                        Button("Manage Cache") {
                            showingCacheManager = true
                        }
                        .buttonStyle(.bordered)
                        
                        Menu("Clear Cache") {
                            Button("Clear Stale Cache") {
                                clearStaleCache()
                            }
                            
                            Button("Clear Personal Data Cache") {
                                clearPersonalDataCache()
                            }
                            
                            Button("Clear Disk Cache") {
                                clearDiskCache()
                            }
                            
                            Button("Clear Memory Cache") {
                                clearMemoryCache()
                            }
                            
                            Divider()
                            
                            Button("Privacy Cleanup") {
                                performCachePrivacyCleanup()
                            }
                            
                            Divider()
                            
                            Button("Clear All Cache", role: .destructive) {
                                clearAllCache()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isClearing)
                        
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // Privacy Controls Section
            adTrackerBlockingSection(trackingBinding: trackingBinding)
            
            Divider()
            
            // Website Data Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Website Data")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Button("Clear Browsing History") {
                        clearBrowsingHistory()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Clear Cache") {
                        clearCache()
                    }
                    .buttonStyle(.bordered)
                    
                                    }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            Task {
                await cookieManager.loadCookies()
                await cacheManager.loadCacheData()
            }
        }
        .sheet(isPresented: $showingCookieManager) {
            CookieManagementView()
        }
        .sheet(isPresented: $showingCacheManager) {
            CacheManagementView()
        }
    }
    
    // MARK: - Cache Stats View
    
    private var cacheStatsView: some View {
        let stats = cacheManager.getCacheStats()
        
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundColor(.blue)
                Text("Stored Cache")
                    .fontWeight(.medium)
                Spacer()
                Text("\(stats.total)")
                    .foregroundColor(.secondary)
            }
            
            if stats.total > 0 {
                HStack {
                    Spacer().frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Disk: \(formatSize(stats.diskSize))")
                            Text("•")
                            Text("Memory: \(formatSize(stats.memorySize))")
                            if stats.staleCount > 0 {
                                Text("•")
                                Text("Stale: \(stats.staleCount)")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        Text("Total size: \(formatSize(stats.totalSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Cookie Stats View
    
    private var cookieStatsView: some View {
        let stats = cookieManager.getCookieStats()
        
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.blue)
                Text("Stored Cookies")
                    .fontWeight(.medium)
                Spacer()
                Text("\(stats.total)")
                    .foregroundColor(.secondary)
            }
            
            if stats.total > 0 {
                HStack {
                    Spacer().frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Session: \(stats.session)")
                            Text("•")
                            Text("Persistent: \(stats.persistent)")
                            if stats.expired > 0 {
                                Text("•")
                                Text("Expired: \(stats.expired)")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        Text("Total size: \(formatSize(stats.totalSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func clearExpiredCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteExpiredCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteAllCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllWebsiteData() {
        isClearing = true
        Task {
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            await dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast)
            await cookieManager.loadCookies()
            await cacheManager.loadCacheData()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearBrowsingHistory() {
        browserManager.historyManager.clearHistory()
    }
    
    private func clearCache() {
        Task {
            let dataStore = WKWebsiteDataStore.default()
            await dataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: Date.distantPast)
        }
    }
    
        
    // MARK: - Helper Methods
    
    // MARK: - Cache Action Methods
    
    private func clearStaleCache() {
        isClearing = true
        Task {
            await cacheManager.clearStaleCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearDiskCache() {
        isClearing = true
        Task {
            await cacheManager.clearDiskCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearMemoryCache() {
        isClearing = true
        Task {
            await cacheManager.clearMemoryCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllCache() {
        isClearing = true
        Task {
            await cacheManager.clearAllCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    // MARK: - Privacy-Compliant Actions
    
    private func clearThirdPartyCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteThirdPartyCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearHighRiskCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteHighRiskCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func performCookiePrivacyCleanup() {
        isClearing = true
        Task {
            await cookieManager.performPrivacyCleanup()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearPersonalDataCache() {
        isClearing = true
        Task {
            await cacheManager.clearPersonalDataCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func performCachePrivacyCleanup() {
        isClearing = true
        Task {
            await cacheManager.performPrivacyCompliantCleanup()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func adTrackerBlockingSection(trackingBinding: Binding<Bool>) -> some View {
        let manager = browserManager.trackingProtectionManager
        let currentTab = browserManager.currentTabForActiveWindow()
        let currentHost = currentTab?.webView?.url?.host ?? currentTab?.url.host
        let siteState = manager.siteProtectionState(for: currentTab)
        let allowlistedHosts = manager.allowedDomainList
        let currentHostIsAllowed = manager.isDomainAllowed(currentHost)
        let isTemporarilyRelaxed = currentTab.map { manager.isTemporarilyDisabled(tabId: $0.id) } ?? false
        let subscriptions = Array(manager.filterSubscriptions)
        let activeArtifact = manager.activeArtifact
        let currentStats = siteState?.stats

        return VStack(alignment: .leading, spacing: 12) {
            Text("Ad & Tracker Blocking")
                .font(.headline)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Block Ads & Trackers")
                            .font(.headline)
                        Text("Uses WebKit native content blocking to stop common ad and tracker networks, then applies storage restrictions in embedded third-party contexts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Toggle("", isOn: trackingBinding)
                        .labelsHidden()
                }

                HStack(spacing: 8) {
                    privacyStatusChip(
                        title: trackingBinding.wrappedValue ? "Enabled" : "Disabled",
                        systemImage: trackingBinding.wrappedValue ? "checkmark.shield.fill" : "shield.slash",
                        tint: trackingBinding.wrappedValue ? .green : .secondary
                    )

                    privacyStatusChip(
                        title: manager.compilerStatus.title,
                        systemImage: manager.isRuleListInstalled ? "bolt.horizontal.fill" : "clock.arrow.circlepath",
                        tint: compilerTint(for: manager.compilerStatus)
                    )

                    if manager.allowedDomainCount > 0 {
                        privacyStatusChip(
                            title: "\(manager.allowedDomainCount) Allowed Site\(manager.allowedDomainCount == 1 ? "" : "s")",
                            systemImage: "globe.badge.chevron.backward",
                            tint: .purple
                        )
                    }

                    if let activeArtifact {
                        privacyStatusChip(
                            title: "\(activeArtifact.totalRuleCount) Rules",
                            systemImage: "line.3.horizontal.decrease.circle",
                            tint: .blue
                        )
                    }
                }

                Divider()
                    .opacity(0.35)

                VStack(alignment: .leading, spacing: 10) {
                    privacyDetailRow(
                        title: "Embedded Third-Party Storage",
                        value: trackingBinding.wrappedValue ? "Restricted automatically" : "Off while blocker is disabled",
                        systemImage: "externaldrive.badge.icloud"
                    )

                    privacyDetailRow(
                        title: "WebKit Anti-Tracking Protections",
                        value: "Safari/WebKit policies stay active underneath the shell",
                        systemImage: "safari"
                    )

                    if let activeArtifact {
                        privacyDetailRow(
                            title: "Compiled Ruleset",
                            value: "\(activeArtifact.compilerName) • \(activeArtifact.networkRuleCount) network • \(activeArtifact.cosmeticRuleCount) cosmetic • \(activeArtifact.scriptletCandidateCount) scriptlet candidates",
                            systemImage: "shippingbox"
                        )
                    }

                    if isTemporarilyRelaxed {
                        privacyDetailRow(
                            title: "Current Tab Exception",
                            value: "Temporarily relaxed for sign-in compatibility",
                            systemImage: "clock.badge.exclamationmark",
                            accent: .orange
                        )
                    }
                }

                if let currentStats {
                    Divider()
                        .opacity(0.35)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Current Page")
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 8) {
                            privacyStatusChip(
                                title: "\(currentStats.networkRuleCount) network",
                                systemImage: "bolt.horizontal.fill",
                                tint: .blue
                            )
                            privacyStatusChip(
                                title: "\(currentStats.cosmeticRuleCount) cosmetic",
                                systemImage: "eye.slash",
                                tint: .purple
                            )
                            privacyStatusChip(
                                title: "\(currentStats.hiddenElementCount) hidden",
                                systemImage: "trash.slash",
                                tint: .green
                            )
                        }
                    }
                }

                Divider()
                    .opacity(0.35)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Filter Lists")
                                .font(.subheadline.weight(.semibold))
                            Text("Baseline and regional subscriptions are compiled into WebKit content rules and cached locally.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        if let latestUpdate = subscriptions.compactMap(\.lastUpdatedAt).max() {
                            Text("Updated \(relativeDateString(for: latestUpdate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(Array(subscriptions.enumerated()), id: \.element.id) { _, subscription in
                        Toggle(isOn: shieldSubscriptionBinding(for: subscription.id)) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(subscription.title)
                                        .font(.subheadline.weight(.medium))
                                    privacyStatusChip(
                                        title: subscription.subtitle,
                                        systemImage: subscription.category == .core ? "shield.lefthalf.filled" : "globe.europe.africa",
                                        tint: subscription.category == .core ? .blue : .purple
                                    )
                                    if subscription.source == .bundled {
                                        privacyStatusChip(
                                            title: "Bundled",
                                            systemImage: "shippingbox.fill",
                                            tint: .secondary
                                        )
                                    }
                                }

                                Text(subscriptionDetailText(subscription))
                                    .font(.caption)
                                    .foregroundStyle(subscription.lastErrorDescription == nil ? Color.secondary : Color.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    HStack(spacing: 10) {
                        Button {
                            isRefreshingShieldsLists = true
                            Task {
                                await manager.refreshListsAndRecompile(forceRemoteUpdate: true)
                                await MainActor.run {
                                    isRefreshingShieldsLists = false
                                    privacyCardVersion += 1
                                }
                            }
                        } label: {
                            if isRefreshingShieldsLists {
                                Label("Refreshing…", systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label("Refresh Lists", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRefreshingShieldsLists)

                        Button("Restore Bundled Defaults") {
                            manager.restoreDefaultSubscriptions()
                            privacyCardVersion += 1
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let currentHost, !currentHost.isEmpty {
                    Divider()
                        .opacity(0.35)

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Site")
                                .font(.subheadline.weight(.semibold))
                            Text(currentHost)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        Button(currentHostIsAllowed ? "Block on Site" : "Allow on Site") {
                            manager.allowDomain(currentHost, allowed: !currentHostIsAllowed)
                            privacyCardVersion += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(currentHostIsAllowed ? .red : .accentColor)
                    }
                }

                if !allowlistedHosts.isEmpty {
                    Divider()
                        .opacity(0.35)

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Allowed Sites")
                                .font(.subheadline.weight(.semibold))
                            Text(allowlistedHosts.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Menu("Manage Allow List") {
                            ForEach(allowlistedHosts, id: \.self) { host in
                                Button("Block \(host)") {
                                    manager.allowDomain(host, allowed: false)
                                    privacyCardVersion += 1
                                }
                            }

                            Divider()

                            Button("Reset All Exceptions", role: .destructive) {
                                manager.clearAllowedDomains()
                                privacyCardVersion += 1
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .id(privacyCardVersion)
        }
    }

    private func privacyStatusChip(title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private func privacyDetailRow(
        title: String,
        value: String,
        systemImage: String,
        accent: Color = .secondary
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shieldSubscriptionBinding(for subscriptionID: String) -> Binding<Bool> {
        Binding(
            get: {
                browserManager.trackingProtectionManager.filterSubscriptions
                    .first(where: { $0.id == subscriptionID })?
                    .isEnabled ?? false
            },
            set: { enabled in
                browserManager.trackingProtectionManager
                    .setSubscriptionEnabled(subscriptionID, enabled: enabled)
                privacyCardVersion += 1
            }
        )
    }

    private func compilerTint(for status: ShieldsCompilerStatus) -> Color {
        switch status {
        case .idle:
            return .secondary
        case .preparing:
            return .orange
        case .ready:
            return .green
        case .fallback:
            return .blue
        case .failed:
            return .red
        }
    }

    private func relativeDateString(for date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func subscriptionDetailText(_ subscription: FilterSubscription) -> String {
        if let error = subscription.lastErrorDescription, !error.isEmpty {
            return "Last update failed: \(error)"
        }

        var parts: [String] = []
        if let lastUpdatedAt = subscription.lastUpdatedAt {
            parts.append("Updated \(relativeDateString(for: lastUpdatedAt))")
        } else if subscription.source == .remote {
            parts.append("Not refreshed yet")
        }

        if let checksum = subscription.checksum {
            parts.append("Checksum \(checksum.prefix(8))")
        }

        return parts.isEmpty ? "Ready" : parts.joined(separator: " • ")
    }
}

#Preview {
    PrivacySettingsView()
        .environmentObject(BrowserManager())
}
