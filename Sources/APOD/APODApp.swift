// NASA's Astronomy Picture of the Day as the wallpaper, from the menu bar.
import APODCore
import SwiftUI
import UserNotifications

@main
struct APODApp: App {
    @StateObject private var model = AppModel()
    private let notifications = NotificationDelegate()

    init() {
        if Notifier.available { UNUserNotificationCenter.current().delegate = notifications }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.busy != nil ? "sparkle" : "sparkles")
                .help(model.status.entry?.title.map { "APOD: \($0)" } ?? "NASA APOD")
        }
        .menuBarExtraStyle(.window)
    }
}
