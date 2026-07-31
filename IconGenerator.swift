import AppKit
import CoreImage

// Draws the two app icons in a glassmorphism style: a vivid colour mesh under a
// frosted-glass glyph that refracts the blurred background, with a specular
// highlight, an inner shadow and a soft halo.
//   OFF → indigo / violet / magenta mesh, moon glyph  (sleep allowed)
//   ON  → teal / green / cyan mesh,       eye glyph    (Mac kept awake)
// Usage: icongen <output-dir>  →  icon_off_1024.png, icon_on_1024.png

let S: CGFloat = 1024
let INSET: CGFloat = 88
let CS = CGColorSpace(name: CGColorSpace.sRGB)!
let ciCtx = CIContext()
let fullRect = CGRect(x: 0, y: 0, width: S, height: S)

func nsc(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func w(_ a: Double) -> NSColor { nsc(1, 1, 1, a) }
func k(_ a: Double) -> NSColor { nsc(0, 0, 0, a) }

struct Palette {
    let base: [NSColor]                        // gradient top → bottom
    let blobs: [(NSColor, CGPoint, CGFloat)]   // colour, unit centre, unit radius
    let glyph: String
}

let offPalette = Palette(
    base: [nsc(0.28, 0.22, 0.62), nsc(0.07, 0.06, 0.26)],
    blobs: [
        (nsc(0.42, 0.35, 1.00, 0.95), CGPoint(x: 0.22, y: 0.78), 0.62),
        (nsc(0.95, 0.32, 0.85, 0.85), CGPoint(x: 0.80, y: 0.26), 0.58),
        (nsc(0.25, 0.75, 1.00, 0.70), CGPoint(x: 0.80, y: 0.84), 0.44),
    ],
    glyph: "moon.zzz.fill")

let onPalette = Palette(
    base: [nsc(0.06, 0.52, 0.46), nsc(0.02, 0.20, 0.32)],
    blobs: [
        (nsc(0.20, 1.00, 0.62, 0.95), CGPoint(x: 0.24, y: 0.26), 0.60),
        (nsc(0.10, 0.92, 0.95, 0.90), CGPoint(x: 0.80, y: 0.78), 0.58),
        (nsc(0.70, 1.00, 0.45, 0.65), CGPoint(x: 0.78, y: 0.20), 0.44),
    ],
    glyph: "eye.fill")

// MARK: - drawing primitives

func render(_ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    body(g.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func linear(_ ctx: CGContext, _ colors: [NSColor], from a: CGPoint, to b: CGPoint) {
    let g = CGGradient(colorsSpace: CS, colors: colors.map { $0.cgColor } as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: a, end: b, options: [])
}

func blob(_ ctx: CGContext, _ c: NSColor, _ center: CGPoint, _ radius: CGFloat) {
    let g = CGGradient(colorsSpace: CS,
                       colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

func strokeGradient(_ ctx: CGContext, _ path: CGPath, _ width: CGFloat,
                    _ colors: [NSColor], _ rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(width); ctx.replacePathWithStrokedPath(); ctx.clip()
    linear(ctx, colors, from: CGPoint(x: rect.minX, y: rect.maxY),
           to: CGPoint(x: rect.maxX, y: rect.minY))
    ctx.restoreGState()
}

func squircle(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237,
           cornerHeight: rect.width * 0.2237, transform: nil)
}

// Fine film grain, so the glass reads as a material rather than flat colour.
let noise: CGImage = {
    let n = 512
    var bytes = [UInt8](repeating: 0, count: n * n * 4)
    for i in 0..<(n * n) {
        let v = UInt8.random(in: 110...255)
        bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v
        bytes[i * 4 + 3] = UInt8.random(in: 0...22)
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: n * 4, space: CS,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}()

func grain(_ ctx: CGContext, _ alpha: CGFloat) {
    ctx.saveGState(); ctx.setAlpha(alpha)
    ctx.draw(noise, in: fullRect)
    ctx.restoreGState()
}

func background(_ p: Palette) -> CGImage {
    render { ctx in
        linear(ctx, p.base, from: CGPoint(x: 0, y: S), to: CGPoint(x: 0, y: 0))
        for (c, u, r) in p.blobs {
            blob(ctx, c, CGPoint(x: u.x * S, y: u.y * S), r * S)
        }
    }.cgImage!
}

func blurImage(_ img: CGImage, _ radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: img)
    let out = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
        .cropped(to: ci.extent)
    return ciCtx.createCGImage(out, from: ci.extent)!
}

// MARK: - glyph helpers

func symbolImage(_ name: String, _ box: CGRect, _ color: NSColor) -> (NSImage, CGRect)? {
    let cfg = NSImage.SymbolConfiguration(pointSize: box.height, weight: .semibold)
    guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let sz = s.size
    let scale = min(box.width / sz.width, box.height / sz.height)
    let sw = sz.width * scale, sh = sz.height * scale
    let tinted = NSImage(size: NSSize(width: sw, height: sh), flipped: false) { r in
        s.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
    }
    return (tinted, CGRect(x: box.midX - sw / 2, y: box.midY - sh / 2, width: sw, height: sh))
}

func drawSymbol(_ name: String, _ box: CGRect, _ color: NSColor, glow: CGFloat = 0) {
    guard let (img, rect) = symbolImage(name, box, color) else { return }
    if glow > 0 {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = w(glow); sh.shadowBlurRadius = 34; sh.shadowOffset = .zero
        sh.set()
        img.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
    img.draw(in: rect)
}

func glyphMask(_ name: String, _ box: CGRect) -> CGImage? {
    guard let (img, rect) = symbolImage(name, box, .white) else { return nil }
    let canvas = NSImage(size: NSSize(width: box.width, height: box.height), flipped: false) { _ in
        img.draw(in: CGRect(x: rect.minX - box.minX, y: rect.minY - box.minY,
                            width: rect.width, height: rect.height))
        return true
    }
    var pr = CGRect(origin: .zero, size: canvas.size)
    return canvas.cgImage(forProposedRect: &pr, context: nil, hints: nil)
}

// MARK: - the icon

func makeIcon(_ p: Palette) -> NSBitmapImageRep {
    let bg = background(p)
    let soft = blurImage(bg, 46)
    let rect = CGRect(x: INSET, y: INSET, width: S - 2 * INSET, height: S - 2 * INSET)
    let outer = squircle(rect)
    let box = CGRect(x: rect.midX - rect.width * 0.26, y: rect.midY - rect.height * 0.26,
                     width: rect.width * 0.52, height: rect.height * 0.52)

    return render { ctx in
        // Drop shadow + opaque base so the squircle reads on any wallpaper.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: k(0.30).cgColor)
        ctx.addPath(outer); ctx.setFillColor(p.base[1].cgColor); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(outer); ctx.clip()

        // Colour mesh + grain + top sheen.
        ctx.draw(bg, in: fullRect)
        grain(ctx, 0.4)
        linear(ctx, [w(0.16), w(0.0)], from: CGPoint(x: 0, y: rect.maxY),
               to: CGPoint(x: 0, y: rect.midY))

        // Soft halo behind the glass shape (no hard outline).
        drawSymbol(p.glyph, box, w(0.30), glow: 0.55)

        // The glyph itself is the glass: refracted background, frost, specular, inner shadow.
        if let mask = glyphMask(p.glyph, box) {
            ctx.saveGState()
            ctx.clip(to: box, mask: mask)
            ctx.draw(soft, in: fullRect)
            ctx.setFillColor(w(0.46).cgColor); ctx.fill(box)
            linear(ctx, [w(0.72), w(0.04)], from: CGPoint(x: 0, y: box.maxY),
                   to: CGPoint(x: 0, y: box.minY))
            linear(ctx, [k(0.12), k(0.0)], from: CGPoint(x: 0, y: box.minY),
                   to: CGPoint(x: 0, y: box.minY + box.height * 0.28))
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // Rim light on the squircle edge.
        strokeGradient(ctx, outer, 3, [w(0.45), w(0.05)], rect)
    }
}

// MARK: - output

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func save(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent(name))
}

save(makeIcon(offPalette), "icon_off_1024.png")
save(makeIcon(onPalette), "icon_on_1024.png")
print("icons written to \(outDir.path)")
