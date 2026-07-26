import AppKit
import SwiftUI

/// The yapping design system: dark surfaces, YAP yellow accent, the six-bar
/// waveform as the recurring motif, lowercase headers.
enum Brand {
    static let yellow = Color(red: 0.96, green: 0.82, blue: 0.27)
    static let background = Color(red: 0.055, green: 0.055, blue: 0.07)
    static let surface = Color(red: 0.1, green: 0.1, blue: 0.125)

    /// Logo bar heights on the 24-grid, shared with the menu bar and HUD.
    static let barHeights: [CGFloat] = [4, 9, 15, 7, 11, 3]
}

/// The six-bar logo as a static SwiftUI mark.
struct BrandLogo: View {
    var height: CGFloat = 20
    var color: Color = .white

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
                    .foregroundStyle(.white)
                Text(title.lowercased())
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Brand.yellow)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)   // clears the hidden traffic-light titlebar
            .padding(.bottom, 14)

            content
        }
        .background(Brand.background)
        .tint(Brand.yellow)
        .preferredColorScheme(.dark)
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
                        .foregroundStyle(selection == index ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selection == index ? Brand.yellow : Brand.surface))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}
