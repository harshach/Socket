//
//  HelloStage.swift
//  Socket
//
//  Created by Maciek Bagiński on 19/02/2026.
//

import SwiftUI

struct HelloStage: View {

    var body: some View {
        VStack(spacing: 24) {
            Text("Say Hi to Socket")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            SocketAppIcon(size: 128)
            Text("Your new open-source browser.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
