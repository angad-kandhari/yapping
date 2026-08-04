import AppKit
import SwiftUI

/// The yapping design system, living inside the system appearance: native
/// light/dark surfaces, brand orange accent (#FF5A1F), the six-bar waveform as the
/// recurring motif, lowercase headers.
enum Brand {
    static let accent = Color(red: 1.0, green: 0.353, blue: 0.122)  // #FF5A1F
    /// Same accent for AppKit surfaces (menu bar, panels). One source only.
    static let accentNSColor = NSColor(red: 1.0, green: 0.353, blue: 0.122, alpha: 1)

    /// Logo bar heights on the 24-grid; the menu bar and HUD scale these
    /// rather than keeping their own copies.
    static let barHeights: [CGFloat] = [4, 9, 15, 7, 11, 3]
}

/// The six-bar logo as a static SwiftUI mark.
struct BrandLogo: View {
    var height: CGFloat = 20
    var color: Color = .primary

    var body: some View {
        let unit = height / 15
        HStack(alignment: .center, spacing: unit * 1.5) {
            ForEach(Array(Brand.barHeights.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(color)
                    .frame(width: unit * 2, height: h * unit)
            }
        }
        .frame(height: height)
    }
}

/// Window chrome: dark canvas, custom header with the mark and a lowercase
/// title, content below. Pairs with UtilityWindow's hidden system titlebar.
struct BrandChrome<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandLogo(height: 16)
                Text("yapping")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                Text(title.lowercased())
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Brand.accent)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)   // clears the hidden traffic-light titlebar
            .padding(.bottom, 14)

            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.accent)
    }
}

/// Brand pill tabs, replacing the generic macOS tab control.
struct BrandTabs: View {
    let tabs: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                Button {
                    selection = index
                } label: {
                    Text(tab.lowercased())
                        .font(.system(size: 12.5, weight: selection == index ? .semibold : .regular))
                        .foregroundStyle(selection == index ? Color.black : Color.primary.opacity(0.75))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selection == index
                                ? Brand.accent
                                : Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}
