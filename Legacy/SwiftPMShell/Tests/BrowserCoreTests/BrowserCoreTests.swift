import BrowserCore
import Foundation
import Testing

@MainActor
struct BrowserCoreTests {
    @Test
    func childPagesFlattenInTreeOrder() throws {
        let store = WorkspaceStore()
        let rootID = try #require(store.paneState.mainPageID)

        let childID = try #require(store.openChildPage(
            from: rootID,
            url: URL(string: "https://example.com/child")!
        ))
        _ = store.openChildPage(from: childID, url: URL(string: "https://example.com/grandchild")!)

        let flattened = store.flattenedPages()
        #expect(flattened.count == 3)
        #expect(flattened[0].id == rootID)
        #expect(flattened[1].id == childID)
        #expect(flattened[1].depth == 1)
        #expect(flattened[2].depth == 2)
    }

    @Test
    func closingSelectedPageFallsBackToNextSiblingThenParent() throws {
        let store = WorkspaceStore()
        let firstRoot = try #require(store.paneState.mainPageID)
        let secondRoot = try #require(store.openPage(url: URL(string: "https://example.com/second")!))

        store.selectPage(firstRoot)
        store.closePage(firstRoot)

        #expect(store.paneState.mainPageID == secondRoot)
    }

    @Test
    func indentAndOutdentPreserveTreeIntegrity() throws {
        let store = WorkspaceStore()
        let firstRoot = try #require(store.paneState.mainPageID)
        let secondRoot = try #require(store.openPage(url: URL(string: "https://example.com/second")!))

        store.indentPage(secondRoot)
        let parentAfterIndent = try #require(store.page(for: secondRoot)?.parentID)
        #expect(parentAfterIndent == firstRoot)

        store.outdentPage(secondRoot)
        #expect(store.page(for: secondRoot)?.parentID == nil)
        let rootIDs = store.activeWorkspace()?.rootPageIDs ?? []
        #expect(rootIDs.contains(secondRoot))
    }

    @Test
    func sharedAndIsolatedProfilesStaySeparated() throws {
        let store = WorkspaceStore()
        let firstWorkspaceID = try #require(store.activeWorkspaceID)
        let sharedWorkspace = try #require(store.workspace(for: firstWorkspaceID))

        let isolatedWorkspaceID = store.createWorkspace(title: "Isolated", profileMode: .isolated)
        let isolatedWorkspace = try #require(store.workspace(for: isolatedWorkspaceID))

        let sessionManager = BrowserSessionManager()
        let sharedA = sessionManager.profile(for: sharedWorkspace)
        let sharedB = sessionManager.profile(for: sharedWorkspace)
        let isolated = sessionManager.profile(for: isolatedWorkspace)

        #expect(sharedA.websiteDataStore === sharedB.websiteDataStore)
        #expect(sharedA.websiteDataStore !== isolated.websiteDataStore)
        #expect(sharedA.isEphemeral == false)
        #expect(isolated.isEphemeral == true)
    }

    @Test
    func workspaceConfigurationCanBeUpdated() throws {
        let store = WorkspaceStore()
        let workspaceID = try #require(store.activeWorkspaceID)

        store.updateWorkspace(workspaceID, title: "Research", iconGlyph: "🔬", profileMode: .isolated)

        let updated = try #require(store.workspace(for: workspaceID))
        #expect(updated.title == "Research")
        #expect(updated.iconGlyph == "🔬")
        #expect(updated.profileMode == .isolated)
    }

    @Test
    func residencyEvictsLeastRecentUnprotectedPages() {
        let controller = PageResidencyController(maxLivePages: 3)
        let pageIDs = (0..<5).map { _ in UUID() }

        pageIDs.forEach(controller.touch)
        let evicted = controller.reconcile(protectedIDs: Set([pageIDs[4], pageIDs[3]]))

        #expect(evicted == [pageIDs[0], pageIDs[1]])
        #expect(controller.currentlyLivePageIDs() == [pageIDs[2], pageIDs[3], pageIDs[4]])
    }
}
