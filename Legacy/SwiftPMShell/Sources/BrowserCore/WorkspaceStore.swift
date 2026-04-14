import Foundation

public enum MoveDirection {
    case up
    case down
}

@MainActor
public final class WorkspaceStore {
    public typealias Observer = @MainActor (WorkspaceStore) -> Void

    private var observers: [UUID: Observer] = [:]

    private(set) public var workspacesByID: [UUID: Workspace]
    private(set) public var workspaceOrder: [UUID]
    private(set) public var pagesByID: [UUID: PageNode]
    public var activeWorkspaceID: UUID?
    public var paneState: PaneState
    public var isInsertMode: Bool

    public init(snapshot: BrowserStateSnapshot = WorkspaceStore.defaultSnapshot()) {
        let orderedWorkspaces = snapshot.workspaces.sorted { lhs, rhs in
            lhs.orderIndex < rhs.orderIndex
        }

        self.workspaceOrder = orderedWorkspaces.map(\.id)
        self.workspacesByID = Dictionary(uniqueKeysWithValues: orderedWorkspaces.map { ($0.id, $0) })
        self.pagesByID = Dictionary(uniqueKeysWithValues: snapshot.pages.map { ($0.id, $0) })
        self.activeWorkspaceID = snapshot.activeWorkspaceID ?? orderedWorkspaces.first?.id
        self.paneState = snapshot.paneState
        self.isInsertMode = snapshot.isInsertMode
        ensureValidState()
    }

    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(self)
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    public func snapshot() -> BrowserStateSnapshot {
        BrowserStateSnapshot(
            workspaces: orderedWorkspaces(),
            pages: Array(pagesByID.values),
            activeWorkspaceID: activeWorkspaceID,
            paneState: paneState,
            isInsertMode: isInsertMode
        )
    }

    public func orderedWorkspaces() -> [Workspace] {
        workspaceOrder.compactMap { workspacesByID[$0] }
    }

    public func workspace(for workspaceID: UUID) -> Workspace? {
        workspacesByID[workspaceID]
    }

    public func page(for pageID: UUID) -> PageNode? {
        pagesByID[pageID]
    }

    public func activeWorkspace() -> Workspace? {
        guard let activeWorkspaceID else {
            return nil
        }
        return workspacesByID[activeWorkspaceID]
    }

    public func flattenedPages(in workspaceID: UUID? = nil) -> [FlattenedPageNode] {
        guard let workspace = workspacesByID[workspaceID ?? activeWorkspaceID ?? UUID()] else {
            return []
        }

        var flattened: [FlattenedPageNode] = []
        for rootPageID in workspace.rootPageIDs {
            appendPage(id: rootPageID, depth: 0, into: &flattened)
        }
        return flattened
    }

    public func selectedPageID(for pane: BrowserPaneFocus) -> UUID? {
        paneState.pageID(for: pane)
    }

    public func selectWorkspace(_ workspaceID: UUID) {
        guard workspacesByID[workspaceID] != nil else {
            return
        }

        activeWorkspaceID = workspaceID

        if paneState.mainPageID == nil || pagesByID[paneState.mainPageID ?? UUID()]?.workspaceID != workspaceID {
            paneState.mainPageID = workspacesByID[workspaceID]?.rootPageIDs.first
        }
        if let splitPageID = paneState.splitPageID,
           pagesByID[splitPageID]?.workspaceID != workspaceID {
            paneState.splitPageID = nil
            paneState.focusedPane = .main
        }

        ensureValidState()
        notifyObservers()
    }

    public func focusPane(_ pane: BrowserPaneFocus) {
        guard pane == .main || paneState.splitPageID != nil else {
            return
        }
        paneState.focusedPane = pane
        notifyObservers()
    }

    public func setInsertMode(_ isInsertMode: Bool) {
        guard self.isInsertMode != isInsertMode else {
            return
        }
        self.isInsertMode = isInsertMode
        notifyObservers()
    }

    public func createWorkspace(
        title: String,
        iconGlyph: String? = nil,
        profileMode: WorkspaceProfileMode = .shared,
        kind: WorkspaceKind = .regular,
        accentColorName: String = "copper",
        isSharedWorkspace: Bool = false,
        defaultOpenInSplit: Bool = false,
        initialURL: URL = URL(string: "https://www.apple.com")!
    ) -> UUID {
        let workspaceID = UUID()
        var workspace = Workspace(
            id: workspaceID,
            title: title,
            iconGlyph: iconGlyph ?? Self.suggestedWorkspaceIcon(orderIndex: workspaceOrder.count),
            profileMode: profileMode,
            kind: kind,
            accentColorName: accentColorName,
            isSharedWorkspace: isSharedWorkspace,
            defaultOpenInSplit: defaultOpenInSplit,
            rootPageIDs: [],
            orderIndex: workspaceOrder.count
        )

        let pageID = UUID()
        let page = PageNode(
            id: pageID,
            workspaceID: workspaceID,
            title: title,
            urlString: initialURL.absoluteString,
            restorationState: RestorationState(lastCommittedURL: initialURL.absoluteString, pageTitle: title)
        )

        workspace.rootPageIDs = [pageID]
        workspacesByID[workspaceID] = workspace
        workspaceOrder.append(workspaceID)
        pagesByID[pageID] = page
        activeWorkspaceID = workspaceID
        paneState.mainPageID = pageID
        paneState.splitPageID = nil
        paneState.focusedPane = .main
        notifyObservers()
        return workspaceID
    }

    public func updateWorkspace(
        _ workspaceID: UUID,
        title: String,
        iconGlyph: String,
        profileMode: WorkspaceProfileMode,
        kind: WorkspaceKind? = nil,
        accentColorName: String? = nil,
        isSharedWorkspace: Bool? = nil,
        defaultOpenInSplit: Bool? = nil,
        pinnedExtensionIDs: [String]? = nil
    ) {
        guard var workspace = workspacesByID[workspaceID] else {
            return
        }

        workspace.title = title
        workspace.iconGlyph = iconGlyph
        workspace.profileMode = profileMode
        if let kind {
            workspace.kind = kind
        }
        if let accentColorName {
            workspace.accentColorName = accentColorName
        }
        if let isSharedWorkspace {
            workspace.isSharedWorkspace = isSharedWorkspace
        }
        if let defaultOpenInSplit {
            workspace.defaultOpenInSplit = defaultOpenInSplit
        }
        if let pinnedExtensionIDs {
            workspace.pinnedExtensionIDs = pinnedExtensionIDs
        }
        workspacesByID[workspaceID] = workspace
        notifyObservers()
    }

    public func selectWorkspaceRelative(offset: Int) {
        guard let activeWorkspaceID,
              let currentIndex = workspaceOrder.firstIndex(of: activeWorkspaceID),
              !workspaceOrder.isEmpty else {
            return
        }

        let targetIndex = max(0, min(workspaceOrder.count - 1, currentIndex + offset))
        selectWorkspace(workspaceOrder[targetIndex])
    }

    public func selectWorkspace(at index: Int) {
        guard workspaceOrder.indices.contains(index) else {
            return
        }
        selectWorkspace(workspaceOrder[index])
    }

    public func deleteWorkspace(_ workspaceID: UUID) {
        guard let workspace = workspacesByID[workspaceID] else {
            return
        }

        for pageID in workspace.rootPageIDs {
            removePageSubtree(pageID)
        }

        workspacesByID[workspaceID] = nil
        workspaceOrder.removeAll { $0 == workspaceID }

        for (offset, id) in workspaceOrder.enumerated() {
            guard var existing = workspacesByID[id] else {
                continue
            }
            existing.orderIndex = offset
            workspacesByID[id] = existing
        }

        if activeWorkspaceID == workspaceID {
            activeWorkspaceID = workspaceOrder.first
        }

        ensureValidState()
        notifyObservers()
    }

    @discardableResult
    public func openPage(
        url: URL,
        title: String? = nil,
        in workspaceID: UUID? = nil,
        parentID: UUID? = nil,
        targetPane: BrowserPaneFocus = .main
    ) -> UUID? {
        guard let workspaceID = workspaceID ?? activeWorkspaceID,
              var workspace = workspacesByID[workspaceID] else {
            return nil
        }

        let pageID = UUID()
        let pageTitle = title ?? hostTitle(for: url)
        let page = PageNode(
            id: pageID,
            workspaceID: workspaceID,
            parentID: parentID,
            title: pageTitle,
            urlString: url.absoluteString,
            restorationState: RestorationState(lastCommittedURL: url.absoluteString, pageTitle: pageTitle)
        )
        pagesByID[pageID] = page

        if let parentID, var parent = pagesByID[parentID] {
            parent.childIDs.append(pageID)
            pagesByID[parentID] = parent
        } else {
            workspace.rootPageIDs.append(pageID)
            workspacesByID[workspaceID] = workspace
        }

        activeWorkspaceID = workspaceID
        assignPage(pageID, to: targetPane)
        notifyObservers()
        return pageID
    }

    @discardableResult
    public func openChildPage(
        from parentID: UUID,
        url: URL,
        title: String? = nil,
        targetPane: BrowserPaneFocus = .main
    ) -> UUID? {
        guard let parent = pagesByID[parentID] else {
            return nil
        }
        return openPage(url: url, title: title, in: parent.workspaceID, parentID: parentID, targetPane: targetPane)
    }

    public func openURLInCurrentContext(_ url: URL, targetPane: BrowserPaneFocus? = nil) {
        guard let workspaceID = activeWorkspaceID else {
            return
        }

        let pane = targetPane ?? paneState.focusedPane
        if let pageID = paneState.pageID(for: pane), var page = pagesByID[pageID] {
            page.urlString = url.absoluteString
            page.title = hostTitle(for: url)
            page.lastActivatedAt = .now
            page.restorationState = RestorationState(lastCommittedURL: url.absoluteString, pageTitle: page.title)
            pagesByID[pageID] = page
            activeWorkspaceID = workspaceID
            paneState.focusedPane = pane
        } else {
            _ = openPage(url: url, in: workspaceID, targetPane: pane)
        }
        notifyObservers()
    }

    public func selectPage(_ pageID: UUID, in pane: BrowserPaneFocus? = nil) {
        guard let selectedPage = pagesByID[pageID] else {
            return
        }

        let destinationPane = pane ?? paneState.focusedPane
        activeWorkspaceID = selectedPage.workspaceID
        assignPage(pageID, to: destinationPane)
        pageTouched(pageID)
        notifyObservers()
    }

    public func selectRelativePage(offset: Int, in pane: BrowserPaneFocus) {
        let flattened = flattenedPages()
        guard !flattened.isEmpty else {
            return
        }

        let currentPageID = selectedPageID(for: pane)
        let currentIndex = flattened.firstIndex(where: { $0.id == currentPageID }) ?? 0
        let targetIndex = max(0, min(flattened.count - 1, currentIndex + offset))
        selectPage(flattened[targetIndex].id, in: pane)
    }

    public func toggleSplit() {
        if paneState.splitPageID != nil {
            paneState.splitPageID = nil
            paneState.focusedPane = .main
        } else {
            let candidate = fallbackSplitCandidate(excluding: paneState.mainPageID)
            paneState.splitPageID = candidate
            if candidate != nil {
                paneState.focusedPane = .split
            }
        }
        notifyObservers()
    }

    public func openSelectedPageInSplit() {
        let selected = paneState.pageID(for: paneState.focusedPane)
        guard let selected, selected != paneState.mainPageID else {
            return
        }
        paneState.splitPageID = selected
        paneState.focusedPane = .split
        notifyObservers()
    }

    public func closeSplit() {
        paneState.splitPageID = nil
        paneState.focusedPane = .main
        notifyObservers()
    }

    public func setSplitProportion(_ proportion: Double) {
        let clamped = min(max(proportion, 0.2), 0.8)
        guard paneState.splitProportion != clamped else {
            return
        }
        paneState.splitProportion = clamped
        notifyObservers()
    }

    public func swapMainAndSplit() {
        guard let splitPageID = paneState.splitPageID else {
            return
        }
        let previousMain = paneState.mainPageID
        paneState.mainPageID = splitPageID
        paneState.splitPageID = previousMain
        paneState.focusedPane = paneState.focusedPane == .main ? .split : .main
        ensureValidState()
        notifyObservers()
    }

    public func closeSelectedPage(in pane: BrowserPaneFocus? = nil) {
        guard let pageID = selectedPageID(for: pane ?? paneState.focusedPane) else {
            return
        }
        closePage(pageID)
    }

    public func closePage(_ pageID: UUID) {
        guard pagesByID[pageID] != nil else {
            return
        }

        let subtree = Set(subtreeIDs(from: pageID))
        let fallbackForMain = subtree.contains(paneState.mainPageID ?? UUID()) ? fallbackPageID(afterClosing: pageID) : paneState.mainPageID
        let fallbackForSplit = subtree.contains(paneState.splitPageID ?? UUID()) ? fallbackPageID(afterClosing: pageID, excluding: fallbackForMain) : paneState.splitPageID

        removePageSubtree(pageID)

        paneState.mainPageID = fallbackForMain
        paneState.splitPageID = fallbackForSplit
        if paneState.splitPageID == nil && paneState.focusedPane == .split {
            paneState.focusedPane = .main
        }

        if let activeWorkspaceID, workspacesByID[activeWorkspaceID]?.rootPageIDs.isEmpty == true {
            paneState.mainPageID = nil
        }

        pageTouched(fallbackForMain)
        pageTouched(fallbackForSplit)
        ensureValidState()
        notifyObservers()
    }

    public func movePage(_ pageID: UUID, direction: MoveDirection) {
        guard let page = pagesByID[pageID] else {
            return
        }

        if let parentID = page.parentID, var parent = pagesByID[parentID] {
            guard let index = parent.childIDs.firstIndex(of: pageID) else {
                return
            }
            let destination = direction == .up ? index - 1 : index + 1
            guard parent.childIDs.indices.contains(destination) else {
                return
            }
            parent.childIDs.swapAt(index, destination)
            pagesByID[parentID] = parent
        } else if var workspace = workspacesByID[page.workspaceID],
                  let index = workspace.rootPageIDs.firstIndex(of: pageID) {
            let destination = direction == .up ? index - 1 : index + 1
            guard workspace.rootPageIDs.indices.contains(destination) else {
                return
            }
            workspace.rootPageIDs.swapAt(index, destination)
            workspacesByID[page.workspaceID] = workspace
        }

        notifyObservers()
    }

    public func indentPage(_ pageID: UUID) {
        guard let page = pagesByID[pageID], page.parentID == nil,
              var workspace = workspacesByID[page.workspaceID],
              let index = workspace.rootPageIDs.firstIndex(of: pageID),
              index > 0 else {
            return
        }

        let newParentID = workspace.rootPageIDs[index - 1]
        workspace.rootPageIDs.remove(at: index)
        workspacesByID[page.workspaceID] = workspace

        var updatedPage = page
        updatedPage.parentID = newParentID
        pagesByID[pageID] = updatedPage

        if var parent = pagesByID[newParentID] {
            parent.childIDs.append(pageID)
            pagesByID[newParentID] = parent
        }

        notifyObservers()
    }

    public func outdentPage(_ pageID: UUID) {
        guard let page = pagesByID[pageID],
              let parentID = page.parentID,
              let parent = pagesByID[parentID],
              var workspace = workspacesByID[page.workspaceID] else {
            return
        }

        var updatedParent = parent
        updatedParent.childIDs.removeAll { $0 == pageID }
        pagesByID[parentID] = updatedParent

        var updatedPage = page
        updatedPage.parentID = nil
        pagesByID[pageID] = updatedPage

        if let parentIndex = workspace.rootPageIDs.firstIndex(of: parentID) {
            workspace.rootPageIDs.insert(pageID, at: parentIndex + 1)
        } else {
            workspace.rootPageIDs.append(pageID)
        }
        workspacesByID[workspace.id] = workspace
        notifyObservers()
    }

    public func updatePageNavigation(pageID: UUID, title: String?, url: URL?) {
        guard var page = pagesByID[pageID] else {
            return
        }

        if let url {
            page.urlString = url.absoluteString
            page.restorationState.lastCommittedURL = url.absoluteString
        }
        if let title, !title.isEmpty {
            page.title = title
            page.restorationState.pageTitle = title
        }
        page.lastActivatedAt = .now
        pagesByID[pageID] = page
        notifyObservers()
    }

    public func setPagePinned(_ pageID: UUID, isPinned: Bool) {
        guard var page = pagesByID[pageID],
              page.isPinned != isPinned else {
            return
        }
        page.isPinned = isPinned
        pagesByID[pageID] = page
        notifyObservers()
    }

    public func setPageLocked(_ pageID: UUID, isLocked: Bool) {
        guard var page = pagesByID[pageID],
              page.isLocked != isLocked else {
            return
        }
        page.isLocked = isLocked
        pagesByID[pageID] = page
        notifyObservers()
    }

    public func setPageSnoozed(_ pageID: UUID, isSnoozed: Bool) {
        guard var page = pagesByID[pageID],
              page.isSnoozed != isSnoozed else {
            return
        }
        page.isSnoozed = isSnoozed
        pagesByID[pageID] = page
        notifyObservers()
    }

    public func setPageDisplayTitle(_ pageID: UUID, displayTitle: String?) {
        guard var page = pagesByID[pageID],
              page.displayTitleOverride != displayTitle else {
            return
        }
        page.displayTitleOverride = displayTitle
        pagesByID[pageID] = page
        notifyObservers()
    }

    public func fallbackSplitCandidate(excluding excludedPageID: UUID?) -> UUID? {
        flattenedPages().first(where: { $0.id != excludedPageID })?.id
    }

    public static func defaultSnapshot() -> BrowserStateSnapshot {
        let workspaceID = UUID()
        let quickSearchWorkspaceID = UUID()
        let sharedWorkspaceID = UUID()
        let pageID = UUID()
        let initialURL = URL(string: "https://www.apple.com")!

        let page = PageNode(
            id: pageID,
            workspaceID: workspaceID,
            title: "Start",
            urlString: initialURL.absoluteString,
            restorationState: RestorationState(lastCommittedURL: initialURL.absoluteString, pageTitle: "Start")
        )

        let workspace = Workspace(
            id: workspaceID,
            title: "Playground",
            iconGlyph: "🛝",
            profileMode: .shared,
            kind: .regular,
            accentColorName: "copper",
            rootPageIDs: [pageID],
            orderIndex: 0
        )

        let quickSearchWorkspace = Workspace(
            id: quickSearchWorkspaceID,
            title: "Quick Search",
            iconGlyph: "⚡️",
            profileMode: .shared,
            kind: .quickSearch,
            accentColorName: "blue",
            rootPageIDs: [],
            orderIndex: 1
        )

        let sharedWorkspace = Workspace(
            id: sharedWorkspaceID,
            title: "Shared with me",
            iconGlyph: "👥",
            profileMode: .shared,
            kind: .sharedWithMe,
            accentColorName: "violet",
            isSharedWorkspace: true,
            rootPageIDs: [],
            orderIndex: 2
        )

        return BrowserStateSnapshot(
            workspaces: [workspace, quickSearchWorkspace, sharedWorkspace],
            pages: [page],
            activeWorkspaceID: workspaceID,
            paneState: PaneState(mainPageID: pageID, splitPageID: nil, focusedPane: .main, splitProportion: 0.33),
            isInsertMode: false
        )
    }

    public static func suggestedWorkspaceIcon(orderIndex: Int) -> String {
        let glyphs = ["🛝", "💼", "🎨", "🚀", "📚", "⚡️", "🏃", "🧠"]
        return glyphs[orderIndex % glyphs.count]
    }

    private func appendPage(id pageID: UUID, depth: Int, into flattened: inout [FlattenedPageNode]) {
        guard let page = pagesByID[pageID] else {
            return
        }

        flattened.append(FlattenedPageNode(page: page, depth: depth))
        for childID in page.childIDs {
            appendPage(id: childID, depth: depth + 1, into: &flattened)
        }
    }

    private func assignPage(_ pageID: UUID, to pane: BrowserPaneFocus) {
        guard pagesByID[pageID] != nil else {
            return
        }

        switch pane {
        case .main:
            if paneState.splitPageID == pageID {
                paneState.splitPageID = nil
            }
            paneState.mainPageID = pageID
        case .split:
            guard paneState.mainPageID != pageID else {
                return
            }
            paneState.splitPageID = pageID
        }

        paneState.focusedPane = pane
        pageTouched(pageID)
    }

    private func hostTitle(for url: URL) -> String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }

    private func pageTouched(_ pageID: UUID?) {
        guard let pageID, var page = pagesByID[pageID] else {
            return
        }
        page.lastActivatedAt = .now
        pagesByID[pageID] = page
    }

    private func subtreeIDs(from pageID: UUID) -> [UUID] {
        guard let page = pagesByID[pageID] else {
            return []
        }

        return [pageID] + page.childIDs.flatMap(subtreeIDs(from:))
    }

    private func removePageSubtree(_ pageID: UUID) {
        guard let page = pagesByID[pageID] else {
            return
        }

        for childID in page.childIDs {
            removePageSubtree(childID)
        }

        if let parentID = page.parentID, var parent = pagesByID[parentID] {
            parent.childIDs.removeAll { $0 == pageID }
            pagesByID[parentID] = parent
        } else if var workspace = workspacesByID[page.workspaceID] {
            workspace.rootPageIDs.removeAll { $0 == pageID }
            workspacesByID[workspace.id] = workspace
        }

        pagesByID[pageID] = nil
    }

    private func fallbackPageID(afterClosing pageID: UUID, excluding excludedPageID: UUID? = nil) -> UUID? {
        guard let page = pagesByID[pageID] else {
            return nil
        }

        let removedSet = Set(subtreeIDs(from: pageID))
        func firstRemaining(_ candidates: [UUID]) -> UUID? {
            candidates.first { !removedSet.contains($0) && $0 != excludedPageID }
        }

        if let parentID = page.parentID, let parent = pagesByID[parentID],
           let siblingIndex = parent.childIDs.firstIndex(of: pageID) {
            let nextSiblings = Array(parent.childIDs.dropFirst(siblingIndex + 1))
            if let next = firstRemaining(nextSiblings) {
                return next
            }

            let previousSiblings = Array(parent.childIDs.prefix(siblingIndex).reversed())
            if let previous = firstRemaining(previousSiblings) {
                return previous
            }

            if parentID != excludedPageID {
                return parentID
            }
        } else if let workspace = workspacesByID[page.workspaceID],
                  let rootIndex = workspace.rootPageIDs.firstIndex(of: pageID) {
            let nextRoots = Array(workspace.rootPageIDs.dropFirst(rootIndex + 1))
            if let next = firstRemaining(nextRoots) {
                return next
            }

            let previousRoots = Array(workspace.rootPageIDs.prefix(rootIndex).reversed())
            if let previous = firstRemaining(previousRoots) {
                return previous
            }
        }

        return flattenedPages(in: page.workspaceID).map(\.id).first { !removedSet.contains($0) && $0 != excludedPageID }
    }

    private func ensureValidState() {
        if let activeWorkspaceID, workspacesByID[activeWorkspaceID] == nil {
            self.activeWorkspaceID = workspaceOrder.first
        }

        if let mainPageID = paneState.mainPageID, pagesByID[mainPageID] == nil {
            paneState.mainPageID = nil
        }
        if let splitPageID = paneState.splitPageID, pagesByID[splitPageID] == nil {
            paneState.splitPageID = nil
        }
        if paneState.mainPageID == nil, let activeWorkspace = activeWorkspace() {
            paneState.mainPageID = activeWorkspace.rootPageIDs.first
        }
        if paneState.splitPageID == nil, paneState.focusedPane == .split {
            paneState.focusedPane = .main
        }
        if paneState.mainPageID == paneState.splitPageID {
            paneState.splitPageID = nil
        }
    }

    private func notifyObservers() {
        ensureValidState()
        for observer in observers.values {
            observer(self)
        }
    }
}
