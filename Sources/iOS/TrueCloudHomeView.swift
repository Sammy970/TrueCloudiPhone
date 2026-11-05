import SwiftUI
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

/// TrueCloud home: start the cloud PC, then Play hands off to Moonlight,
/// which adds, pairs (PIN submitted automatically) and launches "Desktop".
struct TrueCloudHomeView: View {
    @ObservedObject var store: TrueCloudStore
    @ObservedObject private var session: SessionService
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// A destructive action waiting for the user to confirm.
    private enum Confirm: Identifiable {
        case shutDown, forceStop, unpair
        var id: Self { self }
        var title: String {
            switch self {
            case .shutDown: "Shut down your cloud PC?"
            case .forceStop: "Force stop your cloud PC?"
            case .unpair: "Unpair all devices?"
            }
        }
        var message: String {
            switch self {
            case .shutDown: "Windows closes down and plan time stops counting. Unsaved work on the cloud PC is lost."
            case .forceStop: "This cuts the power like pulling the plug. Use it only if Shut Down doesn't work. Unsaved work is lost."
            case .unpair: "Every paired device is removed from your cloud PC. You'll be paired again the next time you press Play."
            }
        }
        var button: String {
            switch self {
            case .shutDown: "Shut Down"
            case .forceStop: "Force Stop"
            case .unpair: "Unpair All"
            }
        }
    }
    @State private var connecting = false
    @State private var confirm: Confirm?
    @State private var prefs = MoonlightPrefs.load()
    @State private var showingSettings = false
    @State private var showingNetwork = false
    @State private var showingAbout = false
    @State private var showingControls = false
    @State private var showingControllers = false
    @State private var showingActivity = false
    @State private var showingPayments = false
    /// Kept here so the sheets show the last list at once and refresh behind it.
    @StateObject private var activityModel = ActivityModel()
    @StateObject private var paymentsModel = PaymentsModel()
    /// Watches controllers for the controller-check card and sheet.
    @StateObject private var gamepads = GamepadMonitor()
    /// Kept here so the card can show the last result.
    @StateObject private var networkCheck = NetworkCheck()

    init(store: TrueCloudStore) {
        self.store = store
        _session = ObservedObject(wrappedValue: store.session)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .reveal(0)
                    .padding(.bottom, 20)

                DisplayHero(phase: session.phase, uptime: session.status?.uptime)
                    .frame(maxWidth: 290)
                    .reveal(0.06)
                    .padding(.bottom, 26)

                VStack(spacing: 6) {
                    Text(connecting ? "Connecting to your cloud PC…" : session.phase.statusText)
                        .font(.title3.weight(.semibold))
                    Text(connecting ? "Your stream opens in a moment." : (session.lockMessage ?? detailText))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .id(connecting ? "connecting" : session.phase.screenState)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .reveal(0.12)
                .padding(.bottom, session.status?.isRunning == true ? 12 : 20)

                telemetry
                    .padding(.bottom, 20)

                ConnectionTrack(phase: session.phase)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .glassSurface(cornerRadius: 26)
                    .reveal(0.18)
                    .padding(.bottom, 24)

                actions
                    .reveal(0.24)
                    .padding(.bottom, 28)

                GlassGroup(spacing: 14) {
                    VStack(spacing: 14) {
                        streamCard.reveal(0.3)
                        networkCard.reveal(0.33)
                        controlsCard.reveal(0.345)
                        activityCard.reveal(0.35)
                        paymentsCard.reveal(0.355)
                        appCard.reveal(0.36)
                    }
                }

                Button { showingAbout = true } label: {
                    HStack(spacing: 6) {
                        Text("\(Config.appName) \(Config.appVersion)")
                        Text("·")
                        Text("Made by \(Config.creatorName)").fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .glassCapsule()
                }
                .buttonStyle(.plain)
                .padding(.top, 22)
                .reveal(0.42)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            // The screen's width, so nothing can push the page sideways. Not containerRelativeFrame:
            // it kept a stale width after the controls editor rotated the app to landscape and back.
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.45, dampingFraction: 0.9), value: session.phase)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background { AuroraBackground(intensity: 0.5) }
        .navigationTitle("TrueCloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { accountMenu }
        .refreshable { await auth.reloadProfile() }
        .onAppear { AppExpiry.scheduleReminder() }
        .sensoryFeedback(trigger: session.phase) { old, new in
            switch new {
            case .ready, .streaming: .success
            case .idle where old != .idle: .impact(weight: .light)
            default: nil
            }
        }
        .sensoryFeedback(.warning, trigger: session.notice?.id)
        .sensoryFeedback(.selection, trigger: prefs)
        .sheet(isPresented: $showingSettings) {
            StreamSettingsSheet(prefs: $prefs)
        }
        .sheet(isPresented: $showingAbout) {
            NavigationStack {
                ScrollView { AboutView() }
                    .background { AuroraBackground(intensity: 0.35) }
                    .navigationTitle("About")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingAbout = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingNetwork) {
            NavigationStack {
                NetworkCheckView(
                    check: networkCheck,
                    resolution: String(prefs.height),
                    fps: String(prefs.fps),
                    bitrate: prefs.bitrateKbps,
                    applyBitrate: { prefs.bitrateKbps = $0; prefs.save() },
                    busy: connecting || session.phase == .pairing
                )
                .background { AuroraBackground(intensity: 0.35) }
                .navigationTitle("Network Check")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingNetwork = false }
                    }
                }
            }
            .sensoryFeedback(.success, trigger: networkCheck.stage == .done)
        }
        .sheet(isPresented: $showingControls) {
            ControlsSheet(prefs: $prefs, monitor: gamepads)
        }
        .sheet(isPresented: $showingControllers) {
            ControllersSheet(monitor: gamepads) { showingControllers = false }
        }
        .sheet(isPresented: $showingActivity) {
            ActivitySheet(model: activityModel)
        }
        .sheet(isPresented: $showingPayments) {
            PaymentsSheet(model: paymentsModel)
        }
        .onAppear(perform: previewControllers)
        .onAppear { syncNetworkHost() }
        .onChange(of: session.endpoint) { _ in syncNetworkHost() }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { item in
            Button(item.button, role: .destructive) {
                switch item {
                case .shutDown: session.shutDown()
                case .forceStop: session.forceStop()
                case .unpair: session.unpairAll()
                }
            }
        } message: { item in
            Text(item.message)
        }
        .alert(item: $session.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message))
        }
    }

    /// On iPhone Moonlight streams on its own, so "ready" means "tap Play".
    private var detailText: String {
        switch session.phase {
        case .ready: "Tap Play. It connects and pairs on its own."
        case .streaming: "You're streaming. Come back here when you're done."
        default: session.phase.detailText
        }
    }

    /// The network check probes the gateway the stream would use.
    private func syncNetworkHost() {
        if let profile = auth.profile { networkCheck.host = session.endpoint.host(for: profile) }
    }

    // MARK: Header

    /// Who's signed in and how much plan time is left: the first thing to see.
    @ViewBuilder
    private var header: some View {
        if let profile = auth.profile {
            card {
                VStack(alignment: .leading, spacing: 14) {
                    ProfileBadge(profile: profile, size: 40)
                    PlanUsage(profile: profile)
                    expiryBanner(profile)
                }
            }
        }
    }

    /// Red when the plan has ended, orange in its last days, like the dashboard's banners.
    @ViewBuilder
    private func expiryBanner(_ profile: RigProfile) -> some View {
        if let end = profile.expiration {
            let date = PlanUsage.dateText(end)
            if profile.isExpired() {
                notice("Your plan ended on \(date). Renew it at truecloud.in to keep playing.",
                       symbol: "xmark.octagon.fill", tint: .red)
            } else if profile.isExpiringSoon(), let days = profile.daysUntilExpiry() {
                let when = days < 1 ? "today" : days == 1 ? "in 1 day" : "in \(days) days"
                notice("Your plan ends \(when) (\(date)).", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Renew") { openURL(Config.dashboardURL.appendingPathComponent("plans")) }
                .textLinkStyle()
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }

    /// Network speed and data used, while the cloud PC runs.
    @ViewBuilder
    private var telemetry: some View {
        if let status = session.status, status.isRunning, session.phase != .shuttingDown {
            let down = chip("arrow.down", String(format: "%.2f MB/s", session.traffic.downloadMBps))
            let up = chip("arrow.up", String(format: "%.2f MB/s", session.traffic.uploadMBps))
            let used = chip("arrow.up.arrow.down", "\(TrafficMeter.text(bytes: status.netin + status.netout)) used")
            // One line on a 6.1" screen; two when it doesn't fit (larger text sizes)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { down; up; used }
                VStack(spacing: 6) {
                    HStack(spacing: 6) { down; up }
                    used
                }
            }
            .transition(.opacity)
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassCapsule()
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            switch session.phase {
            case .idle:
                primary("Start Cloud PC", systemImage: "power", action: startCloudPC)
            case .ready, .pairing, .streaming:
                primary(connecting ? "Connecting" : "Play", systemImage: "play.fill", action: play)
                    .disabled(connecting)
                endpointPicker
                shutDown
            default:
                shutDown
            }
        }
    }

    private func primary(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if connecting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: systemImage).contentTransition(.symbolEffect(.replace))
                }
                Text(title).contentTransition(.interpolate)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .primaryGlassButton()
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    /// Which TrueCloud gateway the stream goes through (both reach the same cloud PC).
    private var endpointPicker: some View {
        HStack(spacing: 10) {
            Label("Server", systemImage: "network")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Server", selection: $session.endpoint) {
                ForEach(Endpoint.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 140)
        }
        .padding(.vertical, 2)
    }

    private var shutDown: some View {
        Button(role: .destructive) {
            if session.phase.isBusy { session.shutDown() } else { confirm = .shutDown }
        } label: {
            Text(session.phase.isBusy ? "Cancel" : "Shut Down")
                .font(.body.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
        }
        .secondaryGlassButton()
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    // MARK: Cards

    private var streamCard: some View {
        Button { showingSettings = true } label: {
            card {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.tcAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stream settings").font(.subheadline.weight(.semibold))
                        Text(prefs.summary)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }

    private var networkCard: some View {
        Button { showingNetwork = true } label: {
            card {
                HStack(spacing: 12) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(networkTint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Network check").font(.subheadline.weight(.semibold))
                        Text(networkSummary)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var controlsCard: some View {
        Button { showingControls = true } label: {
            card {
                HStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.tcAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Controls").font(.subheadline.weight(.semibold))
                        Text(controlsSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }

    private var activityCard: some View {
        Button { showingActivity = true } label: {
            card {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.tcAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity").font(.subheadline.weight(.semibold))
                        Text("Starts, shutdowns and how they went")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }

    private var paymentsCard: some View {
        Button { showingPayments = true } label: {
            card {
                HStack(spacing: 12) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.tcAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Payments").font(.subheadline.weight(.semibold))
                        Text("Purchases, upgrades and failures")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }

    /// e.g. "Auto · Trackpad · Floating sticks on · Xbox Wireless Controller connected"
    private var controlsSummary: String {
        let level = ["Off", "Auto", "Simple", "Full"][min(max(prefs.onscreenControls, 0), 3)]
        var parts = [level, prefs.directTouch ? "Direct touch" : "Trackpad"]
        if OSCLayoutStore.load().floatingSticks { parts.append("Floating sticks on") }
        var text = parts.joined(separator: " · ")
        if let pad = gamepads.pads.first { text += " · \(pad.name) connected" }
        return text
    }

    /// Debug builds only: `TRUECLOUD_PREVIEW=home:<phase>:controllers` opens the controller check, and
    /// `:sample` shows a sample controller mid-press. `:activity` and `:payments` open those sheets with sample data.
    private func previewControllers() {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["TRUECLOUD_PREVIEW"] else { return }
        if value.contains(":sample") { gamepads.showPreview() }
        if value.contains(":controllers") { showingControllers = true }
        if value.contains(":controls") { showingControls = true }
        // `:settings` opens Stream settings; `:roundtrip` then opens the controls editor and closes it again.
        if value.contains(":settings") { showingSettings = true }
        if value.hasSuffix(":network") { showingNetwork = true }
        if value.contains(":about") { showingAbout = true }
        if value.contains(":activity") { activityModel.preview(Self.sampleActivity); showingActivity = true }
        if value.contains(":payments") { paymentsModel.preview(Self.samplePayments); showingPayments = true }
        if value.contains(":roundtrip") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                TrueCloudPanel.presentControlsEditor()
                try? await Task.sleep(for: .seconds(3))
                var top = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.rootViewController
                while let next = top?.presentedViewController { top = next }
                (top as? OSCEditorViewController)?.close()
                try? await Task.sleep(for: .seconds(3))
                showingSettings = false
            }
        }
        #endif
    }

    #if DEBUG
    private static var sampleActivity: [ActivityEntry] {
        let now = Date()
        let rows: [(String, String, TimeInterval)] = [
            ("start", "Success: Start command sent", 2_400),
            ("system", "Log initialized.", 2_460),
            ("shutdown", "Success: VM stopped", 9_000),
            ("start", "Success: Start command sent", 17_000),
            ("shutdown", "Timed out waiting for stop status", 26_000),
            ("shutdown", "Success: VM stopped", 30_000),
            ("start", "Success: Start command sent", 36_000),
            ("shutdown", "Success: VM stopped", 100_000),
            ("start", "Success: Start command sent", 108_000),
            ("start", "Success: Start command sent", 120_000),
        ]
        return rows.enumerated().map { index, row in
            ActivityEntry(id: "\(index)", type: row.0, status: row.1, timestamp: now.addingTimeInterval(-row.2))
        }
    }

    private static var samplePayments: [PaymentRecord] {
        let now = Date()
        return [
            PaymentRecord(id: "p3", planName: "Regular", amount: 159_920, status: .pending, isUpgrade: true,
                          createdAt: now.addingTimeInterval(-3_600)),
            PaymentRecord(id: "p2", planName: "Regular", amount: 159_920, status: .failure, isUpgrade: true,
                          createdAt: now.addingTimeInterval(-86_400 * 9), failureReason: "Payment declined"),
            PaymentRecord(id: "p1", planName: "Basic", amount: 99_900, status: .success,
                          createdAt: now.addingTimeInterval(-86_400 * 40)),
        ]
    }
    #endif

    /// The last result, e.g. "45 ms · Good · 322 Mbps", or what the check does.
    private var networkSummary: String {
        guard let median = networkCheck.medianLatency, networkCheck.stage == .done else {
            return networkCheck.isRunning ? "Testing…" : "See how a stream would feel, before starting your PC"
        }
        let zone = LatencyScale.zone(for: median).name
        let speed = networkCheck.downloadMbps.map { " · \(Int($0.rounded())) Mbps" } ?? ""
        return "\(Int(median.rounded())) ms · \(zone)\(speed)"
    }

    private var networkTint: Color {
        guard let median = networkCheck.medianLatency, networkCheck.stage == .done else { return .tcAccent }
        return LatencyScale.zone(for: median).color
    }

    private var appCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("This app", systemImage: "iphone").font(.subheadline.weight(.semibold))
                    Spacer()
                    expiry
                }
                Text("Builds signed with a free Apple ID stop opening after 7 days. You'll get a reminder the day before; then reinstall from your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var expiry: some View {
        if let date = AppExpiry.date, let days = AppExpiry.daysLeft {
            Text("Expires \(date.formatted(.dateTime.day().month().hour().minute()))")
                .font(.footnote.weight(.medium))
                .foregroundStyle(days <= 1 ? .red : days <= 2 ? .orange : .secondary)
        } else {
            Text("Expiry unknown").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassSurface(cornerRadius: 26)
    }

    private var accountMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let name = auth.profile?.displayName, !name.isEmpty { Text(name) }
                Button("Refresh Account", systemImage: "arrow.clockwise") { Task { await auth.reloadProfile() } }
                Button("Plans & Pricing", systemImage: "creditcard") { openURL(Config.dashboardURL) }
                Button("About", systemImage: "info.circle") { showingAbout = true }
                Divider()
                Button("Unpair All Devices", systemImage: "link.badge.plus") { confirm = .unpair }
                    .disabled(session.phase == .idle || session.phase == .checking)
                Button("Force Stop Cloud PC", systemImage: "bolt.slash", role: .destructive) { confirm = .forceStop }
                    .disabled(session.phase == .idle || session.phase == .checking)
                Divider()
                Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    auth.logout()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: Actions

    private func startCloudPC() {
        session.start()
    }

    private func play() {
        connecting = true
        Task {
            defer { connecting = false }
            do {
                // The rig's address and port come from the profile: read it fresh, in case TrueCloud changed them
                await auth.reloadProfile()
                let host = try store.prepareConnection()
                Log.info("[panel] play → \(host), phase \(session.phase)")
                // Moonlight's main screen picks this up in viewDidAppear once the panel is gone.
                TrueCloudPanel.pendingConnectAddress = host
                dismiss()
                // The in-stream overlay (time left, health warnings) appears once the panel is gone.
                let profile = auth.profile
                Task {
                    try? await Task.sleep(for: .seconds(0.6))
                    StreamOverlayWindow.shared.begin(host: host, profile: profile)
                }
            } catch {
                Log.info("[panel] play failed: \(error.localizedDescription)")
                session.notice = .init(title: "Couldn't Connect", message: error.localizedDescription)
            }
        }
    }
}
