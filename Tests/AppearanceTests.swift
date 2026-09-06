import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

/// Dark is what every earlier build drew. An unknown or missing value has to
/// land there, or an upgrade would recolour the notch uninvited.
@MainActor
final class AppearancePreferenceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AppearancePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testItDefaultsToDark() {
        XCTAssertEqual(Preferences(defaults: defaults()).appearance, .dark)
    }

    func testTheChoiceSurvivesARestart() {
        let defaults = defaults()
        Preferences(defaults: defaults).appearance = .light
        XCTAssertEqual(Preferences(defaults: defaults).appearance, .light)
    }

    func testAnUnknownStoredValueFallsBackToDark() {
        let defaults = defaults()
        defaults.set("solarized", forKey: "appearance")
        XCTAssertEqual(Preferences(defaults: defaults).appearance, .dark)
    }

    func testEveryModeIsOfferedAndNamed() {
        XCTAssertEqual(AppearancePreference.allCases.count, 3)
        for mode in AppearancePreference.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.explanation.isEmpty)
        }
    }

    func testOnlySystemInheritsTheMac() {
        XCTAssertNotNil(AppearancePreference.dark.nsAppearance)
        XCTAssertNotNil(AppearancePreference.light.nsAppearance)
        XCTAssertNil(AppearancePreference.system.nsAppearance)
    }
}

/// The two materials have to stay readable, and they have to stay themselves:
/// light is not a washed invert of dark.
final class PaletteContrastTests: XCTestCase {
    private var dark: NSAppearance { NSAppearance(named: .darkAqua)! }
    private var light: NSAppearance { NSAppearance(named: .aqua)! }

    func testDarkNotchIsBlack() {
        let notch = Palette.resolve(Palette.notch, in: dark)
        XCTAssertEqual(notch.redComponent, 0, accuracy: 0.02)
        XCTAssertEqual(notch.greenComponent, 0, accuracy: 0.02)
        XCTAssertEqual(notch.blueComponent, 0, accuracy: 0.02)
    }

    func testDarkPrimaryTextIsWhite() {
        let text = Palette.resolve(Palette.textPrimary, in: dark)
        XCTAssertEqual(text.redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(text.greenComponent, 1, accuracy: 0.02)
        XCTAssertEqual(text.blueComponent, 1, accuracy: 0.02)
    }

    func testLightNotchIsWhite() {
        let notch = Palette.resolve(Palette.notch, in: light)
        XCTAssertEqual(notch.redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(notch.greenComponent, 1, accuracy: 0.02)
        XCTAssertEqual(notch.blueComponent, 1, accuracy: 0.02)
    }

    func testLightPrimaryTextMeetsBodyContrast() {
        let ratio = contrast(
            Palette.resolve(Palette.textPrimary, in: light),
            Palette.resolve(Palette.notch, in: light)
        )
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "primary text on the light notch is \(ratio)")
    }

    func testLightSecondaryTextMeetsBodyContrast() {
        let ratio = contrast(
            Palette.resolve(Palette.textSecondary, in: light),
            Palette.resolve(Palette.notch, in: light)
        )
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "secondary text on the light notch is \(ratio)")
    }

    /// Waiting is drawn as type on the tooltip. The ring stays neon; the word
    /// uses the ink companion so it holds on white.
    func testLightWatchInkMeetsBodyContrast() {
        let ratio = contrast(
            Palette.resolve(Palette.watchInk, in: light),
            Palette.resolve(Palette.card, in: light)
        )
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "waiting gold on the light card is \(ratio)")
    }

    func testLightCriticalInkMeetsBodyContrast() {
        let ratio = contrast(
            Palette.resolve(Palette.criticalInk, in: light),
            Palette.resolve(Palette.card, in: light)
        )
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "blocked orange on the light card is \(ratio)")
    }

    func testLightStatusColoursStayThreeSignals() {
        let ample = Palette.resolve(Palette.ample, in: light)
        let watch = Palette.resolve(Palette.watch, in: light)
        let critical = Palette.resolve(Palette.critical, in: light)
        XCTAssertGreaterThan(distance(ample, watch), 0.2)
        XCTAssertGreaterThan(distance(watch, critical), 0.15)
        XCTAssertGreaterThan(distance(ample, critical), 0.2)
    }

    /// Dark keeps the shipped hexes. Light keeps the same three hues, just
    /// light enough to hold on white.
    func testDarkSignalsAreTheOriginalFrameColours() {
        let ample = Palette.resolve(Palette.ample, in: dark)
        let watch = Palette.resolve(Palette.watch, in: dark)
        let critical = Palette.resolve(Palette.critical, in: dark)
        XCTAssertEqual(ample.redComponent, 0, accuracy: 0.02)
        XCTAssertEqual(ample.greenComponent, 1, accuracy: 0.02)
        XCTAssertEqual(ample.blueComponent, 0x88 / 255, accuracy: 0.02)
        XCTAssertEqual(watch.redComponent, 0xF2 / 255, accuracy: 0.02)
        XCTAssertEqual(watch.greenComponent, 1, accuracy: 0.02)
        XCTAssertEqual(watch.blueComponent, 0, accuracy: 0.02)
        XCTAssertEqual(critical.redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(critical.greenComponent, 0x3F / 255, accuracy: 0.02)
        XCTAssertEqual(critical.blueComponent, 0, accuracy: 0.02)
    }

    func testLightSignalsStayTheSameHues() {
        let ample = Palette.resolve(Palette.ample, in: light)
        let watch = Palette.resolve(Palette.watch, in: light)
        let critical = Palette.resolve(Palette.critical, in: light)
        XCTAssertGreaterThan(ample.greenComponent, 0.8)
        XCTAssertLessThan(ample.redComponent, 0.2)
        XCTAssertGreaterThan(watch.redComponent, 0.9)
        XCTAssertGreaterThan(watch.greenComponent, 0.7)
        XCTAssertLessThan(watch.blueComponent, 0.15)
        XCTAssertGreaterThan(critical.redComponent, 0.9)
        XCTAssertLessThan(critical.greenComponent, 0.35)
    }

    func testDarkTrackIsTheShippedCharcoal() {
        let track = Palette.resolve(Palette.ringTrack, in: dark)
        XCTAssertEqual(track.redComponent, 0x30 / 255, accuracy: 0.02)
    }

    func testLightTrackRecedesIntoWhite() {
        let track = Palette.resolve(Palette.ringTrack, in: light)
        let luma = 0.2126 * track.redComponent + 0.7152 * track.greenComponent + 0.0722 * track.blueComponent
        XCTAssertGreaterThan(luma, 0.8, "light track is still a dark ring")
        XCTAssertLessThan(luma, 0.96, "light track vanished into the body")
    }

    func testDarkRimIsInvisible() {
        XCTAssertEqual(Palette.resolve(Palette.notchRim, in: dark).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(Palette.resolve(Palette.cardLift, in: dark).alphaComponent, 0, accuracy: 0.01)
    }

    func testLightRimAndLiftArePresent() {
        XCTAssertGreaterThan(Palette.resolve(Palette.notchRim, in: light).alphaComponent, 0.9)
        XCTAssertGreaterThan(Palette.resolve(Palette.cardLift, in: light).alphaComponent, 0.08)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func lin(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(color.redComponent)
             + 0.7152 * lin(color.greenComponent)
             + 0.0722 * lin(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let l1 = luminance(a), l2 = luminance(b)
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let dr = a.redComponent - b.redComponent
        let dg = a.greenComponent - b.greenComponent
        let db = a.blueComponent - b.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }
}

/// Paints the real views under both appearances. The layout tests can be right
/// in every unit and still ship a light notch that is white-on-white.
@MainActor
final class AppearanceRenderTests: XCTestCase {
    private func makeModel() -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .right
        model.isExpanded = true
        model.snapshots = Fixtures.snapshots()
        return model
    }

    private func renderNotch(appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        drawing(appearance) {
            let model = makeModel()
            let size = model.panelSize
            let renderer = ImageRenderer(
                content: NotchRootView(model: model)
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            )
            renderer.scale = 2
            guard let image = renderer.cgImage else { return nil }
            return NSBitmapImageRep(cgImage: image)
        }
    }

    private func renderTooltip(appearance: NSAppearance.Name) -> NSImage? {
        drawing(appearance) {
            let snapshot = Fixtures.snapshots()[0]
            let view = TooltipCard(snapshot: snapshot, activity: nil, now: Date())
                .padding(24)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.nsImage
        }
    }

    private func drawing<T>(_ name: NSAppearance.Name, _ work: () -> T) -> T {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: name)
        defer { NSApp.appearance = previous }
        var result: T!
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            result = work()
        }
        return result
    }

    func testTheNotchPaintsBlackInDark() {
        guard let rep = renderNotch(appearance: .darkAqua) else {
            return XCTFail("dark notch produced no image")
        }
        XCTAssertLessThan(bezelLuminance(rep), 0.08, "dark notch is not black")
    }

    func testTheNotchPaintsLightInLight() {
        guard let rep = renderNotch(appearance: .aqua) else {
            return XCTFail("light notch produced no image")
        }
        let luma = bezelLuminance(rep)
        XCTAssertGreaterThan(luma, 0.95, "light notch is still dark (\(luma))")
    }

    func testBothTooltipsLayOut() throws {
        let dark = try XCTUnwrap(renderTooltip(appearance: .darkAqua))
        let light = try XCTUnwrap(renderTooltip(appearance: .aqua))
        XCTAssertGreaterThan(dark.size.height, 80)
        XCTAssertGreaterThan(light.size.height, 80)
        XCTAssertEqual(dark.size.width, light.size.width, accuracy: 1)
    }

    /// Set `APPEARANCE_RENDER_DIR` to write PNG frames for eyeballing.
    func testDumpFramesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["APPEARANCE_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try write(renderNotch(appearance: .darkAqua), to: folder.appendingPathComponent("notch-dark.png"))
        try write(renderNotch(appearance: .aqua), to: folder.appendingPathComponent("notch-light.png"))
        try write(renderTooltip(appearance: .darkAqua), to: folder.appendingPathComponent("tooltip-dark.png"))
        try write(renderTooltip(appearance: .aqua), to: folder.appendingPathComponent("tooltip-light.png"))
    }

    /// Luminance at the bezel, halfway along the stack.
    private func bezelLuminance(_ rep: NSBitmapImageRep) -> CGFloat {
        let model = makeModel()
        let place = NotchPlacement(edge: .right, panelSize: model.panelSize)
        let onBezel = place.point(along: model.slack + model.shapeLength / 2, across: 1)
        let x = min(rep.pixelsWide - 1, max(0, Int(onBezel.x * CGFloat(rep.pixelsWide) / model.panelSize.width)))
        let y = min(rep.pixelsHigh - 1, max(0, Int(onBezel.y * CGFloat(rep.pixelsHigh) / model.panelSize.height)))
        guard let colour = rep.colorAt(x: x, y: y) else { return -1 }
        return colour.brightnessComponent
    }

    private func write(_ rep: NSBitmapImageRep?, to url: URL) throws {
        let png = try XCTUnwrap(rep?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    private func write(_ image: NSImage?, to url: URL) throws {
        let tiff = try XCTUnwrap(image?.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
