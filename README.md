# NASA APOD for macOS

NASA's [Astronomy Picture of the Day](https://science.nasa.gov/apod/) as your Mac wallpaper, on every display, with terminal colours taken from the picture. A red nebula gives a deep red Terminal, a blue twilight sky a blue one, and the text stays readable.

This is the macOS version of [omarchy-apod](https://github.com/smolamSK/omarchy-apod) and [kde-apod](https://github.com/smolamSK/kde-apod).

## Features

- **Daily wallpaper.** NASA's new picture shortly after it is published, and after login or waking if the Mac was off or asleep. On days when APOD is a video, the most recent photo stays, and the popover links to the video.
- **Fitted to every display.** Each display gets its own copy at its own resolution. If the picture's shape is close to the screen's, it is cropped to fill it. If the shapes are very different (a tall photo on a wide screen), the whole picture is shown over a blurred copy of itself. Small pictures are never enlarged more than twice. Plugging in a display, or changing its resolution, re-fits the picture.
- **Every Space.** macOS sets a wallpaper only on the Space that is showing, so APOD sets it again as you switch Spaces.
- **Terminal colours from the picture.** The picture's strongest colours become the accent and cursor, and its dark sky tints the background. Terminal colours keep their meaning (red is still red) but lean towards the picture's own hues. Every text colour is checked against the background and adjusted until it is readable. For Terminal, Ghostty and iTerm2.
- **Notification** with the title, credit and NASA's explanation when the picture changes. Click it to open the picture's page.
- **Menu bar popover** (the sparkles) with the picture, its story, the colours taken from it, and:
  - **Latest:** NASA's new picture every day.
  - **Random:** a random picture from the archive every day. Click **Shuffle** for another one right away. Many older APOD pictures are only about 1000 pixels wide, so Random reads each picture's size before downloading it and passes over those under 1920 pixels. If none of the 15 it looks at is that big, it uses the largest.
  - While it works, the popover says what it is doing, with a progress bar for the download.
  - Click the picture to open its page on science.nasa.gov.

## Requirements

macOS 14 (Sonoma) or later. Building needs Xcode or the Swift 6 command line tools; there are no other dependencies.

## Install

```sh
git clone https://github.com/smolamSK/macos-apod.git
cd macos-apod
scripts/build-app.sh --install
```

This builds `APOD.app`, copies it to `/Applications` and opens it. The first picture arrives about 20 seconds later. Turn on **Open at login** in the settings (the sliders button) so it keeps running.

**Get a free NASA API key** at https://api.nasa.gov (it is shown as soon as you sign up). Paste it into the settings and click **Save**; it is kept in your login Keychain. Without a key, the shared `DEMO_KEY` is used. It is limited per IP address and runs out quickly, especially when using Random. When the API is unavailable, the picture is read from the APOD website instead.

## Terminal colours

The colours are rewritten with every new picture. Only profiles and files that APOD made are ever written; if you already have your own theme called APOD, it is left alone. kitty is the one exception, and only once you turn it on.

- **Terminal:** in the settings, click **Add to Terminal**. Terminal imports the APOD profile and opens a window with it. Make it the default in Terminal → Settings → Profiles if you like. With a new picture, the background, text and cursor of open windows change right away (macOS asks once whether APOD may control Terminal). Terminal's scripting can't change the 16 ANSI colours, so those follow the next time Terminal quits.
- **Ghostty:** APOD writes `~/.config/ghostty/themes/apod`. Add `theme = apod` to Ghostty's config, and reload it (⌘⇧,) after a new picture.
- **kitty:** off until you turn it on, because APOD then replaces kitty's theme: it writes `~/.config/kitty/current-theme.conf`, the file `kitty.conf` includes and `kitten themes` writes. Your previous theme is kept as `current-theme.conf.before-apod`, and turning kitty off in the settings brings it back. Every kitty window recolours at once, all 16 colours included, because kitty reloads its config when APOD signals it. Your `background_opacity` and other settings in `kitty.conf` stay as they are. If `kitty.conf` has no `include current-theme.conf` line, the popover says to add it.
- **iTerm2:** APOD writes a dynamic profile called APOD, which iTerm2 picks up by itself. Choose it in iTerm2 → Settings → Profiles.

The Ghostty, iTerm2 and kitty options only show up when those apps are installed.

## Settings

Click the sliders button in the popover:

| Setting | Meaning |
|---|---|
| Colours | Auto, Dark or Light terminal colours. Auto picks light for bright pictures. |
| Strength | Subtle, Balanced or Vivid: how strongly the picture tints the colours. |
| Announce new pictures | The notification when the picture changes. |
| Open at login | Start APOD when you log in. |
| Terminal / Ghostty / iTerm2 / kitty | Which terminals get the colours. kitty is off until you turn it on. |
| NASA API key | Your key, kept in the Keychain. |

Changing the colours rebuilds them from the current picture right away.

## Update and uninstall

```sh
cd macos-apod && git pull && scripts/build-app.sh --install
```

To uninstall, first turn kitty off in the settings if you turned it on (that brings back your previous kitty theme), quit APOD, then:

```sh
rm -rf /Applications/APOD.app
rm -rf ~/Library/Application\ Support/APOD ~/Library/Caches/APOD   # state and pictures
defaults delete io.github.smolamsk.apod-mac                         # settings
security delete-generic-password -s io.github.smolamsk.apod-mac     # the API key
rm -f ~/.config/ghostty/themes/apod ~/Library/Application\ Support/iTerm2/DynamicProfiles/apod.json
```

Your wallpaper stays as it is until you choose another one. Delete the APOD profile in Terminal → Settings → Profiles.

## How it works

| Part | Where |
|---|---|
| Fetching, picking, downloading, the update rules | `Sources/APODCore/APODClient.swift`, `Updater.swift` |
| Fitting a picture to a screen | `Sources/APODCore/Renderer.swift` (Core Image) |
| Picture → palette | `Sources/APODCore/Palette.swift`, a port of omarchy-apod's `apod-palette.py` (colours in OKLCH) |
| Terminal profiles | `Sources/APODCore/TerminalThemes.swift` |
| Menu bar app, scheduling (20 s after launch, hourly, after waking) | `Sources/APOD/` |
| State | `~/Library/Application Support/APOD/` |
| Pictures and renders | `~/Library/Caches/APOD/`, older than 7 days pruned |

## Troubleshooting

- **See what happened:** quit APOD and run `/Applications/APOD.app/Contents/MacOS/APOD` in a terminal; it explains each step.
- **"NASA API rate limit reached":** you're using `DEMO_KEY`. Get a free key and save it in the settings.
- **Terminal colours don't change live:** allow APOD in System Settings → Privacy & Security → Automation → Terminal.

## Development

```sh
swift build
swift test
scripts/build-app.sh
```

The tests use temporary state and stand in for NASA, the desktop and notifications; they never touch your wallpaper or Terminal. `PaletteTests` checks the palette against numbers from the Python original.

## License

GPL-2.0-or-later. Pictures are © their respective authors, as credited on APOD.
