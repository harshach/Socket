//
//  MiniWindowToolbar.swift
//  Socket
//
//  Created by Jonathan Caudill on 26/08/2025.
//

import AppKit
import SwiftUI

struct MiniWindowToolbar: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var session: MiniWindowSession
    let adoptAction: () -> Void
    let dismissAction: () -> Void

    private var resolvedToolbarColor: NSColor {
        session.toolbarColor
            ?? (colorScheme == .dark ? .windowBackgroundColor : .windowBackgroundColor)
    }

    private var toolbarBackgroundColor: Color {
        Color(nsColor: resolvedToolbarColor)
    }

    private var foregroundColor: Color {
        resolvedToolbarColor.isPerceivedDark
            ? Color.white.opacity(0.88)
            : Color.black.opacity(0.78)
    }

    private var secondaryForegroundColor: Color {
        resolvedToolbarColor.isPerceivedDark
            ? Color.white.opacity(0.58)
            : Color.black.opacity(0.42)
    }

    private var linkAccentColor: Color {
        resolvedToolbarColor.isPerceivedDark
            ? Color.white.opacity(0.72)
            : Color.black.opacity(0.62)
    }

    private var bottomBorderColor: Color {
        adjustColorBrightness(
            Color(nsColor: resolvedToolbarColor),
            factor: resolvedToolbarColor.isPerceivedDark ? 1.22 : 0.86
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            titleGroup
            Spacer(minLength: 12)
            actionGroup
        }
        .padding(.horizontal, TopBarMetrics.horizontalPadding)
        .padding(.vertical, TopBarMetrics.verticalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: TopBarMetrics.height)
        .background(toolbarBackgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(bottomBorderColor)
                .frame(height: 1)
        }
    }

    private var titleGroup: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(linkAccentColor)

            Text(displayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("· \(session.currentSpaceLabel)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryForegroundColor)
                .lineLimit(1)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var actionGroup: some View {
        HStack(spacing: 6) {
            Button(action: adoptAction) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Open")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(RectNavButtonStyle())
            .controlSize(.small)
            .foregroundStyle(foregroundColor)
            .help("Open in \(session.selectedDestinationMenuTitle)")
            .keyboardShortcut("o", modifiers: [])

            Menu {
                Button(action: session.selectCurrentSpace) {
                    Label(
                        session.currentSpaceMenuTitle,
                        systemImage: session.selectedDestination == nil ? "checkmark" : "circle"
                    )
                }

                if !session.availableDestinations.isEmpty {
                    Divider()
                    ForEach(session.availableDestinations) { destination in
                        Button(action: { session.selectDestination(destination) }) {
                            Label(
                                destination.menuTitle,
                                systemImage: session.isSelected(destination) ? "checkmark" : "circle"
                            )
                        }
                    }
                }

                Divider()

                Button(action: session.toggleAlwaysUseExternalView) {
                    Label(
                        "Always use this behavior",
                        systemImage: session.alwaysUseExternalView ? "checkmark.circle.fill" : "circle"
                    )
                }
            } label: {
                HStack(spacing: 6) {
                    Text(session.selectedDestinationLabel)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .menuStyle(.button)
            .buttonStyle(RectNavButtonStyle())
            .controlSize(.small)
            .foregroundStyle(foregroundColor)
            .help("Choose where Open sends this page")

            Button(action: dismissAction) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(NavButtonStyle(size: .small))
            .foregroundStyle(foregroundColor)
            .help("Close external view")
            .keyboardShortcut("d", modifiers: [])
        }
    }

    private var displayTitle: String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != session.currentURL.absoluteString {
            return title
        }
        return session.currentURL.host ?? session.currentURL.absoluteString
    }

    private func adjustColorBrightness(_ color: Color, factor: CGFloat) -> Color {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else {
            return color
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        return Color(
            nsColor: NSColor(
                srgbRed: min(1.0, max(0.0, red * factor)),
                green: min(1.0, max(0.0, green * factor)),
                blue: min(1.0, max(0.0, blue * factor)),
                alpha: alpha
            )
        )
    }
}
