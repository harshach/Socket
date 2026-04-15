//
//  SocketDragItem.swift
//  Socket
//

import Foundation
import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let socketTabItem = UTType(exportedAs: "com.socket.tab-drag-item")
}

extension NSPasteboard.PasteboardType {
    static let socketTabItem = NSPasteboard.PasteboardType("com.socket.tab-drag-item")
}

// MARK: - Drop Zone Identity

enum DropZoneID: Hashable {
    case essentials
    case spacePinned(UUID)
    case spaceRegular(UUID)
    case folder(UUID)

    var asDragContainer: TabDragManager.DragContainer {
        switch self {
        case .essentials: return .essentials
        case .spacePinned(let id): return .spacePinned(id)
        case .spaceRegular(let id): return .spaceRegular(id)
        case .folder(let id): return .folder(id)
        }
    }

    var spaceId: UUID? {
        switch self {
        case .essentials: return nil
        case .spacePinned(let id): return id
        case .spaceRegular(let id): return id
        case .folder: return nil
        }
    }
}

// MARK: - Drag Item

struct SocketDragItem: Codable, Equatable {
    let tabId: UUID
    var title: String
    var urlString: String

    init(tabId: UUID, title: String, urlString: String = "") {
        self.tabId = tabId
        self.title = title
        self.urlString = urlString
    }
}

extension SocketDragItem {
    func writeToPasteboard(_ pasteboard: NSPasteboard) {
        pasteboard.declareTypes([.socketTabItem, .string], owner: nil)
        do {
            let data = try JSONEncoder().encode(self)
            pasteboard.setData(data, forType: .socketTabItem)
        } catch {
            NSLog("SocketDragItem encoding failed: %@", String(describing: error))
        }
        pasteboard.setString(tabId.uuidString, forType: .string)
    }

    static func fromPasteboard(_ pasteboard: NSPasteboard) -> SocketDragItem? {
        guard let data = pasteboard.data(forType: .socketTabItem) else { return nil }
        return try? JSONDecoder().decode(SocketDragItem.self, from: data)
    }
}
