import AppKit

/// How Codenotch paints itself.
///
/// Dark is the original material — a black cutout welded to the bezel — and it
/// is the default so an update does not recolour an existing install. Light is
/// the same shape in white, not a cream invert. System follows the Mac.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark:   return "Dark"
        case .light:  return "Light"
        case .system: return "System"
        }
    }

    var explanation: String {
        switch self {
        case .dark:
            return "The notch stays black, the way it was drawn."
        case .light:
            return "A light notch that still sits flush on the screen edge."
        case .system:
            return "Follows whether the Mac itself is Light or Dark."
        }
    }

    /// `nil` means inherit, which is how an app follows the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark:   return NSAppearance(named: .darkAqua)
        case .light:  return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}
