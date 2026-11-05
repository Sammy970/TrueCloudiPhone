import SwiftUI
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

// The Activity and Payments sheets: the cloud PC's power events and the account's purchases,
// read from the same TrueCloud records as the Mac app.

/// The cloud PC's power events (starts, shutdowns, force stops), loaded from TrueCloud's activity log.
/// Kept in the home view so the list survives closing the sheet.
@MainActor
final class ActivityModel: ObservableObject {
    @Published private(set) var entries: [ActivityEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false

    func load(auth: AuthStore) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            entries = Array(try await auth.activityLog().prefix(200))
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if DEBUG
    /// Sample data for screenshots, without network.
    func preview(_ entries: [ActivityEntry]) {
        self.entries = entries
        hasLoaded = true
    }
    #endif
}

/// The account's plan purchases and upgrades, loaded from TrueCloud's transaction records.
@MainActor
final class PaymentsModel: ObservableObject {
    @Published private(set) var records: [PaymentRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false

    func load(auth: AuthStore) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            records = try await auth.payments()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if DEBUG
    /// Sample data for screenshots, without network.
    func preview(_ records: [PaymentRecord]) {
        self.records = records
        hasLoaded = true
    }
    #endif
}

// MARK: - Activity

struct ActivitySheet: View {
    @ObservedObject var model: ActivityModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    /// Entries grouped by calendar day, newest day first.
    private var days: [(day: Date, entries: [ActivityEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.entries) { calendar.startOfDay(for: $0.timestamp) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day, default: []].sorted { $0.timestamp > $1.timestamp })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Starts, shutdowns and force stops of your cloud PC, as TrueCloud recorded them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let message = model.errorMessage {
                        errorCard(message)
                    } else if !model.hasLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if model.entries.isEmpty {
                        empty
                    } else {
                        ForEach(days, id: \.day) { group in
                            daySection(group.day, group.entries)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background { AuroraBackground(intensity: 0.35) }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Task { await model.load(auth: auth) } } label: {
                        if model.isLoading { ProgressView() } else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    .disabled(model.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await model.load(auth: auth) }
            .task { if !model.hasLoaded { await model.load(auth: auth) } }
        }
    }

    private func daySection(_ day: Date, _ entries: [ActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.dayTitle(day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 52) }
                    row(entry)
                }
            }
            .padding(.vertical, 4)
            .glassSurface(cornerRadius: 20)
        }
    }

    private func row(_ entry: ActivityEntry) -> some View {
        let tint = Self.tint(entry)
        return HStack(spacing: 12) {
            Image(systemName: Self.symbol(entry.type))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.callout.weight(.medium))
                Text(entry.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Circle().fill(tint).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No activity yet").font(.headline)
            Text("Starting or shutting down your cloud PC shows up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 24)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Couldn't load activity").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { Task { await model.load(auth: auth) } }
                .secondaryGlassButton()
                .disabled(model.isLoading)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 24)
    }

    private static func symbol(_ type: String) -> String {
        switch type.lowercased() {
        case "start": return "power"
        case "shutdown", "stop": return "stop.circle"
        default: return "gearshape"
        }
    }

    private static func tint(_ entry: ActivityEntry) -> Color {
        entry.isFailure ? .red : entry.isSuccess ? .green : .gray
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return dayFormatter.string(from: day)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()
}

// MARK: - Payments

struct PaymentsSheet: View {
    @ObservedObject var model: PaymentsModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your plan purchases and upgrades, as TrueCloud recorded them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let message = model.errorMessage {
                        errorCard(message)
                    } else if !model.hasLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if model.records.isEmpty {
                        empty
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.records.enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Divider().padding(.horizontal, 14) }
                                row(record)
                            }
                        }
                        .padding(.vertical, 4)
                        .glassSurface(cornerRadius: 20)
                    }

                    footer
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background { AuroraBackground(intensity: 0.35) }
            .navigationTitle("Payments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Task { await model.load(auth: auth) } } label: {
                        if model.isLoading { ProgressView() } else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    .disabled(model.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await model.load(auth: auth) }
            .task { if !model.hasLoaded { await model.load(auth: auth) } }
        }
    }

    private func row(_ record: PaymentRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.createdAt.map { Self.dateFormatter.string(from: $0) } ?? "Unknown date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.planName.isEmpty ? "Plan" : record.planName).font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    chip(record.typeText, color: .gray)
                    statusChip(record.status)
                }
                if record.status == .failure, let reason = record.failureReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(record.amountText)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color == .gray ? Color.secondary : color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .glassCapsule(tint: color.opacity(0.15))
    }

    @ViewBuilder
    private func statusChip(_ status: PaymentRecord.Status) -> some View {
        switch status {
        case .success: chip("Success", color: .green)
        case .failure: chip("Failed", color: .red)
        case .pending: chip("Pending", color: .orange)
        case .other(let text): chip(text.capitalized, color: .gray)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "creditcard")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No payments yet").font(.headline)
            Text("Plan purchases and upgrades show up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 24)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Couldn't load payments").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { Task { await model.load(auth: auth) } }
                .secondaryGlassButton()
                .disabled(model.isLoading)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 24)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plans and billing are managed on truecloud.in.")
                .foregroundStyle(.secondary)
            Button("Open Plans") { openURL(Config.dashboardURL.appendingPathComponent("plans")) }
                .textLinkStyle()
        }
        .font(.callout)
        .padding(.leading, 4)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()
}
