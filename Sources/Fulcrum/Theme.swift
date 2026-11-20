import AppKit
import CoreText
import SwiftUI

/// "The Engraved Barrel" — Fulcrum's design tokens (see DESIGN.md).
/// Chrome is neutral grey only; yellow is a scale's second unit; red is the brand mark.
extension Color {
    static let fcAnodised = Color(hex: 0x0B0B0C)      // photo ground
    static let fcBarrel = Color(hex: 0x141415)        // toolbar, sidebar, inspector
    static let fcRaised = Color(hex: 0x1E1E20)        // grip surfaces on the photo
    static let fcControlFill = Color(hex: 0x232326)
    static let fcHairline = Color(hex: 0x242427)
    static let fcRing = Color(hex: 0x2E2E31)          // selected / pressed
    static let fcTrack = Color(hex: 0x3A3A3D)
    static let fcGhostMark = Color(hex: 0x4A4A4E)     // unlit scale marks
    static let fcRib = Color(hex: 0x6A6A6E)
    static let fcMetadata = Color(hex: 0x9A9A9E)      // tertiary text, tick figures
    static let fcFigure = Color(hex: 0xA8A8AC)        // scale values, explainers
    static let fcOnFill = Color(hex: 0xA0A09E)        // the one on-colour (a step under the knob)
    static let fcLabel = Color(hex: 0xC0C0BE)
    static let fcKnob = Color(hex: 0xB6B6B4)        // slider thumbs: below engraving so the index leads
    static let fcEngraving = Color(hex: 0xF2F2F0)     // values, index, divider
    static let fcSecondScale = Color(hex: 0xE8B92E)   // only a scale's second unit
    static let fcIndexRed = Color(hex: 0xD7261E)      // only the brand mark
    // Histogram channel lines only: muted so they read as data, not decoration.
    static let fcChannelRed = Color(hex: 0xE0645A).opacity(0.85)
    static let fcChannelGreen = Color(hex: 0x5FBF73).opacity(0.85)
    static let fcChannelBlue = Color(hex: 0x5B8CF0).opacity(0.9)

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension NSColor {
    static let fcAnodised = NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)
    static let fcRaised = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255, alpha: 1)
    static let fcTrack = NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3D / 255, alpha: 1)
    static let fcRib = NSColor(srgbRed: 0x6A / 255, green: 0x6A / 255, blue: 0x6E / 255, alpha: 1)
    static let fcEngraving = NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF0 / 255, alpha: 1)
}

/// Saira for every number on a scale (engraved figures); the system face for every word.
enum FulcrumFont {
    /// Registers the bundled Saira once. In the .app it lives in Contents/Resources/Fonts; when run
    /// from SwiftPM it is read straight from the repo.
    static let registered: Bool = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts/Saira-Variable.ttf"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/Fonts/Saira-Variable.ttf"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
            // Already registered (e.g. ATSApplicationFontsPath) also counts.
            if let e = error?.takeRetainedValue(), CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue { return true }
        }
        return false
    }()

    /// Saira at a given weight (100–900), with tabular figures. Falls back to the system face's
    /// monospaced digits if the font isn't available.
    static func figures(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        guard registered else {
            return .system(size: size, weight: weight >= 550 ? .semibold : weight >= 450 ? .medium : .regular).monospacedDigit()
        }
        let wght: UInt32 = 0x7767_6874   // 'wght'
        let desc = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: "Saira",
            kCTFontVariationAttribute: [wght: weight],
            kCTFontFeatureSettingsAttribute: [[
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ]],
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(desc, size, nil))
    }

    static let value = figures(14, weight: 500)         // a slider's current value
    static let valueAtIndex = figures(15, weight: 600)  // the median under the pivot index
    static let scale = figures(11)                      // tick figures
    static let zone = figures(11, weight: 500)          // second-unit zone numerals
}

/// The brand mark: an upward index triangle (never a dot).
struct IndexTriangle: Shape {
    var pointingUp = true
    func path(in r: CGRect) -> Path {
        var p = Path()
        if pointingUp {
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}
