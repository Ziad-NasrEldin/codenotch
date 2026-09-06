import AppKit
import SwiftUI

/// Dark swatches are sampled from `docs/design/frame-124-hover-tooltip.png`.
/// Light is the same language on white — the dual of the black cutout, not a
/// cream invert. Callers ask for a role; the appearance picks the ink.
enum Palette {
    static let notch         = Color(nsColor: Ink.notch)
    static let card          = Color(nsColor: Ink.card)
    static let ringTrack     = Color(nsColor: Ink.ringTrack)
    static let barTrack      = Color(nsColor: Ink.barTrack)
    static let ample         = Color(nsColor: Ink.ample)
    static let watch         = Color(nsColor: Ink.watch)
    static let critical      = Color(nsColor: Ink.critical)

    /// The same three signals, as type. Rings stay neon on white; words cannot.
    static let ampleInk      = Color(nsColor: Ink.ampleInk)
    static let watchInk      = Color(nsColor: Ink.watchInk)
    static let criticalInk   = Color(nsColor: Ink.criticalInk)

    static let textPrimary   = Color(nsColor: Ink.textPrimary)
    static let textSecondary = Color(nsColor: Ink.textSecondary)

    /// Inner silhouette of the notch and the settings orb. Clear in dark —
    /// black needs no edge — and a hairline in light so a white shape holds
    /// against a pale wallpaper without drawing a line on the bezel.
    static let notchRim      = Color(nsColor: Ink.notchRim)

    /// Thin strokes that have to hold against the desktop: the resting settings
    /// arc. Matches the notch in dark; a step denser in light, because a 2pt
    /// white stroke vanishes where a white fill still reads.
    static let chrome        = Color(nsColor: Ink.chrome)

    /// Lift under the tooltip. Clear in dark, where black already separates;
    /// a soft shade in light, offset, so the card sits on the desktop rather
    /// than flattening into it.
    static let cardLift      = Color(nsColor: Ink.cardLift)

    /// The sRGB a swatch paints under a given appearance. Tests use this so a
    /// light Mac does not silently recolour the dark assertions, and so the
    /// contrast floor is a number rather than an intention.
    static func resolve(_ color: Color, in appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return resolved
    }
}

/// Named so SwiftUI `Color` values stay identical across calls — equality in
/// tests compares the wrapper, and an anonymous dynamic colour is a new object
/// every time.
private enum Ink {
    static let notch         = adaptive("notch",         dark: .black,              light: .white)
    static let card          = adaptive("card",          dark: .black,              light: .white)

    // Track recedes into the body the same way in both themes: a step off
    // black in Dark, a step off white in Light. Charcoal on a white notch
    // made the doughnut the thing you saw, not the reading.
    static let ringTrack     = adaptive("ringTrack",     dark: NSColor(hex: 0x303030), light: NSColor(hex: 0xE4E4E4))
    static let barTrack      = adaptive("barTrack",      dark: NSColor(hex: 0x2D2D2D), light: NSColor(hex: 0xE8E8E8))

    // Dark keeps the frame. Light keeps the same three hues at a lightness
    // that still reads as neon on white — lemon yellow on white is the same
    // colour as the paper, so it shifts to gold without going brown.
    static let ample         = adaptive("ample",         dark: NSColor(hex: 0x00FF88), light: NSColor(hex: 0x00E676))
    static let watch         = adaptive("watch",         dark: NSColor(hex: 0xF2FF00), light: NSColor(hex: 0xFFC400))
    static let critical      = adaptive("critical",      dark: NSColor(hex: 0xFF3F00), light: NSColor(hex: 0xFF3F00))

    static let ampleInk      = adaptive("ampleInk",      dark: NSColor(hex: 0x00FF88), light: NSColor(hex: 0x007A45))
    static let watchInk      = adaptive("watchInk",      dark: NSColor(hex: 0xF2FF00), light: NSColor(hex: 0x9A5A00))
    static let criticalInk   = adaptive("criticalInk",   dark: NSColor(hex: 0xFF3F00), light: NSColor(hex: 0xC02400))

    static let textPrimary   = adaptive("textPrimary",   dark: .white,              light: .black)
    static let textSecondary = adaptive("textSecondary", dark: NSColor(hex: 0x808080), light: NSColor(hex: 0x5C5C5C))

    static let notchRim      = adaptive("notchRim",      dark: .clear,              light: NSColor(hex: 0xD0D0D0))
    static let chrome        = adaptive("chrome",        dark: .black,              light: NSColor(hex: 0x8A8A8A))
    static let cardLift      = adaptive("cardLift",      dark: .clear,              light: NSColor.black.withAlphaComponent(0.10))

    static func adaptive(_ name: String, dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: "codenotch.palette.\(name)") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8) & 0xFF) / 255,
            blue:    CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
