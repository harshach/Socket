//
//  HoverTrackingView.swift
//  Socket
//
//  Uses AppKit tracking areas for hover state instead of SwiftUI view-tree hit testing.
//

import AppKit
import SwiftUI

struct HoverTrackingView: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHover = onHover
    }
}

final class HoverTrackingNSView: NSView {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

private struct HoverTrackingModifier: ViewModifier {
    let onHover: (Bool) -> Void

    func body(content: Content) -> some View {
        content.background(HoverTrackingView(onHover: onHover))
    }
}

extension View {
    func onHoverTracking(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(HoverTrackingModifier(onHover: action))
    }
}
