import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import APODCore

/// A picture drawn by `draw` into a w x h sRGB context.
func makeImage(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

func rgb(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func solid(_ hex: Int, _ w: Int = 40, _ h: Int = 40) -> CGImage {
    makeImage(w, h) { $0.setFillColor(rgb(hex)); $0.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
}

func linear(_ from: Int, _ to: Int, _ size: Int = 80) -> CGImage {
    makeImage(size, size) { ctx in
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(from), rgb(to)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size), options: [])
    }
}

func radial(_ inner: Int, _ outer: Int, _ size: Int = 80) -> CGImage {
    makeImage(size, size) { ctx in
        ctx.setFillColor(rgb(outer))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(inner), rgb(outer)] as CFArray, locations: nil)!
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2 * 1.41, options: [])
    }
}

func encode(_ image: CGImage, as type: UTType = .png) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("apod-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// NASA, as the tests want it: responses by URL prefix, and a log of what was asked.
final class FakeHTTP: HTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(prefix: String, code: Int, body: Data)] = []
    private(set) var requests: [String] = []

    func route(_ prefix: String, _ body: Data, code: Int = 200) {
        lock.withLock { routes.insert((prefix, code, body), at: 0) }
    }

    func route(_ prefix: String, json: String, code: Int = 200) { route(prefix, Data(json.utf8), code: code) }

    var asked: [String] { lock.withLock { requests } }

    private func answer(_ url: URL) throws -> (Data, Int) {
        let s = url.absoluteString
        return try lock.withLock {
            requests.append(s)
            guard let r = routes.first(where: { s.hasPrefix($0.prefix) }) else { throw URLError(.cannotConnectToHost) }
            return (r.body, r.code)
        }
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) { try answer(url) }

    func head(_ url: URL, bytes: Int, timeout: TimeInterval) async throws -> Data {
        let (data, code) = try answer(url)
        guard code == 200 else { throw URLError(.badServerResponse) }
        return data.prefix(bytes)
    }

    func download(_ url: URL, to file: URL, timeout: TimeInterval, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let (data, code) = try answer(url)
        guard code == 200 else { throw URLError(.badServerResponse) }
        progress(Int64(data.count), Int64(data.count))
        try data.write(to: file)
    }
}

final class FakeDesktop: Desktop, @unchecked Sendable {
    let lock = NSLock()
    var fail = false
    private(set) var set: [[String: URL]] = []

    func screens() async -> [Screen] { [Screen(id: "1", width: 320, height: 180), Screen(id: "2", width: 180, height: 320)] }

    func setWallpapers(_ files: [String: URL]) async throws {
        try lock.withLock {
            if fail { throw URLError(.unknown) }
            set.append(files)
        }
    }
}

final class FakeAnnouncer: Announcer, @unchecked Sendable {
    let lock = NSLock()
    private(set) var announced: [String] = []
    func announce(_ entry: APODEntry, image: URL?) async { lock.withLock { announced.append(entry.date) } }
}

/// An Updater on temporary state, with a fake NASA, desktop and notifications.
struct Harness {
    let dir = temporaryDirectory()
    let http = FakeHTTP()
    let desktop = FakeDesktop()
    let announcer = FakeAnnouncer()
    var store: Store { Store(data: dir.appendingPathComponent("data"), cache: dir.appendingPathComponent("cache")) }
    var updater: Updater {
        Updater(store: store, http: http, desktop: desktop, announcer: announcer,
                themes: TerminalThemes(home: dir.appendingPathComponent("home"), reload: false))
    }

    func context(now: Date = Date(), settings: Settings = Settings()) -> Updater.Context {
        var s = settings
        s.terminalApp = false   // never touch the real Terminal's preferences
        return Updater.Context(settings: s, apiKey: "DEMO_KEY",
                               patience: Patience(retries: 0, delay: 0, maxTime: 0, requestTimeout: 5, downloadTimeout: 5), now: now)
    }

    /// An API entry for date with an image of the given size at assets.science.nasa.gov.
    func picture(_ date: String, width: Int = 2400, height: Int = 1600, title: String = "Picture") -> String {
        let url = "https://apod.nasa.gov/apod/image/\(date).png"
        http.route(url, encode(solid(0x203060, width, height)))
        return #"{"date":"\#(date)","title":"\#(title)","media_type":"image","url":"\#(url)","hdurl":"\#(url)"}"#
    }
}
