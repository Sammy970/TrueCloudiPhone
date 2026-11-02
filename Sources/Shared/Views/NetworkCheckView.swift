import SwiftUI

/// Network check: how a stream would feel, measured without starting the cloud PC.
/// Shared by the Mac's Network pane and the iPhone's network sheet.
struct NetworkCheckView: View {
    @ObservedObject var check: NetworkCheck
    /// The stream's resolution ("1080") and frame rate ("60"), for the bitrate suggestion.
    let resolution: String
    let fps: String
    /// The bitrate in use, in kbps, and how to change it.
    let bitrate: Int
    let applyBitrate: (Int) -> Void
    /// Testing while streaming would compete with the stream for bandwidth.
    let busy: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How would a stream feel right now?")
                        .font(.title2.weight(.semibold))
                    Text("Measures your connection to \(check.host), the same address Moonlight streams from, so you get an idea without starting your cloud PC.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .reveal(0)

                latencyCard.reveal(0.06)
                statsCard.reveal(0.12)
                if check.stage == .done { verdictCard.transition(.opacity.combined(with: .offset(y: 8))) }
                if case .failed(let message) = check.stage {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }

                ViewThatFits(in: .horizontal) {
                    HStack { runButton; runStatus }
                    VStack(alignment: .leading, spacing: 10) { runButton; runStatus }
                }
                .reveal(0.18)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.isPhone ? 20 : 32)
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: check.stage)
        }
        #if DEBUG
        .task {
            // Screenshot mode (`TRUECLOUD_PREVIEW=…:network`) runs the test on its own.
            if ProcessInfo.processInfo.environment["TRUECLOUD_PREVIEW"]?.hasSuffix(":network") == true {
                await check.run()
            }
        }
        #endif
    }

    #if os(iOS)
    private static let isPhone = true
    private static let horizontalPadding: CGFloat = 20
    #else
    private static let isPhone = false
    private static let horizontalPadding: CGFloat = 32
    #endif

    private var runButton: some View {
        Button {
            Task { await check.run() }
        } label: {
            Label(check.stage == .idle ? "Run Test" : "Run Again", systemImage: "gauge.with.dots.needle.67percent")
                .font(.body.weight(.semibold))
                .frame(width: 200)
        }
        .primaryGlassButton()
        .controlSize(.large)
        .disabled(check.isRunning || busy)
    }

    @ViewBuilder
    private var runStatus: some View {
        if check.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(check.stage == .latency ? "Measuring latency…" : "Measuring download speed…")
                    .foregroundStyle(.secondary)
            }
        } else if busy {
            Text("Available when you're not streaming.").foregroundStyle(.secondary)
        }
    }

    // MARK: Latency

    private var latencyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Latency").font(.headline)
                Spacer()
                if let median = check.medianLatency {
                    Text("\(Int(median.rounded())) ms")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(LatencyScale.zone(for: median).color)
                }
            }
            SampleBars(samples: check.samples, expected: NetworkCheck.sampleCount)
                .frame(height: 54)
            LatencyScale(value: check.medianLatency)
        }
        .padding(20)
        .glassSurface(cornerRadius: 20)
    }

    // MARK: Stats

    private var statsCard: some View {
        HStack(spacing: 0) {
            stat("Jitter", value: check.jitter.map { "\(Int($0.rounded())) ms" }, help: "How much latency varies. Under 10 ms is steady.")
            Divider().frame(height: 36)
            stat("Packet loss", value: check.samples.isEmpty ? nil : "\(Int(check.lossPercent.rounded()))%", help: "Attempts that got no answer.")
            Divider().frame(height: 36)
            stat("Download",
                 value: check.downloadMbps.map { "\(Int($0.rounded())) Mbps" } ?? (check.stage == .download ? "\(Int(check.liveMbps.rounded())) Mbps" : nil),
                 help: "Your internet speed, measured through Cloudflare.")
        }
        .padding(.vertical, 16)
        .glassSurface(cornerRadius: 20)
    }

    private func stat(_ title: String, value: String?, help: String) -> some View {
        VStack(spacing: 4) {
            Text(value ?? "–")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(help)
    }

    // MARK: Verdict

    @ViewBuilder
    private var verdictCard: some View {
        if let median = check.medianLatency {
            let zone = LatencyScale.zone(for: median)
            VStack(alignment: .leading, spacing: 12) {
                Label(zone.verdict, systemImage: zone.symbol)
                    .font(.headline)
                    .foregroundStyle(zone.color)
                Text(advice(median: median))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggested = check.suggestedBitrate(resolution: resolution, fps: fps) {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suggested for \(resolution == "2160" ? "4K" : resolution + "p") at \(fps) FPS: \(suggested / 1000) Mbps")
                                .font(.callout.weight(.medium))
                            Text(bitrate == suggested
                                 ? "That's what you're using."
                                 : "You're using \(bitrate / 1000) Mbps.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if bitrate != suggested {
                            Button("Use \(suggested / 1000) Mbps") { applyBitrate(suggested) }
                                .secondaryGlassButton()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 20)
        }
    }

    private func advice(median: Double) -> String {
        var parts = [LatencyScale.zone(for: median).detail]
        if let jitter = check.jitter, jitter > 12 {
            parts.append("Latency is jumping around (\(Int(jitter)) ms jitter); a wired connection or 5 GHz Wi-Fi closer to the router usually steadies it.")
        }
        if check.lossPercent >= 5 {
            parts.append("Some attempts got no answer, which shows up as stutters.")
        }
        if let mbps = check.downloadMbps, mbps < 15 {
            parts.append("Your download speed is low for streaming; 720p at 10 Mbps will be smoother than 1080p.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Sample bars

/// One bar per latency sample, filling in as they arrive.
private struct SampleBars: View {
    let samples: [Double]
    let expected: Int

    var body: some View {
        GeometryReader { geo in
            let top = max(120, (samples.max() ?? 0) * 1.15)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<expected, id: \.self) { i in
                    let value = i < samples.count ? samples[i] : nil
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(value.map { LatencyScale.zone(for: $0).color } ?? Color.secondary.opacity(0.15))
                        .frame(height: value.map { max(3, geo.size.height * $0 / top) } ?? 3)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: value)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Latency scale

/// Excellent → Good → Playable → High, with a marker that slides to the measured value.
struct LatencyScale: View {
    let value: Double?

    struct Zone {
        let name: String
        let upTo: Double
        let color: Color
        let verdict: String
        let detail: String
        let symbol: String
    }

    static let zones = [
        Zone(name: "Excellent", upTo: 35, color: .green, verdict: "Excellent for streaming",
             detail: "Feels close to a PC under your desk, even in fast shooters.", symbol: "checkmark.seal.fill"),
        Zone(name: "Good", upTo: 60, color: Color(red: 0.55, green: 0.8, blue: 0.2), verdict: "Good for streaming",
             detail: "Great for most games. Competitive shooters may feel a touch behind.", symbol: "hand.thumbsup.fill"),
        Zone(name: "Playable", upTo: 90, color: .orange, verdict: "Playable",
             detail: "Fine for slower and single-player games; fast games will feel delayed.", symbol: "exclamationmark.circle.fill"),
        Zone(name: "High", upTo: 150, color: .red, verdict: "High latency",
             detail: "Expect noticeable lag. Try another network if you can.", symbol: "xmark.octagon.fill"),
    ]

    static func zone(for ms: Double) -> Zone { zones.first { ms <= $0.upTo } ?? zones[zones.count - 1] }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let maxValue = Self.zones.last!.upTo
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(Self.zones.indices, id: \.self) { i in
                            let lower = i == 0 ? 0 : Self.zones[i - 1].upTo
                            Capsule()
                                .fill(Self.zones[i].color.opacity(value.map { Self.zone(for: $0).name == Self.zones[i].name ? 0.9 : 0.25 } ?? 0.25))
                                .frame(width: max(0, geo.size.width * (Self.zones[i].upTo - lower) / maxValue - 2))
                        }
                    }
                    .frame(height: 8)

                    if let value {
                        let x = geo.size.width * min(value, maxValue) / maxValue
                        Circle()
                            .fill(.white)
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            .overlay(Circle().fill(Self.zone(for: value).color).frame(width: 8, height: 8))
                            .offset(x: x - 8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
                .animation(.spring(response: 0.6, dampingFraction: 0.75), value: value)
            }
            .frame(height: 18)

            GeometryReader { geo in
                let maxValue = Self.zones.last!.upTo
                ForEach(Self.zones.indices, id: \.self) { i in
                    let lower = i == 0 ? 0 : Self.zones[i - 1].upTo
                    Text(Self.zones[i].name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: geo.size.width * (Self.zones[i].upTo - lower) / maxValue)
                        .offset(x: geo.size.width * lower / maxValue)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(Int($0)) milliseconds, \(Self.zone(for: $0).name)" } ?? "Not measured yet")
    }
}
