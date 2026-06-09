#!/usr/bin/env swift
//
//  make-appicon.swift — renders the Rawloom app icon with CoreGraphics.
//
//  Concept: "Editorial Aperture". A camera iris drawn flat and matte in an editorial,
//  letterpress idiom — warm espresso "ink" ground, cream "paper" blades carved by crisp
//  seams, a single earthy accent at the open centre. Palette/feel borrowed from InkType
//  (inktype.lfkdsk.org): no gloss, no glow, no gradients — just precise warm shapes.
//
//  Usage:
//    swift scripts/make-appicon.swift preview <dir>          # 3 concept variants @512 + contact sheet
//    swift scripts/make-appicon.swift build <AppIcon.appiconset-dir> [variant]
//                                                            # full iOS icon set + Contents.json
//
//  Pure CoreGraphics + ImageIO — no external dependencies, runs anywhere macOS does.
//
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - small helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green:    CGFloat((hex >> 8)  & 0xff) / 255,
            blue:     CGFloat( hex        & 0xff) / 255,
            alpha: a)
}

func grad(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    // (hex, alpha, location)
    CGGradient(colorsSpace: sRGB,
               colors: stops.map { col($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

func d2r(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

func makeContext(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - palette / variants

struct Palette {
    let ground: UInt32      // flat icon background ("ink" or "paper")
    let disk: UInt32        // lens/iris fill
    let seam: UInt32        // colour carving the blade seams (usually the ground)
    let center: UInt32      // accent at the open centre
    let ring: UInt32        // thin barrel rule just inside the rim
    let ringAlpha: CGFloat
}

enum Variant: String {
    case ink, paper, clay

    var palette: Palette {
        switch self {
        case .ink:        // recommended — cream iris on warm espresso, clay centre
            return Palette(ground: 0x1A1614, disk: 0xEDE4D3, seam: 0x1A1614,
                           center: 0xD97757, ring: 0x8A7F6F, ringAlpha: 0.30)
        case .paper:      // letterpress — espresso iris on cream paper, terracotta centre
            return Palette(ground: 0xEDE4D3, disk: 0x211C19, seam: 0xEDE4D3,
                           center: 0xC8553D, ring: 0x8A7F6F, ringAlpha: 0.45)
        case .clay:       // bold — cream iris on terracotta, espresso centre
            return Palette(ground: 0xC8553D, disk: 0xEDE4D3, seam: 0xC8553D,
                           center: 0x1A1614, ring: 0xEDE4D3, ringAlpha: 0.30)
        }
    }
}

// MARK: - geometry

/// Regular hexagon, `rot` radians of rotation.
func hexPath(center c: CGPoint, radius rad: CGFloat, rot: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<6 {
        let a = rot + CGFloat(i) * .pi / 3
        let pt = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

// MARK: - the icon

func drawIcon(into ctx: CGContext, size S: CGFloat, variant: Variant) {
    let pal = variant.palette
    let c = CGPoint(x: S / 2, y: S / 2)
    let R = S * 0.400          // lens disk radius
    let a = S * 0.118          // aperture opening (apothem of the hexagon)
    let seamW = S * 0.016      // blade seam thickness
    let L = sqrt(R * R - a * a) // half-length of a blade chord across the disk

    // 1) flat ground — no gradient, no vignette, no glow
    ctx.setFillColor(col(pal.ground))
    ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))

    // 2) the lens — a flat disk
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    ctx.setFillColor(col(pal.disk)); ctx.fillPath()

    // 3) the iris — six blade seams. Each is the outward half of a chord tangent to the
    //    opening circle: it starts at a hexagon vertex and spirals to the rim, all six
    //    leaning the same way (a pinwheel), exactly as a real aperture's blades do.
    let halfEdge = a * tan(.pi / 6)        // hexagon half-edge along the chord
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)); ctx.clip()
    ctx.setStrokeColor(col(pal.seam)); ctx.setLineWidth(seamW); ctx.setLineCap(.round)
    for k in 0..<6 {
        let phi = CGFloat(k) * .pi / 3
        let t = CGPoint(x: c.x + a * cos(phi), y: c.y + a * sin(phi))   // tangent point
        let d = CGPoint(x: -sin(phi), y: cos(phi))                      // chord direction
        ctx.move(to: CGPoint(x: t.x + halfEdge * d.x, y: t.y + halfEdge * d.y))  // hex vertex
        ctx.addLine(to: CGPoint(x: t.x + L * d.x, y: t.y + L * d.y))             // rim
        ctx.strokePath()
    }
    ctx.restoreGState()

    // 4) open centre — a single accent hexagon, aligned exactly to the blade chords,
    //    set off by a hairline ground gap
    let hexR = a / cos(.pi / 6)        // circumradius so the hex edges sit on the chords
    ctx.addPath(hexPath(center: c, radius: hexR, rot: .pi / 6))
    ctx.setStrokeColor(col(pal.seam)); ctx.setLineWidth(seamW * 1.4); ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.addPath(hexPath(center: c, radius: hexR, rot: .pi / 6))
    ctx.setFillColor(col(pal.center)); ctx.fillPath()

    // 5) lens barrel — one thin concentric rule just inside the rim (editorial framing)
    ctx.addArc(center: c, radius: R * 0.90, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setStrokeColor(col(pal.ring, pal.ringAlpha)); ctx.setLineWidth(S * 0.008)
    ctx.strokePath()
}

func renderImage(size: Int, variant: Variant) -> CGImage {
    let ctx = makeContext(size)
    drawIcon(into: ctx, size: CGFloat(size), variant: variant)
    return ctx.makeImage()!
}

/// Optional rounded-corner mask, only for human-facing previews (the real iOS icon is square).
func roundedPreview(size: Int, variant: Variant) -> CGImage {
    let ctx = makeContext(size)
    let S = CGFloat(size)
    let radius = S * 0.2237   // iOS superellipse ≈ 22.37% — close enough with a round-rect
    let rr = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                    cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(rr); ctx.clip()
    drawIcon(into: ctx, size: S, variant: variant)
    return ctx.makeImage()!
}

// MARK: - outputs

func runPreview(_ dir: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let variants: [Variant] = [.ink, .paper, .clay]
    var rounded: [CGImage] = []
    for v in variants {
        let sq = renderImage(size: 512, variant: v)
        let rd = roundedPreview(size: 512, variant: v)
        rounded.append(rd)
        writePNG(sq, to: URL(fileURLWithPath: "\(dir)/icon-\(v.rawValue)-square.png"))
        writePNG(rd, to: URL(fileURLWithPath: "\(dir)/icon-\(v.rawValue)-rounded.png"))
    }
    // contact sheet: three rounded previews side by side on a neutral card
    let pad = 48, tile = 512, gap = 48
    let w = pad * 2 + tile * 3 + gap * 2, h = pad * 2 + tile
    let ctx = makeContext(max(w, h))               // square canvas, draw centred row
    ctx.setFillColor(col(0x4A443D)); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    let y = (ctx.height - tile) / 2
    for (i, img) in rounded.enumerated() {
        let x = pad + i * (tile + gap)
        ctx.draw(img, in: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(tile), height: CGFloat(tile)))
    }
    writePNG(ctx.makeImage()!, to: URL(fileURLWithPath: "\(dir)/contact-sheet.png"))
    print("preview written to \(dir)")
}

func runBuild(_ dir: String, _ variant: Variant) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // (size_pt, scale, idiom) entries for a classic, universally-compatible iOS icon set
    struct Entry { let pt: Double; let scale: Int; let idiom: String }
    let entries: [Entry] = [
        .init(pt: 20, scale: 2, idiom: "iphone"), .init(pt: 20, scale: 3, idiom: "iphone"),
        .init(pt: 29, scale: 2, idiom: "iphone"), .init(pt: 29, scale: 3, idiom: "iphone"),
        .init(pt: 40, scale: 2, idiom: "iphone"), .init(pt: 40, scale: 3, idiom: "iphone"),
        .init(pt: 60, scale: 2, idiom: "iphone"), .init(pt: 60, scale: 3, idiom: "iphone"),
        .init(pt: 20, scale: 1, idiom: "ipad"),   .init(pt: 20, scale: 2, idiom: "ipad"),
        .init(pt: 29, scale: 1, idiom: "ipad"),   .init(pt: 29, scale: 2, idiom: "ipad"),
        .init(pt: 40, scale: 1, idiom: "ipad"),   .init(pt: 40, scale: 2, idiom: "ipad"),
        .init(pt: 76, scale: 1, idiom: "ipad"),   .init(pt: 76, scale: 2, idiom: "ipad"),
        .init(pt: 83.5, scale: 2, idiom: "ipad"),
        .init(pt: 1024, scale: 1, idiom: "ios-marketing"),
    ]

    // render each unique pixel size once, reuse across entries
    var cache: [Int: Bool] = [:]
    func filename(_ px: Int) -> String { "AppIcon-\(px).png" }
    var images: [[String: String]] = []
    for e in entries {
        let px = Int((e.pt * Double(e.scale)).rounded())
        if cache[px] == nil {
            writePNG(renderImage(size: px, variant: variant),
                     to: URL(fileURLWithPath: "\(dir)/\(filename(px))"))
            cache[px] = true
        }
        let ptStr = e.pt == 83.5 ? "83.5" : String(Int(e.pt))
        images.append([
            "idiom": e.idiom,
            "size": "\(ptStr)x\(ptStr)",
            "scale": "\(e.scale)x",
            "filename": filename(px),
        ])
    }

    let contents: [String: Any] = [
        "images": images,
        "info": ["author": "rawloom", "version": 1],
    ]
    let data = try! JSONSerialization.data(withJSONObject: contents,
                                           options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: "\(dir)/Contents.json"))
    print("built \(variant.rawValue) icon set (\(cache.count) sizes) -> \(dir)")
}

// MARK: - entry

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-appicon.swift preview <dir>")
    print("       make-appicon.swift build <AppIcon.appiconset> [warm|spectral|mono]")
    exit(2)
}
switch args[1] {
case "preview": runPreview(args[2])
case "build":   runBuild(args[2], Variant(rawValue: args.count > 3 ? args[3] : "ink") ?? .ink)
default: print("unknown command \(args[1])"); exit(2)
}
