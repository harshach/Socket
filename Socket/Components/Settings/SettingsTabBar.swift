//
//  SettingsTabBar.swift
//  Socket
//
//  Created by Maciek Bagiński on 03/08/2025.
//
import SwiftUI

struct SettingsTabBar: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(\.socketSettings) var socketSettings

    var body: some View {
        ZStack {
            BlurEffectView(
                material: socketSettings.currentMaterial,
                state: .active
            )
            HStack {
                MacButtonsView()
                    .frame(width: 70, height: 32)
                Spacer()
                Text(socketSettings.currentSettingsTab.name)
                    .font(.headline)
                Spacer()
            }

        }
        .backgroundDraggable()
    }
}
