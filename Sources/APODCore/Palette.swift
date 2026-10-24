// Palette — terminal colours taken from a picture. A port of omarchy-apod's apod-palette.py.
//
// The picture decides the character, never the legibility. Its most prominent hues become
// the accent and the border gradient, its dark areas tint the background, and the terminal
// colours keep their usual meaning (red still reads as red) but lean towards nearby hues of
// the picture. Every text colour is then checked against the background and moved in
// lightness until it is readable.
//
// Colours are worked out in OKLab/OKLCH, where equal steps in lightness look equal, so the
// same recipe gives an even theme for a red nebula and a blue one.
import CoreGraphics
import Foundation
import ImageIO

public enum ColorMode: String, CaseIterable, Codable, Sendable {
    case auto, dark, light
}

public enum Vividness: String, CaseIterable, Codable, Sendable {
    case subtle, balanced, vivid

    var factor: Double {
        switch self {
        case .subtle: 0.7
        case .balanced: 1.0
        case .vivid: 1.35
        }
    }
}

enum PaletteConstants {
    static let sample = 160         // the picture is shrunk to at most sample x sample pixels
    static let chromatic = 0.03     // OKLCH chroma below which a pixel counts as grey
    static let bins = 72            // 5-degree hue bins
    static let peakGap = 35.0       // degrees between two hues that count as different colours
}

/// Terminal colours: the usual OKLCH hue of each, and the lightness it gets on a dark and on
/// a light background. Yellow and green need to be lighter than red and blue to look equally bright.
public let ansiColours: [(name: String, hue: Double, dark: Double, light: Double)] = [
    ("red", 25, 0.68, 0.52),
    ("orange", 55, 0.74, 0.56),
    ("yellow", 95, 0.84, 0.60),
    ("green", 145, 0.77, 0.54),
    ("cyan", 200, 0.78, 0.54),
    ("blue", 258, 0.70, 0.50),
    ("magenta", 330, 0.72, 0.52),
]
public let brightColours = ["red", "yellow", "green", "cyan", "blue", "magenta"]

// MARK: - Colour maths

/// Python's % for floats: the result has the sign of the divisor.
func positiveMod(_ a: Double, _ m: Double) -> Double {
    let r = a.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
}

func positiveMod(_ a: Int, _ m: Int) -> Int {
    let r = a % m
    return r < 0 ? r + m : r
}

func srgbToLinear(_ c: Double) -> Double {
    let c = c / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

func linearToSRGB(_ c: Double) -> Double {
    c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
}

func oklab(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
    let r = srgbToLinear(r), g = srgbToLinear(g), b = srgbToLinear(b)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

func oklabToLinear(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
    let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
    return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
}

func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
    [rgb.0, rgb.1, rgb.2].allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 }
}

func hueDistance(_ h1: Double, _ h2: Double) -> Double {
    let d = positiveMod(abs(h1 - h2), 360)
    return min(d, 360 - d)
}

/// An OKLCH colour, kept inside sRGB by lowering chroma, never by shifting hue.
public struct PaletteColour: Equatable, Sendable {
    public let L: Double
    public let C: Double
    public let h: Double
    public let red: Int, green: Int, blue: Int

    public init(_ L: Double, _ C: Double, _ h: Double) {
        let L = min(max(L, 0), 1)
        let h = positiveMod(h, 360)
        let rad = h * .pi / 180
        var C = C
        if !inGamut(oklabToLinear(L, C * cos(rad), C * sin(rad))) {
            var lo = 0.0, hi = C
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if inGamut(oklabToLinear(L, mid * cos(rad), mid * sin(rad))) { lo = mid } else { hi = mid }
            }
            C = lo
        }
        let lin = oklabToLinear(L, C * cos(rad), C * sin(rad))
        // Python's round() rounds halves to even; so does this, to give the same hex values.
        func channel(_ c: Double) -> Int {
            min(max(Int((linearToSRGB(min(max(c, 0), 1)) * 255).rounded(.toNearestOrEven)), 0), 255)
        }
        self.L = L
        self.C = C
        self.h = h
        (red, green, blue) = (channel(lin.0), channel(lin.1), channel(lin.2))
    }

    /// From "#rrggbb", e.g. a palette read back from palette.json.
    public init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        let (r, g, b) = ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
        let lab = oklab(Double(r), Double(g), Double(b))
        L = lab.L
        C = hypot(lab.a, lab.b)
        h = positiveMod(atan2(lab.b, lab.a) * 180 / .pi, 360)
        (red, green, blue) = (r, g, b)
    }

    public func lighter(_ dL: Double) -> PaletteColour { PaletteColour(L + dL, C, h) }

    public var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }

    public var luminance: Double {
        0.2126 * srgbToLinear(Double(red)) + 0.7152 * srgbToLinear(Double(green)) + 0.0722 * srgbToLinear(Double(blue))
    }

    /// 0...1 components, for NSColor and terminal profiles.
    public var components: (Double, Double, Double) {
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }
}

public func contrast(_ c1: PaletteColour, _ c2: PaletteColour) -> Double {
    let a = max(c1.luminance, c2.luminance), b = min(c1.luminance, c2.luminance)
    return (a + 0.05) / (b + 0.05)
}

/// colour, moved away from bg in lightness until the WCAG contrast reaches ratio.
func readable(_ colour: PaletteColour, _ bg: PaletteColour, _ ratio: Double) -> PaletteColour {
    let step = bg.L < 0.5 ? 0.01 : -0.01
    var colour = colour
    for _ in 0..<100 {
        if contrast(colour, bg) >= ratio || !(colour.L > 0 && colour.L < 1) { break }
        colour = colour.lighter(step)
    }
    return colour
}

// MARK: - The picture

public struct Peak: Codable, Equatable, Sendable {
    public var hue: Double
    public var chroma: Double
    public var share: Double
}

public struct PictureInfo: Codable, Equatable, Sendable {
    public var meanLightness: Double
    public var colourfulness: Double
    public var peaks: [Peak]
    public var darkHue: Double
    public var darkChroma: Double
}

public enum PaletteError: Error, LocalizedError {
    case unreadable(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "can't read \(name) as a picture"
        }
    }
}

/// The picture as OKLab (L, a, b), shrunk to at most `PaletteConstants.sample` pixels a side.
public func readPixels(_ url: URL) throws -> [(L: Double, a: Double, b: Double)] {
    let name = url.lastPathComponent
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PaletteError.unreadable(name) }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: PaletteConstants.sample,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw PaletteError.unreadable(name)
    }
    return try pixels(of: image, name: name)
}

func pixels(of image: CGImage, name: String = "picture") throws -> [(L: Double, a: Double, b: Double)] {
    let w = image.width, h = image.height
    guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let data = ctx.data else { throw PaletteError.unreadable(name) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var cache: [UInt32: (L: Double, a: Double, b: Double)] = [:]
    var out: [(L: Double, a: Double, b: Double)] = []
    out.reserveCapacity(w * h)
    for i in 0..<(w * h) {
        let r = bytes[i * 4], g = bytes[i * 4 + 1], b = bytes[i * 4 + 2]
        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        if let lab = cache[key] {
            out.append(lab)
        } else {
            let lab = oklab(Double(r), Double(g), Double(b))
            cache[key] = lab
            out.append(lab)
        }
    }
    return out
}

/// What the palette needs to know about the picture.
public func analyse(_ pixels: [(L: Double, a: Double, b: Double)]) -> PictureInfo {
    let bins = PaletteConstants.bins
    let n = Double(pixels.count)
    let meanL = pixels.reduce(0) { $0 + $1.L } / n

    // Hue histogram of the coloured pixels, weighted by chroma so that a small vivid nebula
    // outweighs a large dull haze.
    var hist = [Double](repeating: 0, count: bins)
    var members = [[(L: Double, a: Double, b: Double, C: Double)]](repeating: [], count: bins)
    var totalChroma = 0.0
    for p in pixels {
        let C = hypot(p.a, p.b)
        totalChroma += C
        if C < PaletteConstants.chromatic || !(p.L > 0.12 && p.L < 0.98) { continue }
        let h = positiveMod(atan2(p.b, p.a) * 180 / .pi, 360)
        let k = Int(h / (360 / Double(bins))) % bins
        hist[k] += pow(C, 1.5)
        members[k].append((p.L, p.a, p.b, C))
    }
    let kernel: [Double] = [1, 2, 3, 2, 1]
    let smooth = (0..<bins).map { i in
        kernel.enumerated().reduce(0.0) { $0 + $1.element * hist[positiveMod(i + $1.offset - 2, bins)] }
    }
    let chromaticWeight = hist.reduce(0, +)

    var peaks: [Peak] = []
    // Strongest first; equal ones in bin order, as Python's stable sort leaves them.
    let order = (0..<bins).sorted { smooth[$0] != smooth[$1] ? smooth[$0] > smooth[$1] : $0 < $1 }
    for i in order {
        if smooth[i] <= 0 || peaks.count == 3 { break }
        if smooth[i] < smooth[positiveMod(i - 1, bins)] || smooth[i] < smooth[(i + 1) % bins] { continue }
        let centre = (Double(i) + 0.5) * 360 / Double(bins)
        if peaks.contains(where: { hueDistance(centre, $0.hue) < PaletteConstants.peakGap }) { continue }
        let near = (i - 3...i + 3).flatMap { members[positiveMod($0, bins)] }
        if near.isEmpty { continue }
        let a = near.reduce(0) { $0 + $1.a * $1.C }
        let b = near.reduce(0) { $0 + $1.b * $1.C }
        let chromas = near.map(\.C).sorted()
        let share = (i - 3...i + 3).reduce(0) { $0 + hist[positiveMod($1, bins)] } / chromaticWeight
        if !peaks.isEmpty && share < 0.04 { continue }
        peaks.append(Peak(hue: positiveMod(atan2(b, a) * 180 / .pi, 360),
                          chroma: chromas[Int(Double(chromas.count) * 0.75)],
                          share: share))
    }

    // The background takes the hue of the picture's dark areas: the sky around the object,
    // which is rarely pure black.
    var dark = pixels.filter { $0.L < 0.4 }
    if dark.isEmpty { dark = pixels }
    let da = dark.reduce(0) { $0 + $1.a } / Double(dark.count)
    let db = dark.reduce(0) { $0 + $1.b } / Double(dark.count)

    return PictureInfo(meanLightness: meanL, colourfulness: totalChroma / n, peaks: peaks,
                       darkHue: positiveMod(atan2(db, da) * 180 / .pi, 360), darkChroma: hypot(da, db))
}

// MARK: - The palette

public struct Palette: Equatable, Sendable {
    /// "dark" or "light": what auto resolved to.
    public var mode: ColorMode
    public var colours: [String: PaletteColour]
    /// The two ends of the border gradient: the picture's two strongest colours.
    public var border: (PaletteColour, PaletteColour)

    public subscript(_ name: String) -> PaletteColour { colours[name]! }

    public static func == (a: Palette, b: Palette) -> Bool {
        a.mode == b.mode && a.colours == b.colours && a.border == b.border
    }

    /// The colours shown as swatches in the popover, as in the Omarchy widget.
    public static let swatchKeys = ["background", "lighter_background", "selection", "accent", "red", "orange",
                                    "yellow", "green", "cyan", "blue", "magenta", "foreground"]
}

public func buildPalette(_ info: PictureInfo, mode: ColorMode = .auto, vividness: Vividness = .balanced) -> Palette {
    let vivid = vividness.factor
    let mode: ColorMode = mode == .auto ? (info.meanLightness > 0.68 ? .light : .dark) : mode
    let light = mode == .light
    let peaks = info.peaks

    let accentHue: Double, accentChroma: Double
    if let first = peaks.first {
        accentHue = first.hue
        accentChroma = min(max(first.chroma * 1.1, 0.09), 0.19) * vivid
    } else {
        // A black-and-white picture gets a nearly grey theme.
        (accentHue, accentChroma) = (250, 0.03)
    }

    // Background: the dark areas' hue, or the accent's when they are neutral.
    var bgHue: Double, bgChroma: Double
    if info.darkChroma >= 0.006 {
        (bgHue, bgChroma) = (info.darkHue, min(max(info.darkChroma * 1.3, 0.010), 0.045))
    } else {
        (bgHue, bgChroma) = (accentHue, peaks.isEmpty ? 0.0 : 0.012)
    }
    bgChroma *= vivid
    let textChroma = min(bgChroma * 0.6, 0.02)

    func surface(_ L: Double) -> PaletteColour { PaletteColour(L, bgChroma, bgHue) }
    func text(_ L: Double, _ chroma: Double? = nil) -> PaletteColour { PaletteColour(L, chroma ?? textChroma, bgHue) }

    var c: [String: PaletteColour]
    let background: PaletteColour
    if light {
        background = surface(0.975)
        c = [
            "background": background,
            "dark_background": surface(0.95),
            "darker_background": surface(0.92),
            "lighter_background": surface(0.88),
            "foreground": text(0.27),
            "light_foreground": text(0.22),
            "bright_foreground": text(0.17),
            "dark_foreground": text(0.68, bgChroma),
            "muted": text(0.60, bgChroma),
            "selection": PaletteColour(0.86, min(0.07, accentChroma * 0.5), accentHue),
            "accent": PaletteColour(0.52, accentChroma, accentHue),
        ]
    } else {
        background = surface(0.19)
        c = [
            "background": background,
            "dark_background": surface(0.165),
            "darker_background": surface(0.14),
            "lighter_background": surface(0.26),
            "foreground": text(0.91),
            "light_foreground": text(0.86),
            "bright_foreground": text(0.97),
            "dark_foreground": text(0.62, bgChroma),
            "muted": text(0.50, bgChroma),
            "selection": PaletteColour(0.33, min(0.07, accentChroma * 0.5), accentHue),
            "accent": PaletteColour(0.78, accentChroma, accentHue),
        ]
    }

    // Terminal colours lean towards a prominent hue of the picture that is close to them, so
    // a teal nebula gets a teal cyan, but never so far that green stops looking green.
    let ansiChroma = min(max(0.06 + info.colourfulness * 0.8, 0.09), 0.15) * vivid
    for (name, baseHue, darkL, lightL) in ansiColours {
        var hue = baseHue, chroma = ansiChroma
        for p in peaks where p.share >= 0.08 && hueDistance(hue, p.hue) <= 30 {
            let delta = positiveMod(p.hue - hue + 180, 360) - 180
            hue += delta * 0.6
            // Capped: a clear blue sky would otherwise make cyan glare.
            chroma = max(chroma, min(p.chroma, 0.15) * vivid)
            break
        }
        c[name] = PaletteColour(light ? lightL : darkL, chroma, hue)
        if brightColours.contains(name) {
            c["bright_" + name] = PaletteColour(light ? lightL - 0.06 : darkL + 0.07, chroma * 1.1, hue)
        }
    }
    c["brown"] = PaletteColour(light ? 0.40 : 0.50, 0.07 * vivid, 60)

    // Legibility wins over fidelity.
    for name in ["foreground", "light_foreground", "bright_foreground"] {
        c[name] = readable(c[name]!, background, 10)
    }
    for name in ["accent"] + ansiColours.map(\.name) + brightColours.map({ "bright_" + $0 }) {
        c[name] = readable(c[name]!, background, 4.5)
    }
    c["dark_foreground"] = readable(c["dark_foreground"]!, background, 3)
    c["muted"] = readable(c["muted"]!, background, 2.2)

    let accent = c["accent"]!
    let second = peaks.count > 1
        ? PaletteColour(accent.L, max(peaks[1].chroma, 0.08) * vivid, peaks[1].hue)
        : PaletteColour(accent.L, accentChroma, accentHue + 50)
    return Palette(mode: mode, colours: c, border: (accent, second))
}

/// The palette of the picture at url.
public func palette(of url: URL, mode: ColorMode, vividness: Vividness) throws -> Palette {
    buildPalette(analyse(try readPixels(url)), mode: mode, vividness: vividness)
}

// MARK: - palette.json

/// What palette.json holds: enough for the popover's swatches and to rewrite terminal themes.
public struct PaletteFile: Codable, Equatable, Sendable {
    public var mode: String
    public var colors: [String: String]
    public var border: [String]

    public init(_ p: Palette) {
        mode = p.mode.rawValue
        colors = p.colours.mapValues(\.hex)
        border = [p.border.0.hex, p.border.1.hex]
    }

    public var palette: Palette? {
        var colours: [String: PaletteColour] = [:]
        for (k, v) in colors {
            guard let c = PaletteColour(hex: v) else { return nil }
            colours[k] = c
        }
        guard let m = ColorMode(rawValue: mode), border.count == 2,
              let b0 = PaletteColour(hex: border[0]), let b1 = PaletteColour(hex: border[1]) else { return nil }
        return Palette(mode: m, colours: colours, border: (b0, b1))
    }
}
