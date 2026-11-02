import SwiftUI

extension Color {
    // Theme tokens. This client's own accent (teal, with indigo as its partner); not TrueCloud's brand colours.
    /// Primary accent: teal.
    static let tcAccent = Color(red: 0.07, green: 0.66, blue: 0.62)
    /// Lighter teal for highlights and gradients.
    static let tcAccentLight = Color(red: 0.25, green: 0.82, blue: 0.74)
    /// Deeper teal for gradient ends and pressed states.
    static let tcAccentDeep = Color(red: 0.04, green: 0.45, blue: 0.50)
    /// Secondary accent: indigo.
    static let tcIndigo = Color(red: 0.36, green: 0.34, blue: 0.86)
    /// Dark screen tint used inside the monitor (deep indigo-navy).
    static let tcScreenTop = Color(red: 0.08, green: 0.09, blue: 0.2)
    static let tcScreenBottom = Color(red: 0.03, green: 0.04, blue: 0.1)
}

enum KeyboardKind { case email, phone, oneTimeCode, number }

extension View {
    /// Plain text-link button: `.link` on macOS, borderless on iOS.
    @ViewBuilder
    func textLinkStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link).foregroundStyle(Color.tcAccent)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// Picks a suitable software keyboard on iOS; no-op on macOS.
    @ViewBuilder
    func keyboard(_ kind: KeyboardKind) -> some View {
        #if os(iOS)
        switch kind {
        case .email:
            keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        case .phone:
            keyboardType(.phonePad).textContentType(.telephoneNumber)
        case .oneTimeCode:
            keyboardType(.numberPad).textContentType(.oneTimeCode)
        case .number:
            keyboardType(.numberPad)
        }
        #else
        self
        #endif
    }
}

/// The app's own icon (the bundle icon).
struct AppIconImage: View {
    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
        #else
        Image("TrueCloudLogo").resizable().interpolation(.high)
        #endif
    }
}

extension View {
    /// Sign-in fields: large rounded-border fields on macOS, filled rounded fields on iOS.
    @ViewBuilder
    func loginFieldStyle() -> some View {
        #if os(macOS)
        textFieldStyle(.roundedBorder).controlSize(.large)
        #else
        textFieldStyle(FilledFieldStyle())
        #endif
    }
}

#if os(iOS)
private struct FilledFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
#endif

extension View {
    /// Lets the view run under a hidden, transparent window title bar (macOS 15+); no-op elsewhere.
    @ViewBuilder
    func transparentTitleBar() -> some View {
        #if os(macOS)
        if #available(macOS 15, *) {
            toolbar(removing: .title).toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Liquid Glass

/// Glass is used on iOS/macOS 26+. Debug window snapshots (`TRUECLOUD_SNAPSHOT`) can't draw it,
/// so they get the pre-26 look instead.
private let glassAllowed: Bool = {
    #if DEBUG && os(macOS)
    return ProcessInfo.processInfo.environment["TRUECLOUD_SNAPSHOT"] == nil
    #else
    return true
    #endif
}()

extension View {
    /// A Liquid Glass panel on iOS/macOS 26+; a material card on earlier systems.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26, macOS 26, *), glassAllowed {
            glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
    }

    /// Capsule-shaped Liquid Glass, for chips and small strips.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26, macOS 26, *), glassAllowed {
            glassEffect(Self.glass(tint: tint, interactive: interactive), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    /// The one main action: tinted glass on 26+, bordered-prominent before.
    @ViewBuilder
    func primaryGlassButton() -> some View {
        if #available(iOS 26, macOS 26, *), glassAllowed {
            buttonStyle(.glassProminent)
        } else {
            #if DEBUG
            // Window snapshots draw native prominent buttons grey; this draws the accent fill they have when live.
            if !glassAllowed { buttonStyle(SnapshotProminentStyle()) } else { buttonStyle(.borderedProminent) }
            #else
            buttonStyle(.borderedProminent)
            #endif
        }
    }

    /// Secondary actions: clear, untinted glass on 26+ (the app's blue tint is kept for the one
    /// main action), bordered before.
    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(iOS 26, macOS 26, *), glassAllowed {
            buttonStyle(.glass).tint(nil)
        } else {
            buttonStyle(.bordered)
        }
    }

    @available(iOS 26, macOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

#if DEBUG
private struct SnapshotProminentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.tcAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
#endif

/// A thin accent progress bar (the native one stays grey whenever the window isn't active).
struct AccentBar: View {
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                Capsule()
                    .fill(LinearGradient(colors: [.tcAccentLight, .tcAccent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Groups nearby glass shapes so they blend and morph together on 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26, macOS 26, *), glassAllowed {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
