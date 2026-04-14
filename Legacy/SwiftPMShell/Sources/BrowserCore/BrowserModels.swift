import Foundation

public enum WorkspaceProfileMode: String, Codable, CaseIterable, Sendable {
    case shared
    case isolated
}

public enum WorkspaceKind: String, Codable, CaseIterable, Sendable {
    case regular
    case quickSearch
    case sharedWithMe
}

public enum BrowserPaneFocus: String, Codable, Sendable {
    case main
    case split
}

public struct RestorationState: Codable, Equatable, Sendable {
    public var lastCommittedURL: String
    public var pageTitle: String?

    public init(lastCommittedURL: String, pageTitle: String? = nil) {
        self.lastCommittedURL = lastCommittedURL
        self.pageTitle = pageTitle
    }
}

public struct PageNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public var parentID: UUID?
    public var childIDs: [UUID]
    public var title: String
    public var urlString: String
    public var isPinned: Bool
    public var isLocked: Bool
    public var isSnoozed: Bool
    public var displayTitleOverride: String?
    public var lastActivatedAt: Date
    public var restorationState: RestorationState

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        parentID: UUID? = nil,
        childIDs: [UUID] = [],
        title: String,
        urlString: String,
        isPinned: Bool = false,
        isLocked: Bool = false,
        isSnoozed: Bool = false,
        displayTitleOverride: String? = nil,
        lastActivatedAt: Date = .now,
        restorationState: RestorationState
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.parentID = parentID
        self.childIDs = childIDs
        self.title = title
        self.urlString = urlString
        self.isPinned = isPinned
        self.isLocked = isLocked
        self.isSnoozed = isSnoozed
        self.displayTitleOverride = displayTitleOverride
        self.lastActivatedAt = lastActivatedAt
        self.restorationState = restorationState
    }

    public var url: URL? {
        URL(string: urlString)
    }
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var iconGlyph: String
    public var profileMode: WorkspaceProfileMode
    public var kind: WorkspaceKind
    public var accentColorName: String
    public var isSharedWorkspace: Bool
    public var defaultOpenInSplit: Bool
    public var pinnedExtensionIDs: [String]
    public var rootPageIDs: [UUID]
    public var createdAt: Date
    public var orderIndex: Int

    public init(
        id: UUID = UUID(),
        title: String,
        iconGlyph: String = "🛝",
        profileMode: WorkspaceProfileMode = .shared,
        kind: WorkspaceKind = .regular,
        accentColorName: String = "copper",
        isSharedWorkspace: Bool = false,
        defaultOpenInSplit: Bool = false,
        pinnedExtensionIDs: [String] = [],
        rootPageIDs: [UUID] = [],
        createdAt: Date = .now,
        orderIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.iconGlyph = iconGlyph
        self.profileMode = profileMode
        self.kind = kind
        self.accentColorName = accentColorName
        self.isSharedWorkspace = isSharedWorkspace
        self.defaultOpenInSplit = defaultOpenInSplit
        self.pinnedExtensionIDs = pinnedExtensionIDs
        self.rootPageIDs = rootPageIDs
        self.createdAt = createdAt
        self.orderIndex = orderIndex
    }
}

public struct PaneState: Codable, Equatable, Sendable {
    public var mainPageID: UUID?
    public var splitPageID: UUID?
    public var focusedPane: BrowserPaneFocus
    public var splitProportion: Double

    public init(
        mainPageID: UUID? = nil,
        splitPageID: UUID? = nil,
        focusedPane: BrowserPaneFocus = .main,
        splitProportion: Double = 0.33
    ) {
        self.mainPageID = mainPageID
        self.splitPageID = splitPageID
        self.focusedPane = focusedPane
        self.splitProportion = splitProportion
    }

    public var isSplitVisible: Bool {
        splitPageID != nil
    }

    public func pageID(for pane: BrowserPaneFocus) -> UUID? {
        switch pane {
        case .main:
            return mainPageID
        case .split:
            return splitPageID
        }
    }
}

public struct BrowserStateSnapshot: Codable, Equatable, Sendable {
    public var workspaces: [Workspace]
    public var pages: [PageNode]
    public var activeWorkspaceID: UUID?
    public var paneState: PaneState
    public var isInsertMode: Bool

    public init(
        workspaces: [Workspace],
        pages: [PageNode],
        activeWorkspaceID: UUID?,
        paneState: PaneState,
        isInsertMode: Bool
    ) {
        self.workspaces = workspaces
        self.pages = pages
        self.activeWorkspaceID = activeWorkspaceID
        self.paneState = paneState
        self.isInsertMode = isInsertMode
    }
}

public struct FlattenedPageNode: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let depth: Int
    public let page: PageNode

    public init(page: PageNode, depth: Int) {
        self.id = page.id
        self.page = page
        self.depth = depth
    }
}

public enum URLInputNormalizer {
    public static func normalize(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let directURL = URL(string: trimmed), directURL.scheme != nil {
            return directURL
        }

        if trimmed.contains(" "), let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://www.google.com/search?q=\(escaped)")
        }

        if trimmed.contains(".") {
            return URL(string: "https://\(trimmed)")
        }

        if let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://www.google.com/search?q=\(escaped)")
        }

        return nil
    }
}
