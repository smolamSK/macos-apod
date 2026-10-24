// Settings, in the popover below the buttons.
import APODCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    @State private var keyRejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Colours") {
                Picker("", selection: $model.settings.colorMode) {
                    Text("Auto").tag(ColorMode.auto)
                    Text("Dark").tag(ColorMode.dark)
                    Text("Light").tag(ColorMode.light)
                }
                .help("Auto picks light terminal colours for bright pictures and dark ones for the rest")
            }
            row("Strength") {
                Picker("", selection: $model.settings.vividness) {
                    Text("Subtle").tag(Vividness.subtle)
                    Text("Balanced").tag(Vividness.balanced)
                    Text("Vivid").tag(Vividness.vivid)
                }
                .help("How strongly the picture tints the terminal colours; text stays readable at every level")
            }
            Toggle("Announce new pictures", isOn: $model.settings.notify)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))

            Divider()
            terminals

            Divider()
            apiKey

            HStack {
                Spacer()
                Button("Quit APOD") { NSApplication.shared.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label)
            Spacer()
            content().pickerStyle(.segmented).labelsHidden().frame(width: 220)
        }
    }

    @ViewBuilder private var terminals: some View {
        Text("Terminal colours from the picture").font(.callout.weight(.semibold))
        Toggle("Terminal", isOn: $model.settings.terminalApp)
        if model.settings.terminalApp {
            switch model.themes.terminalProfileInstalled {
            case true?:
                Text("Pick the APOD profile in Terminal → Settings → Profiles to use it.")
                    .font(.caption).foregroundStyle(.secondary)
            case false?:
                HStack {
                    Text("Not in Terminal yet.").font(.caption).foregroundStyle(.secondary)
                    Button("Add to Terminal") { model.addToTerminal() }
                }
            case nil:
                Text("Terminal already has an APOD profile this app didn't make; rename it to use this one.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        if model.themes.ghosttyInstalled {
            Toggle("Ghostty", isOn: $model.settings.ghostty)
            if model.settings.ghostty {
                Text("Add `theme = apod` to Ghostty's config, then reload it (⌘⇧,).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if model.themes.kittyInstalled {
            Toggle("kitty", isOn: $model.settings.kitty)
            if model.settings.kitty {
                Text("Replaces kitty's current theme; your previous one is kept as current-theme.conf.before-apod and comes back when you turn this off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if model.themes.itermInstalled {
            Toggle("iTerm2", isOn: $model.settings.iterm)
            if model.settings.iterm {
                Text("Pick the APOD profile in iTerm2 → Settings → Profiles.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var apiKey: some View {
        Text(model.personalKey ? "NASA API key: your own, kept in the Keychain"
                               : "NASA API key: the shared DEMO_KEY, which runs out quickly")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            SecureField(model.personalKey ? "Replace your key" : "Paste your key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Button("Save", action: save).disabled(key.isEmpty)
            if !model.apiKey.isEmpty {
                Button("Remove") { model.saveKey("") }
            }
        }
        if keyRejected {
            Text("A NASA API key is letters and digits only.").font(.caption).foregroundStyle(.red)
        }
        Link("Get a free key at api.nasa.gov", destination: URL(string: "https://api.nasa.gov")!)
            .font(.caption)
    }

    private func save() {
        keyRejected = !model.saveKey(key)
        if !keyRejected { key = "" }
    }
}
