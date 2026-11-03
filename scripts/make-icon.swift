// Draws the app icon and writes scripts/AppIcon.icns.
// Usage: swift scripts/make-icon.swift            (PREVIEW=/path.png also writes a 1024 px preview)
//
// If scripts/AppIcon.svg exists (or ICON_SVG=/path.svg is set) the icon is that
// SVG, drawn by AppKit with the icon-grid shadow (`shadow` in icon-design.json,
// or SHADOW=0.35). A local icon editor writes both
// files. NO_ICNS=1 skips the .icns, for previews. Without an SVG the icon is
// the 8-bit sprite below.
//
// An orange shield with an exclamation mark on a dark navy tile, in the
// PICO-8 palette. The tile follows the macOS icon grid (824 pt on a 1024 pt
// canvas) but is built from an 18 x 18 grid of square "pixels", with stepped
// corners instead of a smooth radius. Every block is snapped to whole device
// pixels at each output size, so edges stay hard rather than blurred.

import AppKit

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// PICO-8 palette.
let palette: [Character: CGColor] = [
    "K": rgb(0x000000),   // outline and the mark
    "O": rgb(0xFFA300),   // shield
    "Y": rgb(0xFFEC27),   // highlight
    "B": rgb(0xAB5236),   // shaded edge
]
let navy = rgb(0x1D2B53)
let navyLight = rgb(0x2A3F78)
let navyDark = rgb(0x111A36)
let star = rgb(0xFFF1E8)
let starBlue = rgb(0x29ADFF)

/// 12 x 15 sprite; "." is transparent. A heater shield: flat top, straight
/// sides, a point at the bottom.
let shield = [
    "KKKKKKKKKKKK",
    "KYYYYOOOOOBK",
    "KYOOOOOOOOBK",
    "KYOOOKKOOOBK",
    "KYOOOKKOOOBK",
    "KYOOOKKOOOBK",
    "KYOOOKKOOOBK",
    "KYOOOOOOOOBK",
    "KOOOOKKOOOBK",
    ".KOOOKKOOBK.",
    ".KOOOOOOOBK.",
    "..KOOOOOBK..",
    "...KOOOBK...",
    "....KOBK....",
    ".....KK.....",
]

let grid = 18                       // tile is 18 x 18 cells
let spriteOrigin = (x: 3, y: 2)     // top-left cell of the sprite
/// Cells removed from each corner, per row from the edge: a stepped radius.
let cornerSteps = [2, 1]
let stars: [(Int, Int, CGColor)] = [(1, 5, star), (16, 3, starBlue), (15, 14, star), (2, 13, starBlue), (16, 9, star)]

func insideTile(_ x: Int, _ y: Int) -> Bool {
    guard x >= 0, y >= 0, x < grid, y < grid else { return false }
    let fromTop = min(y, grid - 1 - y)
    let fromSide = min(x, grid - 1 - x)
    return fromTop >= cornerSteps.count || fromSide >= cornerSteps[fromTop]
}

func spriteCell(_ x: Int, _ y: Int) -> Character? {
    let sx = x - spriteOrigin.x, sy = y - spriteOrigin.y
    guard sy >= 0, sy < shield.count else { return nil }
    let row = Array(shield[sy])
    guard sx >= 0, sx < row.count, row[sx] != "." else { return nil }
    return row[sx]
}

func drawIcon(in ctx: CGContext, size: Int) {
    if let svg { drawSVG(svg, in: ctx, size: size); return }
    ctx.setShouldAntialias(false)
    ctx.interpolationQuality = .none
    let s = CGFloat(size)
    let tile = s * 824 / 1024
    let origin = (s - tile) / 2
    // Cell edges rounded to whole pixels, so blocks never blur.
    func edge(_ i: Int) -> CGFloat { (origin + tile * CGFloat(i) / CGFloat(grid)).rounded() }
    // Grid y runs top to bottom; Core Graphics y runs bottom to top.
    func cell(_ x: Int, _ y: Int, offset: CGFloat = 0) -> CGRect {
        let x0 = edge(x), x1 = edge(x + 1)
        let yTop = s - edge(y), yBottom = s - edge(y + 1)
        return CGRect(x: x0, y: yBottom - offset, width: x1 - x0, height: yTop - yBottom)
    }

    // Hard shadow under the tile: the same stepped shape, nudged down.
    let shadowOffset = max(1, (tile / CGFloat(grid) * 0.35).rounded())
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
    for y in 0..<grid { for x in 0..<grid where insideTile(x, y) { ctx.fill(cell(x, y, offset: shadowOffset)) } }

    for y in 0..<grid {
        for x in 0..<grid where insideTile(x, y) {
            // One-cell bevel: light on the top and left edge, dark on the bottom and right.
            let top = !insideTile(x, y - 1), left = !insideTile(x - 1, y)
            let bottom = !insideTile(x, y + 1), right = !insideTile(x + 1, y)
            var color = navy
            if top || left { color = navyLight }
            if bottom || right { color = navyDark }
            // The shield's own drop shadow: one cell down and right.
            if spriteCell(x - 1, y - 1) != nil, spriteCell(x, y) == nil { color = navyDark }
            ctx.setFillColor(color)
            ctx.fill(cell(x, y))
        }
    }
    for (x, y, c) in stars where insideTile(x, y) && spriteCell(x, y) == nil {
        ctx.setFillColor(c)
        ctx.fill(cell(x, y))
    }
    for y in 0..<grid {
        for x in 0..<grid {
            if let ch = spriteCell(x, y), let c = palette[ch] {
                ctx.setFillColor(c)
                ctx.fill(cell(x, y))
            }
        }
    }
}

// MARK: - SVG design

let scriptsDir = ProcessInfo.processInfo.environment["SCRIPTS_DIR"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let env = ProcessInfo.processInfo.environment
let svgURL = env["ICON_SVG"].map { URL(fileURLWithPath: $0) } ?? scriptsDir.appendingPathComponent("AppIcon.svg")
let svg: NSImage? = FileManager.default.fileExists(atPath: svgURL.path) ? NSImage(contentsOf: svgURL) : nil
/// Settings the SVG itself cannot carry: the tile's drop shadow (0 = none).
let designSettings: [String: Any] = (try? Data(contentsOf: scriptsDir.appendingPathComponent("icon-design.json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
let shadowAlpha = env["SHADOW"].flatMap(Double.init) ?? (designSettings["shadow"] as? Double) ?? 0.35

/// Draws the 1024-unit SVG at `size` px, with the macOS icon-grid shadow under the tile.
func drawSVG(_ image: NSImage, in ctx: CGContext, size: Int) {
    let s = CGFloat(size)
    if shadowAlpha > 0 {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: CGColor(gray: 0, alpha: shadowAlpha))
    }
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    drawIcon(in: gc.cgContext, size: size)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("pwnd-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview = ProcessInfo.processInfo.environment["PREVIEW"] {
    try png(size: 1024).write(to: URL(fileURLWithPath: preview))
    try png(size: 64).write(to: URL(fileURLWithPath: preview.replacingOccurrences(of: ".png", with: "-64.png")))
}

if ProcessInfo.processInfo.environment["NO_ICNS"] == "1" { exit(0) }
let out = scriptsDir.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")
