import AppKit

// Read-only checks of actual decoded assets and bundle payloads; no app/process/account APIs.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL branding: \(message)\n", stderr); exit(1) }
}
func decoded(_ path: URL, width: Int, height: Int) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: path)) else { fatalError("Cannot decode \(path.lastPathComponent)") }
    require(rep.pixelsWide == width && rep.pixelsHigh == height, "Wrong dimensions: \(path.lastPathComponent)")
    require(rep.hasAlpha && rep.bitsPerSample == 8, "Expected 8-bit RGBA: \(path.lastPathComponent)")
    return rep
}
// Eight-neighbor components retain corner-touching pixel steps within each arc.
// The reference deliberately contains four shapes: two filled sparks and two arcs.
func componentAreas(_ pixels: Set<Int>, width: Int) -> [Int] {
    var remaining = pixels, areas: [Int] = []
    while let first = remaining.first {
        remaining.remove(first)
        var pending = [first], area = 0
        while let pixel = pending.popLast() {
            area += 1
            let x = pixel % width, y = pixel / width
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0 && nx < width && ny >= 0 else { continue }
                    let next = ny * width + nx
                    if remaining.remove(next) != nil { pending.append(next) }
                }
            }
        }
        areas.append(area)
    }
    return areas.sorted()
}
let assets = root.appendingPathComponent("Resources/Assets.xcassets")
func catalog(_ name: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: assets.appendingPathComponent(name + "/Contents.json"))) as! [String: Any]
}
let app = try catalog("AppIcon.appiconset")
let appImages = app["images"] as! [[String: String]]
require(appImages.count == 10 && Set(appImages.compactMap { $0["filename"] }).count == 10, "Complete, unique AppIcon slots")
var dimensions = Set<Int>()
for entry in appImages {
    let size = Int(entry["size"]!.split(separator: "x")[0])!, scale = Int(entry["scale"]!.dropLast())!
    require(entry["idiom"] == "mac" && [16, 32, 128, 256, 512].contains(size) && [1, 2].contains(scale), "macOS AppIcon slot")
    let rep = try decoded(assets.appendingPathComponent("AppIcon.appiconset/" + entry["filename"]!), width: size * scale, height: size * scale)
    dimensions.insert(size * scale)
    require(rep.colorAt(x: 0, y: 0)!.alphaComponent == 0, "Transparent legacy tile margin")
    // Inspect decoded channel values directly; AppKit's calibrated-to-screen conversion is not asset data.
    let center = rep.colorAt(x: size * scale / 2, y: size * scale / 2)!
    if rep.pixelsWide <= 64 {
        require(abs(center.redComponent - 23.0 / 255) < 0.005 && abs(center.greenComponent - 25.0 / 255) < 0.005,
                "Charcoal small-size background")
    } else {
        require(center.alphaComponent == 1 && center.redComponent < 0.3 && center.greenComponent < 0.2
                && center.blueComponent < 0.2, "Dark tile with subtle warm bloom")
    }
    var coral = 0, coralPixels = Set<Int>()
    // Inspect foreground fully: any colored edge must be exact opaque coral, never a blurred pixel.
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let color = rep.colorAt(x: x, y: y)!
            if color.redComponent > 0.5 && color.redComponent - color.greenComponent > 0.2 && color.alphaComponent > 0 {
                require(color.alphaComponent == 1 && abs(color.redComponent - 1) < 0.005
                    && abs(color.greenComponent - 90.0 / 255) < 0.005 && abs(color.blueComponent - 54.0 / 255) < 0.005,
                    "Crisp coral foreground")
                coral += 1
                if rep.pixelsWide <= 64 { coralPixels.insert(y * rep.pixelsWide + x) }
            }
        }
    }
    let foregroundCell = rep.pixelsWide == 16 ? 1 : rep.pixelsWide / 32
    require(coral == (rep.pixelsWide == 16 ? 32 : 70) * foregroundCell * foregroundCell,
            "Exact solid foreground area; no missing cells or extra particles")
    if rep.pixelsWide <= 64 {
        let cell = rep.pixelsWide == 16 ? 1 : rep.pixelsWide / 32
        let areas = rep.pixelsWide == 16 ? [3, 3, 13, 13] : [6, 6, 29, 29]
        require(componentAreas(coralPixels, width: rep.pixelsWide) == areas.map { $0 * cell * cell },
                "Two solid sparks and two separate stepped arcs at small sizes")
        let grid = rep.pixelsWide == 16 ? 14 : 24
        let origin = (rep.pixelsWide - grid * cell) / 2
        let centers = rep.pixelsWide == 16 ? [(3,10),(10,3)] : [(6,17),(17,6)]
        for (x,y) in centers {
            require(coralPixels.contains((origin + y * cell) * rep.pixelsWide + origin + x * cell),
                    "Filled spark center, never a hollow node")
        }
    }
}
require(dimensions == [16, 32, 64, 128, 256, 512, 1024], "All required pixel sizes")
let menu = try catalog("MenuBarIcon.imageset")
require((menu["properties"] as? [String: String])?["template-rendering-intent"] == "template", "Template asset intent")
var maskCounts: [Int] = []
for scale in [1, 2] {
    let name = "MenuBarIcon\(scale == 2 ? "@2x" : "").png"
    let rep = try decoded(assets.appendingPathComponent("MenuBarIcon.imageset/" + name), width: 18 * scale, height: 18 * scale)
    var opaque = 0, opaquePixels = Set<Int>()
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let color = rep.colorAt(x: x, y: y)!
            require(color.alphaComponent == 0 || color.alphaComponent == 1, "Binary menu alpha")
            if color.alphaComponent == 1 {
                require(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0, "Monochrome menu mask")
                require(x >= scale && y >= scale && x < 17 * scale && y < 17 * scale, "Menu transparent padding")
                opaque += 1
                opaquePixels.insert(y * rep.pixelsWide + x)
            }
        }
    }
    require(componentAreas(opaquePixels, width: rep.pixelsWide) == [5, 5, 13, 13].map { $0 * scale * scale },
            "Template retains two solid sparks and two separate arcs")
    for (x,y) in [(5,5),(12,12)] {
        require(opaquePixels.contains(y * scale * rep.pixelsWide + x * scale),
                "Reference Menu Bar orientation and filled spark centers")
    }
    maskCounts.append(opaque)
}
require(maskCounts[0] > 20 && maskCounts[1] == maskCounts[0] * 4, "Consistent Retina mask")
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns"), bytes = try Data(contentsOf: icnsURL)
require(String(data: bytes.prefix(4), encoding: .ascii) == "icns", "ICNS container")
func uint32(_ position: Int) -> Int { bytes[position..<(position + 4)].reduce(0) { ($0 << 8) | Int($1) } }
require(bytes.count >= 8 && uint32(4) == bytes.count, "Complete ICNS length")
var offset = 8, chunks = Set<String>()
while offset < bytes.count {
    require(offset + 8 <= bytes.count, "ICNS chunk header")
    let size = uint32(offset + 4)
    require(size >= 8 && offset + size <= bytes.count, "ICNS chunk payload")
    chunks.insert(String(data: bytes[offset..<(offset + 4)], encoding: .ascii)!)
    offset += size
}
require(chunks.isSuperset(of: ["ic07", "ic08", "ic09", "ic10", "ic11", "ic12", "ic13", "ic14"])
    && !chunks.isDisjoint(with: ["icp4", "ic04", "is32"])
    && !chunks.isDisjoint(with: ["icp5", "ic05", "il32"]), "ICNS size/Retina representations")
let representations = NSImage(contentsOf: icnsURL)!.representations
require(Set(representations.map(\.pixelsWide)) == dimensions && representations.count == 10, "AppKit decodes all ICNS slots")
if CommandLine.arguments.count == 3 && ["--bundle", "--native-bundle"].contains(CommandLine.arguments[1]) {
    let bundle = URL(fileURLWithPath: CommandLine.arguments[2])
    let native = CommandLine.arguments[1] == "--native-bundle"
    for name in ["AppIcon.icns", "MenuBarIcon.png", "MenuBarIcon@2x.png"] {
        let expected = name.hasSuffix(".icns") ? icnsURL : assets.appendingPathComponent("MenuBarIcon.imageset/" + name)
        let actual = try Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/" + name))
        let source = try Data(contentsOf: expected)
        if native && name.hasSuffix(".icns") {
            // actool keeps legacy non-Retina fallback sizes in ICNS; all ten slots live in Assets.car.
            let icon = NSImage(data: actual)
            require(icon != nil && Set(icon!.representations.map(\.pixelsWide)).isSuperset(of: [16, 32, 128, 256]), "Compiled legacy AppIcon dimensions")
        } else {
            require(actual == source, "Bundle contains new \(name)")
        }
    }
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
    require(["AppIcon", "AppIcon.icns"].contains(info["CFBundleIconFile"] as? String ?? ""), "Bundle icon reference")
    if native {
        let car = bundle.appendingPathComponent("Contents/Resources/Assets.car")
        require(FileManager.default.fileExists(atPath: car.path), "Compiled asset catalog")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["assetutil", "--info", car.path]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        require(process.terminationStatus == 0, "assetutil must inspect compiled resources")
        guard let renditions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fatalError("Invalid assetutil response") }
        let icons = renditions.filter { $0["Name"] as? String == "AppIcon" && $0["AssetType"] as? String == "Icon Image" }
        require(icons.count == appImages.count, "All ten compiled AppIcon slots")
        for entry in appImages {
            let size = Int(entry["size"]!.split(separator: "x")[0])!, scale = Int(entry["scale"]!.dropLast())!
            require(icons.filter { $0["RenditionName"] as? String == entry["filename"] && $0["PixelWidth"] as? Int == size * scale
                && $0["PixelHeight"] as? Int == size * scale && $0["Scale"] as? Int == scale }.count == 1,
                "Unique compiled AppIcon slot: \(entry["filename"]!)")
        }
        let masks = renditions.filter { $0["Name"] as? String == "MenuBarIcon" && $0["AssetType"] as? String == "Image" }
        require(masks.count == 2, "Both compiled Menu Bar masks")
        for scale in [1, 2] {
            require(masks.filter { $0["PixelWidth"] as? Int == 18 * scale && $0["PixelHeight"] as? Int == 18 * scale
                && $0["Scale"] as? Int == scale && $0["Template Mode"] as? String == "template" }.count == 1,
                "Compiled template mask at scale \(scale)")
        }
    }
    require(info.keys.allSatisfy { !$0.hasPrefix("CodexSwoopTest") }, "Ordinary bundle contains no fixture flags or root")
}
print("PASS branding: 10 PNG slots, 16–1024px, crisp coral/charcoal, independent 18/36px template masks (\(maskCounts)), complete ICNS and requested bundle payload.")
