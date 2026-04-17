//
//  TabGroupsShim.swift
//  Socket
//
//  chrome.tabGroups shim. Apple's WKWebExtension does not expose tab groups,
//  so we project Socket's `TabFolder` model onto Chrome's API surface.
//
//  Mapping:
//    * Chrome `TabGroup` ↔ Socket `TabFolder` (registry-backed Int ↔ UUID)
//    * Chrome `windowId` ↔ Socket `Space.id` (registry-backed Int ↔ UUID)
//    * Chrome `color` ↔ NSColor (palette mapping; nearest-match on read)
//
//  Scope:
//    * `get`, `query` — full read.
//    * `update` — title (rename), color, collapsed.
//    * `move` — within-space reorder via `index` mutation.
//    * Cross-space `move` and `create`/`remove` (which Chrome handles via
//      chrome.tabs.group/.ungroup) are out of scope for this phase; the JS
//      shim doesn't even advertise them. Adding them later is mechanical.
//

import AppKit
import Foundation
import os

@available(macOS 15.4, *)
@MainActor
final class TabGroupsShim: Shim {
    private static let logger = Logger(subsystem: "com.socket.browser", category: "TabGroupsShim")

    let namespaces: Set<String> = ["tabGroups"]

    private unowned let extensionManager: ExtensionManager

    /// Bidirectional registry of Chrome group ids ↔ TabFolder uuids. Chrome
    /// extensions assume small monotonic ints; we hand them out lazily and
    /// reuse on subsequent lookups so the same folder always returns the
    /// same id within a session.
    private var groupIdByFolder: [UUID: Int] = [:]
    private var folderIdByGroup: [Int: UUID] = [:]
    private var nextGroupId: Int = 1

    /// Same registry pattern for windowId ↔ space.
    private var windowIdBySpace: [UUID: Int] = [:]
    private var spaceIdByWindow: [Int: UUID] = [:]
    private var nextWindowId: Int = 1

    /// Chrome's fixed tab-group palette. We map to/from NSColor by named
    /// approximation — Socket's folders use arbitrary NSColors so we pick
    /// the nearest palette entry on read.
    private static let palette: [(name: String, color: NSColor)] = [
        ("grey",   NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)),
        ("blue",   NSColor(srgbRed: 0.10, green: 0.45, blue: 0.96, alpha: 1)),
        ("red",    NSColor(srgbRed: 0.92, green: 0.20, blue: 0.20, alpha: 1)),
        ("yellow", NSColor(srgbRed: 0.98, green: 0.80, blue: 0.10, alpha: 1)),
        ("green",  NSColor(srgbRed: 0.20, green: 0.66, blue: 0.33, alpha: 1)),
        ("pink",   NSColor(srgbRed: 0.95, green: 0.36, blue: 0.66, alpha: 1)),
        ("purple", NSColor(srgbRed: 0.62, green: 0.31, blue: 0.83, alpha: 1)),
        ("cyan",   NSColor(srgbRed: 0.10, green: 0.70, blue: 0.85, alpha: 1)),
        ("orange", NSColor(srgbRed: 0.98, green: 0.55, blue: 0.10, alpha: 1)),
    ]

    init(extensionManager: ExtensionManager) {
        self.extensionManager = extensionManager
    }

    func handle(_ request: ShimRequest) async throws -> Any? {
        switch request.method {
        case "get":    return try get(args: request.args)
        case "query":  return try query(args: request.args)
        case "update": return try update(args: request.args)
        case "move":   return try move(args: request.args)
        default:
            throw ShimError.unknownMethod(namespace: "tabGroups", method: request.method)
        }
    }

    // MARK: - get / query

    private func get(args: [Any]) throws -> [String: Any] {
        guard let groupId = intArg(args.first) else {
            throw ShimError.invalidArgument("get(groupId) requires an integer id")
        }
        guard let (folder, spaceId) = resolveFolder(groupId: groupId) else {
            throw ShimError.notFound("no tab group with id \(groupId)")
        }
        return serialize(folder: folder, spaceId: spaceId)
    }

    private func query(args: [Any]) throws -> [[String: Any]] {
        let filter = (args.first as? [String: Any]) ?? [:]
        let filterWindow = intArg(filter["windowId"])
        let filterTitle = filter["title"] as? String
        let filterColor = filter["color"] as? String
        let filterCollapsed = filter["collapsed"] as? Bool

        guard let tabManager = extensionManager.attachedBrowserManager?.tabManager else { return [] }

        var results: [[String: Any]] = []
        for space in tabManager.spaces {
            let windowId = ensureWindowId(for: space.id)
            if let filterWindow, filterWindow != windowId { continue }

            for folder in tabManager.folders(for: space.id) {
                if let filterTitle, folder.name != filterTitle { continue }
                if let filterColor, nearestPaletteName(for: folder.color) != filterColor { continue }
                if let filterCollapsed, folder.isOpen == filterCollapsed {
                    // Chrome's `collapsed` semantics is the opposite of
                    // Socket's `isOpen`. Skip when they don't match the
                    // negation.
                    continue
                }
                results.append(serialize(folder: folder, spaceId: space.id))
            }
        }
        return results
    }

    // MARK: - update

    private func update(args: [Any]) throws -> [String: Any] {
        guard let groupId = intArg(args.first) else {
            throw ShimError.invalidArgument("update(groupId, props) requires an integer id")
        }
        guard let props = args.count > 1 ? args[1] as? [String: Any] : nil else {
            throw ShimError.invalidArgument("update(groupId, props) requires a properties object")
        }
        guard let (folder, spaceId) = resolveFolder(groupId: groupId) else {
            throw ShimError.notFound("no tab group with id \(groupId)")
        }
        guard let tabManager = extensionManager.attachedBrowserManager?.tabManager else {
            throw ShimError.internalError("no TabManager attached")
        }

        if let title = props["title"] as? String, !title.isEmpty, title != folder.name {
            tabManager.renameFolder(folder.id, newName: title)
        }
        if let colorName = props["color"] as? String,
           let color = paletteColor(named: colorName) {
            folder.color = color
        }
        if let collapsed = props["collapsed"] as? Bool {
            // Socket stores `isOpen` (the opposite). Toggle only when needed.
            if folder.isOpen == collapsed {
                tabManager.toggleFolder(folder.id)
            }
        }
        return serialize(folder: folder, spaceId: spaceId)
    }

    // MARK: - move

    private func move(args: [Any]) throws -> [String: Any] {
        guard let groupId = intArg(args.first) else {
            throw ShimError.invalidArgument("move(groupId, props) requires an integer id")
        }
        guard let props = args.count > 1 ? args[1] as? [String: Any] : nil else {
            throw ShimError.invalidArgument("move(groupId, props) requires a properties object")
        }
        guard let (folder, spaceId) = resolveFolder(groupId: groupId) else {
            throw ShimError.notFound("no tab group with id \(groupId)")
        }
        // Cross-space moves: out of scope for this phase.
        if let targetWindow = intArg(props["windowId"]),
           let currentWindow = windowIdBySpace[spaceId],
           targetWindow != currentWindow {
            throw ShimError.notSupported("Cross-space tab group moves are not yet supported")
        }
        guard let newIndex = intArg(props["index"]) else {
            throw ShimError.invalidArgument("move requires { index } property")
        }
        guard let tabManager = extensionManager.attachedBrowserManager?.tabManager else {
            throw ShimError.internalError("no TabManager attached")
        }

        var folders = tabManager.folders(for: spaceId)
        guard let currentIdx = folders.firstIndex(where: { $0.id == folder.id }) else {
            throw ShimError.notFound("folder not in space")
        }
        let clamped = max(0, min(newIndex, folders.count - 1))
        if clamped != currentIdx {
            let moved = folders.remove(at: currentIdx)
            folders.insert(moved, at: clamped)
            for (i, f) in folders.enumerated() { f.index = i }
        }
        return serialize(folder: folder, spaceId: spaceId)
    }

    // MARK: - Serialization

    private func serialize(folder: TabFolder, spaceId: UUID) -> [String: Any] {
        return [
            "id": ensureGroupId(for: folder.id),
            "title": folder.name,
            "color": nearestPaletteName(for: folder.color),
            "windowId": ensureWindowId(for: spaceId),
            "collapsed": !folder.isOpen,
        ]
    }

    // MARK: - Registry / mapping

    private func ensureGroupId(for folderId: UUID) -> Int {
        if let existing = groupIdByFolder[folderId] { return existing }
        let id = nextGroupId
        nextGroupId += 1
        groupIdByFolder[folderId] = id
        folderIdByGroup[id] = folderId
        return id
    }

    private func ensureWindowId(for spaceId: UUID) -> Int {
        if let existing = windowIdBySpace[spaceId] { return existing }
        let id = nextWindowId
        nextWindowId += 1
        windowIdBySpace[spaceId] = id
        spaceIdByWindow[id] = spaceId
        return id
    }

    private func resolveFolder(groupId: Int) -> (TabFolder, UUID)? {
        guard let folderId = folderIdByGroup[groupId],
              let tabManager = extensionManager.attachedBrowserManager?.tabManager else { return nil }
        for space in tabManager.spaces {
            if let folder = tabManager.folders(for: space.id).first(where: { $0.id == folderId }) {
                return (folder, space.id)
            }
        }
        return nil
    }

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    /// Map a Chrome palette name to NSColor. Returns nil for unknown names
    /// so callers can reject the update rather than silently defaulting.
    private func paletteColor(named name: String) -> NSColor? {
        let lower = name.lowercased()
        return Self.palette.first(where: { $0.name == lower })?.color
    }

    /// Return the closest Chrome palette name for an arbitrary NSColor.
    /// Distance is computed in sRGB space — good enough for palette pinning.
    private func nearestPaletteName(for color: NSColor) -> String {
        guard let target = color.usingColorSpace(.sRGB) else { return "grey" }
        let tr = target.redComponent, tg = target.greenComponent, tb = target.blueComponent
        var best: (name: String, distance: CGFloat) = ("grey", .greatestFiniteMagnitude)
        for entry in Self.palette {
            guard let c = entry.color.usingColorSpace(.sRGB) else { continue }
            let dr = c.redComponent - tr, dg = c.greenComponent - tg, db = c.blueComponent - tb
            let d = dr*dr + dg*dg + db*db
            if d < best.distance { best = (entry.name, d) }
        }
        return best.name
    }
}
