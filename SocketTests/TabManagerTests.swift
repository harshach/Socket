//
//  TabManagerTests.swift
//  SocketTests
//
//  Covers TabManager's CRUD + tab-closure undo lifecycle against an
//  in-memory SwiftData container with a nil BrowserManager. We avoid
//  testing methods that require a live `BrowserManager` (split view,
//  window validation, compositor) — those need a separate integration
//  harness.
//

import SwiftData
import XCTest

@testable import Socket

@MainActor
final class TabManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: TabManager!
    private let testProfileId = UUID()

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: config)
        context = ModelContext(container)
        manager = TabManager(browserManager: nil, context: context)
        // Init schedules `loadFromStore()` on the MainActor; wait for it to
        // post its completion notification before tests proceed. Without this
        // we race the seed-default-space step.
        let loaded = expectation(forNotification: .tabManagerDidLoadInitialData, object: nil)
        await fulfillment(of: [loaded], timeout: 2.0)
    }

    // MARK: - empty state — TabManager seeds a default "Personal" space on
    // first launch so the user is never staring at an empty sidebar. We
    // verify that explicit invariant here.

    func test_freshManager_seedsOneDefaultSpace() {
        XCTAssertEqual(
            manager.spaces.count, 1,
            "TabManager guarantees at least one space exists post-load to keep the sidebar usable."
        )
        XCTAssertNotNil(manager.currentSpace)
        XCTAssertEqual(manager.currentSpace?.name, "Personal")
        XCTAssertFalse(manager.hasRecentlyClosedTabs())
    }

    // MARK: - space lifecycle

    func test_createSpace_addsAlongsideSeedAndActivates() {
        let baseline = manager.spaces.count   // 1 (the seed)
        let space = manager.createSpace(name: "Work", profileId: testProfileId)
        XCTAssertEqual(manager.spaces.count, baseline + 1)
        XCTAssertEqual(manager.currentSpace?.id, space.id, "Newly-created space becomes active.")
        XCTAssertEqual(space.profileId, testProfileId)
    }

    func test_createSpace_twice_addsBothBesideSeed() {
        let baseline = manager.spaces.count
        manager.createSpace(name: "A", profileId: testProfileId)
        manager.createSpace(name: "B", profileId: testProfileId)
        XCTAssertEqual(manager.spaces.count, baseline + 2)
        XCTAssertEqual(manager.spaces.suffix(2).map(\.name), ["A", "B"])
    }

    // MARK: - tab add / remove

    func test_addTab_appearsInTabsForCurrentSpace() {
        let space = manager.createSpace(name: "S", profileId: testProfileId)
        // createSpace runs `createNewTab` itself; snapshot first so the
        // assertion isn't coupled to that implementation detail.
        let baseline = manager.tabs.count

        let tab = Tab(
            url: URL(string: "https://example.com")!,
            name: "Example",
            spaceId: space.id,
            index: 99
        )
        manager.addTab(tab)

        XCTAssertEqual(manager.tabs.count, baseline + 1)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == tab.id }))
    }

    func test_removeTab_removesAndTracksForUndo() {
        let space = manager.createSpace(name: "S", profileId: testProfileId)
        let tab = Tab(
            url: URL(string: "https://example.com")!,
            name: "Example",
            spaceId: space.id,
            index: 99
        )
        manager.addTab(tab)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == tab.id }))

        manager.removeTab(tab.id)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == tab.id }))
        XCTAssertTrue(
            manager.hasRecentlyClosedTabs(),
            "Removing a tab must enqueue it for the undo toast — without that the Cmd+Shift+T flow is broken."
        )
    }

    func test_removeTab_unknownId_isANoop() {
        manager.createSpace(name: "S", profileId: testProfileId)
        let baseline = manager.tabs.count
        manager.removeTab(UUID())
        XCTAssertEqual(manager.tabs.count, baseline)
        XCTAssertFalse(manager.hasRecentlyClosedTabs())
    }

    // MARK: - undo

    func test_undoCloseTab_restoresATabWithTheClosedURL() {
        // `trackRecentlyClosedTab` deliberately makes a deep copy with a new
        // UUID so old WKWebView state can't leak into the restored tab. So
        // we can't assert id equality — we assert by URL + name instead.
        guard let originalTab = manager.currentTab else {
            XCTFail("setUp should have seeded a default current tab"); return
        }
        manager.clearRecentlyClosedTabs()
        let originalUrl = originalTab.url
        let originalName = originalTab.name
        let originalCount = manager.tabs.count

        manager.removeTab(originalTab.id)
        XCTAssertTrue(manager.hasRecentlyClosedTabs())
        XCTAssertEqual(manager.tabs.count, originalCount - 1)

        manager.undoCloseTab()

        XCTAssertEqual(
            manager.tabs.count, originalCount,
            "Undo must put the tab count back to where it was — exactly one restoration."
        )
        XCTAssertTrue(
            manager.tabs.contains(where: { $0.url == originalUrl && $0.name == originalName }),
            "The restored tab carries the same URL + name as the closed one (its id is intentionally fresh)."
        )
        XCTAssertFalse(
            manager.hasRecentlyClosedTabs(),
            "Stack drains after undo of its only entry."
        )
    }

    func test_clearRecentlyClosedTabs_emptiesUndoStack() {
        let space = manager.createSpace(name: "S", profileId: testProfileId)
        let tab = Tab(
            url: URL(string: "https://example.com")!,
            name: "Tmp",
            spaceId: space.id
        )
        manager.addTab(tab)
        manager.removeTab(tab.id)
        XCTAssertTrue(manager.hasRecentlyClosedTabs())

        manager.clearRecentlyClosedTabs()
        XCTAssertFalse(manager.hasRecentlyClosedTabs())
    }
}
