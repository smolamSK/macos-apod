import AppKit
import Foundation
import Testing
@testable import APODCore

struct UpdaterTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-01T18:00:00Z")!   // 14:00 in New York
    let api = "https://api.nasa.gov/planetary/apod"

    @Test func newPictureSetsTheWallpaperOnEveryScreenAndNotifiesOnce() async throws {
        let h = Harness()
        h.http.route(api, json: "[\(h.picture("2026-10-01"))]")
        try await h.updater.update(h.context(now: now))
        #expect(h.store.current?.lastPathComponent == "orig-2026-10-01.png")
        #expect(h.store.meta?.title == "Picture")
        #expect(h.announcer.announced == ["2026-10-01"])
        let files = try #require(h.desktop.set.last)
        #expect(Set(files.keys) == ["1", "2"])
        // Each screen gets its own render at its own size.
        #expect(Renderer.size(of: files["1"]!)! == (320, 180))
        #expect(Renderer.size(of: files["2"]!)! == (180, 320))
        #expect(h.store.palette != nil)
        // The same picture again changes nothing and says nothing.
        let again = h.context(now: now.addingTimeInterval(4 * 3600))
        try await h.updater.update(again)
        #expect(h.announcer.announced.count == 1)
    }

    @Test func updateAsksNasaOnlyWhenSomethingMayBeNew() async throws {
        let h = Harness()
        h.http.route(api, json: "[\(h.picture("2026-09-30"))]")
        try await h.updater.update(h.context(now: now))
        let asked = h.http.asked.count
        // Yesterday's picture is showing, but NASA was asked less than 3 hours ago.
        try await h.updater.update(h.context(now: now.addingTimeInterval(3600)))
        #expect(h.http.asked.count == asked)
        // After 3 hours it asks again.
        try await h.updater.update(h.context(now: now.addingTimeInterval(3 * 3600 + 1)))
        #expect(h.http.asked.count > asked)
    }

    @Test func latestPassesOverAVideoAndNotesIt() async throws {
        let h = Harness()
        let video = #"{"date":"2026-10-01","title":"A video","media_type":"video","url":"https://youtube.com/x"}"#
        h.http.route(api, json: "[\(h.picture("2026-09-30")), \(video)]")
        try await h.updater.update(h.context(now: now))
        #expect(h.store.current?.lastPathComponent == "orig-2026-09-30.png")
        #expect(h.store.video?.date == "2026-10-01")
        #expect(await h.updater.status().video?.title == "A video")
        // Today's APOD is a video: nothing more to ask today.
        let asked = h.http.asked.count
        try await h.updater.update(h.context(now: now.addingTimeInterval(5 * 3600)))
        #expect(h.http.asked.count == asked)
    }

    @Test func randomSkipsSmallPicturesWithoutDownloadingThem() async throws {
        let h = Harness()
        h.http.route(api, json: "[\(h.picture("2010-01-01", width: 800, height: 600)), \(h.picture("2010-01-02"))]")
        try await h.updater.choose(.random, h.context(now: now))
        #expect(h.store.current?.lastPathComponent == "orig-2010-01-02.png")
        #expect(h.store.mode == .random)
        #expect(!FileManager.default.fileExists(atPath: h.store.cache.appendingPathComponent("orig-2010-01-01.png").path))
    }

    @Test func randomSettlesForTheLargestWhenAllAreSmall() async throws {
        let h = Harness()
        h.http.route(api, json: "[\(h.picture("2010-01-01", width: 800, height: 600)), \(h.picture("2010-01-02", width: 1200, height: 900))]")
        try await h.updater.choose(.random, h.context(now: now))
        #expect(h.store.current?.lastPathComponent == "orig-2010-01-02.png")
    }

    @Test func randomReshufflesOnceADay() async throws {
        let h = Harness()
        h.http.route(api, json: "[\(h.picture("2010-01-02"))]")
        try await h.updater.choose(.random, h.context(now: now))
        let asked = h.http.asked.count
        try await h.updater.update(h.context(now: now.addingTimeInterval(60)))
        #expect(h.http.asked.count == asked)
    }

    @Test func failureKeepsStateAndModeAndSaysWhy() async throws {
        let h = Harness()
        h.http.route(api, json: "[\(h.picture("2026-10-01"))]")
        try await h.updater.update(h.context(now: now))
        h.http.route(api, json: "{}", code: 429)
        h.http.route("https://science.nasa.gov/", json: "", code: 503)
        let ctx = h.context(now: now)
        await #expect(throws: APODError.self) { try await h.updater.choose(.random, ctx) }
        #expect(h.store.mode == .latest)
        #expect(h.store.current?.lastPathComponent == "orig-2026-10-01.png")
        #expect(ctx.report.firstProblem != nil)
    }

    @Test func failedWallpaperKeepsTheOldPictureAndDoesNotNotify() async throws {
        let h = Harness()
        h.desktop.fail = true
        h.http.route(api, json: "[\(h.picture("2026-10-01"))]")
        await #expect(throws: APODError.self) { try await h.updater.update(h.context(now: now)) }
        #expect(h.store.current == nil)
        #expect(h.announcer.announced.isEmpty)
        // It works once the desktop does.
        h.desktop.fail = false
        try await h.updater.update(h.context(now: now))
        #expect(h.announcer.announced == ["2026-10-01"])
    }

    @Test func hdUpgradeDoesNotNotifyAgain() async throws {
        let h = Harness()
        let hd = "https://apod.nasa.gov/apod/image/hd.png", sd = "https://apod.nasa.gov/apod/image/sd.png"
        h.http.route(sd, encode(solid(0x203060, 400, 300)))
        h.http.route(hd, Data(), code: 404)
        h.http.route(api, json: #"[{"date":"2026-10-01","title":"P","media_type":"image","url":"\#(sd)","hdurl":"\#(hd)"}]"#)
        try await h.updater.update(h.context(now: now))
        #expect(h.store.current?.lastPathComponent == "orig-2026-10-01-sd.png")
        // The HD picture arrives by the next check: a new render, no second notification.
        h.http.route(hd, encode(solid(0x203060, 2400, 1800)))
        try await h.updater.update(h.context(now: now.addingTimeInterval(3 * 3600 + 1)))
        #expect(h.store.current?.lastPathComponent == "orig-2026-10-01.png")
        #expect(h.announcer.announced == ["2026-10-01"])
    }

    @Test func aDownloadThatIsNotAPictureIsDropped() async throws {
        let h = Harness()
        let url = "https://apod.nasa.gov/apod/image/a.jpg"
        h.http.route(url, json: "<html>Wi-Fi login</html>")
        h.http.route(api, json: #"[{"date":"2026-10-01","title":"P","media_type":"image","url":"\#(url)","hdurl":"\#(url)"}]"#)
        await #expect(throws: APODError.self) { try await h.updater.update(h.context(now: now)) }
        let files = try FileManager.default.contentsOfDirectory(atPath: h.store.cache.path)
        #expect(files.isEmpty)
    }

    @Test func colourSettingChangeRebuildsThePalette() async throws {
        let h = Harness()
        h.http.route(api, json: "[\(h.picture("2026-10-01"))]")
        try await h.updater.update(h.context(now: now))
        #expect(h.store.palette?.mode == "dark")
        var settings = Settings()
        settings.colorMode = .light
        try await h.updater.apply(h.context(now: now, settings: settings))
        #expect(h.store.palette?.mode == "light")
    }
}

struct RendererTests {
    @Test func cropsWhenTheShapesAreClose() {
        #expect(Renderer.plan(imageWidth: 4000, imageHeight: 2400, screenWidth: 1920, screenHeight: 1080) == .crop)
    }

    @Test func fitsWhenTheShapesDiffer() {
        // A tall photo on a wide screen.
        #expect(Renderer.plan(imageWidth: 2000, imageHeight: 3000, screenWidth: 1920, screenHeight: 1080) == .fit(width: 720, height: 1080))
    }

    @Test func smallPicturesAreNotEnlargedMoreThanTwice() {
        #expect(Renderer.plan(imageWidth: 800, imageHeight: 450, screenWidth: 3840, screenHeight: 2160) == .fit(width: 1600, height: 900))
    }

    @Test func rendersAtTheScreenSize() throws {
        let dir = temporaryDirectory()
        let src = dir.appendingPathComponent("a.png"), out = dir.appendingPathComponent("r.jpg")
        try encode(radial(0xff5030, 0x100000, 300)).write(to: src)
        for (w, h) in [(640, 360), (360, 640)] {
            try Renderer.render(src, width: w, height: h, to: out)
            #expect(Renderer.size(of: out)! == (w, h))
        }
        #expect(!FileManager.default.fileExists(atPath: out.path + ".part"))
    }

    @Test func readsTheSizeFromTheStartOfAFile() {
        let data = encode(solid(0x102030, 2600, 1300), as: .jpeg)
        #expect(Renderer.longerSide(ofStart: data.prefix(4096)) == 2600)
    }
}

struct TerminalThemeTests {
    func palette() throws -> Palette {
        buildPalette(analyse(try pixels(of: radial(0xff5030, 0x100000))))
    }

    @Test func ghosttyThemeHasEveryColour() throws {
        let text = TerminalThemes.ghostty(TerminalScheme(try palette()), title: "Test (2026-10-01)")
        #expect(text.hasPrefix("# " + generatedHeader))
        for i in 0..<16 { #expect(text.contains("palette = \(i)=#")) }
        #expect(text.contains("background = #"))
    }

    @Test func itermProfileIsValidJSON() throws {
        let data = try TerminalThemes.iterm(TerminalScheme(try palette()))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
        let profile = try #require(json["Profiles"]?.first)
        #expect(profile["Name"] as? String == "APOD")
        #expect(profile["Ansi 15 Color"] != nil)
    }

    @Test func terminalFileUnarchivesToColours() throws {
        let data = try TerminalThemes.terminalFileData(TerminalScheme(try palette()))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["name"] as? String == "APOD")
        let archived = try #require(plist["ANSIRedColor"] as? Data)
        #expect(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: archived) != nil)
    }

    @Test func aUsersOwnThemeIsNeverOverwritten() throws {
        let home = temporaryDirectory()
        let themes = TerminalThemes(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/ghostty/themes"), withIntermediateDirectories: true)
        try "background = #ffffff\n".write(to: themes.ghosttyTheme, atomically: true, encoding: .utf8)
        var settings = Settings()
        settings.terminalApp = false
        let report = Reporter()
        themes.write(try palette(), title: "", settings: settings, report: report)
        #expect(try String(contentsOf: themes.ghosttyTheme, encoding: .utf8) == "background = #ffffff\n")
        #expect(report.warnings.first?.contains("didn't make") == true)
        // Ours gets rewritten.
        try FileManager.default.removeItem(at: themes.ghosttyTheme)
        themes.write(try palette(), title: "", settings: settings, report: report)
        themes.write(try palette(), title: "", settings: settings, report: report)
        #expect(try String(contentsOf: themes.ghosttyTheme, encoding: .utf8).contains(generatedHeader))
    }

    @Test func kittyThemeHasEveryColour() throws {
        let p = try palette()
        let text = TerminalThemes.kitty(TerminalScheme(p), palette: p, title: "Test (2026-10-01)")
        #expect(text.hasPrefix("# " + generatedHeader))
        for i in 0..<16 { #expect(text.contains("\ncolor\(i) #")) }
        #expect(text.contains("\nbackground #"))
        #expect(text.contains("\nactive_tab_background #"))
        // The user's opacity and blur in kitty.conf stay in effect.
        #expect(!text.contains("opacity"))
    }

    @Test func kittyTakesOverAndGivesBackTheTheme() throws {
        let home = temporaryDirectory()
        let themes = TerminalThemes(home: home, reload: false)
        let dir = home.appendingPathComponent(".config/kitty")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "font_size 13\ninclude current-theme.conf\n".write(to: dir.appendingPathComponent("kitty.conf"), atomically: true, encoding: .utf8)
        let catppuccin = "## name: Catppuccin-Mocha\nbackground #1E1E2E\n"
        try catppuccin.write(to: themes.kittyTheme, atomically: true, encoding: .utf8)
        var settings = Settings()
        settings.terminalApp = false
        settings.kitty = true
        let report = Reporter()
        themes.write(try palette(), title: "", settings: settings, report: report)
        themes.write(try palette(), title: "", settings: settings, report: report)
        #expect(report.warnings.isEmpty)
        #expect(try String(contentsOf: themes.kittyBackup, encoding: .utf8) == catppuccin)
        #expect(try String(contentsOf: themes.kittyTheme, encoding: .utf8).contains(generatedHeader))
        themes.restoreKittyTheme()
        #expect(try String(contentsOf: themes.kittyTheme, encoding: .utf8) == catppuccin)
        #expect(!FileManager.default.fileExists(atPath: themes.kittyBackup.path))
    }

    @Test func kittyWithoutTheIncludeSaysWhatToAdd() throws {
        let home = temporaryDirectory()
        let themes = TerminalThemes(home: home, reload: false)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/kitty"), withIntermediateDirectories: true)
        var settings = Settings()
        settings.terminalApp = false
        settings.kitty = true
        let report = Reporter()
        themes.write(try palette(), title: "", settings: settings, report: report)
        #expect(report.warnings.first?.contains("include current-theme.conf") == true)
    }

    @Test func settingsWithoutNewKeysStillDecode() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"notify":false}"#.utf8))
        #expect(s.notify == false)
        #expect(s.kitty == false)
        #expect(s.iterm == true)
    }
}
