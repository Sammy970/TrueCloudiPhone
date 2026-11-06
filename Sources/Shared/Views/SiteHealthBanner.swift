import SwiftUI

/// Shown at the top of the Cloud PC screen when something needs the user's attention:
/// TrueCloud blocking the app, TrueCloud changing something the app depends on, or a newer version of the app.
/// Nothing is shown while everything matches, or when a check simply couldn't run (offline).
struct SiteHealthBanner: View {
    @ObservedObject var health: SiteHealth
    @ObservedObject var updates: UpdateChecker = .shared
    @Environment(\.openURL) private var openURL
    @State private var expanded = false

    private var changed: [(area: SiteHealth.Area, details: [String])] {
        SiteHealth.Area.allCases.compactMap { area in
            if case .changed(let details) = health.results[area] { return (area, details) }
            return nil
        }
    }

    private var updateURL: URL { updates.available?.pageURL ?? Config.releasesURL }

    var body: some View {
        if let reason = health.blockedReason {
            blockedCard(reason)
        } else if !changed.isEmpty {
            changedCard
        } else if updates.shouldShow, let release = updates.available {
            updateCard(release.version)
        }
    }

    // MARK: Cards

    /// TrueCloud refuses the app on purpose. Offer the fix if one is out, otherwise the website.
    private func blockedCard(_ reason: String) -> some View {
        card(tint: .red, symbol: "hand.raised.fill",
             title: "TrueCloud is blocking this app",
             message: updates.available.map {
                 "TrueCloud's website stopped accepting this app. Version \($0.version) is out and may fix it."
             } ?? "TrueCloud's website stopped accepting this app, so Start, Shut Down and pairing won't work. "
                 + "No fix is out yet. Use truecloud.in for now.",
             details: ["TrueCloud said: \(reason)"], detailsLabel: "Details") {
            if let release = updates.available {
                Button("Update to \(release.version)") { openURL(release.pageURL) }
                    .buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button("Open truecloud.in") { openURL(Config.dashboardURL) }
                    .buttonStyle(.borderedProminent).tint(.red)
                Button(updates.isChecking ? "Checking…" : "Check for Update") {
                    Task { await updates.check(minAge: 0) }
                }
                .buttonStyle(.bordered)
                .disabled(updates.isChecking)
            }
        }
    }

    private var changedCard: some View {
        let blocking = changed.contains { $0.area == .controls || $0.area == .account }
        let tint: Color = blocking ? .red : .orange
        return card(tint: tint,
                    symbol: blocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                    title: blocking ? "Update needed" : "Some details can't load",
                    message: blocking
                        ? "TrueCloud changed its website. Start, Shut Down and pairing are off so nothing goes wrong. Update the app, or use truecloud.in for now."
                        : "TrueCloud changed how it stores \(changed.map { $0.area.rawValue }.joined(separator: " and ")). Your cloud PC still works.",
                    details: changed.flatMap { item in item.details.map { "\(item.area.rawValue): \($0)" } }) {
            Button(updates.available.map { "Update to \($0.version)" } ?? "Update the App") { openURL(updateURL) }
                .buttonStyle(.borderedProminent).tint(tint)
        }
    }

    private func updateCard(_ version: String) -> some View {
        card(tint: .tcAccent, symbol: "arrow.down.circle.fill",
             title: "Version \(version) is available",
             message: "You have \(Config.appVersion). Download the new version from GitHub and replace the app in Applications.",
             details: []) {
            Button("Download") { openURL(updateURL) }
                .buttonStyle(.borderedProminent).tint(.tcAccent)
            Button("Later") { withAnimation(.easeOut(duration: 0.2)) { updates.dismiss() } }
                .buttonStyle(.borderless)
        }
    }

    private func card<Actions: View>(tint: Color, symbol: String, title: String, message: String, details: [String],
                                     detailsLabel: String = "What Changed?",
                                     @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if expanded, !details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(details, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 10) {
                actions()
                if !details.isEmpty {
                    Button(expanded ? "Hide Details" : detailsLabel) {
                        withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                    }
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }
}
