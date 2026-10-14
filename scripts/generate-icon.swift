import AppKit

// Dual Spark 02: the user-selected reference, recreated as editable pixel geometry.
// Two solid four-point sparks and two opposing stepped arc segments, without arrowheads.
struct Pixel: Hashable { let x: Int; let y: Int }
struct Glyph {
    let grid: Int
    var pixels: Set<Pixel> = []
    mutating func stamp(_ rows: [String], x: Int, y: Int) {
        for (row, text) in rows.enumerated() {
            for (column, character) in text.enumerated() where character == "#" {
                pixels.insert(Pixel(x: x + column, y: y + row))
            }
        }
    }
    mutating func arc(_ points: [(Int, Int)]) { for (x, y) in points { pixels.insert(Pixel(x: x, y: y)) } }
    var ordered: [Pixel] { pixels.sorted { ($0.y, $0.x) < ($1.y, $1.x) } }
}
let spark = ["....#....", "....#....", "...###...", "..#####..", "#########",
             "..#####..", "...###...", "....#....", "....#...."]
let tinySpark = ["..#..", ".###.", "#####", ".###.", "..#.."]
var symbol = Glyph(grid: 24)
symbol.stamp(spark, x: 2, y: 13)
symbol.stamp(spark, x: 13, y: 2)
symbol.arc([(6,10),(6,9),(7,8),(8,7),(9,6),(10,6)])
symbol.arc([(17,13),(17,14),(16,15),(15,16),(14,17),(13,17)])
// Optical 16px redraw keeps all four separate shapes and solid spark centers.
var compact = Glyph(grid: 14)
compact.stamp(tinySpark, x: 1, y: 8)
compact.stamp(tinySpark, x: 8, y: 1)
compact.arc([(3,5),(4,4),(5,3)])
compact.arc([(10,8),(9,9),(8,10)])
// Independent 18pt template; macOS supplies the light/dark/selected tint.
var menu = Glyph(grid: 16)
menu.stamp(tinySpark, x: 2, y: 9)
menu.stamp(tinySpark, x: 9, y: 2)
menu.arc([(3,7),(3,6),(4,5),(5,4),(6,4)])
menu.arc([(12,8),(12,9),(11,10),(10,11),(9,11)])
// The reference rotates the Menu Bar composition: sparks at top-left and bottom-right.
menu.pixels = Set(menu.pixels.map { Pixel(x: menu.grid - 1 - $0.y, y: $0.x) })
var menu24 = symbol
menu24.pixels = Set(symbol.pixels.map { Pixel(x: symbol.grid - 1 - $0.y, y: $0.x) })

let coral = NSColor(srgbRed: 1, green: 90.0 / 255, blue: 54.0 / 255, alpha: 1)
let charcoal = NSColor(srgbRed: 23.0 / 255, green: 25.0 / 255, blue: 29.0 / 255, alpha: 1)
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let appAssets = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let menuAssets = root.appendingPathComponent("Resources/Assets.xcassets/MenuBarIcon.imageset")
let masters = root.appendingPathComponent("Resources/Branding")
let previews = root.appendingPathComponent("build/branding/dual-spark")
for directory in [iconset, appAssets, menuAssets, masters, previews] {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
}

func bitmap(width: Int, height: Int? = nil, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let height = height ?? width
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
          let graphics = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Cannot create icon bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
    draw(graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func drawGlyph(_ glyph: Glyph, _ context: CGContext, x: Int, y: Int, cell: Int, color: NSColor) {
    context.setShouldAntialias(false)
    context.setFillColor(color.cgColor)
    for p in glyph.ordered {
        context.fill(CGRect(x: x + p.x * cell, y: y + (glyph.grid - 1 - p.y) * cell, width: cell, height: cell))
    }
}
func appIcon(size: Int, squareMaster: Bool = false) -> NSBitmapImageRep {
    bitmap(width: size) { context in
        // The existing ICNS/catalog path includes its legacy macOS tile and transparent outer margin.
        // The square master below leaves masking to modern system/Icon Composer workflows.
        let inset = squareMaster ? 0 : max(1, size / 16)
        let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        context.saveGState()
        context.setShouldAntialias(size > 32)
        let outline = CGPath(roundedRect: tile, cornerWidth: CGFloat(size) * 0.19,
                             cornerHeight: CGFloat(size) * 0.19, transform: nil)
        if !squareMaster { context.addPath(outline); context.clip() }
        if size > 64 {
            let colors = [NSColor(srgbRed: 0.20, green: 0.125, blue: 0.125, alpha: 1).cgColor,
                          charcoal.cgColor, NSColor(srgbRed: 0.035, green: 0.039, blue: 0.047, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 0.5, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY),
                                       end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
        } else {
            context.setFillColor(charcoal.cgColor); context.fill(tile)
        }
        let glyph = size == 16 ? compact : symbol
        let cell = size == 16 ? 1 : max(1, size / 32)
        if size > 64 {
            context.saveGState()
            context.setShadow(offset: .zero, blur: CGFloat(cell) * 1.6,
                              color: coral.withAlphaComponent(0.28).cgColor)
            drawGlyph(glyph, context, x: (size - glyph.grid * cell) / 2, y: (size - glyph.grid * cell) / 2,
                      cell: cell, color: coral)
            context.restoreGState()
        }
        // Paint the integer-cell foreground separately to preserve exact opaque coral over the bloom.
        drawGlyph(glyph, context, x: (size - glyph.grid * cell) / 2, y: (size - glyph.grid * cell) / 2,
                  cell: cell, color: coral)
        context.restoreGState()
        if size > 64 && !squareMaster {
            context.setShouldAntialias(true)
            context.addPath(outline)
            context.setStrokeColor(NSColor(srgbRed: 0.44, green: 0.39, blue: 0.39, alpha: 0.48).cgColor)
            context.setLineWidth(max(1, CGFloat(size) / 128)); context.strokePath()
        }
    }
}
func menuIcon(scale: Int, color: NSColor = .black) -> NSBitmapImageRep {
    bitmap(width: 18 * scale) { context in
        drawGlyph(menu, context, x: scale, y: scale, cell: scale, color: color)
    }
}
func png(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    try data.write(to: url)
}
func contents(images: [[String: String]], properties: [String: String] = [:], at directory: URL) throws {
    var object: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if !properties.isEmpty { object["properties"] = properties }
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"))
}
// Editable Swift geometry is authoritative; SVG masters retain exact square cells for reuse.
func svg(_ glyph: Glyph, canvas: Int, cell: Int = 1, offset: Int = 0, background: Bool = false, fill: String = "#FF5A36") -> String {
    let rectangles = glyph.ordered.map { p in
        "  <rect x=\"\(offset + p.x * cell)\" y=\"\(offset + p.y * cell)\" width=\"\(cell)\" height=\"\(cell)\"/>"
    }.joined(separator: "\n")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(canvas)" height="\(canvas)" viewBox="0 0 \(canvas) \(canvas)">
      <title>CodexSwoop Dual Spark 02</title>
    \(background ? "  <rect width=\"\(canvas)\" height=\"\(canvas)\" fill=\"#17191D\"/>" : "")
      <g fill="\(fill)" shape-rendering="crispEdges">
    \(rectangles)
      </g>
    </svg>

    """
}
try svg(symbol, canvas: 24).write(to: masters.appendingPathComponent("DualSpark.svg"), atomically: true, encoding: .utf8)
try svg(symbol, canvas: 1024, cell: 32, offset: 128, background: true)
    .write(to: masters.appendingPathComponent("DualSpark-AppIcon-Master.svg"), atomically: true, encoding: .utf8)
try svg(menu, canvas: 18, offset: 1, fill: "#000000")
    .write(to: masters.appendingPathComponent("DualSpark-MenuBar.svg"), atomically: true, encoding: .utf8)
try svg(menu24, canvas: 24, fill: "#000000")
    .write(to: masters.appendingPathComponent("DualSpark-MenuBar-24.svg"), atomically: true, encoding: .utf8)
try png(bitmap(width: 24) { drawGlyph(menu24, $0, x: 0, y: 0, cell: 1, color: .black) },
        to: previews.appendingPathComponent("MenuBar-24.png"))
try png(appIcon(size: 1024, squareMaster: true), to: previews.appendingPathComponent("AppIcon-Square-Master-1024.png"))

var appImages: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let rep = appIcon(size: size * scale)
        try png(rep, to: iconset.appendingPathComponent(filename))
        try png(rep, to: appAssets.appendingPathComponent(filename))
        appImages.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
try contents(images: appImages, at: appAssets)
var menuImages: [[String: String]] = []
for scale in [1, 2] {
    let filename = "MenuBarIcon\(scale == 2 ? "@2x" : "").png"
    try png(menuIcon(scale: scale), to: menuAssets.appendingPathComponent(filename))
    menuImages.append(["idiom": "mac", "scale": "\(scale)x", "filename": filename])
}
try contents(images: menuImages, properties: ["template-rendering-intent": "template"], at: menuAssets)
for size in [512, 128, 32, 24, 16] { try png(appIcon(size: size), to: previews.appendingPathComponent("AppIcon-\(size).png")) }

// Contact sheet: actual exports, nearest-neighbor enlargements and illustrative template tints.
let preview = bitmap(width: 1120, height: 900) { context in
    context.setFillColor(NSColor(srgbRed: 0.94, green: 0.945, blue: 0.955, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1120, height: 900))
    context.interpolationQuality = .none
    func label(_ text: String, x: Int, y: Int, size: CGFloat = 14, color: NSColor = .labelColor) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color
        ])
    }
    label("CODEXSWOOP   /   DUAL SPARK 02", x: 48, y: 846, size: 24, color: charcoal)
    label("User-selected reference · solid pixel sparks  ·  #FF5A36 / #17191D", x: 48, y: 816, color: charcoal)
    if let image = appIcon(size: 512).cgImage { context.draw(image, in: CGRect(x: 40, y: 280, width: 512, height: 512)) }
    label("512px · actual size", x: 72, y: 270, color: charcoal)
    for (size, x, y) in [(128, 660, 640), (32, 870, 688), (16, 1016, 696)] {
        if let image = appIcon(size: size).cgImage { context.draw(image, in: CGRect(x: x, y: y, width: size, height: size)) }
        label("\(size)px · actual", x: x - 10, y: 610, color: charcoal)
    }
    for (size, x, width) in [(32, 650, 192), (16, 914, 128)] {
        if let image = appIcon(size: size).cgImage { context.draw(image, in: CGRect(x: x, y: 340, width: width, height: width)) }
        label("\(size)px · nearest-neighbor", x: x, y: 302, color: charcoal)
    }
    label("MENU BAR   /   18pt mask · illustrative tint states", x: 48, y: 218, size: 16, color: charcoal)
    for (column, name) in ["Normal", "Selected", "Inactive"].enumerated() {
        let x = 48 + column * 348
        for (row, dark) in [false, true].enumerated() {
            let y = 126 - row * 64
            let background: NSColor = name == "Selected" ? NSColor(srgbRed: 0.12, green: 0.35, blue: 0.8, alpha: 1) : (dark ? charcoal : .white)
            let foreground: NSColor = (dark || name == "Selected") ? .white : charcoal
            context.setShouldAntialias(false)
            context.setFillColor(background.cgColor); context.fill(CGRect(x: x, y: y, width: 324, height: 48))
            drawGlyph(menu, context, x: x + 18, y: y + 16, cell: 1,
                      color: foreground.withAlphaComponent(name == "Inactive" ? 0.4 : 1))
            label("\(dark ? "Dark" : "Light") · \(name)", x: x + 60, y: y + 15, color: foreground)
        }
    }
}
try png(preview, to: previews.appendingPathComponent("Preview.png"))
print("Generated Dual Spark 02: 10 AppIcon PNGs (16–1024px), ICNS inputs, independent 18/36px template masks, SVG masters and preview.")

let mockup = bitmap(width: 1000, height: 520) { context in
    context.setFillColor(NSColor(srgbRed: 0.91, green: 0.92, blue: 0.94, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1000, height: 520))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 40, y: 180, width: 920, height: 285))
    ("Finder / Applications · illustrative preview" as NSString).draw(at: NSPoint(x: 62, y: 430), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: charcoal])
    if let icon = appIcon(size: 128).cgImage { context.draw(icon, in: CGRect(x: 100, y: 255, width: 128, height: 128)) }
    ("CodexSwoop.app" as NSString).draw(at: NSPoint(x: 102, y: 230), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: charcoal])
    ("Dual Spark 02 · two solid sparks, opposing stepped arcs" as NSString).draw(at: NSPoint(x: 340, y: 310), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: charcoal])
    context.setFillColor(NSColor(srgbRed: 0.8, green: 0.82, blue: 0.85, alpha: 1).cgColor)
    context.addPath(CGPath(roundedRect: CGRect(x: 260, y: 30, width: 480, height: 112), cornerWidth: 26, cornerHeight: 26, transform: nil)); context.fillPath()
    for (i, size) in [48,64,80,64,48].enumerated() {
        if let icon = appIcon(size: size).cgImage { context.draw(icon, in: CGRect(x: 300 + i * 80, y: 47, width: size, height: size)) }
    }
}
try png(mockup, to: previews.appendingPathComponent("Dock-Finder-Mockup.png"))
