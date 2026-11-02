#!/usr/bin/env swift
// Draws the TrueCloud iPhone art: a white cloud with a play triangle on a teal-to-indigo tile. Original artwork.
//  - Assets/AppIcon-1024.png   full-bleed opaque square (iOS rounds it)
//  - Assets/TrueCloudLogo.png  rounded tile with transparent corners (login, About, launch screen)
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

func render(size: Int, fullBleed: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Artwork is laid out on a 1024 canvas; the logo uses the tile alone (824 square) scaled up to fill.
    let s = CGFloat(size) / (fullBleed ? 1024 : 824)
    ctx.scaleBy(x: s, y: s)
    if !fullBleed { ctx.translateBy(x: -100, y: -100) }

    let tile = fullBleed ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = fullBleed ? NSBezierPath(rect: tile) : NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    tilePath.addClip()
    let colors = [NSColor(red: 0.25, green: 0.82, blue: 0.74, alpha: 1).cgColor,
                  NSColor(red: 0.07, green: 0.58, blue: 0.62, alpha: 1).cgColor,
                  NSColor(red: 0.30, green: 0.30, blue: 0.82, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    let cloud = NSBezierPath()
    cloud.append(NSBezierPath(roundedRect: CGRect(x: 230, y: 330, width: 564, height: 230), xRadius: 115, yRadius: 115))
    cloud.append(NSBezierPath(ovalIn: CGRect(x: 292, y: 420, width: 280, height: 280)))
    cloud.append(NSBezierPath(ovalIn: CGRect(x: 436, y: 468, width: 330, height: 330)))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(red: 0.02, green: 0.12, blue: 0.2, alpha: 0.35).cgColor)
    NSColor.white.setFill(); cloud.fill()
    ctx.restoreGState()

    let play = NSBezierPath()
    play.move(to: CGPoint(x: 458, y: 410)); play.line(to: CGPoint(x: 458, y: 640)); play.line(to: CGPoint(x: 650, y: 525)); play.close()
    play.lineJoinStyle = .round
    NSColor(red: 0.07, green: 0.50, blue: 0.58, alpha: 1).setFill(); play.fill()
    NSColor(red: 0.07, green: 0.50, blue: 0.58, alpha: 1).setStroke(); play.lineWidth = 34; play.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
try? FileManager.default.createDirectory(atPath: "Assets", withIntermediateDirectories: true)
write(render(size: 1024, fullBleed: true), to: "Assets/AppIcon-1024.png")
write(render(size: 512, fullBleed: false), to: "Assets/TrueCloudLogo.png")
print("Wrote Assets/AppIcon-1024.png and Assets/TrueCloudLogo.png")
