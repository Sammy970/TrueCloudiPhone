import SwiftUI

/// The Moonlight settings TrueCloud exposes. Moonlight keeps them in its own database and reads
/// them when it connects, so editing them here is all it takes.
struct MoonlightPrefs: Equatable {
    var height = 1080
    var fps = 60
    var bitrateKbps = 20000
    var hevc = true
    var directTouch = false
    var onscreenControls = 1
    var statsOverlay = false
    var audioOnPC = false

    static let heights = [720, 1080, 1440, 2160]
    static let bitrates = [5000, 10000, 15000, 20000, 30000, 40000, 50000]

    /// 16:9, matching the cloud PC's display.
    var width: Int { height * 16 / 9 }

    static func load() -> MoonlightPrefs {
        var prefs = MoonlightPrefs()
        guard let s = DataManager().getSettings() else { return prefs }
        let height = s.height.intValue
        prefs.height = heights.min { abs($0 - height) < abs($1 - height) } ?? 1080
        prefs.fps = s.framerate.intValue
        prefs.bitrateKbps = s.bitrate.intValue
        // `preferredCodec` is an anonymous C enum Swift doesn't import; 1 == CODEC_PREF_H264.
        prefs.hevc = (s.value(forKey: "preferredCodec") as? Int) != 1
        prefs.directTouch = s.absoluteTouchMode
        prefs.onscreenControls = s.onscreenControls.intValue
        prefs.statsOverlay = s.statsOverlay
        prefs.audioOnPC = s.playAudioOnPC
        return prefs
    }

    /// Writes these values and keeps every other Moonlight setting as it was.
    func save() {
        let data = DataManager()
        guard let s = data.getSettings() else { return }
        data.saveSettings(
            withBitrate: bitrateKbps,
            framerate: fps,
            height: height,
            width: width,
            audioConfig: s.audioConfig.intValue,
            onscreenControls: onscreenControls,
            optimizeGames: s.optimizeGames,
            multiController: s.multiController,
            swapABXYButtons: s.swapABXYButtons,
            audioOnPC: audioOnPC,
            preferredCodec: hevc ? 2 : 1,
            useFramePacing: s.useFramePacing,
            enableHdr: s.enableHdr,
            btMouseSupport: s.btMouseSupport,
            absoluteTouchMode: directTouch,
            statsOverlay: statsOverlay
        )
    }

    /// e.g. "1080p · 60 FPS · 20 Mbps · HEVC"
    var summary: String {
        let res = height == 2160 ? "4K" : "\(height)p"
        return "\(res) · \(fps) FPS · \(bitrateKbps / 1000) Mbps · \(hevc ? "HEVC" : "H.264")"
    }

    var gigabytesPerHour: String {
        (Double(bitrateKbps) * 1000 * 3600 / 8 / 1e9).formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// Stream settings, edited in TrueCloud and saved straight into Moonlight.
struct StreamSettingsSheet: View {
    @Binding var prefs: MoonlightPrefs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $prefs.height) {
                        ForEach(MoonlightPrefs.heights, id: \.self) { Text($0 == 2160 ? "4K" : "\($0)p").tag($0) }
                    }
                    Picker("Frame rate", selection: $prefs.fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                        Text("120").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Picker("Bitrate", selection: $prefs.bitrateKbps) {
                        ForEach(bitrateOptions, id: \.self) { Text("\($0 / 1000) Mbps").tag($0) }
                    }
                } header: {
                    Text("Picture")
                } footer: {
                    Text("Streams at \(prefs.width) × \(prefs.height) and uses up to \(prefs.gigabytesPerHour) GB of data per hour. Lower the bitrate if the picture stutters.")
                }

                Section {
                    Toggle(isOn: $prefs.hevc) {
                        Text("HEVC (H.265)")
                        Text("Sharper picture at the same bitrate.")
                    }
                }

                Section {
                    Picker("Touch", selection: $prefs.directTouch) {
                        Text("Trackpad").tag(false)
                        Text("Direct touch").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("On-screen controls", selection: $prefs.onscreenControls) {
                        Text("Off").tag(0)
                        Text("Auto").tag(1)
                        Text("Simple").tag(2)
                        Text("Full").tag(3)
                    }
                    Button {
                        TrueCloudPanel.presentControlsEditor()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Customize on-screen controls")
                                Text("Move, resize or hide each control, and set how see-through they are.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Trackpad moves a cursor like a laptop trackpad. Direct touch clicks where your finger lands.")
                }

                Section {
                    Toggle("Show performance stats", isOn: $prefs.statsOverlay)
                    Toggle(isOn: $prefs.audioOnPC) {
                        Text("Play sound on the cloud PC")
                        Text("Off sends the sound to your iPhone.")
                    }
                }
            }
            .navigationTitle("Stream Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: prefs) { _, value in value.save() }
    }

    /// The standard steps, plus the current value if Moonlight had a custom one.
    private var bitrateOptions: [Int] {
        MoonlightPrefs.bitrates.contains(prefs.bitrateKbps)
            ? MoonlightPrefs.bitrates
            : (MoonlightPrefs.bitrates + [prefs.bitrateKbps]).sorted()
    }
}
