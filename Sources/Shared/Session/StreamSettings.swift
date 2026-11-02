import Foundation

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case wide = "16:9", tall = "16:10", ultrawide = "21:9"

    var id: String { rawValue }

    /// Moonlight resolution flags for a given vertical resolution, matching the Windows client.
    func moonlightArgs(height: String) -> [String] {
        let custom: [String: String]
        switch self {
        case .wide:
            return [height == "2160" ? "--4K" : "--\(height)"]
        case .tall:
            custom = ["720": "1280x800", "1080": "1920x1200", "1440": "2560x1600", "2160": "3840x2400"]
        case .ultrawide:
            custom = ["720": "1680x720", "1080": "2560x1080", "1440": "3440x1440", "2160": "5120x2160"]
        }
        return custom[height].map { ["--resolution", $0] } ?? ["--1080"]
    }
}

struct StreamSettings: Codable, Equatable {
    var resolution = "1080"
    var fps = "60"
    var bitrate = "20000"
    var aspect = AspectRatio.wide
    var fullscreen = true
    var hevc = true

    func moonlightStreamArgs(host: String) -> [String] {
        ["stream", host, Config.hostApp]
            + aspect.moonlightArgs(height: resolution)
            + ["--fps", fps,
               "--bitrate", bitrate,
               "--display-mode", fullscreen ? "fullscreen" : "windowed",
               "--capture-system-keys", fullscreen ? "fullscreen" : "never",
               "--video-codec", hevc ? "HEVC" : "H.264"]
    }

    private static let defaultsKey = "streamSettings"

    static func load() -> StreamSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(StreamSettings.self, from: data) else { return StreamSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
