import SwiftUI
import QuartzCore

// Looping decorations (the scanning band, pulsing dots, the breathing Play glow) run as Core Animation
// animations: the system's render server draws every frame, so the app itself does no work while they loop.
// The same effects done with SwiftUI `repeatForever` / `TimelineView(.animation)` re-evaluated the view
// 60 times a second and cost about 25–35% CPU, even during a stream.

#if os(macOS)
import AppKit
typealias PlatformView = NSView
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformView = UIView
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// A view whose layer is set up by `build` and rebuilt when its size changes.
final class LoopingLayerView: PlatformView {
    var build: ((CALayer, CGSize) -> Void)?
    private var builtSize: CGSize = .zero

    #if os(macOS)
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true   // y grows downward, as on iOS and in SwiftUI
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); rebuildIfNeeded() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var root: CALayer? { layer }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); rebuildIfNeeded() }
    private var root: CALayer? { layer }
    #endif

    func rebuildIfNeeded(force: Bool = false) {
        guard let root, bounds.width > 0, bounds.height > 0, force || bounds.size != builtSize else { return }
        builtSize = bounds.size
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        build?(root, bounds.size)
        CATransaction.commit()
    }
}

/// Hosts a `LoopingLayerView` in SwiftUI.
struct LoopingLayer: PlatformViewRepresentable {
    /// Changing `key` rebuilds the layers (e.g. a new color).
    let key: String
    let build: (CALayer, CGSize) -> Void

    #if os(macOS)
    func makeNSView(context: Context) -> LoopingLayerView { make() }
    func updateNSView(_ view: LoopingLayerView, context: Context) { update(view, context) }
    #else
    func makeUIView(context: Context) -> LoopingLayerView { make() }
    func updateUIView(_ view: LoopingLayerView, context: Context) { update(view, context) }
    #endif

    private func make() -> LoopingLayerView {
        let view = LoopingLayerView()
        view.build = build
        return view
    }

    private func update(_ view: LoopingLayerView, _ context: Context) {
        view.build = build
        if context.coordinator.key != key {
            context.coordinator.key = key
            view.rebuildIfNeeded(force: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var key = "" }
}

private func cgColor(_ color: Color, opacity: Double = 1) -> CGColor {
    #if os(macOS)
    NSColor(color).withAlphaComponent(opacity).cgColor
    #else
    UIColor(color).withAlphaComponent(opacity).cgColor
    #endif
}

private func forever(_ animation: CABasicAnimation, duration: CFTimeInterval, autoreverses: Bool = false,
                     timing: CAMediaTimingFunctionName = .easeInEaseOut) -> CABasicAnimation {
    animation.duration = duration
    animation.repeatCount = .infinity
    animation.autoreverses = autoreverses
    animation.timingFunction = CAMediaTimingFunction(name: timing)
    animation.isRemovedOnCompletion = false   // keep looping after the window hides and shows again
    return animation
}

/// A soft band of brand light sweeping down while the PC is working.
struct ScanBand: View {
    var color: Color = .tcAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopingLayer(key: "\(reduceMotion)") { root, size in
            let band = CAGradientLayer()
            band.colors = [cgColor(color, opacity: 0), cgColor(color, opacity: 0.35), cgColor(color, opacity: 0)]
            band.startPoint = CGPoint(x: 0.5, y: 0)
            band.endPoint = CGPoint(x: 0.5, y: 1)
            let height = size.height * 0.45
            band.bounds = CGRect(x: 0, y: 0, width: size.width, height: height)
            band.anchorPoint = CGPoint(x: 0.5, y: 0)
            band.position = CGPoint(x: size.width / 2, y: -height)
            root.masksToBounds = true
            root.addSublayer(band)
            guard !reduceMotion else { band.position.y = size.height * 0.3; return }
            let move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = -height
            move.toValue = size.height
            band.add(forever(move, duration: 2.4, timing: .linear), forKey: "scan")
        }
        .allowsHitTesting(false)
    }
}

/// A small dot with a ring that grows and fades, over and over.
struct PulsingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopingLayer(key: "\(color)\(reduceMotion)") { root, size in
            let d: CGFloat = 7
            let rect = CGRect(x: (size.width - d) / 2, y: (size.height - d) / 2, width: d, height: d)

            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
            ring.fillColor = cgColor(color, opacity: 0.4)
            ring.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            ring.position = CGPoint(x: rect.midX, y: rect.midY)
            root.addSublayer(ring)

            let dot = CAShapeLayer()
            dot.path = CGPath(ellipseIn: rect, transform: nil)
            dot.fillColor = cgColor(color)
            root.addSublayer(dot)

            guard !reduceMotion else { ring.opacity = 0; return }
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 2.4
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 1.4
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "pulse")
        }
        .frame(width: 7, height: 7)
        .allowsHitTesting(false)
    }
}

/// A soft glow that slowly brightens and dims behind the Play button.
struct BreathingGlow: View {
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopingLayer(key: "\(reduceMotion)") { root, size in
            let d = min(size.width, size.height) * 0.62
            let glow = CALayer()
            glow.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            glow.position = CGPoint(x: size.width / 2, y: size.height / 2)
            glow.cornerRadius = d / 2
            glow.backgroundColor = cgColor(color, opacity: 0.22)
            glow.shadowColor = cgColor(color)
            glow.shadowRadius = 14
            glow.shadowOpacity = 0.5
            glow.shadowOffset = .zero
            glow.shadowPath = CGPath(ellipseIn: glow.bounds, transform: nil)
            glow.opacity = 0.35
            root.addSublayer(glow)
            guard !reduceMotion else { return }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.25
            breathe.toValue = 1
            glow.add(forever(breathe, duration: 1.6, autoreverses: true), forKey: "breathe")
            let swell = CABasicAnimation(keyPath: "transform.scale")
            swell.fromValue = 0.94
            swell.toValue = 1.08
            glow.add(forever(swell, duration: 1.6, autoreverses: true), forKey: "swell")
        }
        .allowsHitTesting(false)
    }
}
