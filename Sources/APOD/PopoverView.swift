// The popover: the picture, its story, the colours taken from it, Latest / Random, and settings.
import APODCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    private var entry: APODEntry? { model.status.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            picture
            Text(entry?.title ?? (model.busy != nil ? model.busyText : "No picture yet"))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let entry {
                Text(entry.date + (entry.credit.isEmpty ? "" : "  ·  © " + entry.credit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let explanation = entry?.explanation, !explanation.isEmpty {
                ScrollView {
                    Text(explanation)
                        .font(.callout)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
            }
            if let video = model.status.video, let url = URL(string: video.page) {
                Link(destination: url) {
                    Label("Today's APOD is a video\(video.title.map { ": \($0)" } ?? ""); watch it on NASA's site",
                          systemImage: "play.rectangle")
                        .font(.caption)
                }
            }
            swatches
            progress
            if let error = model.error {
                Label(error.prefix(1).uppercased() + error.dropFirst(), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.warnings, id: \.self) { warning in
                Label(warning.prefix(1).uppercased() + warning.dropFirst(), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
            if showSettings {
                Divider()
                SettingsView()
            }
        }
        .padding(14)
        .frame(width: 400)
        .task { await model.refresh() }
    }

    /// The picture as it is on the desktop. Click for the APOD page.
    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25))
            if let image = model.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 372, height: 372 * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { if let entry, let url = URL(string: entry.page) { NSWorkspace.shared.open(url) } }
        .help(entry == nil ? "" : "Open on science.nasa.gov")
    }

    /// The colours the terminal themes took from this picture.
    @ViewBuilder private var swatches: some View {
        if let colors = model.status.palette?.colors {
            HStack(spacing: 4) {
                ForEach(Palette.swatchKeys, id: \.self) { key in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: colors[key] ?? "#000000"))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.primary.opacity(0.2)))
                        .frame(height: 14)
                        .help(key.replacingOccurrences(of: "_", with: " "))
                }
            }
        }
    }

    @ViewBuilder private var progress: some View {
        if model.busy != nil {
            VStack(alignment: .leading, spacing: 4) {
                if entry != nil { Text(model.busyText).font(.caption).foregroundStyle(.secondary) }
                if model.downloaded > 0 {
                    if model.downloadTotal > 0 {
                        ProgressView(value: Double(model.downloaded), total: Double(model.downloadTotal))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(downloadText).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private var downloadText: String {
        func mb(_ b: Int64) -> String { String(format: "%.1f", Double(b) / 1_048_576) }
        guard model.downloadTotal > 0 else { return "\(mb(model.downloaded)) MB" }
        return "\(mb(model.downloaded)) of \(mb(model.downloadTotal)) MB  ·  \(100 * model.downloaded / model.downloadTotal)%"
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            let random = model.status.mode == .random
            Button { model.run(.latest) } label: { Label("Latest", systemImage: "calendar") }
                .help("NASA's newest picture, every day")
                .selected(!random)
            Button { model.run(.random) } label: { Label(random ? "Shuffle" : "Random", systemImage: "shuffle") }
                .help(random ? "Another random picture now" : "A random picture from the archive, every day")
                .selected(random)
            Spacer()
            if let entry, let url = URL(string: entry.page) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Open on science.nasa.gov")
            }
            Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help(showSettings ? "Hide settings" : "Settings")
        }
        .disabled(model.busy != nil)
    }
}

extension View {
    /// The prominent style for the selected mode, the plain bordered one otherwise.
    @ViewBuilder func selected(_ selected: Bool) -> some View {
        if selected { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}

extension Color {
    init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}
