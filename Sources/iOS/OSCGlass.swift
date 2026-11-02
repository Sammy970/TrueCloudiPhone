import UIKit

/// Draws the on-screen gamepad's glass controls. Each control is rendered once into an image (and cached)
/// instead of blurring the stream behind it: a live blur under ~15 controls would cost GPU time on every
/// video frame, and latency matters more here than a true refraction.
///
/// The look: a smoky, translucent body so the picture shows through, a soft highlight along the top edge
/// like light on glass, a thin bright rim that fades toward the bottom, and a gentle drop shadow. A pressed
/// control fills with TrueCloud blue and glows.
enum OSCGlass {
    enum Direction: Int, Hashable { case up, right, down, left }

    enum Shape: Hashable {
        /// Face buttons, LS/RS.
        case circle
        /// Back and Start.
        case pill
        /// Bumpers and triggers: a rounded hexagon.
        case gem
        /// One piece of the D-pad, tapering toward the centre.
        case dpad(Direction)
        /// The big ring a stick moves in.
        case stickBase
        /// The stick itself.
        case knob
    }

    struct Spec: Hashable {
        var shape: Shape
        /// Size in half points, so the spec stays Hashable.
        var width2: Int
        var height2: Int
        var label = ""
        /// Degrees; the shoulder buttons' labels follow the diagonal they sit on.
        var labelAngle = 0
        var pressed = false
        /// Screen scale the image is rendered for.
        var scale2 = 6

        init(shape: Shape, size: CGSize, label: String = "", labelAngle: Int = 0, pressed: Bool = false, scale: CGFloat) {
            self.shape = shape
            width2 = Int((size.width * 2).rounded())
            height2 = Int((size.height * 2).rounded())
            self.label = label
            self.labelAngle = labelAngle
            self.pressed = pressed
            scale2 = Int((scale * 2).rounded())
        }
    }

    struct Art {
        let image: UIImage
        /// Transparent margin around the shape (for the shadow and glow).
        let pad: CGFloat
    }

    static let blue = UIColor(red: 0.07, green: 0.66, blue: 0.62, alpha: 1)  // TrueCloud teal
    private static let cache = NSCache<Key, CachedArt>()

    private final class Key: NSObject {
        let spec: Spec
        init(_ spec: Spec) { self.spec = spec }
        override var hash: Int { spec.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.spec == spec }
    }

    private final class CachedArt {
        let art: Art
        init(_ art: Art) { self.art = art }
    }

    static func art(_ spec: Spec) -> Art {
        let key = Key(spec)
        if let hit = cache.object(forKey: key) { return hit.art }
        let art = render(spec)
        cache.setObject(CachedArt(art), forKey: key)
        return art
    }

    // MARK: Rendering

    private static func render(_ spec: Spec) -> Art {
        let size = CGSize(width: CGFloat(spec.width2) / 2, height: CGFloat(spec.height2) / 2)
        let pad: CGFloat = 14
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(spec.scale2) / 2
        format.opaque = false
        let canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        let rect = CGRect(x: pad, y: pad, width: size.width, height: size.height)

        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let cg = context.cgContext
            let (path, transform) = shapePath(spec.shape, in: rect)
            let big = spec.shape == .stickBase
            let pressed = spec.pressed

            // Shadow (and glow when pressed): drawn from a solid shape, then the shape is punched out so the
            // glass itself stays see-through.
            cg.saveGState()
            if pressed {
                cg.setShadow(offset: .zero, blur: 13, color: blue.withAlphaComponent(0.85).cgColor)
            } else {
                cg.setShadow(offset: CGSize(width: 0, height: 2.5), blur: big ? 12 : 8, color: UIColor.black.withAlphaComponent(0.42).cgColor)
            }
            cg.setFillColor(UIColor.black.cgColor)
            cg.addPath(path)
            cg.fillPath()
            cg.restoreGState()
            cg.saveGState()
            cg.setBlendMode(.clear)
            cg.addPath(path)
            cg.fillPath()
            cg.restoreGState()

            // Body, clipped to the shape.
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            let bounds = path.boundingBoxOfPath

            // Smoky tint: darker than the picture so white labels stay readable on bright scenes.
            let tint: UIColor = pressed ? blue.withAlphaComponent(0.62) : UIColor(white: 0.06, alpha: big ? 0.20 : 0.36)
            cg.setFillColor(tint.cgColor)
            cg.fill(bounds)

            // Light falling from above.
            gradient(cg, [(UIColor.white.withAlphaComponent(pressed ? 0.34 : 0.27), 0), (UIColor.white.withAlphaComponent(0.07), 0.5), (UIColor.white.withAlphaComponent(0.02), 1)],
                     from: CGPoint(x: bounds.midX, y: bounds.minY), to: CGPoint(x: bounds.midX, y: bounds.maxY))
            // A little shade pooling at the bottom edge gives the body depth.
            gradient(cg, [(UIColor.clear, 0.55), (UIColor.black.withAlphaComponent(0.20), 1)],
                     from: CGPoint(x: bounds.midX, y: bounds.minY), to: CGPoint(x: bounds.midX, y: bounds.maxY))

            if spec.shape == .knob {
                // A glass bead: the highlight sits off-centre, toward the light.
                let hi = CGPoint(x: bounds.minX + bounds.width * 0.36, y: bounds.minY + bounds.height * 0.30)
                radial(cg, [(UIColor.white.withAlphaComponent(0.55), 0), (UIColor.white.withAlphaComponent(0), 1)], center: hi, radius: bounds.width * 0.62)
            } else if spec.shape != .stickBase {
                // The glossy band across the top.
                let band = CGRect(x: bounds.minX + bounds.width * 0.10, y: bounds.minY + bounds.height * 0.05,
                                  width: bounds.width * 0.80, height: bounds.height * 0.44)
                cg.saveGState()
                cg.addPath(CGPath(roundedRect: band, cornerWidth: min(band.height * 0.5, 14), cornerHeight: min(band.height * 0.5, 14), transform: nil))
                cg.clip()
                gradient(cg, [(UIColor.white.withAlphaComponent(0.36), 0), (UIColor.white.withAlphaComponent(0.03), 1)],
                         from: CGPoint(x: band.midX, y: band.minY), to: CGPoint(x: band.midX, y: band.maxY))
                cg.restoreGState()
            }
            cg.restoreGState()

            // Rim: bright where the light hits (top-left), fading toward the bottom-right.
            cg.saveGState()
            cg.addPath(path)
            cg.setLineWidth(big ? 1.2 : 1.5)
            cg.replacePathWithStrokedPath()
            cg.clip()
            let rimBounds = path.boundingBoxOfPath
            gradient(cg, [(UIColor.white.withAlphaComponent(pressed ? 0.95 : 0.80), 0), (UIColor.white.withAlphaComponent(0.16), 0.5), (UIColor.white.withAlphaComponent(0.42), 1)],
                     from: CGPoint(x: rimBounds.minX, y: rimBounds.minY), to: CGPoint(x: rimBounds.maxX, y: rimBounds.maxY))
            cg.restoreGState()

            decorate(spec, in: rect, path: path, transform: transform, cg: cg)
        }
        return Art(image: image, pad: pad)
    }

    /// Labels, the D-pad arrow, and the stick ring's markings.
    private static func decorate(_ spec: Spec, in rect: CGRect, path: CGPath, transform: CGAffineTransform, cg: CGContext) {
        switch spec.shape {
        case .stickBase:
            // Four notches on the rim show where the stick's travel ends.
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = rect.width / 2
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            cg.setLineWidth(2.2)
            cg.setLineCap(.round)
            for i in 0..<4 {
                let a = CGFloat(i) * .pi / 2
                cg.move(to: CGPoint(x: c.x + cos(a) * (r - 11), y: c.y + sin(a) * (r - 11)))
                cg.addLine(to: CGPoint(x: c.x + cos(a) * (r - 5), y: c.y + sin(a) * (r - 5)))
            }
            cg.strokePath()
            // A faint guide ring the knob sits on at rest.
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.10).cgColor)
            cg.setLineWidth(1)
            cg.strokeEllipse(in: CGRect(x: c.x - r * 0.46, y: c.y - r * 0.46, width: r * 0.92, height: r * 0.92))
        case .dpad:
            // A small arrow near the outer end, pointing away from the centre.
            let cx = rect.midX, cy = rect.midY
            let short = min(rect.width, rect.height), long = max(rect.width, rect.height)
            let u = short * 0.2
            let tip = CGPoint(x: cx, y: cy - long * 0.5 + long * 0.2)
            let points = [CGPoint(x: tip.x, y: tip.y), CGPoint(x: tip.x + u, y: tip.y + u * 1.1), CGPoint(x: tip.x - u, y: tip.y + u * 1.1)]
            let glyph = CGMutablePath()
            glyph.addLines(between: points.map { $0.applying(rotation(for: spec.shape, about: CGPoint(x: cx, y: cy))) })
            glyph.closeSubpath()
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            cg.setFillColor(UIColor.white.withAlphaComponent(0.92).cgColor)
            cg.addPath(glyph)
            cg.fillPath()
        default:
            break
        }
        guard !spec.label.isEmpty else { return }
        let height = CGFloat(spec.height2) / 2, width = CGFloat(spec.width2) / 2
        let fontSize: CGFloat
        switch spec.shape {
        case .pill: fontSize = height * 0.36
        case .gem: fontSize = min(width, height) * 0.31
        case .knob: fontSize = width * 0.34
        default: fontSize = min(width, height) * (spec.label.count > 1 ? 0.34 : 0.45)
        }
        var font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        if let rounded = font.fontDescriptor.withDesign(.rounded) { font = UIFont(descriptor: rounded, size: fontSize) }
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = 2.5
        let text = NSAttributedString(string: spec.label, attributes: [
            .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.97), .shadow: shadow,
            .kern: spec.shape == .pill ? 0.6 : 0,
        ])
        let textSize = text.size()
        cg.saveGState()
        cg.translateBy(x: rect.midX, y: rect.midY)
        cg.rotate(by: CGFloat(spec.labelAngle) * .pi / 180)
        UIGraphicsPushContext(cg)
        text.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
        UIGraphicsPopContext()
        cg.restoreGState()
    }

    // MARK: Shapes

    private static func shapePath(_ shape: Shape, in rect: CGRect) -> (CGPath, CGAffineTransform) {
        switch shape {
        case .circle, .stickBase, .knob:
            return (CGPath(ellipseIn: rect, transform: nil), .identity)
        case .pill:
            let r = min(rect.height * 0.32, 13)
            return (CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil), .identity)
        case .gem:
            let w = rect.width, h = rect.height
            let points = [
                CGPoint(x: rect.midX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY + h * 0.26),
                CGPoint(x: rect.maxX, y: rect.maxY - h * 0.26),
                CGPoint(x: rect.midX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY - h * 0.26),
                CGPoint(x: rect.minX, y: rect.minY + h * 0.26),
            ]
            return (roundedPolygon(points, radius: min(w, h) * 0.2), .identity)
        case .dpad:
            // Built pointing up in a short × long box, then turned to face the right way.
            let short = min(rect.width, rect.height), long = max(rect.width, rect.height)
            let box = CGRect(x: rect.midX - short / 2, y: rect.midY - long / 2, width: short, height: long)
            let points = [
                CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.minY + long * 0.60),
                CGPoint(x: box.midX, y: box.maxY),
                CGPoint(x: box.minX, y: box.minY + long * 0.60),
            ]
            let turn = rotation(for: shape, about: CGPoint(x: rect.midX, y: rect.midY))
            return (roundedPolygon(points, radius: short * 0.24, transform: turn), turn)
        }
    }

    private static func rotation(for shape: Shape, about c: CGPoint) -> CGAffineTransform {
        guard case .dpad(let direction) = shape else { return .identity }
        let angle: CGFloat = [.up: 0, .right: .pi / 2, .down: .pi, .left: -.pi / 2][direction] ?? 0
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y)
    }

    private static func roundedPolygon(_ points: [CGPoint], radius: CGFloat, transform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[n - 1], points[0]), transform: transform)
        for i in 0..<n {
            path.addArc(tangent1End: points[i], tangent2End: mid(points[i], points[(i + 1) % n]), radius: radius, transform: transform)
        }
        path.closeSubpath()
        return path
    }

    // MARK: Gradients

    private static func gradient(_ cg: CGContext, _ stops: [(UIColor, CGFloat)], from: CGPoint, to: CGPoint) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map { $0.0.cgColor } as CFArray, locations: stops.map { $0.1 }) else { return }
        cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radial(_ cg: CGContext, _ stops: [(UIColor, CGFloat)], center: CGPoint, radius: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map { $0.0.cgColor } as CFArray, locations: stops.map { $0.1 }) else { return }
        cg.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
}
