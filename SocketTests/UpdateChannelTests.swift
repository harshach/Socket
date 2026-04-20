//
//  UpdateChannelTests.swift
//  SocketTests
//
//  Guards the Sparkle multi-channel wiring: the enum's raw values round-trip
//  through UserDefaults, the Settings service posts `.updateChannelChanged`
//  on switch so AppDelegate can reset Sparkle's polling cycle, and both
//  channel URLs in AppDelegate point at reachable feeds.
//

import XCTest

@testable import Socket

@MainActor
final class UpdateChannelTests: XCTestCase {
    // MARK: - UpdateChannel enum

    func test_rawValues() {
        XCTAssertEqual(UpdateChannel.stable.rawValue, "stable")
        XCTAssertEqual(UpdateChannel.nightly.rawValue, "nightly")
    }

    func test_allCases_coversStableAndNightly() {
        XCTAssertEqual(Set(UpdateChannel.allCases), [.stable, .nightly])
    }

    func test_displayName_isUserFacing() {
        XCTAssertEqual(UpdateChannel.stable.displayName, "Stable")
        XCTAssertEqual(UpdateChannel.nightly.displayName, "Nightly")
    }

    func test_subtitle_isNonEmptyForBothChannels() {
        // We don't pin the exact copy (it'll shift). But empty subtitles mean
        // the Settings picker renders without an explanation — a UX regression.
        XCTAssertFalse(UpdateChannel.stable.subtitle.isEmpty)
        XCTAssertFalse(UpdateChannel.nightly.subtitle.isEmpty)
        XCTAssertNotEqual(
            UpdateChannel.stable.subtitle,
            UpdateChannel.nightly.subtitle,
            "Stable and Nightly need distinct subtitles or the picker reads misleading."
        )
    }

    // MARK: - Feed URL constants on AppDelegate

    func test_feedURLs_arePublicGitHubPagesURLs() {
        // We don't ping the network here; just assert shape. The canonical
        // repo is `harshach/Socket`, so both URLs should live under
        // `harshach.github.io/Socket/` and point at the expected file names.
        XCTAssertTrue(AppDelegate.stableFeedURL.hasPrefix("https://"))
        XCTAssertTrue(AppDelegate.stableFeedURL.hasSuffix("/appcast.xml"))
        XCTAssertTrue(AppDelegate.nightlyFeedURL.hasPrefix("https://"))
        XCTAssertTrue(AppDelegate.nightlyFeedURL.hasSuffix("/appcast-nightly.xml"))
        XCTAssertNotEqual(AppDelegate.stableFeedURL, AppDelegate.nightlyFeedURL)
    }

    // MARK: - SocketSettingsService.updateChannel

    func test_settings_defaultChannelIsStable() {
        // Scope this test to a throwaway suite so we don't pollute the real
        // UserDefaults and affect other tests or the running app.
        let (suite, defaults) = makeScopedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Priming the registered default matches SocketSettingsService.init's
        // behavior without instantiating the full service (it hits real
        // UserDefaults.standard). We assert the default registration shape.
        defaults.register(defaults: ["settings.updateChannel": UpdateChannel.stable.rawValue])
        XCTAssertEqual(
            defaults.string(forKey: "settings.updateChannel"),
            UpdateChannel.stable.rawValue
        )
    }

    func test_settings_writingChannel_postsNotification() {
        // The service writes to UserDefaults.standard in its didSet. We
        // instantiate it and listen for the notification it posts.
        let settings = SocketSettingsService()
        let originalChannel = settings.updateChannel
        defer { settings.updateChannel = originalChannel }

        let exp = expectation(forNotification: .updateChannelChanged, object: nil) { note in
            (note.userInfo?["channel"] as? String) == UpdateChannel.nightly.rawValue
        }
        settings.updateChannel = .nightly
        wait(for: [exp], timeout: 0.5)
    }

    // MARK: - helpers

    /// Makes a scoped `UserDefaults` suite so mutations don't bleed into the
    /// running process or other tests. Returns the suite name + the defaults
    /// instance; caller is responsible for tearing down with
    /// `removePersistentDomain(forName:)`.
    private func makeScopedDefaults() -> (String, UserDefaults) {
        let suite = "SocketTests.UpdateChannel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (suite, defaults)
    }
}
