import Core
import SwiftUI
import UIKit

extension UIColor {
    /// A colour that follows the appearance: `light` in light mode, `dark` in dark mode.
    convenience init(_ h: Hex) {
        self.init { $0.userInterfaceStyle == .dark ? UIColor(rgb: h.dark) : UIColor(rgb: h.light) }
    }

    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static let page = Color(UIColor(Palette.page))
    static let card = Color(UIColor(Palette.card))
    static let inset = Color(UIColor(Palette.inset))
    static let ink = Color(UIColor(Palette.text))
    static let muted = Color(UIColor(Palette.muted))
    static let satsuma = Color(UIColor(Palette.satsuma))
}

extension Font {
    /// Bricolage Grotesque for big numbers and titles; scales with Dynamic Type like `style`.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        // The variable font's default instance: display optical size, ExtraBold.
        .custom("BricolageGrotesque-96ptExtraBold", size: size, relativeTo: style)
    }
}

/// A filled paper card: no outline, 12 pt continuous corners.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .background(Color.card, in: .rect(cornerRadius: 22, style: .continuous))
    }
}

/// A list row: its title with the value underneath, the same in every list of LifePath.
struct InfoRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Color.ink)
            value.font(.subheadline).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension InfoRow where Value == Text {
    init(_ title: String, value: String) { self.init(title: title) { Text(value) } }
}

/// The appearance chosen in Settings.
enum Appearance: String, CaseIterable {
    case system, light, dark
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    var label: String { rawValue.capitalized }
}
