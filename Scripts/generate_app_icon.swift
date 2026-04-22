#!/usr/bin/env swift
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let outURL = URL(fileURLWithPath: "FitTrack/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fputs("CGContext failed\n", stderr); exit(1) }

// Background: vertical lime → teal gradient.
let lime = CGColor(red: 200/255.0, green: 255/255.0, blue: 0/255.0, alpha: 1.0)
let teal = CGColor(red: 26/255.0,  green: 188/255.0, blue: 156/255.0, alpha: 1.0)
let bgGradient = CGGradient(
    colorsSpace: cs,
    colors: [lime, teal] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Glyph color: near-black (Theme.Colors.background)
let glyph = CGColor(red: 16/255.0, green: 18/255.0, blue: 20/255.0, alpha: 1.0)
ctx.setFillColor(glyph)

// Hand-drawn dumbbell, centered. Coordinate origin is bottom-left.
let cx = size / 2, cy = size / 2

// Bar: long thin pill across the middle.
let barW: CGFloat = size * 0.46
let barH: CGFloat = size * 0.08
let barRect = CGRect(x: cx - barW/2, y: cy - barH/2, width: barW, height: barH)
let barPath = CGPath(roundedRect: barRect, cornerWidth: barH/2, cornerHeight: barH/2, transform: nil)
ctx.addPath(barPath); ctx.fillPath()

// Weight plates: two thicker rounded rects flanking each end.
let plateOuterW: CGFloat = size * 0.10
let plateOuterH: CGFloat = size * 0.36
let plateInnerW: CGFloat = size * 0.06
let plateInnerH: CGFloat = size * 0.26
let plateGap: CGFloat = size * 0.012  // gap between inner plate and bar
let plateRadius: CGFloat = size * 0.022

func plate(centerX: CGFloat, w: CGFloat, h: CGFloat) {
    let r = CGRect(x: centerX - w/2, y: cy - h/2, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil))
    ctx.fillPath()
}

// Right side: inner small plate, then outer big plate further out.
let rightInnerCX = barRect.maxX + plateGap + plateInnerW/2
let rightOuterCX = rightInnerCX + plateInnerW/2 + size*0.018 + plateOuterW/2
plate(centerX: rightInnerCX, w: plateInnerW, h: plateInnerH)
plate(centerX: rightOuterCX, w: plateOuterW, h: plateOuterH)

// Left side mirror.
let leftInnerCX = barRect.minX - plateGap - plateInnerW/2
let leftOuterCX = leftInnerCX - plateInnerW/2 - size*0.018 - plateOuterW/2
plate(centerX: leftInnerCX, w: plateInnerW, h: plateInnerH)
plate(centerX: leftOuterCX, w: plateOuterW, h: plateOuterH)

// End caps on the very outside — small rounded rects so the dumbbell
// has clean tips instead of flat plate edges.
let capW: CGFloat = size * 0.025
let capH: CGFloat = size * 0.18
let capRadius: CGFloat = capW/2
let rightCapCX = rightOuterCX + plateOuterW/2 + capW/2 - capW*0.4
let leftCapCX = leftOuterCX - plateOuterW/2 - capW/2 + capW*0.4
let rightCapRect = CGRect(x: rightCapCX - capW/2, y: cy - capH/2, width: capW, height: capH)
let leftCapRect = CGRect(x: leftCapCX - capW/2, y: cy - capH/2, width: capW, height: capH)
ctx.addPath(CGPath(roundedRect: rightCapRect, cornerWidth: capRadius, cornerHeight: capRadius, transform: nil))
ctx.addPath(CGPath(roundedRect: leftCapRect, cornerWidth: capRadius, cornerHeight: capRadius, transform: nil))
ctx.fillPath()

guard let cgImage = ctx.makeImage() else { fputs("makeImage failed\n", stderr); exit(1) }

try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("dest failed\n", stderr); exit(1)
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else { fputs("PNG write failed\n", stderr); exit(1) }
print("wrote \(outURL.path) (\(Int(size))x\(Int(size)))")
