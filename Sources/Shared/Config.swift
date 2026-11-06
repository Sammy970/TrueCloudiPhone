import Foundation

enum Config {
    static let siteURL = URL(string: "https://truecloud.in")!
    static let dashboardURL = URL(string: "https://truecloud.in/dashboard")!

    /// Sunshine app name started on the VM.
    static let hostApp = "Desktop"

    static let keychainService = "com.samyakjain.truecloud"

    /// This app's version. The build scripts stamp it into the app bundle.
    static let appVersion = "0.1.6"

    /// Where updates are published.
    #if os(iOS)
    static let githubRepository = "Sammy970/TrueCloudiPhone"
    #else
    static let githubRepository = "Sammy970/TrueCloudMac"
    #endif
    static let releasesURL = URL(string: "https://github.com/\(githubRepository)/releases/latest")!

    // MARK: Credits

    static let creatorName = "Samyak Jain"
    static let creatorGitHub = URL(string: "https://github.com/Sammy970")!
    static let creatorX = URL(string: "https://x.com/Sammy_970")!
    static let moonlightURL = URL(string: "https://moonlight-stream.org")!
    #if os(iOS)
    static let appName = "TrueCloud for iPhone"
    #else
    static let appName = "TrueCloud for Mac"
    #endif
}
