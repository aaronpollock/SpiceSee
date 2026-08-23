#!/usr/bin/env swift
//
// make-icons.swift
//
// Repeatable generator for SpiceSee's app icon and .vv document icon.
// Renders the "display + chili pepper" mark from a single vector description
// at every required size, applying the legibility ladder described in
// docs/design/design-text.txt (lines 278-299) and
// docs/design/SpiceSee UI.dc.html (artboard 08):
//
//   - >=128px: gradient plate/screen/pepper, stem, stand, bezel highlight.
//   - 32-64px: solid screen (#191A1D) + solid pepper (#D0392A), stem and
//     bezel highlight kept, stand dropped.
//   - 16px: stem and highlight dropped too, leaving a dark rectangle + a red
//     form on a flat plate -- the strongest 2-value silhouette.
//
// Run with: swift Tools/make-icons.swift
// Writes into Sources/SpiceSee/Assets.xcassets/{AppIcon.appiconset,VVDocument.imageset}
// and a verification contact sheet at docs/design/icon-ladder.png.

import Foundation
import CoreGraphics
import CoreText
import ImageIO

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsRoot = repoRoot.appendingPathComponent("Sources/SpiceSee/Assets.xcassets")
let appIconDir = assetsRoot.appendingPathComponent("AppIcon.appiconset")
let appIconDarkDir = appIconDir.appendingPathComponent("dark-variant")
let docIconDir = assetsRoot.appendingPathComponent("VVDocument.imageset")
let docLadderDir = docIconDir.appendingPathComponent("ladder")
let docLadderDarkDir = docIconDir.appendingPathComponent("ladder-dark")
let designDir = repoRoot.appendingPathComponent("docs/design")

let fm = FileManager.default
for dir in [appIconDir, appIconDarkDir, docIconDir, docLadderDir, docLadderDarkDir] {
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
}

// MARK: - Colour helpers

func hex(_ h: UInt32, alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((h >> 16) & 0xFF) / 255
    let g = CGFloat((h >> 8) & 0xFF) / 255
    let b = CGFloat(h & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: alpha)
}

enum Palette {
    static let plateLightTop: UInt32 = 0xFBFBFC
    static let plateLightBottom: UInt32 = 0xDEDEE2
    static let plateDarkTop: UInt32 = 0x2C2C2E
    static let plateDarkBottom: UInt32 = 0x1C1C1E
    static let plateFlatLight: UInt32 = 0xE7E7EA
    static let plateFlatDark: UInt32 = 0x3A3A3C

    static let screenGradTop: UInt32 = 0x232328
    static let screenGradBottom: UInt32 = 0x111114
    static let screenSolid: UInt32 = 0x191A1D

    static let pepperGradTop: UInt32 = 0xE4523E
    static let pepperGradBottom: UInt32 = 0xA82419
    static let pepperSolid: UInt32 = 0xD0392A

    static let stem: UInt32 = 0x3E7A3A
    static let stand: UInt32 = 0xC6C6CB

    static let pageLightTop: UInt32 = 0xFFFFFF
    static let pageLightBottom: UInt32 = 0xF2F2F4
    static let pageDarkTop: UInt32 = 0x323236
    static let pageDarkBottom: UInt32 = 0x242428
    static let pageFlatLight: UInt32 = 0xF4F4F6
    static let pageFlatDark: UInt32 = 0x2E2E32

    static let foldLight: UInt32 = 0xE4E4E8
    static let foldDark: UInt32 = 0x3F3F44
    static let linesLight: UInt32 = 0xDCDCE0
    static let linesDark: UInt32 = 0x48484C
    static let vvTextLight: UInt32 = 0x8E8E93
    static let vvTextDark: UInt32 = 0xAEAEB2
}

// MARK: - Geometry helpers

/// CSS-style fractional frame: (x, y, w, h) as fractions of `rect`, measured
/// with y growing downward from the top (matching the design's own markup),
/// converted into CoreGraphics' bottom-left-origin space.
typealias Frac = (CGFloat, CGFloat, CGFloat, CGFloat)

func frame(_ f: Frac, in rect: CGRect) -> CGRect {
    let (fx, fy, fw, fh) = f
    let x = rect.minX + fx * rect.width
    let y = rect.minY + (1 - fy - fh) * rect.height
    return CGRect(x: x, y: y, width: fw * rect.width, height: fh * rect.height)
}

/// Builds a CSS `border-radius`-style path with independent per-corner
/// elliptical radii (given as fractions of the box width/height), including
/// the CSS overlap-scaling rule so adjacent radii never exceed an edge.
func blobPath(
    rect: CGRect,
    tl: (CGFloat, CGFloat), tr: (CGFloat, CGFloat),
    br: (CGFloat, CGFloat), bl: (CGFloat, CGFloat)
) -> CGPath {
    let w = rect.width, h = rect.height
    var tlrx = tl.0 * w, tlry = tl.1 * h
    var trrx = tr.0 * w, trry = tr.1 * h
    var brrx = br.0 * w, brry = br.1 * h
    var blrx = bl.0 * w, blry = bl.1 * h

    let f = min(
        1,
        w / max(tlrx + trrx, 0.0001),
        w / max(blrx + brrx, 0.0001),
        h / max(tlry + blry, 0.0001),
        h / max(trry + brry, 0.0001)
    )
    tlrx *= f; tlry *= f; trrx *= f; trry *= f; brrx *= f; brry *= f; blrx *= f; blry *= f

    let kappa: CGFloat = 0.5522847
    func pt(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + lx, y: rect.minY + (h - ly))
    }

    let path = CGMutablePath()
    path.move(to: pt(tlrx, 0))
    path.addLine(to: pt(w - trrx, 0))
    path.addCurve(to: pt(w, trry), control1: pt(w - trrx + kappa * trrx, 0), control2: pt(w, trry - kappa * trry))
    path.addLine(to: pt(w, h - brry))
    path.addCurve(to: pt(w - brrx, h), control1: pt(w, h - brry + kappa * brry), control2: pt(w - brrx + kappa * brrx, h))
    path.addLine(to: pt(blrx, h))
    path.addCurve(to: pt(0, h - blry), control1: pt(blrx - kappa * blrx, h), control2: pt(0, h - blry + kappa * blry))
    path.addLine(to: pt(0, tlry))
    path.addCurve(to: pt(tlrx, 0), control1: pt(0, tlry - kappa * tlry), control2: pt(tlrx - kappa * tlrx, 0))
    path.closeSubpath()
    return path
}

/// Fills `path` rotated by `degrees` (CSS/clockwise-positive convention)
/// about its own rect's centre.
func fillRotated(_ ctx: CGContext, path: CGPath, center: CGPoint, degrees: CGFloat, color: CGColor, shadow: (CGSize, CGFloat, CGColor)? = nil) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: -degrees * .pi / 180)
    ctx.translateBy(x: -center.x, y: -center.y)
    if let (offset, blur, shadowColor) = shadow {
        ctx.setShadow(offset: offset, blur: blur, color: shadowColor)
    }
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

func fillGradient(_ ctx: CGContext, path: CGPath, rect: CGRect, top: UInt32, bottom: UInt32) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let colors = [hex(top), hex(bottom)] as CFArray
    let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

func fillGradientRotated(_ ctx: CGContext, path: CGPath, rect: CGRect, center: CGPoint, degrees: CGFloat, top: UInt32, bottom: UInt32, shadow: (CGSize, CGFloat, CGColor)? = nil) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: -degrees * .pi / 180)
    ctx.translateBy(x: -center.x, y: -center.y)
    if let (offset, blur, shadowColor) = shadow {
        ctx.saveGState()
        ctx.setShadow(offset: offset, blur: blur, color: shadowColor)
        ctx.addPath(path)
        ctx.setFillColor(hex(top))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(path)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let colors = [hex(top), hex(bottom)] as CFArray
    let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

// MARK: - The mark: legibility ladder

struct MarkTier {
    var screenFrame: Frac
    var screenRadiusFrac: CGFloat
    var screenGradient: Bool
    var pepperFrame: Frac
    var pepperRotation: CGFloat
    var pepperCorners: (tl: (CGFloat, CGFloat), tr: (CGFloat, CGFloat), br: (CGFloat, CGFloat), bl: (CGFloat, CGFloat))
    var pepperGradient: Bool
    var pepperShadow: Bool
    var hasStem: Bool
    var stemFrame: Frac
    var stemRotation: CGFloat
    var hasStand: Bool
    var standFrame: Frac
    var standRadiusFrac: CGFloat
    var hasHighlight: Bool
    var plateCornerFrac: CGFloat
    var plateGradient: Bool
}

enum Tier {
    case large, medium, small

    static func forSize(_ s: CGFloat) -> Tier {
        if s >= 128 { return .large }
        if s >= 32 { return .medium }
        return .small
    }
}

let mediumSmallCorners: (tl: (CGFloat, CGFloat), tr: (CGFloat, CGFloat), br: (CGFloat, CGFloat), bl: (CGFloat, CGFloat)) =
    (tl: (0.62, 0.38), tr: (0.46, 0.38), br: (0.54, 0.72), bl: (0.50, 0.72))

let largeTier = MarkTier(
    screenFrame: (0.1477, 0.2159, 0.7045, 0.4886),
    screenRadiusFrac: 0.0625,
    screenGradient: true,
    pepperFrame: (0.4318, 0.3182, 0.2273, 0.3636),
    pepperRotation: 16,
    pepperCorners: (tl: (0.56, 0.30), tr: (0.50, 0.30), br: (0.46, 0.82), bl: (0.44, 0.82)),
    pepperGradient: true,
    pepperShadow: true,
    hasStem: true,
    stemFrame: (0.4545, 0.2955, 0.1591, 0.0455),
    stemRotation: -24,
    hasStand: true,
    standFrame: (0.3409, 0.75, 0.3182, 0.0511),
    standRadiusFrac: 0.0284,
    hasHighlight: true,
    plateCornerFrac: 0.227,
    plateGradient: true
)

let mediumTier = MarkTier(
    screenFrame: (0.1458, 0.2292, 0.7083, 0.5),
    screenRadiusFrac: 0.0625,
    screenGradient: false,
    pepperFrame: (0.3958, 0.3125, 0.3125, 0.4167),
    pepperRotation: 16,
    pepperCorners: mediumSmallCorners,
    pepperGradient: false,
    pepperShadow: false,
    hasStem: true,
    stemFrame: (0.4792, 0.25, 0.2292, 0.0625),
    stemRotation: -26,
    hasStand: false,
    standFrame: (0, 0, 0, 0),
    standRadiusFrac: 0,
    hasHighlight: true,
    plateCornerFrac: 0.227,
    plateGradient: true
)

let smallTier = MarkTier(
    screenFrame: (0.09375, 0.1875, 0.8125, 0.625),
    screenRadiusFrac: 0.09375,
    screenGradient: false,
    pepperFrame: (0.375, 0.25, 0.40625, 0.5625),
    pepperRotation: 14,
    pepperCorners: mediumSmallCorners,
    pepperGradient: false,
    pepperShadow: false,
    hasStem: false,
    stemFrame: (0, 0, 0, 0),
    stemRotation: 0,
    hasStand: false,
    standFrame: (0, 0, 0, 0),
    standRadiusFrac: 0,
    hasHighlight: false,
    plateCornerFrac: 0.25,
    plateGradient: false
)

func tierSpec(_ t: Tier) -> MarkTier {
    switch t {
    case .large: return largeTier
    case .medium: return mediumTier
    case .small: return smallTier
    }
}

/// Draws the display + chili pepper mark into `plateRect`, choosing the
/// legibility tier from `plateRect`'s own pixel size (so the same routine
/// can render the standalone app icon or the small corner badge on the
/// document icon and get correctly-simplified artwork either way).
func drawMark(_ ctx: CGContext, plateRect: CGRect, dark: Bool, includePlate: Bool) {
    let tier = tierSpec(Tier.forSize(min(plateRect.width, plateRect.height)))

    if includePlate {
        let plateRadius = tier.plateCornerFrac * min(plateRect.width, plateRect.height)
        let platePath = CGPath(roundedRect: plateRect, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)
        if tier.plateGradient {
            fillGradient(ctx, path: platePath, rect: plateRect,
                         top: dark ? Palette.plateDarkTop : Palette.plateLightTop,
                         bottom: dark ? Palette.plateDarkBottom : Palette.plateLightBottom)
        } else {
            ctx.addPath(platePath)
            ctx.setFillColor(hex(dark ? Palette.plateFlatDark : Palette.plateFlatLight))
            ctx.fillPath()
        }
    }

    // Screen
    let screenRect = frame(tier.screenFrame, in: plateRect)
    let screenRadius = tier.screenRadiusFrac * min(plateRect.width, plateRect.height)
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil)
    if tier.screenGradient {
        fillGradient(ctx, path: screenPath, rect: screenRect, top: Palette.screenGradTop, bottom: Palette.screenGradBottom)
    } else {
        ctx.addPath(screenPath)
        ctx.setFillColor(hex(Palette.screenSolid))
        ctx.fillPath()
    }
    if tier.hasHighlight {
        ctx.addPath(screenPath)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.setLineWidth(max(1, screenRect.height * 0.02))
        ctx.strokePath()
    }

    // Stand (below the screen, large tier only)
    if includePlate && tier.hasStand {
        let standRect = frame(tier.standFrame, in: plateRect)
        let standRadius = tier.standRadiusFrac * min(plateRect.width, plateRect.height)
        let standPath = CGPath(roundedRect: standRect, cornerWidth: standRadius, cornerHeight: standRadius, transform: nil)
        ctx.addPath(standPath)
        ctx.setFillColor(hex(Palette.stand))
        ctx.fillPath()
    }

    // Stem (drawn under the pepper)
    if tier.hasStem {
        let stemRect = frame(tier.stemFrame, in: plateRect)
        let stemPath = CGPath(roundedRect: stemRect, cornerWidth: stemRect.height / 2, cornerHeight: stemRect.height / 2, transform: nil)
        fillRotated(ctx, path: stemPath, center: CGPoint(x: stemRect.midX, y: stemRect.midY), degrees: tier.stemRotation, color: hex(Palette.stem))
    }

    // Pepper
    let pepperRect = frame(tier.pepperFrame, in: plateRect)
    let pepperPath = blobPath(rect: pepperRect, tl: tier.pepperCorners.tl, tr: tier.pepperCorners.tr, br: tier.pepperCorners.br, bl: tier.pepperCorners.bl)
    let pepperCenter = CGPoint(x: pepperRect.midX, y: pepperRect.midY)
    let shadow: (CGSize, CGFloat, CGColor)? = tier.pepperShadow
        ? (CGSize(width: 0, height: -pepperRect.height * 0.08), pepperRect.height * 0.18, CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        : nil
    if tier.pepperGradient {
        fillGradientRotated(ctx, path: pepperPath, rect: pepperRect, center: pepperCenter, degrees: tier.pepperRotation, top: Palette.pepperGradTop, bottom: Palette.pepperGradBottom, shadow: shadow)
    } else {
        fillRotated(ctx, path: pepperPath, center: pepperCenter, degrees: tier.pepperRotation, color: hex(Palette.pepperSolid), shadow: shadow)
    }
}

// MARK: - Text

func drawText(_ ctx: CGContext, _ text: String, at point: CGPoint, fontSize: CGFloat, color: CGColor) {
    let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
    let attrString = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attrString)
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = point
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - App icon

func drawAppIcon(_ ctx: CGContext, size: CGFloat, dark: Bool) {
    let pad = size * 0.045
    let plateRect = CGRect(x: pad, y: pad, width: size - 2 * pad, height: size - 2 * pad)
    drawMark(ctx, plateRect: plateRect, dark: dark, includePlate: true)
}

// MARK: - Document icon

func drawDocumentIcon(_ ctx: CGContext, size: CGFloat, dark: Bool) {
    let pad = size * 0.05

    if size <= 16 {
        // Page and badge merge: a single flat rounded page with the dark
        // screen + red pepper drawn straight onto it -- no fold, no VV,
        // no separate badge chrome.
        let pageRect = CGRect(x: pad, y: pad, width: size - 2 * pad, height: size - 2 * pad)
        let radius = pageRect.width * 0.18
        let pagePath = CGPath(roundedRect: pageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(pagePath)
        ctx.setFillColor(hex(dark ? Palette.pageFlatDark : Palette.pageFlatLight))
        ctx.fillPath()
        drawMark(ctx, plateRect: pageRect, dark: dark, includePlate: false)
        return
    }

    let availHeight = size - 2 * pad
    let pageHeight = availHeight
    let pageWidth = pageHeight * (100.0 / 126.0)
    let pageRect = CGRect(x: (size - pageWidth) / 2, y: pad, width: pageWidth, height: pageHeight)
    let pageRadius = pageWidth * 0.08

    let pagePath = CGPath(roundedRect: pageRect, cornerWidth: pageRadius, cornerHeight: pageRadius, transform: nil)
    fillGradient(ctx, path: pagePath, rect: pageRect,
                 top: dark ? Palette.pageDarkTop : Palette.pageLightTop,
                 bottom: dark ? Palette.pageDarkBottom : Palette.pageLightBottom)

    // Folded corner (top-right)
    let foldSize = pageWidth * 0.26
    let foldPath = CGMutablePath()
    func foldPt(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
        CGPoint(x: pageRect.minX + lx, y: pageRect.minY + (pageRect.height - ly))
    }
    foldPath.move(to: foldPt(pageWidth - foldSize, 0))
    foldPath.addLine(to: foldPt(pageWidth, foldSize))
    foldPath.addLine(to: foldPt(pageWidth, 0))
    foldPath.closeSubpath()
    ctx.addPath(foldPath)
    ctx.setFillColor(hex(dark ? Palette.foldDark : Palette.foldLight))
    ctx.fillPath()

    // Placeholder text lines (large sizes only -- there is room to read them)
    if size >= 128 {
        let lineColor = hex(dark ? Palette.linesDark : Palette.linesLight)
        let widths: [CGFloat] = [0.52, 0.66, 0.44]
        var ly: CGFloat = 0.26
        for w in widths {
            let lineRect = frame((0.12, ly, w, 0.024), in: pageRect)
            let path = CGPath(roundedRect: lineRect, cornerWidth: lineRect.height / 2, cornerHeight: lineRect.height / 2, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(lineColor)
            ctx.fillPath()
            ly += 0.09
        }
    }

    // "VV" label (illegible below 32pt, so only shown from 64px up)
    if size >= 64 {
        let fontSize = pageWidth * 0.13
        let textOrigin = CGPoint(x: pageRect.minX + pageWidth * 0.11, y: pageRect.minY + pageHeight * 0.08)
        drawText(ctx, "VV", at: textOrigin, fontSize: fontSize, color: hex(dark ? Palette.vvTextDark : Palette.vvTextLight))
    }

    // App-icon badge: 40% of page width, trailing-bottom, overhanging 6%
    // of the badge size on both edges.
    let badgeSize = pageWidth * 0.40
    let overhang = badgeSize * 0.06
    let badgeRect = CGRect(x: pageRect.maxX + overhang - badgeSize, y: pageRect.minY - overhang, width: badgeSize, height: badgeSize)
    drawMark(ctx, plateRect: badgeRect, dark: dark, includePlate: true)
}

// MARK: - Rendering & PNG output

func makeContext(width: Int, height: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func renderAppIcon(pixels: Int, dark: Bool) -> CGImage {
    let ctx = makeContext(width: pixels, height: pixels)
    drawAppIcon(ctx, size: CGFloat(pixels), dark: dark)
    return ctx.makeImage()!
}

func renderDocumentIcon(pixels: Int, dark: Bool) -> CGImage {
    let ctx = makeContext(width: pixels, height: pixels)
    drawDocumentIcon(ctx, size: CGFloat(pixels), dark: dark)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fatalError("Could not write PNG at \(url.path)")
    }
}

// MARK: - Asset catalog sizes: (pixels, size label, scale label)

let catalogSizes: [(pixels: Int, sizeLabel: String, scale: String)] = [
    (16, "16x16", "1x"), (32, "16x16", "2x"),
    (32, "32x32", "1x"), (64, "32x32", "2x"),
    (128, "128x128", "1x"), (256, "128x128", "2x"),
    (256, "256x256", "1x"), (512, "256x256", "2x"),
    (512, "512x512", "1x"), (1024, "512x512", "2x"),
]

func iconFilename(prefix: String, sizeLabel: String, scale: String) -> String {
    scale == "1x" ? "\(prefix)_\(sizeLabel).png" : "\(prefix)_\(sizeLabel)@2x.png"
}

// MARK: - Generate AppIcon.appiconset

print("Rendering AppIcon.appiconset ...")
for entry in catalogSizes {
    let filename = iconFilename(prefix: "icon", sizeLabel: entry.sizeLabel, scale: entry.scale)
    writePNG(renderAppIcon(pixels: entry.pixels, dark: false), to: appIconDir.appendingPathComponent(filename))
    writePNG(renderAppIcon(pixels: entry.pixels, dark: true), to: appIconDarkDir.appendingPathComponent(filename))
}

let appIconContentsImages = catalogSizes.map { entry -> String in
    let filename = iconFilename(prefix: "icon", sizeLabel: entry.sizeLabel, scale: entry.scale)
    return "    { \"filename\" : \"\(filename)\", \"idiom\" : \"mac\", \"scale\" : \"\(entry.scale)\", \"size\" : \"\(entry.sizeLabel)\" }"
}.joined(separator: ",\n")

let appIconContentsJSON = """
{
  "images" : [
\(appIconContentsImages)
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! appIconContentsJSON.write(to: appIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// MARK: - Generate VVDocument.imageset

print("Rendering VVDocument.imageset ...")

// Canonical 1x/2x image actually referenced by Contents.json (light + a
// proper dark "luminosity" appearance variant, which imagesets -- unlike
// appiconsets -- do support).
writePNG(renderDocumentIcon(pixels: 512, dark: false), to: docIconDir.appendingPathComponent("VVDocument.png"))
writePNG(renderDocumentIcon(pixels: 1024, dark: false), to: docIconDir.appendingPathComponent("VVDocument@2x.png"))
writePNG(renderDocumentIcon(pixels: 512, dark: true), to: docIconDir.appendingPathComponent("VVDocument_dark.png"))
writePNG(renderDocumentIcon(pixels: 1024, dark: true), to: docIconDir.appendingPathComponent("VVDocument_dark@2x.png"))

let docContentsJSON = """
{
  "images" : [
    { "filename" : "VVDocument.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "VVDocument@2x.png", "idiom" : "mac", "scale" : "2x" },
    { "filename" : "VVDocument_dark.png", "idiom" : "mac", "scale" : "1x", "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ] },
    { "filename" : "VVDocument_dark@2x.png", "idiom" : "mac", "scale" : "2x", "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ] }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! docContentsJSON.write(to: docIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// Full 16/32/128/256/512 @1x/2x legibility-ladder renders. actool's
// .imageset schema only supports one image per (idiom, scale) pair, so
// these can't all be wired into Contents.json alongside the canonical
// image above; they're kept as loose, clearly-named files in a nested
// subfolder (which actool does not scan for "unassigned children", unlike
// files placed directly inside the .imageset) so the full ladder ships
// alongside the compiled asset without producing catalog warnings.
for entry in catalogSizes {
    let filename = iconFilename(prefix: "vv", sizeLabel: entry.sizeLabel, scale: entry.scale)
    writePNG(renderDocumentIcon(pixels: entry.pixels, dark: false), to: docLadderDir.appendingPathComponent(filename))
    writePNG(renderDocumentIcon(pixels: entry.pixels, dark: true), to: docLadderDarkDir.appendingPathComponent(filename))
}

// MARK: - Contact sheet

print("Rendering docs/design/icon-ladder.png ...")

func drawLabel(_ ctx: CGContext, _ text: String, centerX: CGFloat, top: CGFloat, color: CGColor) {
    let fontSize: CGFloat = 13
    let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
    let attrString = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attrString)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: centerX - bounds.width / 2, y: top)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func makeContactSheet() {
    let appSizes = [176, 128, 48, 32, 16]
    let docSizes = [128, 48, 32, 16]
    let gap: CGFloat = 20
    let sectionGap: CGFloat = 56
    let labelHeight: CGFloat = 20
    let rowMax: CGFloat = 176
    let outerPad: CGFloat = 32
    let bgPad: CGFloat = 24

    let appRowWidth = CGFloat(appSizes.reduce(0, +)) + CGFloat(appSizes.count - 1) * gap
    let docRowWidth = CGFloat(docSizes.reduce(0, +)) + CGFloat(docSizes.count - 1) * gap
    let bgWidth = bgPad * 2 + appRowWidth + sectionGap + docRowWidth
    let bgHeight = bgPad * 2 + labelHeight + rowMax
    let bgGap: CGFloat = 28

    let width = outerPad * 2 + bgWidth
    let height = outerPad * 2 + bgHeight * 2 + bgGap

    let ctx = makeContext(width: Int(width), height: Int(height))
    // Outer canvas
    ctx.setFillColor(hex(0xF0F0F2))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    func renderBackground(originY: CGFloat, dark: Bool) {
        let bgRect = CGRect(x: outerPad, y: originY, width: bgWidth, height: bgHeight)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(dark ? hex(0x1C1C1E) : hex(0xFFFFFF))
        ctx.fillPath()

        let labelColor = dark ? hex(0xAEAEB2) : hex(0x6E6E73)
        var x = bgRect.minX + bgPad
        let iconBottom = bgRect.minY + bgPad
        // Icons are rendered at their true, native pixel size (no
        // upsampling at render time) so the contact sheet honestly shows
        // what each size looks like; the whole sheet is scaled up with
        // nearest-neighbour interpolation afterwards purely so it's
        // inspectable, without smoothing away real aliasing/legibility.
        for s in appSizes {
            let img = renderAppIcon(pixels: s, dark: dark)
            let rect = CGRect(x: x, y: iconBottom + (rowMax - CGFloat(s)), width: CGFloat(s), height: CGFloat(s))
            ctx.interpolationQuality = .none
            ctx.draw(img, in: rect)
            drawLabel(ctx, "\(s)", centerX: x + CGFloat(s) / 2, top: iconBottom + rowMax + 4, color: labelColor)
            x += CGFloat(s) + gap
        }
        x += sectionGap - gap
        for s in docSizes {
            let img = renderDocumentIcon(pixels: s, dark: dark)
            let rect = CGRect(x: x, y: iconBottom + (rowMax - CGFloat(s)), width: CGFloat(s), height: CGFloat(s))
            ctx.interpolationQuality = .none
            ctx.draw(img, in: rect)
            drawLabel(ctx, "\(s)", centerX: x + CGFloat(s) / 2, top: iconBottom + rowMax + 4, color: labelColor)
            x += CGFloat(s) + gap
        }
    }

    renderBackground(originY: outerPad, dark: false)
    renderBackground(originY: outerPad + bgHeight + bgGap, dark: true)

    guard let sheetImage = ctx.makeImage() else { fatalError("Could not render contact sheet") }

    // Upscale the finished sheet (nearest-neighbour) so small icons are
    // easy to inspect without lying about their true pixel fidelity.
    let scale = 3
    let upCtx = makeContext(width: Int(width) * scale, height: Int(height) * scale)
    upCtx.interpolationQuality = .none
    upCtx.draw(sheetImage, in: CGRect(x: 0, y: 0, width: width * CGFloat(scale), height: height * CGFloat(scale)))
    guard let finalImage = upCtx.makeImage() else { fatalError("Could not upscale contact sheet") }
    writePNG(finalImage, to: designDir.appendingPathComponent("icon-ladder.png"))
}

makeContactSheet()

print("Done.")
