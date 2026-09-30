// Draws the app icon: a 2×2 deck of module tiles — one per module colour, the fourth slot left
// open for the next one — on a macOS-style rounded square. Reproducible, no design tool needed.
//
//   swift scripts/make-icon.swift Assets/icon-1024.png
//
// `build.sh` turns the PNG into the .icns.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "Assets/icon-1024.png"
let canvas: CGFloat = 1024

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    // Apple's macOS icon grid: the rounded square is 824 pt on a 1024 canvas, corner ≈ 22.4 %.
    let square = NSRect(x: 100, y: 100, width: 824, height: 824)
    let plate = NSBezierPath(roundedRect: square, xRadius: 184, yRadius: 184)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.set()
    NSColor.black.setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Plate: graphite, lighter at the top.
    NSGradient(colors: [
        NSColor(calibratedRed: 0.27, green: 0.29, blue: 0.34, alpha: 1),
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1),
    ])!.draw(in: plate, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.12), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let tile: CGFloat = 250
    let gap: CGFloat = 56
    let x0 = (canvas - tile * 2 - gap) / 2
    let y0 = (canvas - tile * 2 - gap) / 2
    let colours: [NSColor?] = [
        NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.20, alpha: 1), // top left — Night Shift Focus
        NSColor(calibratedRed: 0.40, green: 0.42, blue: 1.00, alpha: 1), // top right — Altty
        NSColor(calibratedRed: 0.25, green: 0.78, blue: 0.82, alpha: 1), // bottom left — Dock Lock
        nil,                                                             // bottom right — next module
    ]
    for (i, colour) in colours.enumerated() {
        let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)
        let rect = NSRect(x: x0 + col * (tile + gap), y: y0 + row * (tile + gap), width: tile, height: tile)
        let path = NSBezierPath(roundedRect: rect, xRadius: 58, yRadius: 58)
        guard let colour else {
            path.lineWidth = 14
            path.setLineDash([34, 26], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.35).setStroke()
            path.stroke()
            continue
        }
        NSGraphicsContext.saveGraphicsState()
        let tileShadow = NSShadow()
        tileShadow.shadowBlurRadius = 16
        tileShadow.shadowOffset = NSSize(width: 0, height: -8)
        tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        tileShadow.set()
        NSGradient(colors: [colour.blended(withFraction: 0.22, of: .white)!, colour])!.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("could not render") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
