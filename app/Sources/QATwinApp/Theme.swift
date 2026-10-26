import AppKit
import SwiftUI

extension Color {
    static let qaBackground = dynamic(
        "qaBackground",
        light: rgb(1, 1, 1),
        dark: .textBackgroundColor
    )
    static let qaSidebar = dynamic(
        "qaSidebar",
        light: rgb(0.933, 0.941, 0.953),
        dark: .windowBackgroundColor
    )
    static let qaBar = dynamic(
        "qaBar",
        light: rgb(0.965, 0.969, 0.976),
        dark: .controlBackgroundColor
    )
    static let qaSunken = dynamic(
        "qaSunken",
        light: rgb(0.965, 0.969, 0.976),
        dark: .controlBackgroundColor
    )
    static let qaHover = dynamic(
        "qaHover",
        light: rgb(0.894, 0.906, 0.925),
        dark: .controlBackgroundColor
    )
    static let qaLine = dynamic(
        "qaLine",
        light: rgb(0.89, 0.898, 0.914),
        dark: .separatorColor
    )
    static let qaStrongLine = dynamic(
        "qaStrongLine",
        light: rgb(0.812, 0.827, 0.851),
        dark: .separatorColor
    )
    static let qaText = dynamic(
        "qaText",
        light: rgb(0.106, 0.114, 0.129),
        dark: .labelColor
    )
    static let qaSecondaryText = dynamic(
        "qaSecondaryText",
        light: rgb(0.329, 0.353, 0.388),
        dark: .secondaryLabelColor
    )
    static let qaTertiaryText = dynamic(
        "qaTertiaryText",
        light: rgb(0.365, 0.388, 0.424),
        dark: .tertiaryLabelColor
    )
    static let qaAccent = dynamic(
        "qaAccent",
        light: rgb(0.039, 0.392, 0.847),
        dark: rgb(0.290, 0.608, 1)
    )
    static let qaAccentWeak = dynamic(
        "qaAccentWeak",
        light: rgb(0.906, 0.937, 0.984),
        dark: rgb(0.290, 0.608, 1, alpha: 0.18)
    )
    static let qaAccentInk = dynamic(
        "qaAccentInk",
        light: rgb(0.039, 0.29, 0.639),
        dark: rgb(0.290, 0.608, 1)
    )
    static let qaPass = dynamic(
        "qaPass",
        light: rgb(0.11, 0.478, 0.239),
        dark: rgb(0.298, 0.761, 0.455)
    )
    static let qaPassWeak = dynamic(
        "qaPassWeak",
        light: rgb(0.894, 0.953, 0.914),
        dark: rgb(0.298, 0.761, 0.455, alpha: 0.18)
    )
    static let qaFail = dynamic(
        "qaFail",
        light: rgb(0.706, 0.137, 0.094),
        dark: rgb(1, 0.420, 0.369)
    )
    static let qaFailWeak = dynamic(
        "qaFailWeak",
        light: rgb(0.988, 0.922, 0.914),
        dark: rgb(1, 0.420, 0.369, alpha: 0.18)
    )
    static let qaHold = dynamic(
        "qaHold",
        light: rgb(0.561, 0.29, 0),
        dark: rgb(0.941, 0.635, 0.290)
    )
    static let qaHoldWeak = dynamic(
        "qaHoldWeak",
        light: rgb(0.984, 0.933, 0.859),
        dark: rgb(0.941, 0.635, 0.290, alpha: 0.18)
    )
    static let qaTapeHold = dynamic(
        "qaTapeHold",
        light: rgb(0.761, 0.478, 0.102),
        dark: rgb(0.941, 0.635, 0.290)
    )
    static let qaWarn = dynamic(
        "qaWarn",
        light: rgb(0.478, 0.31, 0),
        dark: rgb(0.902, 0.765, 0.361)
    )
    static let qaWarnWeak = dynamic(
        "qaWarnWeak",
        light: rgb(1, 0.961, 0.851),
        dark: rgb(0.902, 0.765, 0.361, alpha: 0.18)
    )
    static let qaWarnLine = dynamic(
        "qaWarnLine",
        light: rgb(0.937, 0.831, 0.541),
        dark: rgb(0.902, 0.765, 0.361)
    )
    static let qaIdle = dynamic(
        "qaIdle",
        light: rgb(0.827, 0.843, 0.867),
        dark: rgb(0.33, 0.36, 0.41)
    )
    static let qaDone = dynamic(
        "qaDone",
        light: rgb(0.498, 0.651, 0.851),
        dark: rgb(0.290, 0.608, 1)
    )
    static let qaSelectedText = dynamic(
        "qaSelectedText",
        light: .white,
        dark: .black
    )
    static let qaVideoText = dynamic(
        "qaVideoText",
        light: .white,
        dark: .labelColor
    )

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat,
        alpha: CGFloat = 1
    ) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

