import Foundation
import WebKit

public struct BrowserSessionProfile {
    public let websiteDataStore: WKWebsiteDataStore
    public let isEphemeral: Bool

    public init(websiteDataStore: WKWebsiteDataStore, isEphemeral: Bool) {
        self.websiteDataStore = websiteDataStore
        self.isEphemeral = isEphemeral
    }
}

@MainActor
public final class BrowserSessionManager {
    private let sharedDataStore = WKWebsiteDataStore.default()
    private var isolatedProfiles: [UUID: BrowserSessionProfile] = [:]
    public var configurationHandler: ((WKWebViewConfiguration) -> Void)?

    public init() {}

    public func profile(for workspace: Workspace) -> BrowserSessionProfile {
        switch workspace.profileMode {
        case .shared:
            return BrowserSessionProfile(
                websiteDataStore: sharedDataStore,
                isEphemeral: false
            )
        case .isolated:
            if let cached = isolatedProfiles[workspace.id] {
                return cached
            }

            // WebKit's public API exposes the shared persistent store and an isolated
            // nonpersistent store. This MVP uses the nonpersistent store to guarantee
            // cookie separation per isolated workspace.
            let profile = BrowserSessionProfile(
                websiteDataStore: .nonPersistent(),
                isEphemeral: true
            )
            isolatedProfiles[workspace.id] = profile
            return profile
        }
    }

    public func configuration(for workspace: Workspace) -> WKWebViewConfiguration {
        let profile = profile(for: workspace)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.websiteDataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.preferences.isTextInteractionEnabled = true
        configurationHandler?(configuration)
        return configuration
    }
}
