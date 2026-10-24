// What the app remembers between runs, and the pictures it keeps.
import Foundation

public enum Mode: String, Codable, Sendable {
    case latest, random
}

public struct Settings: Codable, Equatable, Sendable {
    public var colorMode: ColorMode = .auto
    public var vividness: Vividness = .balanced
    /// A notification when the picture changes.
    public var notify = true
    /// How different the picture and screen shapes may be before the picture is shown whole
    /// over a blurred copy instead of cropped. 1.2 crops away at most about 17%.
    public var fitThreshold = 1.2
    public var keepDays = 7
    /// Random mode picks from the archive since this date; older pictures are mostly small.
    public var randomSince = "2007-01-01"
    /// Random mode passes over pictures whose longer side is smaller.
    public var randomMinSize = 1920
    /// Terminal colour schemes to keep up to date. Ghostty, iTerm2 and kitty only when installed.
    public var terminalApp = true
    public var ghostty = true
    public var iterm = true
    /// kitty's current-theme.conf is the user's own theme, so it is replaced only when asked.
    public var kitty = false

    public init() {}

    /// Keys missing from settings saved by an older version keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        colorMode = try c.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? d.colorMode
        vividness = try c.decodeIfPresent(Vividness.self, forKey: .vividness) ?? d.vividness
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
        fitThreshold = try c.decodeIfPresent(Double.self, forKey: .fitThreshold) ?? d.fitThreshold
        keepDays = try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? d.keepDays
        randomSince = try c.decodeIfPresent(String.self, forKey: .randomSince) ?? d.randomSince
        randomMinSize = try c.decodeIfPresent(Int.self, forKey: .randomMinSize) ?? d.randomMinSize
        terminalApp = try c.decodeIfPresent(Bool.self, forKey: .terminalApp) ?? d.terminalApp
        ghostty = try c.decodeIfPresent(Bool.self, forKey: .ghostty) ?? d.ghostty
        iterm = try c.decodeIfPresent(Bool.self, forKey: .iterm) ?? d.iterm
        kitty = try c.decodeIfPresent(Bool.self, forKey: .kitty) ?? d.kitty
    }
}

/// A newer APOD that is a video, while an older picture is showing.
public struct VideoNote: Codable, Equatable, Sendable {
    public var date: String
    public var title: String?
    public var page: String
}

/// Files in ~/Library/Application Support/APOD (state) and ~/Library/Caches/APOD (pictures).
/// Every write goes to a temporary file first and is renamed into place, so a reader never
/// sees half a file.
public struct Store: Sendable {
    public let data: URL
    public let cache: URL

    public init(data: URL, cache: URL) {
        self.data = data
        self.cache = cache
    }

    public static var standard: Store {
        let fm = FileManager.default
        return Store(data: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("APOD"),
                     cache: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("APOD"))
    }

    public func prepare() throws {
        for dir in [data, cache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    func read(_ name: String) -> String? {
        (try? String(contentsOf: data.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ name: String, _ text: String?) throws {
        let url = data.appendingPathComponent(name)
        guard let text else { try? FileManager.default.removeItem(at: url); return }
        try prepare()
        try Data((text + "\n").utf8).write(to: url, options: [.atomic])
    }

    func readJSON<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let d = try? Data(contentsOf: data.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    func writeJSON<T: Encodable>(_ name: String, _ value: T?) throws {
        let url = data.appendingPathComponent(name)
        guard let value else { try? FileManager.default.removeItem(at: url); return }
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    public var mode: Mode { read("mode").flatMap(Mode.init) ?? .latest }
    public func setMode(_ m: Mode) throws { try write("mode", m.rawValue) }

    /// The current original, in the cache.
    public var current: URL? {
        guard let name = read("current"), !name.isEmpty, !name.contains("/") else { return nil }
        return cache.appendingPathComponent(name)
    }
    func setCurrent(_ url: URL) throws { try write("current", url.lastPathComponent) }

    /// The local day of the last picture change: random mode reshuffles once a day.
    public var changed: String? { read("changed") }
    func setChanged(_ day: String) throws { try write("changed", day) }

    /// When NASA was last asked for the newest picture.
    public var checked: Date? { read("checked").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }
    func setChecked(_ d: Date) throws { try write("checked", String(Int(d.timeIntervalSince1970))) }

    public var meta: APODEntry? { readJSON("meta.json", as: APODEntry.self) }
    func setMeta(_ e: APODEntry) throws { try writeJSON("meta.json", e) }

    public var video: VideoNote? { readJSON("video.json", as: VideoNote.self) }
    func setVideo(_ v: VideoNote?) throws { try writeJSON("video.json", v) }

    public var palette: PaletteFile? { readJSON("palette.json", as: PaletteFile.self) }
    func setPalette(_ p: PaletteFile) throws { try writeJSON("palette.json", p) }

    /// The cache path for entry's original, with the URL's extension; sd for the
    /// standard-size stand-in when the HD picture isn't there.
    func originalPath(_ entry: APODEntry, url: String, sd: Bool = false) -> URL {
        var ext = (URL(string: url)?.pathExtension ?? "").lowercased()
        if !["jpg", "jpeg", "png", "gif", "webp", "tif", "tiff"].contains(ext) { ext = "jpg" }
        return cache.appendingPathComponent("orig-\(entry.date)\(sd ? "-sd" : "").\(ext)")
    }

    /// The part of an original's name that its renders carry: "2026-10-01" or "2026-10-01-sd".
    public static func key(_ original: URL) -> String {
        String(original.deletingPathExtension().lastPathComponent.dropFirst("orig-".count))
    }

    /// Renders are named by picture, screen, size and fit setting, so a change of any of them
    /// makes a fresh one.
    func renderPath(key: String, screen: Screen, fit: Double) -> URL {
        cache.appendingPathComponent("render-\(key)-\(screen.id)-\(screen.width)x\(screen.height)-fit\(fit).jpg")
    }

    /// The renders of the picture with key, newest first.
    public func renders(key: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("render-\(key)-") && $0.pathExtension == "jpg" }
            .sorted { modified($0) > modified($1) }
    }

    func removeRenders(key: String) {
        for url in renders(key: key) { try? FileManager.default.removeItem(at: url) }
    }

    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Drop cached originals and renders older than keepDays, except the current picture's.
    func prune(keepDays: Int, now: Date = Date()) {
        guard let current else { return }
        let key = Self.key(current)
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("orig-") || name.hasPrefix("render-"), !name.contains(key),
                  now.timeIntervalSince(modified(url)) > Double(keepDays) * 86400 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// What a running action reports: its stage for the popover, download progress, the
/// problems it ran into (the first is the reason given when the action fails), and warnings
/// that are shown even when it succeeds.
public final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var problems: [String] = []
    private var notes: [String] = []
    private let onStage: @Sendable (String) -> Void
    private let onProgress: @Sendable (Int64, Int64) -> Void

    public init(stage: @escaping @Sendable (String) -> Void = { _ in },
                progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
        onStage = stage
        onProgress = progress
    }

    public func stage(_ message: String) {
        log(message)
        onStage(message)
    }

    public func problem(_ message: String) {
        log(message)
        lock.withLock { problems.append(message) }
    }

    /// Something worth telling even when the action succeeds, such as a terminal theme that
    /// couldn't be written.
    public func warning(_ message: String) {
        log(message)
        lock.withLock { if !notes.contains(message) { notes.append(message) } }
    }

    public var warnings: [String] { lock.withLock { notes } }

    public func progress(_ done: Int64, _ total: Int64) { onProgress(done, total) }

    /// After falling back to the APOD website, the API's error has been dealt with.
    public func forgetProblems() { lock.withLock { problems.removeAll() } }

    public var firstProblem: String? { lock.withLock { problems.first } }

    func log(_ message: String) {
        FileHandle.standardError.write(Data("apod: \(message)\n".utf8))
    }
}
