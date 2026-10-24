// The app's state, scheduling and the actions behind the popover's buttons.
import APODCore
import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    enum Action: String {
        case update, latest, random, apply
    }

    @Published private(set) var status: Status
    @Published private(set) var thumbnail: NSImage?
    /// The action in progress, its latest progress message, and its download.
    @Published private(set) var busy: Action?
    @Published private(set) var stage = ""
    @Published private(set) var downloaded: Int64 = 0
    @Published private(set) var downloadTotal: Int64 = 0
    @Published private(set) var error: String?
    /// Things the last action wants you to know although it worked, such as a terminal
    /// theme it couldn't write.
    @Published private(set) var warnings: [String] = []
    @Published private(set) var apiKey: String
    @Published var settings: Settings {
        didSet { settingsChanged(from: oldValue) }
    }

    let store = Store.standard
    let themes = TerminalThemes()
    private let updater: Updater
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screenChange: Task<Void, Never>?

    init() {
        // Pictures, state and the Terminal profile are private to this user.
        umask(0o077)
        try? store.prepare()
        settings = Self.loadSettings()
        apiKey = Keychain.apiKey ?? ""
        updater = Updater(store: store, http: URLSessionHTTP(), desktop: MacDesktop(), announcer: Notifier(), themes: themes)
        status = Status()
        Notifier.requestPermission()
        Task { await refresh() }
        schedule()
    }

    // MARK: Scheduling

    /// 20 seconds after launch, then hourly and after waking: `update` returns at once when
    /// there is nothing new, and asks NASA at most every 3 hours.
    private func schedule() {
        Task {
            try? await Task.sleep(for: .seconds(20))
            run(.update)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.run(.update) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))   // the network comes back a little after the screen
                self?.run(.update)
            }
        })
        // setDesktopImageURL sets only the Space that is showing; others get it when they show.
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refit(after: .milliseconds(300)) }
        })
        // A monitor plugged in, unplugged, or set to another resolution.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refit(after: .seconds(2)) }
        })
        // Terminal's scripting can't set the ANSI colours, and it writes its profiles back
        // when it quits: those colours go into its preferences after that.
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.Terminal" else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.updateTerminalPreferences()
            }
        })
    }

    /// Fit the current picture to the screens as they are now (renders are reused), coalescing bursts.
    private func refit(after delay: Duration) {
        screenChange?.cancel()
        screenChange = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, store.current != nil else { return }
            try? await updater.apply(context(quick: true, report: Reporter()), rebuildPalette: false)
            await refresh()
        }
    }

    private func updateTerminalPreferences() {
        guard settings.terminalApp, let p = store.palette?.palette else { return }
        _ = try? themes.updateTerminalPreferences(TerminalScheme(p))
    }

    // MARK: Actions

    func run(_ action: Action) {
        guard busy == nil else { return }
        busy = action
        stage = ""
        error = nil
        warnings = []
        downloaded = 0
        downloadTotal = 0
        let report = Reporter(
            stage: { [weak self] message in Task { @MainActor in self?.stage = message } },
            progress: { [weak self] done, total in
                Task { @MainActor in
                    self?.downloaded = done
                    self?.downloadTotal = total
                }
            })
        let ctx = context(quick: action != .update, report: report)
        Task {
            do {
                switch action {
                case .update: try await updater.update(ctx)
                case .latest: try await updater.choose(.latest, ctx)
                case .random: try await updater.choose(.random, ctx)
                case .apply: try await updater.apply(ctx)
                }
            } catch {
                self.error = error.localizedDescription
            }
            warnings = report.warnings
            busy = nil
            stage = ""
            downloaded = 0
            await refresh()
        }
    }

    private func context(quick: Bool, report: Reporter) -> Updater.Context {
        Updater.Context(settings: settings, apiKey: apiKey.isEmpty ? "DEMO_KEY" : apiKey,
                        patience: quick ? .quick : .background, report: report)
    }

    func refresh() async {
        let new = await updater.status()
        if new.image != status.image || thumbnail == nil { thumbnail = new.image.flatMap(Self.thumbnail) }
        status = new
    }

    static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 960,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// What the running action is doing now, in its own words, without the detail in brackets.
    var busyText: String {
        if !stage.isEmpty {
            let text = stage.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression)
            return text.prefix(1).uppercased() + text.dropFirst() + "…"
        }
        switch busy {
        case .update: return "Checking for a new picture…"
        case .latest: return "Fetching today's picture…"
        case .random: return "Finding a random picture…"
        case .apply: return "Rebuilding the colours…"
        case nil: return ""
        }
    }

    // MARK: Settings

    private static let settingsKey = "settings"

    private static func loadSettings() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    private func settingsChanged(from old: Settings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        // Changing the colours rebuilds them from the current picture right away.
        let colours = old.colorMode != settings.colorMode || old.vividness != settings.vividness
        let terminals = old.terminalApp != settings.terminalApp || old.ghostty != settings.ghostty || old.iterm != settings.iterm
            || old.kitty != settings.kitty
        if old.kitty && !settings.kitty { themes.restoreKittyTheme() }
        if (colours || terminals) && store.current != nil { run(.apply) }
    }

    var personalKey: Bool { APODClient.isPersonal(apiKey) }

    /// Save the key; letters and digits only, as api.nasa.gov issues them. Empty removes it.
    @discardableResult
    func saveKey(_ key: String) -> Bool {
        let key = key.filter { !$0.isWhitespace }
        guard key.isEmpty || (key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        Keychain.apiKey = key.isEmpty ? nil : key
        apiKey = key
        return true
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self.error = "couldn't change the login item: \(error.localizedDescription)"
            }
        }
    }

    /// Import the APOD profile into Terminal: it opens a window with it, once.
    func addToTerminal() {
        if !FileManager.default.fileExists(atPath: themes.terminalFile.path) { run(.apply); return }
        NSWorkspace.shared.open(themes.terminalFile)
        Task {
            try? await Task.sleep(for: .seconds(2))
            objectWillChange.send()
        }
    }
}
