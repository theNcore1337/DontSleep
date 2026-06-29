import AppKit
import CoreGraphics

// Generates two glass, iOS-style app icons matching the in-app states.
//   OFF → deep indigo, moon glyph   (sleep allowed)
//   ON  → teal/green,  eye glyph     (Mac kept awake)
// The glyphs are rendered as liquid glass: the colourful background refracts
// (zoomed + shifted) through the glyph, with a specular highlight + inner shadow.
// Usage: icongen <output-dir>  →  icon_off_1024.png, icon_on_1024.png

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { rgb(1, 1, 1, a) }

func radialBlob(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
    let g = CGGradient(colorsSpace: cs, colors: [color, color.copy(alpha: 0)!] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

// Just the colour layer (gradient + blobs) — re-used for the glyph's refraction.
func drawColors(_ ctx: CGContext, rect: CGRect,
                top: CGColor, bottom: CGColor, blobA: CGColor, blobB: CGColor) {
    let base = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY), options: [])
    radialBlob(ctx, center: CGPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.78),
               radius: rect.width * 0.55, color: blobA)
    radialBlob(ctx, center: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.24),
               radius: rect.width * 0.55, color: blobB)
}

func drawSheen(_ ctx: CGContext, rect: CGRect) {
    ctx.setFillColor(white(0.06))
    ctx.fill(rect)
    let gloss = CGGradient(colorsSpace: cs, colors: [white(0.22), white(0.0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.midY), options: [])
}

// SF Symbol → white-on-clear CGImage the size of `box` (used as a clip mask).
func glyphMask(_ name: String, box: CGRect) -> CGImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: box.height, weight: .semibold)
    guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let sz = s.size
    let scale = min(box.width / sz.width, box.height / sz.height)
    let w = sz.width * scale, h = sz.height * scale
    let canvas = NSImage(size: NSSize(width: box.width, height: box.height), flipped: false) { _ in
        s.draw(in: CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h))
        NSColor.white.set()
        CGRect(origin: .zero, size: NSSize(width: box.width, height: box.height)).fill(using: .sourceAtop)
        return true
    }
    var pr = CGRect(origin: .zero, size: canvas.size)
    return canvas.cgImage(forProposedRect: &pr, context: nil, hints: nil)
}

// Draws an SF Symbol tinted `color`, aspect-fit centered in `box`.
func drawSymbol(_ name: String, box: CGRect, color: NSColor) {
    let cfg = NSImage.SymbolConfiguration(pointSize: box.height, weight: .semibold)
    guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return }
    let sz = s.size
    let scale = min(box.width / sz.width, box.height / sz.height)
    let w = sz.width * scale, h = sz.height * scale
    let tinted = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
        s.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
}

// Clips `ctx` to the glyph shape (mask is top-down, so flip vertically about box).
func clipGlyph(_ ctx: CGContext, box: CGRect, mask: CGImage) {
    let s = box.minY + box.maxY
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)
    ctx.clip(to: box, mask: mask)
    ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: -s)
}

func drawGlassGlyph(_ ctx: CGContext, _ name: String, box: CGRect, rect: CGRect,
                    top: CGColor, bottom: CGColor, blobA: CGColor, blobB: CGColor) {
    guard let mask = glyphMask(name, box: box) else { return }

    // Glass body, clipped to the glyph.
    ctx.saveGState()
    clipGlyph(ctx, box: box, mask: mask)

    // Bright frosted body so the glyph stays clearly readable.
    let body = CGGradient(colorsSpace: cs, colors: [white(0.82), white(0.52)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: box.maxY),
                           end: CGPoint(x: 0, y: box.minY), options: [])

    // Subtle colour refraction: a single low-alpha, slightly zoomed copy of the
    // background tints the glass (no ghosting).
    ctx.saveGState()
    ctx.setAlpha(0.30)
    ctx.translateBy(x: box.midX + 6, y: box.midY - 6)
    ctx.scaleBy(x: 1.1, y: 1.1)
    ctx.translateBy(x: -box.midX, y: -box.midY)
    drawColors(ctx, rect: rect, top: top, bottom: bottom, blobA: blobA, blobB: blobB)
    ctx.restoreGState()

    // Glossy top highlight.
    let spec = CGGradient(colorsSpace: cs, colors: [white(0.95), white(0.0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(spec, start: CGPoint(x: 0, y: box.maxY),
                           end: CGPoint(x: 0, y: box.midY + box.height * 0.10), options: [])

    // Soft inner shadow at the bottom edge.
    let inner = CGGradient(colorsSpace: cs, colors: [rgb(0, 0, 0, 0.18), rgb(0, 0, 0, 0.0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(inner, start: CGPoint(x: 0, y: box.minY),
                           end: CGPoint(x: 0, y: box.minY + box.height * 0.30), options: [])
    ctx.restoreGState()
}

func makeIcon(glyph: String, top: CGColor, bottom: CGColor,
              blobA: CGColor, blobB: CGColor) -> NSBitmapImageRep {
    let size: CGFloat = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext

    let inset: CGFloat = 88
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: rgb(0, 0, 0, 0.28))
    ctx.addPath(squircle)
    ctx.setFillColor(bottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    drawColors(ctx, rect: rect, top: top, bottom: bottom, blobA: blobA, blobB: blobB)
    drawSheen(ctx, rect: rect)
    let box = CGRect(x: rect.midX - rect.width * 0.25, y: rect.midY - rect.height * 0.25,
                     width: rect.width * 0.50, height: rect.height * 0.50)
    drawGlassGlyph(ctx, glyph, box: box, rect: rect, top: top, bottom: bottom, blobA: blobA, blobB: blobB)
    ctx.restoreGState()

    ctx.addPath(squircle)
    ctx.setStrokeColor(white(0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// OFF — deep indigo / violet, moon (matches the in-app glyph).
let off = makeIcon(glyph: "moon.zzz.fill",
                   top: rgb(0.32, 0.27, 0.62), bottom: rgb(0.09, 0.09, 0.30),
                   blobA: rgb(0.30, 0.45, 1.00, 0.50), blobB: rgb(0.66, 0.40, 1.00, 0.55))
// ON — teal / green, eye.
let on = makeIcon(glyph: "eye.fill",
                  top: rgb(0.08, 0.58, 0.50), bottom: rgb(0.03, 0.26, 0.37),
                  blobA: rgb(0.30, 0.97, 0.95, 0.50), blobB: rgb(0.35, 0.97, 0.55, 0.55))

save(off, outDir.appendingPathComponent("icon_off_1024.png"))
save(on, outDir.appendingPathComponent("icon_on_1024.png"))
print("icons written to \(outDir.path)")
