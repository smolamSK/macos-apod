import CoreGraphics
import Foundation
import Testing
@testable import APODCore

struct PaletteTests {
    func paletteFor(_ image: CGImage, mode: ColorMode = .auto, vividness: Vividness = .balanced) throws -> Palette {
        buildPalette(analyse(try pixels(of: image)), mode: mode, vividness: vividness)
    }

    static let pictures: [(String, CGImage)] = [
        ("red nebula", radial(0xff5030, 0x100000)),
        ("blue sky", linear(0xa0c8ff, 0x3070d0)),
        ("white", solid(0xffffff, 80, 80)),
        ("black", solid(0x000000, 80, 80)),
        ("grey moon", radial(0xd0d0d0, 0x000000)),
        ("green aurora", linear(0x00ff80, 0x001020)),
    ]

    @Test func textStaysReadableOnEveryKindOfPicture() throws {
        for (name, image) in Self.pictures {
            for mode in ColorMode.allCases {
                for vividness in Vividness.allCases {
                    let p = try paletteFor(image, mode: mode, vividness: vividness)
                    let bg = p["background"]
                    #expect(contrast(p["foreground"], bg) >= 10, "\(name) \(mode) \(vividness)")
                    for key in ["accent"] + ansiColours.map(\.name) + brightColours.map({ "bright_" + $0 }) {
                        #expect(contrast(p[key], bg) >= 4.5, "\(name) \(mode) \(vividness) \(key)")
                    }
                    // Every terminal colour exists.
                    #expect(TerminalScheme(p).ansi.count == 16)
                }
            }
        }
    }

    @Test func brightPicturesGetALightThemeInAuto() throws {
        #expect(try paletteFor(solid(0xfff4e0)).mode == .light)
        #expect(try paletteFor(solid(0x050510)).mode == .dark)
    }

    @Test func accentFollowsThePicturesStrongestHue() throws {
        let image = makeImage(80, 80) { ctx in
            ctx.setFillColor(rgb(0x060608))
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            ctx.setFillColor(rgb(0x20c040))
            ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 40, height: 40))
        }
        let p = try paletteFor(image)
        #expect(hueDistance(p["accent"].h, 145) < 25)
        // Green in the picture pulls the terminal green towards it, but red stays red.
        #expect(hueDistance(p["red"].h, 25) < 1)
    }

    @Test func coloursStayInSRGB() {
        for (L, C, h) in [(0.9, 0.4, 145.0), (0.2, 0.4, 260.0), (0.7, 0.3, 25.0)] {
            let c = PaletteColour(L, C, h)
            #expect(c.hex.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil)
            #expect(c.C <= C)
        }
    }

    @Test func paletteFileRoundTrips() throws {
        let p = try paletteFor(radial(0xff5030, 0x100000))
        let back = try #require(PaletteFile(p).palette)
        #expect(PaletteFile(back) == PaletteFile(p))
    }

    /// apod-palette.py build() output for the same picture description, every colour.
    static let python: [(ColorMode, Vividness, String, [String: String])] = [
        (.auto, .subtle, "dark", ["accent": "#f89b8b", "background": "#15121b", "blue": "#80a1ca", "bright_blue": "#92b8e5", "bright_cyan": "#8fdde2", "bright_foreground": "#f6f4fc", "bright_green": "#acd8ac", "bright_magenta": "#d7a9d2", "bright_red": "#ee9185", "bright_yellow": "#f1e2a7", "brown": "#785d47", "cyan": "#80c5c9", "dark_background": "#0f0d15", "dark_foreground": "#888490", "darker_background": "#0a0810", "foreground": "#e2e0e8", "green": "#99c199", "light_foreground": "#d2cfd7", "lighter_background": "#25222c", "magenta": "#be95ba", "muted": "#65616c", "orange": "#e49478", "red": "#d17e74", "selection": "#4f2923", "yellow": "#d9cb97"]),
        (.auto, .balanced, "dark", ["accent": "#ff9686", "background": "#16111e", "blue": "#71a2db", "bright_blue": "#81b8f9", "bright_cyan": "#68e4ea", "bright_foreground": "#f6f3fe", "bright_green": "#9dde9e", "bright_magenta": "#e3a1dc", "bright_red": "#ff8577", "bright_yellow": "#f8e18a", "brown": "#815939", "cyan": "#5dcbd1", "dark_background": "#100c18", "dark_foreground": "#888394", "darker_background": "#0b0712", "foreground": "#e3dfea", "green": "#8bc58d", "light_foreground": "#d2cfda", "lighter_background": "#26212f", "magenta": "#c88ec3", "muted": "#656070", "orange": "#f9875e", "red": "#e66f62", "selection": "#54261f", "yellow": "#dfca7d"]),
        (.auto, .vivid, "dark", ["accent": "#ff9686", "background": "#161021", "blue": "#5ea2f0", "bright_blue": "#7cb8ff", "bright_cyan": "#00e9f3", "bright_foreground": "#f7f3ff", "bright_green": "#89e48c", "bright_magenta": "#ef96e8", "bright_red": "#ff8577", "bright_yellow": "#ffe068", "brown": "#8a5524", "cyan": "#00d0d9", "dark_background": "#110a1b", "dark_foreground": "#898299", "darker_background": "#0b0615", "foreground": "#e3dfed", "green": "#7acb7d", "light_foreground": "#d3cedd", "lighter_background": "#272033", "magenta": "#d484cd", "muted": "#665f75", "orange": "#ff8255", "red": "#fd584b", "selection": "#54261f", "yellow": "#e6c959"]),
        (.light, .subtle, "light", ["accent": "#a14c3f", "background": "#f8f5ff", "blue": "#46658a", "bright_blue": "#32547c", "bright_cyan": "#126a6f", "bright_foreground": "#100e14", "bright_green": "#416942", "bright_magenta": "#70486c", "bright_red": "#8d3a32", "bright_yellow": "#7d6e37", "brown": "#5b412c", "cyan": "#357b7f", "dark_background": "#f0ecf9", "dark_foreground": "#918d99", "darker_background": "#e6e2ef", "foreground": "#27252b", "green": "#557a55", "light_foreground": "#1b1a1f", "lighter_background": "#d9d5e2", "magenta": "#805a7c", "muted": "#827e8a", "orange": "#a85d43", "red": "#9c4f46", "selection": "#f5c4bb", "yellow": "#7e7140"]),
        (.light, .balanced, "light", ["accent": "#b43628", "background": "#f8f5ff", "blue": "#37659b", "bright_blue": "#1f548d", "bright_cyan": "#006b70", "bright_foreground": "#100e15", "bright_green": "#2f6d34", "bright_magenta": "#793f75", "bright_red": "#a01f1b", "bright_yellow": "#836d03", "brown": "#633e1d", "cyan": "#007e84", "dark_background": "#f1ebfe", "dark_foreground": "#918c9d", "darker_background": "#e7e1f4", "foreground": "#27252d", "green": "#447b46", "light_foreground": "#1c1921", "lighter_background": "#dad4e7", "magenta": "#895284", "muted": "#827d8e", "orange": "#ba4e25", "red": "#af3d34", "selection": "#fcc1b6", "yellow": "#847020"]),
        (.light, .vivid, "light", ["accent": "#c50e00", "background": "#f8f5ff", "blue": "#1e64ad", "bright_blue": "#00529b", "bright_cyan": "#006b70", "bright_foreground": "#110d17", "bright_green": "#06721d", "bright_magenta": "#83317e", "bright_red": "#a80009", "bright_yellow": "#836d00", "brown": "#6b3900", "cyan": "#007e84", "dark_background": "#f1ebff", "dark_foreground": "#928ba2", "darker_background": "#e8e0f9", "foreground": "#28242f", "green": "#2d7f35", "light_foreground": "#1c1923", "lighter_background": "#dbd3ec", "magenta": "#93488d", "muted": "#837c93", "orange": "#c54300", "red": "#c31617", "selection": "#fcc1b6", "yellow": "#867000"]),
    ]

    /// The same colours as apod-palette.py for the same picture description.
    @Test func matchesThePythonOriginal() {
        let info = PictureInfo(meanLightness: 0.2, colourfulness: 0.05,
                               peaks: [Peak(hue: 30, chroma: 0.15, share: 0.6), Peak(hue: 250, chroma: 0.1, share: 0.3)],
                               darkHue: 300, darkChroma: 0.02)
        for (mode, vividness, resolved, colours) in Self.python {
            let p = buildPalette(info, mode: mode, vividness: vividness)
            #expect(p.mode.rawValue == resolved)
            #expect(p.colours.mapValues(\.hex) == colours, "\(mode) \(vividness)")
        }
    }

    /// apod-palette.py's analyse() on the same pixels finds the same peaks.
    @Test func analysesLikeThePythonOriginal() {
        let px = (0..<3000).map { (i: Int) -> (L: Double, a: Double, b: Double) in
            let r = Double((i * 37) % 256), g = Double((i * 91) % 256), b = Double((i * 13) % 256)
            return oklab(r, g, b)
        }
        let info = analyse(px)
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        #expect(close(info.meanLightness, 0.6407317911428737))
        #expect(close(info.colourfulness, 0.1497594608583209))
        #expect(close(info.darkHue, 2.464145818443191))
        #expect(close(info.darkChroma, 0.06417696036407705))
        let expected = [(142.45150026067444, 0.22044917546545878, 0.2552161270360574),
                        (332.63838092963914, 0.25234158725906614, 0.15458006956110246),
                        (25.82278045517283, 0.21297973340260393, 0.12746566260324163)]
        #expect(info.peaks.count == expected.count)
        for (peak, (hue, chroma, share)) in zip(info.peaks, expected) {
            #expect(close(peak.hue, hue) && close(peak.chroma, chroma) && close(peak.share, share))
        }
        let p = buildPalette(info)
        #expect([p["accent"].hex, p["background"].hex, p["cyan"].hex, p.border.1.hex] == ["#64d55d", "#240a12", "#00d0d9", "#ff80ee"])
    }
}
