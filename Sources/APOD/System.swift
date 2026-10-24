// macOS itself: screens and wallpapers, notifications, and the Keychain.
import APODCore
import AppKit
import Security
import UserNotifications

struct MacDesktop: Desktop {
    func screens() async -> [Screen] {
        await MainActor.run {
            NSScreen.screens.compactMap { screen in
                guard let id = Self.id(of: screen) else { return nil }
                // The backing store's pixels, which follow rotation and the chosen resolution.
                let scale = screen.backingScaleFactor
                return Screen(id: id, width: Int((screen.frame.width * scale).rounded()),
                              height: Int((screen.frame.height * scale).rounded()))
            }
        }
    }

    func setWallpapers(_ files: [String: URL]) async throws {
        try await MainActor.run {
            for screen in NSScreen.screens {
                guard let id = Self.id(of: screen), let url = files[id] else { continue }
                // Each render already has the screen's size; scaling only guards against a
                // resolution change between rendering and now.
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
            }
        }
    }

    @MainActor
    static func id(of screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { String($0.uint32Value) }
    }
}

/// Notifications need a bundled app; run from `swift run`, there are none.
struct Notifier: Announcer {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func announce(_ entry: APODEntry, image: URL?) async {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        content.title = entry.title ?? "NASA APOD"
        content.subtitle = entry.date + (entry.credit.isEmpty ? "" : " · © " + entry.credit)
        content.body = entry.explanation ?? ""
        content.userInfo = ["page": entry.page]
        // The attachment is moved into the notification store, so it gets a copy.
        if let image {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("apod-\(UUID().uuidString).jpg")
            if (try? FileManager.default.copyItem(at: image, to: copy)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "picture", url: copy) {
                content.attachments = [attachment]
            }
        }
        let request = UNNotificationRequest(identifier: "apod-\(entry.date)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Clicking a notification opens the picture's page.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let page = response.notification.request.content.userInfo["page"] as? String, let url = URL(string: page) {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner] }
}

/// The NASA API key, in the login Keychain rather than a preferences file.
enum Keychain {
    static let service = "io.github.smolamsk.apod-mac"
    static let account = "nasa-api-key"

    static var apiKey: String? {
        get {
            var item: CFTypeRef?
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                          kSecAttrAccount: account, kSecReturnData: true]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = query
            add[kSecValueData] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
