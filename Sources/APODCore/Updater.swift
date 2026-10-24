// Picking, downloading and showing a picture: the port of omarchy-apod's show, cmd_update
// and set_entry.
import Foundation

/// A display, by its pixel size. The first screen is the primary one, whose render the palette comes from.
public struct Screen: Equatable, Sendable {
    public var id: String
    public var width: Int
    public var height: Int

    public init(id: String, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }
}

public protocol Desktop: Sendable {
    func screens() async -> [Screen]
    /// Set each screen's wallpaper, by screen id.
    func setWallpapers(_ files: [String: URL]) async throws
}

public protocol Announcer: Sendable {
    func announce(_ entry: APODEntry, image: URL?) async
}

public enum PictureKind: Equatable, Sendable {
    case latest, random, date(String)
}

/// What the popover shows.
public struct Status: Equatable, Sendable {
    public var entry: APODEntry?
    public var mode: Mode
    /// The primary screen's render.
    public var image: URL?
    public var palette: PaletteFile?
    /// A video newer than the picture showing, so the popover can say why the picture is older.
    public var video: VideoNote?

    public init(entry: APODEntry? = nil, mode: Mode = .latest, image: URL? = nil, palette: PaletteFile? = nil, video: VideoNote? = nil) {
        self.entry = entry
        self.mode = mode
        self.image = image
        self.palette = palette
        self.video = video
    }
}

public actor Updater {
    public static let maxTries = 15             // random mode: pictures to look at before settling for the largest one
    public static let maxUpscale = 2.0          // never enlarge a picture more; smaller ones are shown whole over a blurred copy
    public static let probeBytes = 262_144      // enough of a file to read the picture's size without downloading it
    public static let checkHours = 3.0          // latest mode: look for a new picture at most this often

    let store: Store
    let http: HTTP
    let desktop: Desktop
    let announcer: Announcer
    let themes: TerminalThemes
    private var last: Task<Void, Never>?

    public init(store: Store, http: HTTP, desktop: Desktop, announcer: Announcer, themes: TerminalThemes) {
        self.store = store
        self.http = http
        self.desktop = desktop
        self.announcer = announcer
        self.themes = themes
    }

    /// Everything one action needs to know.
    public struct Context: Sendable {
        public var settings: Settings
        public var apiKey: String
        public var patience: Patience
        public var report: Reporter
        public var now: Date

        public init(settings: Settings, apiKey: String, patience: Patience = .background, report: Reporter = Reporter(), now: Date = Date()) {
            self.settings = settings
            self.apiKey = apiKey
            self.patience = patience
            self.report = report
            self.now = now
        }
    }

    func client(_ ctx: Context) -> APODClient {
        APODClient(http: http, apiKey: ctx.apiKey, patience: ctx.patience, report: ctx.report)
    }

    /// One action at a time, in the order asked, as the scripts' flock did.
    private func serialized<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = last
        let task = Task { () async throws -> T in
            await previous?.value
            return try await op()
        }
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Entry points

    /// The background run (20 s after launch, hourly, after wake): follows the mode chosen in
    /// the popover, and does nothing at all when there is nothing new.
    public func update(_ ctx: Context, date: String? = nil) async throws {
        try await serialized { try await self.runUpdate(ctx, date: date) }
    }

    /// Latest or Random in the popover: show one now and remember the mode, only on success.
    public func choose(_ mode: Mode, _ ctx: Context) async throws {
        try await serialized {
            try await self.show(mode == .latest ? .latest : .random, ctx, force: true)
            try self.store.setMode(mode)
        }
    }

    /// Rebuild from the current picture: after a colour setting changed (palette) or the
    /// screens changed (renders). Fetches today's picture if there is none yet.
    public func apply(_ ctx: Context, rebuildPalette: Bool = true) async throws {
        try await serialized { try await self.runApply(ctx, rebuildPalette: rebuildPalette) }
    }

    public func status() -> Status {
        let entry = store.meta
        let mode = store.mode
        let image = store.current.flatMap { store.renders(key: Store.key($0)).first }
        var video = store.video
        if mode != .latest || (video?.date ?? "") <= (entry?.date ?? "") { video = nil }
        return Status(entry: entry, mode: mode, image: image, palette: store.palette, video: video)
    }

    // MARK: The work

    func runUpdate(_ ctx: Context, date: String?) async throws {
        if let date {
            try await show(.date(date), ctx, force: false)
            return
        }
        let cur = store.current
        if store.mode == .random {
            // One random picture a day, not one per wake.
            if cur == nil || store.changed != APODDate.localDay(ctx.now) {
                try await show(.random, ctx, force: false)
            }
            return
        }
        let today = APODDate.today(ctx.now)
        if let cur {
            // Today's picture (in HD) is already showing.
            let name = cur.lastPathComponent
            if !name.contains("-sd.") && name.hasPrefix("orig-\(today).") { return }
            // Today's APOD is a video: the newest photo is already showing.
            if store.video?.date == today { return }
            // We looked recently.
            if let checked = store.checked, ctx.now.timeIntervalSince(checked) < Self.checkHours * 3600 { return }
        }
        try await show(.latest, ctx, force: false)
        try store.setChecked(ctx.now)
    }

    func runApply(_ ctx: Context, rebuildPalette: Bool) async throws {
        guard let orig = store.current, FileManager.default.fileExists(atPath: orig.path), let meta = store.meta else {
            ctx.report.stage("no picture yet; fetching today's")
            try await show(.latest, ctx, force: true)
            return
        }
        let renders = try await renderAll(orig, ctx)
        if rebuildPalette || store.palette == nil { try buildTheme(renders.primary, meta: meta, ctx) }
        try await desktop.setWallpapers(renders.files)
    }

    /// APOD entries to try, in order.
    func candidates(_ kind: PictureKind, _ ctx: Context) async throws -> [APODEntry] {
        let client = client(ctx)
        switch kind {
        case .latest:
            // Newest first over 10 days, so that on video days we fall back to the latest photo.
            let today = APODDate.today(ctx.now)
            let dates = (0...10).reversed().map { APODDate.adding(-$0, to: today) }
            return try await client.entries([URLQueryItem(name: "start_date", value: dates[0])], dates: dates).reversed()
        case .random:
            // A random month of the archive, shuffled: one API request gives plenty of candidates.
            let since = APODDate.parse(ctx.settings.randomSince) != nil ? ctx.settings.randomSince : "2007-01-01"
            let days = max(APODDate.days(from: since, to: APODDate.today(ctx.now)) - 30, 1)
            let start = APODDate.adding(Int.random(in: 0..<days), to: since)
            let dates = (0..<30).map { APODDate.adding($0, to: start) }
            return try await client.entries([URLQueryItem(name: "start_date", value: start),
                                             URLQueryItem(name: "end_date", value: dates[29])], dates: dates).shuffled()
        case .date(let d):
            return try await client.entries([URLQueryItem(name: "date", value: d)], dates: [d])
        }
    }

    /// Fetch a picture and make it the wallpaper. Videos are passed over; in latest mode the
    /// newest one is noted for the popover. Random mode reads each picture's size before
    /// downloading it and passes over small ones; when none of maxTries is big enough it
    /// settles for the largest, so it doesn't fail on an archive month full of small pictures.
    /// On failure the current picture stays.
    func show(_ kind: PictureKind, _ ctx: Context, force: Bool) async throws {
        let report = ctx.report, client = client(ctx), minSize = ctx.settings.randomMinSize
        report.stage("looking for a picture")
        var newest = true, tried = 0
        var best: (entry: APODEntry, size: Int)?
        for candidate in try await candidates(kind, ctx) {
            try Task.checkCancellation()
            guard let entry = try? await client.resolve(candidate) else { continue }
            if entry.isVideo {
                if kind == .latest && newest {
                    try? store.setVideo(VideoNote(date: entry.date, title: entry.title, page: entry.page))
                }
                report.stage("\(entry.date) is a video; trying another")
                newest = false
                continue
            }
            if kind == .latest && newest { try? store.setVideo(nil) }
            newest = false
            if kind == .random {
                if tried >= Self.maxTries { break }
                tried += 1
                report.stage("checking \(entry.date): \(entry.title ?? "")")
                if let size = await probeSize(entry.bestURL, ctx), size < minSize {
                    report.stage("\(entry.date) is only \(size)px; trying another")
                    if size > best?.size ?? 0 { best = (entry, size) }
                    continue
                }
            }
            guard let orig = try? await download(entry, ctx) else { continue }
            // The size couldn't be read beforehand; check the download instead.
            if kind == .random, let size = Renderer.size(of: orig).map({ max($0.width, $0.height) }), size < minSize {
                report.stage("\(entry.date) is only \(size)px; trying another")
                if size > best?.size ?? 0 { best = (entry, size) }
                if orig != store.current { try? FileManager.default.removeItem(at: orig) }
                continue
            }
            try await setEntry(entry, orig, ctx, force: force)
            return
        }
        if let best {
            report.stage("no picture of \(minSize)px or more found; using the largest (\(best.size)px)")
            if let orig = try? await download(best.entry, ctx) {
                try await setEntry(best.entry, orig, ctx, force: force)
                return
            }
        }
        try Task.checkCancellation()
        let reason = report.firstProblem ?? "no picture fetched; keeping the current one"
        report.problem("no picture fetched; keeping the current one")
        throw APODError.message(reason)
    }

    /// The picture's longer side, read from the start of the file without downloading the
    /// rest; nil when it can't be told.
    func probeSize(_ url: String?, _ ctx: Context) async -> Int? {
        guard let url = url.flatMap(URL.init(string:)), url.scheme == "https",
              let data = try? await http.head(url, bytes: Self.probeBytes, timeout: ctx.patience.requestTimeout) else { return nil }
        return Renderer.longerSide(ofStart: data)
    }

    /// The cached original of entry, downloading it if needed.
    func download(_ entry: APODEntry, _ ctx: Context) async throws -> URL {
        let report = ctx.report
        guard let hd = entry.bestURL else { throw APODError.message("image download failed") }
        let sd = entry.url
        var orig = store.originalPath(entry, url: hd)
        if nonEmpty(orig) { return orig }
        report.stage("downloading \(entry.date): \(entry.title ?? "")")
        if (try? await fetch(hd, to: orig, ctx)) != nil { return orig }
        // NASA sometimes lists an HD image that isn't on the server (yet). Use the standard-size
        // one, cached under its own name so a later run still picks up the HD image.
        if let sd, sd != hd {
            orig = store.originalPath(entry, url: sd, sd: true)
            if nonEmpty(orig) { return orig }
            if (try? await fetch(sd, to: orig, ctx)) != nil {
                report.stage("HD image unavailable; using the standard-size one")
                return orig
            }
        }
        report.problem("image download failed")
        throw APODError.message("image download failed")
    }

    func nonEmpty(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) > 0
    }

    /// Download url to file, keeping it only if it is a picture.
    func fetch(_ url: String, to file: URL, _ ctx: Context) async throws {
        guard let u = URL(string: url), u.scheme == "https" else { throw APODError.message("not an https address") }
        try store.prepare()
        let part = file.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        let report = ctx.report
        do {
            try await http.download(u, to: part, timeout: ctx.patience.downloadTimeout) { report.progress($0, $1) }
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
        // A Wi-Fi login page or an error page can come back as a successful download.
        guard Renderer.isPicture(part) else {
            try? FileManager.default.removeItem(at: part)
            report.problem("the download of \(u.lastPathComponent) is not an image")
            throw APODError.message("the download of \(u.lastPathComponent) is not an image")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: part, to: file)
        // Renders are named by the original's key only; drop any made from an earlier download of it.
        store.removeRenders(key: Store.key(file))
    }

    /// Make the downloaded picture current: render it for every screen, set the wallpaper and
    /// the terminal colours, and only then save it as the current picture.
    func setEntry(_ entry: APODEntry, _ orig: URL, _ ctx: Context, force: Bool) async throws {
        let cur = store.current
        // The HD image replacing its standard-size stand-in counts as new for rendering but not
        // for the notification.
        let isNew = cur != orig
        if !isNew && !force { return }
        let renders = try await renderAll(orig, ctx)
        if isNew || store.palette == nil { try buildTheme(renders.primary, meta: entry, ctx) }
        ctx.report.stage("setting the wallpaper")
        do {
            try await desktop.setWallpapers(renders.files)
        } catch {
            ctx.report.problem("couldn't set the wallpaper")
            throw APODError.message("couldn't set the wallpaper")
        }
        do {
            try store.setMeta(entry)
            try store.setCurrent(orig)
            try store.setChanged(APODDate.localDay(ctx.now))
        } catch {
            ctx.report.problem("couldn't save picture information")
            throw APODError.message("couldn't save picture information")
        }
        store.prune(keepDays: ctx.settings.keepDays, now: ctx.now)
        // Only announce a picture change, not the HD upgrade of the same picture.
        if isNew && ctx.settings.notify && cur?.lastPathComponent.hasPrefix("orig-\(entry.date)-sd.") != true {
            await announcer.announce(entry, image: renders.primary)
        }
    }

    /// The picture fitted to every screen, reusing renders made before.
    func renderAll(_ orig: URL, _ ctx: Context) async throws -> (files: [String: URL], primary: URL) {
        var screens = await desktop.screens()
        if screens.isEmpty { screens = [Screen(id: "main", width: 1920, height: 1080)] }
        let key = Store.key(orig)
        var files: [String: URL] = [:]
        for screen in screens {
            let out = store.renderPath(key: key, screen: screen, fit: ctx.settings.fitThreshold)
            if !nonEmpty(out) {
                if let (iw, ih) = Renderer.size(of: orig) {
                    let plan = Renderer.plan(imageWidth: iw, imageHeight: ih, screenWidth: screen.width, screenHeight: screen.height,
                                             threshold: ctx.settings.fitThreshold, maxUpscale: Self.maxUpscale)
                    ctx.report.stage("fitting the picture to the screen (\(iw)x\(ih) -> \(screen.width)x\(screen.height), \(plan == .crop ? "crop" : "fit"))")
                }
                do {
                    try Renderer.render(orig, width: screen.width, height: screen.height, to: out,
                                        threshold: ctx.settings.fitThreshold, maxUpscale: Self.maxUpscale)
                } catch {
                    ctx.report.problem("rendering failed")
                    throw APODError.message("rendering failed")
                }
            }
            store.touch(out)
            files[screen.id] = out
        }
        return (files, files[screens[0].id]!)
    }

    /// The palette from the primary screen's render, which is what is actually on screen,
    /// and the terminal themes made from it.
    func buildTheme(_ render: URL, meta: APODEntry, _ ctx: Context) throws {
        ctx.report.stage("working out the theme colours")
        let p: Palette
        do {
            p = try palette(of: render, mode: ctx.settings.colorMode, vividness: ctx.settings.vividness)
        } catch {
            ctx.report.problem("couldn't work out the picture's colours")
            throw APODError.message("couldn't work out the picture's colours")
        }
        try store.setPalette(PaletteFile(p))
        themes.write(p, title: "\(meta.title ?? "") (\(meta.date))", settings: ctx.settings, report: ctx.report)
        ctx.report.stage("theme built (\(p.mode.rawValue), accent \(p["accent"].hex))")
    }
}
