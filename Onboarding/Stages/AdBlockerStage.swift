//
//  AdBlockerStage.swift
//  Socket
//
//  Created by Maciek Bagiński on 17/02/2026.
//

import SwiftUI

struct AdBlockerStage: View {
    @Binding var adBlockerEnabled: Bool

    var body: some View {
        VStack(spacing: 24){
            Text("Ad & Tracker Blocker")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text("Block common ad networks and tracking scripts using WebKit content rules.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 24) {
                layoutOption(image: "adblocker-on", label: "On", enabled: true)
                layoutOption(image: "adblocker-off", label: "Off", enabled: false)
            }
        }
    }

    @ViewBuilder
    private func layoutOption(image: String, label: String, enabled: Bool) -> some View {
        VStack(spacing: 12) {
            Button {
                adBlockerEnabled = enabled
            } label: {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.black.opacity(0.2), lineWidth: adBlockerEnabled == enabled ? 4 : 0)
                    }
                    .animation(.easeInOut(duration: 0.1), value: adBlockerEnabled == enabled)
            }
            .buttonStyle(.plain)

            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
