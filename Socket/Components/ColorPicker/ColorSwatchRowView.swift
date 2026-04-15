import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - ColorSwatchRowView
// Horizontal palette row with arrows
struct ColorSwatchRowView: View {
    var selectedColor: Color?
    var onSelect: (Color) -> Void

    private let swatchSize: CGFloat = 28
    private let colors: [Color] = [
            Color(hex: "F3EAE4"),
            Color(hex: "F29BBB"),
            Color(hex: "63411D"),
            Color(hex: "F25E6C"),
            Color(hex: "FF8658"),
            Color(hex: "F8D558"),
            Color(hex: "34E895"),
            Color(hex: "6DBAD9"),
            Color(hex: "666789"),
            Color(hex: "FFFBFA"),
            Color(hex: "FFE9F4"),
            Color(hex: "F1D1EC"),
            Color(hex: "FFCBD2"),
            Color(hex: "FFF9E5"),
            Color(hex: "DEFDEB"),
            Color(hex: "DCF4FC"),
            Color(hex: "D9D9D9"),
            Color(hex: "4E3A5A"),
            Color(hex: "693558"),
            Color(hex: "8F3F42"),
            Color(hex: "B16D40"),
            Color(hex: "CDCCA4"),
            Color(hex: "D7B35D"),
            Color(hex: "7AA982"),
            Color(hex: "226149"),
            Color(hex: "26456B"),
            Color(hex: "D9D9D9"),
            Color(hex: "E5E5E5"),
            Color(hex: "CCCCCC"),
            Color(hex: "B3B3B3"),
            Color(hex: "808080"),
            Color(hex: "333333"),
            Color(hex: "D9D9D9"),
            Color(hex: "D9D9D9"),
            Color(hex: "000000"),
        ]
    private let pageSize: Int = 17

    @State private var page: Int = 0

    private var palettePages: [[Color]] {
        stride(from: 0, to: colors.count, by: pageSize).map { start in
            Array(colors[start..<min(start + pageSize, colors.count)])
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            navigationButton(systemName: "chevron.left") {
                page = max(0, page - 1)
            }
            .disabled(page == 0)

            HStack(spacing: 10) {
                ForEach(Array(palettePages[page].enumerated()), id: \.offset) { _, color in
                    Button {
                        onSelect(color)
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: swatchSize, height: swatchSize)
                            .overlay(
                                Circle().strokeBorder(Color.white, lineWidth: 2)
                            )
                            .overlay(
                                Circle().strokeBorder(
                                    (selectedColor.map { approxEqual($0, color) } ?? false)
                                        ? Color.accentColor
                                        : Color.clear,
                                    lineWidth: 2.5
                                )
                            )
                            .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(page)
            .animation(.easeInOut(duration: 0.18), value: page)

            navigationButton(systemName: "chevron.right") {
                page = min(palettePages.count - 1, page + 1)
            }
            .disabled(page >= palettePages.count - 1)
        }
    }

    private func navigationButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func approxEqual(_ a: Color, _ b: Color) -> Bool {
        #if canImport(AppKit)
        let nsA = NSColor(a)
        let nsB = NSColor(b)
        var (ha, sa, ba): (CGFloat, CGFloat, CGFloat) = (0,0,0)
        var (hb, sb, bb): (CGFloat, CGFloat, CGFloat) = (0,0,0)
        nsA.usingColorSpace(.deviceRGB)?.getHue(&ha, saturation: &sa, brightness: &ba, alpha: nil)
        nsB.usingColorSpace(.deviceRGB)?.getHue(&hb, saturation: &sb, brightness: &bb, alpha: nil)
        return abs(ha - hb) < 0.03 && abs(sa - sb) < 0.08 && abs(ba - bb) < 0.08
        #else
        return false
        #endif
    }
}
