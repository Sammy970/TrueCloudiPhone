import SwiftUI

/// Who made the app, its version and what it stands on.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 22) {
            header.reveal(0)
            discordCard.reveal(0.04)
            makerCard.reveal(0.08)
            projectCard.reveal(0.16)
            Text("Independent prototype, shown to TrueCloud with their permission. Not an official release.\n\"TrueCloud\" belongs to its owners; this app's icon is its own drawing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .reveal(0.22)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    // MARK: App

    private var header: some View {
        VStack(spacing: 12) {
            AppIconImage()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.tcAccent.opacity(0.55), radius: 22, y: 8)
            VStack(spacing: 4) {
                Text(Config.appName).font(.title2.weight(.bold))
                Text("Version \(Config.appVersion)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Label("Prototype", systemImage: "hammer.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.tcAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassCapsule(tint: Color.tcAccent.opacity(0.15))
        }
    }

    // MARK: Discord

    private static let discordBlurple = Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255)

    private var discordCard: some View {
        Button { openURL(Config.discordInvite) } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Self.discordBlurple.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Join our Discord").font(.subheadline.weight(.semibold))
                    Text("Questions, bugs or ideas? Come and chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Self.discordBlurple)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(cornerRadius: 20)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Self.discordBlurple.opacity(0.45), lineWidth: 1))
        .help(Config.discordInvite.absoluteString)
        .accessibilityLabel("Join our Discord")
    }

    // MARK: Maker

    private var makerCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    Text("MADE BY")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(Config.creatorName).font(.title3.weight(.bold))
                    Text("Designed and built this client, from the sign-in to the last animation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                linkButton("GitHub", handle: "@Sammy970", symbol: "chevron.left.forwardslash.chevron.right", url: Config.creatorGitHub)
                linkButton("X", handle: "@Sammy_970", symbol: "at", url: Config.creatorX)
            }
        }
        .padding(18)
        .glassSurface(cornerRadius: 24)
    }

    private var avatar: some View {
        Text(Config.creatorName.prefix(1))
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(Color.tcAccent.gradient, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: Color.tcAccent.opacity(0.35), radius: 10, y: 4)
    }

    private func linkButton(_ title: String, handle: String, symbol: String, url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(handle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .secondaryGlassButton()
        .controlSize(.large)
        .help(url.absoluteString)
    }

    // MARK: Project

    private var projectCard: some View {
        VStack(spacing: 0) {
            projectRow("TrueCloud", detail: "truecloud.in: plans, billing and account", symbol: "cloud.fill", url: Config.siteURL)
            Divider().padding(.leading, 44)
            projectRow("Streaming by Moonlight", detail: "Open-source game streaming (GPLv3)", symbol: "play.rectangle.fill", url: Config.moonlightURL)
        }
        .glassSurface(cornerRadius: 20)
    }

    private func projectRow(_ title: String, detail: String, symbol: String, url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.tcAccent.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
