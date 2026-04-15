//
//  SocketAppIcon.swift
//  Socket
//
//  Created by Codex on 14/04/2026.
//

import AppKit
import SwiftUI

enum SocketBranding {
    static var appIconImage: NSImage {
        let appIcon = NSApplication.shared.applicationIconImage

        if let appIcon, appIcon.size.width > 0, appIcon.size.height > 0 {
            return appIcon
        }

        return NSImage(imageLiteralResourceName: "socket-logo-1024")
    }
}

struct SocketAppIcon: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: SocketBranding.appIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
