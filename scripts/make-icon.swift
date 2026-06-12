#!/usr/bin/env swift
// Renders the andross app icon (identity tiles motif) to assets/icon-1024.png.
// Run via scripts/make-icon.sh, which also packs the .icns.

import AppKit

let canvas: CGFloat = 1024
// Apple icon grid: content squircle is ~824pt centered in a 1024 canvas.
let content = NSRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 824 * 0.2237

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// Background squircle: deep slate vertical gradient + hairline border.
let squircle = NSBezierPath(roundedRect: content, xRadius: cornerRadius, yRadius: cornerRadius)
squircle.addClip()

let bgGradient = NSGradient(
    starting: NSColor(srgbRed: 0x1E/255, green: 0x2A/255, blue: 0x2E/255, alpha: 1),
    ending: NSColor(srgbRed: 0x10/255, green: 0x15/255, blue: 0x18/255, alpha: 1)
)
bgGradient?.draw(in: content, angle: -90)

// Faint green glow behind the tiles.
let glowCenter = CGPoint(x: 512, y: 470)
let glow = NSGradient(colors: [
    NSColor(srgbRed: 0x3D/255, green: 0xDC/255, blue: 0x84/255, alpha: 0.22),
    NSColor.clear,
])
glow?.draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 430, options: [])

// Identity tiles: three phone-shaped rounded rects, back two as outlines,
// front one filled green — "one device, several identities".
func phoneRect(offsetX: CGFloat, offsetY: CGFloat) -> NSRect {
    NSRect(x: 512 - 170 + offsetX, y: 512 - 295 + offsetY, width: 340, height: 590)
}
let phoneCorner: CGFloat = 86

let backPath = NSBezierPath(roundedRect: phoneRect(offsetX: -128, offsetY: 96), xRadius: phoneCorner, yRadius: phoneCorner)
NSColor(white: 1.0, alpha: 0.14).setStroke()
backPath.lineWidth = 16
backPath.stroke()

let midPath = NSBezierPath(roundedRect: phoneRect(offsetX: -64, offsetY: 48), xRadius: phoneCorner, yRadius: phoneCorner)
NSColor(srgbRed: 0x3D/255, green: 0xDC/255, blue: 0x84/255, alpha: 0.42).setStroke()
midPath.lineWidth = 16
midPath.stroke()

let frontRect = phoneRect(offsetX: 0, offsetY: 0)
let frontPath = NSBezierPath(roundedRect: frontRect, xRadius: phoneCorner, yRadius: phoneCorner)
let frontGradient = NSGradient(
    starting: NSColor(srgbRed: 0x46/255, green: 0xE6/255, blue: 0x91/255, alpha: 1),
    ending: NSColor(srgbRed: 0x2A/255, green: 0xB8/255, blue: 0x6B/255, alpha: 1)
)
ctx.saveGState()
frontPath.addClip()
frontGradient?.draw(in: frontRect, angle: -90)
ctx.restoreGState()

// Screen cutout on the front phone, in the background slate.
let screenRect = frontRect.insetBy(dx: 26, dy: 26)
let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: phoneCorner - 24, yRadius: phoneCorner - 24)
NSColor(srgbRed: 0x12/255, green: 0x17/255, blue: 0x1A/255, alpha: 1).setFill()
screenPath.fill()

// Three identity dots on the screen.
let dotColors: [NSColor] = [
    NSColor(srgbRed: 0x3D/255, green: 0xDC/255, blue: 0x84/255, alpha: 1),
    NSColor(srgbRed: 0x3D/255, green: 0xDC/255, blue: 0x84/255, alpha: 0.55),
    NSColor(white: 1.0, alpha: 0.30),
]
let dotRadius: CGFloat = 34
for (index, color) in dotColors.enumerated() {
    let cy = screenRect.midY + CGFloat(1 - index) * 110
    let dotRect = NSRect(x: screenRect.midX - dotRadius, y: cy - dotRadius,
                         width: dotRadius * 2, height: dotRadius * 2)
    color.setFill()
    NSBezierPath(ovalIn: dotRect).fill()
}

// Hairline border on the squircle.
NSColor(white: 1.0, alpha: 0.08).setStroke()
let border = NSBezierPath(roundedRect: content.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
border.lineWidth = 2
border.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}

let outURL = URL(fileURLWithPath: "assets/icon-1024.png")
try FileManager.default.createDirectory(atPath: "assets", withIntermediateDirectories: true)
try png.write(to: outURL)
print("wrote \(outURL.path) (\(png.count) bytes)")
