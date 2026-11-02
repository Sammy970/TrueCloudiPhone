import SwiftUI

// The in-stream overlay, shared by the Mac's floating panel and the iPhone's overlay window.

/// Time left, this session and connection health.
struct StreamOverlayCard: View {
    @ObservedObject var model: StreamOverlayModel
    @ObservedObject var health: StreamHealth
    /// Shown at the bottom, e.g. "⌃⌥A to hide".
    var hint: String?
    /// Keyboard shortcuts to list (Mac): keys and what they do.
    var shortcuts: [(keys: String, action: String)] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AppIconImage()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("TrueCloud").font(.headline)
                    Spacer()
                    LatencyBadge(health: health)
                }

                if let left = model.minutesLeft(at: context.date) {
                    row("Time left", PlanUsage.duration(left), emphasis: left <= 10 ? .orange : nil)
                }
                if let start = model.sessionStart {
                    row("This session", PlanUsage.duration(Int(context.date.timeIntervalSince(start) / 60)))
                }
                if health.status == .congested {
                    Label("Connection busy on the cloud PC", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                if !shortcuts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Shortcuts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(shortcuts, id: \.keys) { shortcut in
                            HStack(spacing: 10) {
                                Text(shortcut.keys)
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                    .frame(width: 58, alignment: .leading)
                                Text(shortcut.action)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let hint {
                    Text(hint).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(width: shortcuts.isEmpty ? 250 : 290)
            .glassSurface(cornerRadius: 22)
        }
    }

    private func row(_ title: String, _ value: String, emphasis: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(emphasis ?? .primary)
                .contentTransition(.numericText())
        }
        .font(.subheadline)
    }
}

/// Live latency with a dot coloured by the same zones as the network check.
struct LatencyBadge: View {
    @ObservedObject var health: StreamHealth

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(health.latency.map { LatencyScale.zone(for: $0).color } ?? .secondary)
                .frame(width: 7, height: 7)
            Text(health.latency.map { "\(Int($0.rounded())) ms" } ?? "…")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .animation(.easeOut(duration: 0.3), value: health.latency)
    }
}

/// A short message under the card, e.g. the busy-connection warning.
struct StreamToast: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .glassSurface(cornerRadius: 18)
    }
}
