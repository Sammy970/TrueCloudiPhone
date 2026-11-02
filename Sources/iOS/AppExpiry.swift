import Foundation
import UserNotifications

/// Expiry of this sideloaded build: free Apple ID provisioning profiles last 7 days, after which
/// iOS refuses to open the app until it is reinstalled from the Mac.
enum AppExpiry {
    static let date: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The profile is a CMS envelope around a plain XML plist.
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    static var daysLeft: Int? {
        date.map { Calendar.current.dateComponents([.day], from: .now, to: $0).day ?? 0 }
    }

    /// Reminds the user a day before the build stops opening.
    static func scheduleReminder() {
        guard let date, let fireDate = Calendar.current.date(byAdding: .day, value: -1, to: date), fireDate > .now else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "TrueCloud expires tomorrow"
            content.body = "Plug your iPhone into your Mac and reinstall the app to keep using it."
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            center.add(UNNotificationRequest(identifier: "app-expiry", content: content, trigger: trigger))
        }
    }
}
