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
        // SigmaOS-style layout:
        //   Left  — destination picker (split-button Menu: click = Open, chevron = pick)
        //   Center — dimmed page title, flex-grows and truncates
        //   Right — single ✓ close
        // Puts the primary action (where does this page go?) up front and
        // relegates the page title to contextual info, which matches what
        // the user is actually deciding when they see a mini window.
        HStack(spacing: 10) {
            destinationButton
            Spacer(minLength: 12)
            titleCenter
            Spacer(minLength: 12)
            closeButton
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

    /// Split-button destination picker: left press = Open in the selected
    /// destination; right chevron = pick a different destination from the menu.
    /// We compose two distinct controls sharing a single visual capsule
    /// because SwiftUI's `Menu(primaryAction:)` on macOS consumes the whole
    /// label hit-target, leaving the chevron unreachable.
    private var destinationButton: some View {
        HStack(spacing: 0) {
            Button(action: adoptAction) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open in \(session.selectedDestinationLabel)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(foregroundColor)
            .help("Open in \(session.selectedDestinationMenuTitle)")
            .keyboardShortcut("o", modifiers: [])

            Rectangle()
                .fill(secondaryForegroundColor.opacity(0.35))
                .frame(width: 1, height: 14)

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
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(foregroundColor)
            .help("Change destination")
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(secondaryForegroundColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(secondaryForegroundColor.opacity(0.18), lineWidth: 1)
        )
        .fixedSize()
    }

    /// Dimmed, center-aligned page title. Flex-grows and truncates.
    private var titleCenter: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(linkAccentColor)
            Text(displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryForegroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var closeButton: some View {
        Button(action: dismissAction) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(NavButtonStyle(size: .small))
        .foregroundStyle(foregroundColor)
        .help("Close external view")
        .keyboardShortcut("d", modifiers: [])
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
