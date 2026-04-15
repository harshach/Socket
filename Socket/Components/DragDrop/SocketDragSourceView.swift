//
//  SocketDragSourceView.swift
//  Socket
//

import SwiftUI
import AppKit

// MARK: - Drag Source Coordinator (NSDraggingSource)

@MainActor
final class SocketDragSourceCoordinator: NSObject, NSDraggingSource {
    var item: SocketDragItem
    var tab: Tab?
    var zoneID: DropZoneID
    var index: Int
    let manager: SocketDragSessionManager

    init(item: SocketDragItem, tab: Tab?, zoneID: DropZoneID, index: Int, manager: SocketDragSessionManager) {
        self.item = item
        self.tab = tab
        self.zoneID = zoneID
        self.index = index
        self.manager = manager
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? .move : .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        manager.updateCursorScreenPosition(screenPoint)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Task { @MainActor in
            if operation == [] {
                manager.cancelDrag()
            }
        }
    }
}

// MARK: - DragSourceNSView

final class SocketDragSourceNSView: NSView {
    var coordinator: SocketDragSourceCoordinator?
    private(set) var registrationId: UUID?

    func registerWithManager() {
        guard let coordinator = coordinator else { return }
        let id = UUID()
        registrationId = id
        coordinator.manager.registerDragSource(self, id: id)
    }

    func unregisterFromManager() {
        guard let id = registrationId, let coordinator = coordinator else { return }
        coordinator.manager.unregisterDragSource(id: id)
        registrationId = nil
    }

    func initiateDrag(with event: NSEvent) {
        guard let coordinator = coordinator, let tab = coordinator.tab else { return }

        coordinator.manager.beginDrag(
            item: coordinator.item,
            tab: tab,
            from: coordinator.zoneID,
            at: coordinator.index
        )

        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(coordinator.item) {
            pasteboardItem.setData(data, forType: .socketTabItem)
        }
        pasteboardItem.setString(coordinator.item.tabId.uuidString, forType: .string)

        let transparentImage = NSImage(size: NSSize(width: 1, height: 1))

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            NSRect(x: 0, y: 0, width: 1, height: 1),
            contents: transparentImage
        )

        beginDraggingSession(with: [draggingItem], event: event, source: coordinator)
    }
}

// MARK: - Invisible Anchor (NSViewRepresentable)

private struct DragSourceAnchor: NSViewRepresentable {
    let item: SocketDragItem
    let tab: Tab?
    let zoneID: DropZoneID
    let index: Int
    let manager: SocketDragSessionManager

    func makeNSView(context: Context) -> SocketDragSourceNSView {
        let view = SocketDragSourceNSView()
        view.coordinator = context.coordinator
        view.registerWithManager()
        return view
    }

    func updateNSView(_ nsView: SocketDragSourceNSView, context: Context) {
        context.coordinator.item = item
        context.coordinator.tab = tab
        context.coordinator.zoneID = zoneID
        context.coordinator.index = index
    }

    static func dismantleNSView(_ nsView: SocketDragSourceNSView, coordinator: SocketDragSourceCoordinator) {
        nsView.unregisterFromManager()
    }

    func makeCoordinator() -> SocketDragSourceCoordinator {
        SocketDragSourceCoordinator(item: item, tab: tab, zoneID: zoneID, index: index, manager: manager)
    }
}

// MARK: - SocketDragSourceView

struct SocketDragSourceView<Content: View>: View {
    let item: SocketDragItem
    let tab: Tab?
    let zoneID: DropZoneID
    let index: Int
    let manager: SocketDragSessionManager
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                DragSourceAnchor(
                    item: item,
                    tab: tab,
                    zoneID: zoneID,
                    index: index,
                    manager: manager
                )
            )
    }
}
