//
//  ProfileManagerTests.swift
//  SocketTests
//
//  Covers ProfileManager's CRUD against an in-memory SwiftData container so
//  the tests don't touch the real ~/Library/Application Support store. Skips
//  WKWebsiteDataStore destruction (async, completion-based, no realistic mock).
//

import SwiftData
import XCTest

@testable import Socket

@MainActor
final class ProfileManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: ProfileManager!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: config)
        context = ModelContext(container)
        manager = ProfileManager(context: context)
    }

    override func tearDown() async throws {
        // Wipe any residue from the gradients UserDefaults so tests don't bleed.
        UserDefaults.standard.removeObject(forKey: "profiles.gradients")
    }

    // MARK: - Empty / seed state

    func test_freshContainer_hasNoProfiles() {
        XCTAssertEqual(manager.profiles.count, 0)
    }

    func test_ensureDefaultProfile_seedsExactlyOneOnEmptyStore() {
        manager.ensureDefaultProfile()
        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(manager.profiles.first?.name, "Default")
    }

    func test_ensureDefaultProfile_isIdempotent() {
        manager.ensureDefaultProfile()
        manager.ensureDefaultProfile()
        manager.ensureDefaultProfile()
        XCTAssertEqual(
            manager.profiles.count, 1,
            "Calling ensureDefaultProfile multiple times must not create duplicates."
        )
    }

    // MARK: - createProfile

    func test_createProfile_appendsToList() {
        let p = manager.createProfile(name: "Work", icon: "briefcase")
        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(p.name, "Work")
        XCTAssertEqual(p.icon, "briefcase")
        XCTAssertEqual(manager.profiles.first?.id, p.id)
    }

    func test_createProfile_assignsSequentialIndices() throws {
        manager.createProfile(name: "A")
        manager.createProfile(name: "B")
        manager.createProfile(name: "C")

        let entities = try context.fetch(
            FetchDescriptor<ProfileEntity>(sortBy: [SortDescriptor(\.index, order: .forward)])
        )
        XCTAssertEqual(entities.map(\.index), [0, 1, 2])
        XCTAssertEqual(entities.map(\.name), ["A", "B", "C"])
    }

    // MARK: - deleteProfile

    func test_deleteProfile_refusesToDeleteLastProfile() {
        let only = manager.createProfile(name: "Only")
        let ok = manager.deleteProfile(only)
        XCTAssertFalse(ok, "Deleting the last profile must be rejected to avoid an empty store.")
        XCTAssertEqual(manager.profiles.count, 1)
    }

    func test_deleteProfile_removesAndReindexes() throws {
        let a = manager.createProfile(name: "A")
        let b = manager.createProfile(name: "B")
        let c = manager.createProfile(name: "C")
        _ = a; _ = c // silence unused

        XCTAssertTrue(manager.deleteProfile(b))
        XCTAssertEqual(manager.profiles.map(\.name), ["A", "C"])

        // Disk entities should also be reindexed 0, 1 (not 0, 2).
        let entities = try context.fetch(
            FetchDescriptor<ProfileEntity>(sortBy: [SortDescriptor(\.index, order: .forward)])
        )
        XCTAssertEqual(entities.map(\.index), [0, 1])
    }

    // MARK: - reload after restart

    func test_loadProfiles_roundTripsThroughSwiftData() throws {
        manager.createProfile(name: "Personal", icon: "person.crop.circle")
        manager.createProfile(name: "Work", icon: "briefcase")

        // Simulate a restart by spinning up a fresh manager on the same container.
        let reloaded = ProfileManager(context: ModelContext(container))
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(reloaded.profiles.map(\.icon), ["person.crop.circle", "briefcase"])
    }

    // MARK: - ephemeral / incognito profile

    func test_createEphemeralProfile_isIsolatedFromPersistedList() {
        let windowId = UUID()
        manager.ensureDefaultProfile()

        let ephemeral = manager.createEphemeralProfile(for: windowId)

        XCTAssertTrue(ephemeral.isEphemeral)
        XCTAssertEqual(
            manager.profiles.count, 1,
            "Ephemeral profiles must NOT show up in the persisted profile list."
        )
        XCTAssertNotNil(manager.ephemeralProfile(for: windowId))
        XCTAssertTrue(manager.isEphemeralProfile(ephemeral.id))
    }

    func test_ephemeralProfile_differentWindowsGetDifferentProfiles() {
        let w1 = UUID()
        let w2 = UUID()
        let p1 = manager.createEphemeralProfile(for: w1)
        let p2 = manager.createEphemeralProfile(for: w2)
        XCTAssertNotEqual(
            p1.id, p2.id,
            "Each incognito window must get its own ephemeral profile so cookies don't leak between them."
        )
    }
}
