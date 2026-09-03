import AppKit
import Foundation

private let canvasSize = 1024

private func color(_ white: CGFloat, alpha: CGFloat = 1) -> NSColor {
  NSColor(calibratedWhite: white, alpha: alpha)
}

private func sparkle(center: CGPoint, radius: CGFloat) -> NSBezierPath {
  let x = center.x
  let y = center.y
  let shoulder = radius * 0.36
  let tipControl = radius * 0.08
  let path = NSBezierPath()
  path.move(to: CGPoint(x: x, y: y + radius))
  path.curve(
    to: CGPoint(x: x + radius, y: y),
    controlPoint1: CGPoint(x: x + tipControl, y: y + shoulder),
    controlPoint2: CGPoint(x: x + shoulder, y: y + tipControl))
  path.curve(
    to: CGPoint(x: x, y: y - radius),
    controlPoint1: CGPoint(x: x + shoulder, y: y - tipControl),
    controlPoint2: CGPoint(x: x + tipControl, y: y - shoulder))
  path.curve(
    to: CGPoint(x: x - radius, y: y),
    controlPoint1: CGPoint(x: x - tipControl, y: y - shoulder),
    controlPoint2: CGPoint(x: x - shoulder, y: y - tipControl))
  path.curve(
    to: CGPoint(x: x, y: y + radius),
    controlPoint1: CGPoint(x: x - shoulder, y: y + tipControl),
    controlPoint2: CGPoint(x: x - tipControl, y: y + shoulder))
  path.close()
  return path
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: generate-icon.swift OUTPUT.png\n".utf8))
  Foundation.exit(EXIT_FAILURE)
}

guard let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: canvasSize,
  pixelsHigh: canvasSize,
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
) else {
  Foundation.exit(EXIT_FAILURE)
}

bitmap.size = NSSize(width: canvasSize, height: canvasSize)
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
  Foundation.exit(EXIT_FAILURE)
}
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()

let tileRect = NSRect(x: 62, y: 70, width: 900, height: 900)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 205, yRadius: 205)
let tileShadow = NSShadow()
tileShadow.shadowColor = color(0, alpha: 0.19)
tileShadow.shadowBlurRadius = 28
tileShadow.shadowOffset = NSSize(width: 0, height: -16)
tileShadow.set()
NSGradient(
  starting: NSColor(calibratedRed: 0.995, green: 0.994, blue: 0.984, alpha: 1),
  ending: NSColor(calibratedRed: 0.952, green: 0.950, blue: 0.938, alpha: 1)
)?.draw(in: tile, angle: 90)

NSGraphicsContext.saveGraphicsState()
tile.addClip()
let innerHighlight = NSBezierPath(roundedRect: tileRect.insetBy(dx: 3, dy: 3), xRadius: 202, yRadius: 202)
color(1, alpha: 0.82).setStroke()
innerHighlight.lineWidth = 5
innerHighlight.stroke()
NSGraphicsContext.restoreGraphicsState()

let mainMark = sparkle(center: CGPoint(x: 500, y: 496), radius: 220)
NSGradient(
  starting: NSColor(calibratedRed: 0.47, green: 0.48, blue: 0.50, alpha: 1),
  ending: NSColor(calibratedRed: 0.36, green: 0.37, blue: 0.39, alpha: 1)
)?.draw(in: mainMark, angle: 90)

let companion = sparkle(center: CGPoint(x: 696, y: 684), radius: 62)
NSColor(calibratedRed: 0.70, green: 0.71, blue: 0.73, alpha: 1).setFill()
companion.fill()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
  Foundation.exit(EXIT_FAILURE)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
