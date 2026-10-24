# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A macOS menu bar app that sets NASA's Astronomy Picture of the Day as the wallpaper on every display and writes Terminal, Ghostty and iTerm2 colour schemes from the picture. It is a Swift port of [omarchy-apod](https://github.com/smolamSK/omarchy-apod) (itself a port of kde-apod); behaviour and contracts follow that repo's CLAUDE.md unless noted here.

- `Sources/APODCore`: everything testable. `APODClient` (API, website fallback, URL filter), `Updater` (actor: show/update/apply/setEntry), `Renderer`, `Palette`, `TerminalThemes`, `Store`.
- `Sources/APOD`: the SwiftUI `MenuBarExtra` app. `AppModel` schedules and runs Updater actions; `System.swift` holds the NSScreen/NSWorkspace desktop, notifications and Keychain.

## Development

- `swift build`, `swift test`, `scripts/build-app.sh` (bundle, icon, ad-hoc signature; `--install` copies to /Applications). Notifications and the login item only work from the bundle.
- Running the app changes the real wallpaper and may recolour Terminal's APOD profile. The tests never do: they use `Harness` (temporary Store, `FakeHTTP`, `FakeDesktop`) and set `terminalApp = false`.
- New `Settings` fields need a line in its `init(from:)` (`decodeIfPresent`), so settings saved by an older version still load.
- Swift language mode 5 (see Package.swift); keep the build free of warnings.

## Contracts

- **Palette parity.** `Palette.swift` matches `apod-palette.py` hex for hex. `PaletteTests.python` and `analysesLikeThePythonOriginal` hold numbers produced by the Python script; if you change the recipe here, change it there too (or regenerate them from it). Rounding is half-to-even and sorting ties keep bin order, as in Python.
- **When anything happens.** `runUpdate` must stay cheap when nothing is new: no network if today's (US Eastern) HD picture is current, today's APOD is a video, or NASA was asked less than `checkHours` ago. Random mode reshuffles once per local day. `setEntry` returns early for an unchanged picture unless `force` (the popover buttons).
- **Order in `setEntry`.** Render → palette and terminal themes → set wallpapers → only then write `meta.json`, `current`, `changed` → prune → notify. A failure before publishing leaves the old picture current and sends no notification. The sd→HD upgrade of the same date is never announced.
- **One action at a time.** `Updater.serialized` replaces the scripts' flock; every public entry point goes through it.
- **Renders** are `render-KEY-SCREENID-WxH-fitT.jpg` in the cache. `Store.renders(key:)`, `prune` and `fetch` (which drops a re-downloaded original's renders) depend on that name. A new name per picture matters: macOS caches wallpapers by URL.
- **Spaces.** `setDesktopImageURL` sets only the visible Space, so `AppModel` re-applies on `activeSpaceDidChangeNotification` (cheap: renders are reused).
- **Only our own terminal files.** Ghostty and iTerm2 files are written only when missing or carrying our marker (`generatedHeader`, the iTerm Guid). Terminal's profile is ours only if it has the `APODGenerated` key. The one exception is kitty, which only happens after the user opts in (`Settings.kitty`, off by default): its `current-theme.conf` is replaced. The original is moved to `current-theme.conf.before-apod` once (never overwritten), `restoreKittyTheme` puts it back when the option is turned off, and kitty reloads on SIGUSR1. `kitty.conf` is never edited. `TerminalThemes(reload: false)` in tests sends no signals. Terminal's prefs are edited only while Terminal isn't running; while it runs, AppleScript changes the colours it can (not ANSI), and `AppModel` writes the rest when Terminal quits.
- **Progress vs problems.** `Reporter.stage` lines are shown in the popover; `Reporter.problem` lines are failure reasons, and the first one is what a failed action reports. Falling back to the website clears earlier problems (the API error was dealt with). `Reporter.warning` is for non-fatal notices (terminal themes); the popover shows them even when the action succeeded.
- **Privacy.** The app runs with `umask 077`. Downloads are https only, also after redirects, limited to `*.nasa.gov` (`APODClient.acceptable`) and to 200 MB. The API key lives in the Keychain.
