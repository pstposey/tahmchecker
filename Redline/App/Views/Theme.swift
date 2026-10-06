import SwiftUI

/// Visual tokens. OEM-calm: near-black, high-contrast numerals, red only
/// where it means something (peak, warning, simulation flag).
enum Theme {
    static let background = Color.black
    static let tile = Color(white: 0.075)
    static let tileBorder = Color(white: 0.16)
    static let label = Color(white: 0.58)
    static let value = Color.white
    static let staleValue = Color(white: 0.38)
    static let secondaryValue = Color(white: 0.75)
    /// Semantic red: peaks, warnings, simulation banner.
    static let redline = Color(red: 0.92, green: 0.16, blue: 0.14)
    static let ok = Color(red: 0.35, green: 0.78, blue: 0.45)
    static let caution = Color(red: 0.95, green: 0.70, blue: 0.20)

    static let cornerRadius: CGFloat = 14
    static let spacing: CGFloat = 10

    static func numeric(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .default).monospacedDigit()
    }

    static let labelFont = Font.system(size: 13, weight: .semibold).smallCaps()
}
