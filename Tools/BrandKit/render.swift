#!/usr/bin/env swift
//
// Tartelette BrandKit
//
// Procedurally renders every brand asset of the app so the artwork is
// reproducible and reviewable as code:
//
//   Tartelette/AppIcon.icon/            Icon Composer bundle (macOS 26 Liquid Glass)
//   Tartelette/Assets.xcassets/         AccentColor, MenuBarIcon(+Active), BrandMark
//
// Usage (from the Tartelette project directory):
//
//   swift Tools/BrandKit/render.swift .
//
// The script is deterministic and has no dependencies beyond the macOS SDK.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

struct RGBA {
  let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

  init(_ hex: UInt32, alpha: CGFloat = 1) {
    r = CGFloat((hex >> 16) & 0xFF) / 255
    g = CGFloat((hex >> 8) & 0xFF) / 255
    b = CGFloat(hex & 0xFF) / 255
    a = alpha
  }

  var cgColor: CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, a])! }

  func withAlpha(_ alpha: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

  private init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    self.r = r; self.g = g; self.b = b; self.a = a
  }

  /// Icon Composer colour literal, e.g. `srgb:0.22745,0.18431,0.47843,1.00000`.
  var iconComposerLiteral: String {
    "srgb:" + [r, g, b, a].map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
  }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

enum Palette {
  static let backgroundTop = RGBA(0x3A2F7A)
  static let backgroundBottom = RGBA(0x17123A)
  static let backgroundTopDark = RGBA(0x2B2363)
  static let backgroundBottomDark = RGBA(0x0D0A24)

  static let crustLight = RGBA(0xFAC56A)
  static let crust = RGBA(0xF6B24A)
  static let crustDeep = RGBA(0xD7822C)
  static let crustWall = RGBA(0xB9621F)

  static let fillingLight = RGBA(0xE04C58)
  static let filling = RGBA(0xD23A48)
  static let fillingDeep = RGBA(0x8F1732)

  static let creamTop = RGBA(0xFFFAF1)
  static let creamBottom = RGBA(0xFCEBCF)

  static let accentLight = RGBA(0xE8702A)
  static let accentDark = RGBA(0xFF9447)
}

// MARK: - Geometry
//
// Everything is expressed in "units" of the reference icon canvas (1.0 == the
// full 1024 pt Icon Composer canvas) so the same drawing code serves the icon
// layers and the BrandMark at any size.

enum Geometry {
  static let crustOuter: CGFloat = 0.360
  static let crustValley: CGFloat = 0.328
  static let crustHole: CGFloat = 0.252  // hidden under the filling; avoids seams
  static let wallOuter: CGFloat = 0.290  // inner edge of the flat pastry rim
  static let scallops = 16

  static let fillingRadius: CGFloat = 0.262

  static let windowSize = CGSize(width: 0.340, height: 0.256)
  static let windowCorner: CGFloat = 0.044
  static let windowCenterYOffset: CGFloat = 0.004
}

/// A fluted ("scalloped") closed curve in polar form. Peaks are broad and
/// round, valleys are tight but softened so the edge reads like a tart pan.
func flutedPath(
  center c: CGPoint, outer: CGFloat, valley: CGFloat, scallops: Int,
  softness: Double = 0.16, fullness: Double = 0.72, steps: Int = 4096
) -> CGPath {
  let path = CGMutablePath()
  let k = Double(scallops) / 2
  let phase = Double.pi / Double(scallops) // puts a peak at 12 o'clock
  let norm = (1 + softness * softness).squareRoot() - softness
  for i in 0...steps {
    let t = Double(i) / Double(steps) * 2 * .pi
    let s = sin(k * (t + phase))
    let u = ((s * s + softness * softness).squareRoot() - softness) / norm
    let f = pow(max(0, u), fullness)
    let r = Double(valley) + Double(outer - valley) * f
    let angle = t - .pi / 2
    let p = CGPoint(x: c.x + CGFloat(r * cos(angle)), y: c.y + CGFloat(r * sin(angle)))
    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
  }
  path.closeSubpath()
  return path
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
  CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
}

func gradient(_ stops: [(RGBA, CGFloat)]) -> CGGradient {
  CGGradient(
    colorsSpace: sRGB,
    colors: stops.map(\.0.cgColor) as CFArray,
    locations: stops.map(\.1)
  )!
}

// MARK: - Bitmap & file helpers

/// Creates a transparent bitmap context whose user space is top-left origin.
func makeBitmap(pixels: Int) -> CGContext {
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  ctx.translateBy(x: 0, y: CGFloat(pixels))
  ctx.scaleBy(x: 1, y: -1)
  ctx.setShouldAntialias(true)
  ctx.setAllowsAntialiasing(true)
  ctx.interpolationQuality = .high
  return ctx
}

func writePNG(_ ctx: CGContext, to url: URL) throws {
  guard let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw BrandKitError.write(url) }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { throw BrandKitError.write(url) }
}

/// Exact decimal for JSON output (avoids `0.45000000000000001`).
func dec(_ literal: String) -> NSDecimalNumber { NSDecimalNumber(string: literal) }

func writeJSON(_ object: Any, to url: URL) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: url)
}

func recreateDirectory(_ url: URL) throws {
  let fm = FileManager.default
  if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
  try fm.createDirectory(at: url, withIntermediateDirectories: true)
}

enum BrandKitError: Error { case write(URL) }

// MARK: - Artwork layers

/// Back layer: golden fluted crust ring with a darker inner wall.
func drawCrust(_ ctx: CGContext, center c: CGPoint, unit u: CGFloat) {
  let outline = flutedPath(
    center: c, outer: Geometry.crustOuter * u, valley: Geometry.crustValley * u,
    scallops: Geometry.scallops
  )

  ctx.saveGState()
  // Ring = fluted outline minus the hole hidden beneath the filling.
  let ring = CGMutablePath()
  ring.addPath(outline)
  ring.addEllipse(in: circle(c, Geometry.crustHole * u))
  ctx.addPath(ring)
  ctx.clip(using: .evenOdd)

  // Body: warm radial gradient, light falling from the top-left.
  let light = CGPoint(x: c.x - 0.10 * u, y: c.y - 0.12 * u)
  ctx.drawRadialGradient(
    gradient([(Palette.crustLight, 0), (Palette.crust, 0.55), (Palette.crustDeep, 1)]),
    startCenter: light, startRadius: 0,
    endCenter: c, endRadius: Geometry.crustOuter * u * 1.08,
    options: [.drawsAfterEndLocation]
  )

  // Flutes: a soft puff of light on each scallop and a gentle crease
  // between neighbours, so the rim reads as baked pastry.
  let n = Geometry.scallops
  for i in 0..<n {
    let peak = Double(i) / Double(n) * 2 * .pi - .pi / 2
    let puffCentre = (Geometry.crustOuter - 0.024) * u
    let puff = CGPoint(x: c.x + puffCentre * CGFloat(cos(peak)), y: c.y + puffCentre * CGFloat(sin(peak)))
    ctx.drawRadialGradient(
      gradient([(RGBA(0xFFF1CF, alpha: 0.42), 0), (RGBA(0xFFF1CF, alpha: 0), 1)]),
      startCenter: puff, startRadius: 0, endCenter: puff, endRadius: 0.030 * u,
      options: []
    )

    let crease = peak + .pi / Double(n)
    let r0 = (Geometry.crustValley - 0.020) * u
    let r1 = (Geometry.crustValley + 0.002) * u
    ctx.setStrokeColor(RGBA(0x8A4512, alpha: 0.22).cgColor)
    ctx.setLineWidth(0.007 * u)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: c.x + r0 * CGFloat(cos(crease)), y: c.y + r0 * CGFloat(sin(crease))))
    ctx.addLine(to: CGPoint(x: c.x + r1 * CGFloat(cos(crease)), y: c.y + r1 * CGFloat(sin(crease))))
    ctx.strokePath()
  }

  // Inner wall: the darker band where the pastry meets the filling.
  ctx.saveGState()
  let wall = CGMutablePath()
  wall.addEllipse(in: circle(c, Geometry.wallOuter * u))
  wall.addEllipse(in: circle(c, Geometry.crustHole * u))
  ctx.addPath(wall)
  ctx.clip(using: .evenOdd)
  ctx.drawLinearGradient(
    gradient([(Palette.crustDeep, 0), (Palette.crustWall, 1)]),
    start: CGPoint(x: c.x, y: c.y - Geometry.wallOuter * u),
    end: CGPoint(x: c.x, y: c.y + Geometry.wallOuter * u),
    options: []
  )
  ctx.restoreGState()

  // Rim highlight along the top edge of the wall.
  ctx.setStrokeColor(RGBA(0xFFE3A8, alpha: 0.55).cgColor)
  ctx.setLineWidth(0.006 * u)
  ctx.addArc(
    center: c, radius: Geometry.wallOuter * u - 0.003 * u,
    startAngle: .pi * 1.05, endAngle: .pi * 1.70, clockwise: false
  )
  ctx.strokePath()
  ctx.restoreGState()
}

/// Middle layer: glossy berry filling.
func drawFilling(_ ctx: CGContext, center c: CGPoint, unit u: CGFloat) {
  let r = Geometry.fillingRadius * u
  ctx.saveGState()
  ctx.addEllipse(in: circle(c, r))
  ctx.clip()

  ctx.drawLinearGradient(
    gradient([(Palette.fillingLight, 0), (Palette.filling, 0.35), (Palette.fillingDeep, 1)]),
    start: CGPoint(x: c.x - r * 0.75, y: c.y - r * 0.85),
    end: CGPoint(x: c.x + r * 0.70, y: c.y + r * 0.90),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
  )

  // Inner shadow at the rim gives the filling depth inside the crust.
  ctx.drawRadialGradient(
    gradient([(RGBA(0x3D0614, alpha: 0), 0), (RGBA(0x3D0614, alpha: 0), 0.80), (RGBA(0x3D0614, alpha: 0.38), 1)]),
    startCenter: c, startRadius: 0, endCenter: c, endRadius: r,
    options: []
  )

  // Glaze: a soft crescent of light from the top-left.
  ctx.saveGState()
  let glaze = CGMutablePath()
  glaze.addEllipse(in: circle(CGPoint(x: c.x - r * 0.10, y: c.y - r * 0.12), r * 0.92))
  glaze.addEllipse(in: circle(CGPoint(x: c.x + r * 0.10, y: c.y + r * 0.06), r * 0.92))
  ctx.addPath(glaze)
  ctx.clip(using: .evenOdd)
  ctx.addEllipse(in: circle(CGPoint(x: c.x - r * 0.10, y: c.y - r * 0.12), r * 0.92))
  ctx.clip()
  ctx.drawLinearGradient(
    gradient([(RGBA(0xFFFFFF, alpha: 0.32), 0), (RGBA(0xFFFFFF, alpha: 0), 1)]),
    start: CGPoint(x: c.x - r * 0.6, y: c.y - r),
    end: CGPoint(x: c.x, y: c.y - r * 0.2),
    options: []
  )
  ctx.restoreGState()
  ctx.restoreGState()
}

/// Front layer: cream "VM window" with traffic-light dots and a `>_` prompt,
/// both cut out so the filling shows through.
func drawWindow(_ ctx: CGContext, center c: CGPoint, unit u: CGFloat) {
  let size = CGSize(width: Geometry.windowSize.width * u, height: Geometry.windowSize.height * u)
  let rect = CGRect(
    x: c.x - size.width / 2, y: c.y - size.height / 2 + Geometry.windowCenterYOffset * u,
    width: size.width, height: size.height
  )
  let corner = Geometry.windowCorner * u

  ctx.saveGState()
  ctx.beginTransparencyLayer(auxiliaryInfo: nil)

  // Window body.
  ctx.saveGState()
  ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
  ctx.clip()
  ctx.drawLinearGradient(
    gradient([(Palette.creamTop, 0), (Palette.creamBottom, 1)]),
    start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY),
    options: []
  )
  ctx.restoreGState()

  // Cut-outs.
  ctx.setBlendMode(.clear)

  let dotRadius = 0.0115 * u
  let dotY = rect.minY + 0.040 * u
  for i in 0..<3 {
    let x = rect.minX + 0.044 * u + CGFloat(i) * 0.034 * u
    ctx.fillEllipse(in: circle(CGPoint(x: x, y: dotY), dotRadius))
  }

  let stroke = 0.034 * u
  let contentTop = rect.minY + 0.072 * u
  let midY = (contentTop + rect.maxY) / 2 - 0.004 * u
  let chevronHalf = 0.048 * u
  let chevronX = rect.minX + 0.078 * u
  ctx.setLineWidth(stroke)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  ctx.move(to: CGPoint(x: chevronX, y: midY - chevronHalf))
  ctx.addLine(to: CGPoint(x: chevronX + 0.054 * u, y: midY))
  ctx.addLine(to: CGPoint(x: chevronX, y: midY + chevronHalf))
  ctx.strokePath()

  let underscoreY = midY + chevronHalf
  ctx.move(to: CGPoint(x: chevronX + 0.098 * u, y: underscoreY))
  ctx.addLine(to: CGPoint(x: chevronX + 0.176 * u, y: underscoreY))
  ctx.strokePath()

  ctx.endTransparencyLayer()
  ctx.restoreGState()
}

// MARK: - Icon Composer bundle

func renderAppIcon(into appDir: URL) throws {
  let bundle = appDir.appendingPathComponent("AppIcon.icon", isDirectory: true)
  let assets = bundle.appendingPathComponent("Assets", isDirectory: true)
  try recreateDirectory(bundle)
  try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

  let px = 1024
  let u = CGFloat(px)
  let c = CGPoint(x: u / 2, y: u / 2)

  let layers: [(String, (CGContext, CGPoint, CGFloat) -> Void)] = [
    ("Window", drawWindow),
    ("Filling", drawFilling),
    ("Crust", drawCrust),
  ]
  for (name, draw) in layers {
    let ctx = makeBitmap(pixels: px)
    draw(ctx, c, u)
    try writePNG(ctx, to: assets.appendingPathComponent("\(name).png"))
  }

  // Groups are listed front-to-back, as Icon Composer writes them.
  func group(_ name: String, shadow: String, shadowOpacity: String, translucency: String) -> [String: Any] {
    [
      "layers": [["image-name": "\(name).png", "name": name, "glass": true]],
      "shadow": ["kind": shadow, "opacity": dec(shadowOpacity)],
      "translucency": ["enabled": true, "value": dec(translucency)] as [String: Any],
      "specular": true,
    ]
  }

  func verticalGradient(_ top: RGBA, _ bottom: RGBA) -> [String: Any] {
    [
      "linear-gradient": [top.iconComposerLiteral, bottom.iconComposerLiteral],
      "orientation": [
        "start": ["x": dec("0.5"), "y": dec("0")],
        "stop": ["x": dec("0.5"), "y": dec("1")],
      ],
    ]
  }

  let icon: [String: Any] = [
    // Keep the blueberry backdrop in the Dark icon style too (instead of the
    // system's neutral dark fill) so the brand stays recognisable.
    "fill-specializations": [
      ["value": verticalGradient(Palette.backgroundTop, Palette.backgroundBottom)],
      ["appearance": "dark", "value": verticalGradient(Palette.backgroundTopDark, Palette.backgroundBottomDark)],
    ],
    "groups": [
      group("Window", shadow: "neutral", shadowOpacity: "0.45", translucency: "0.15"),
      group("Filling", shadow: "layer-color", shadowOpacity: "0.35", translucency: "0.2"),
      group("Crust", shadow: "neutral", shadowOpacity: "0.6", translucency: "0.2"),
    ],
    "supported-platforms": ["squares": "shared"],
  ]
  try writeJSON(icon, to: bundle.appendingPathComponent("icon.json"))
}

// MARK: - Asset catalog

let catalogInfo: [String: Any] = ["author": "xcode", "version": 1]

func colorEntry(_ c: RGBA, dark: Bool) -> [String: Any] {
  var entry: [String: Any] = [
    "color": [
      "color-space": "srgb",
      "components": [
        "red": String(format: "%.3f", Double(c.r)),
        "green": String(format: "%.3f", Double(c.g)),
        "blue": String(format: "%.3f", Double(c.b)),
        "alpha": "1.000",
      ],
    ],
    "idiom": "universal",
  ]
  if dark { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
  return entry
}

func renderAccentColor(into catalog: URL) throws {
  let dir = catalog.appendingPathComponent("AccentColor.colorset", isDirectory: true)
  try recreateDirectory(dir)
  try writeJSON(
    ["colors": [colorEntry(Palette.accentLight, dark: false), colorEntry(Palette.accentDark, dark: true)],
     "info": catalogInfo],
    to: dir.appendingPathComponent("Contents.json")
  )
}

/// 18×18 pt template glyph for the menu bar: fluted crust outline with a small
/// VM window inside. `filled` draws the window solid (VMs are running).
func renderMenuBarIcon(named name: String, filled: Bool, into catalog: URL) throws {
  let dir = catalog.appendingPathComponent("\(name).imageset", isDirectory: true)
  try recreateDirectory(dir)
  let url = dir.appendingPathComponent("\(name).pdf")

  var box = CGRect(x: 0, y: 0, width: 18, height: 18)
  guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw BrandKitError.write(url) }
  ctx.beginPDFPage(nil)
  ctx.translateBy(x: 0, y: 18)
  ctx.scaleBy(x: 1, y: -1)

  let black = CGColor(gray: 0, alpha: 1)
  let c = CGPoint(x: 9, y: 9)
  let crustStroke: CGFloat = 1.5

  ctx.setStrokeColor(black)
  ctx.setFillColor(black)
  ctx.setLineJoin(.round)
  ctx.setLineCap(.round)

  ctx.setLineWidth(crustStroke)
  ctx.addPath(flutedPath(center: c, outer: 8.3 - crustStroke / 2, valley: 7.1 - crustStroke / 2,
                         scallops: 10, softness: 0.10, fullness: 0.55, steps: 720))
  ctx.strokePath()

  let window = CGRect(x: c.x - 3.3, y: c.y - 2.55, width: 6.6, height: 5.1)
  if filled {
    ctx.addPath(CGPath(roundedRect: window, cornerWidth: 1.3, cornerHeight: 1.3, transform: nil))
    ctx.fillPath()
  } else {
    let inset = window.insetBy(dx: 0.6, dy: 0.6)
    ctx.setLineWidth(1.2)
    ctx.addPath(CGPath(roundedRect: inset, cornerWidth: 0.9, cornerHeight: 0.9, transform: nil))
    ctx.strokePath()
  }

  ctx.endPDFPage()
  ctx.closePDF()

  try writeJSON(
    [
      "images": [["filename": "\(name).pdf", "idiom": "universal"]],
      "info": catalogInfo,
      "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"],
    ],
    to: dir.appendingPathComponent("Contents.json")
  )
}

/// Full-colour tartlet (no squircle) with a soft drop shadow.
func renderBrandMark(into catalog: URL) throws {
  let dir = catalog.appendingPathComponent("BrandMark.imageset", isDirectory: true)
  try recreateDirectory(dir)

  for (scale, file) in [(1, "BrandMark.png"), (2, "BrandMark@2x.png")] {
    let px = 256 * scale
    let canvas = CGFloat(px)
    // The tart (diameter 0.72 u) fills ~86% of the canvas, leaving room for the shadow.
    let u = canvas * 0.86 / (2 * Geometry.crustOuter)
    let c = CGPoint(x: canvas / 2, y: canvas / 2 - canvas * 0.012)

    let ctx = makeBitmap(pixels: px)
    ctx.saveGState()
    ctx.setShadow(
      offset: CGSize(width: 0, height: -canvas * 0.018), blur: canvas * 0.045,
      color: RGBA(0x1A0E2E, alpha: 0.38).cgColor
    )
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawCrust(ctx, center: c, unit: u)
    drawFilling(ctx, center: c, unit: u)
    drawWindow(ctx, center: c, unit: u)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    try writePNG(ctx, to: dir.appendingPathComponent(file))
  }

  try writeJSON(
    [
      "images": [
        ["filename": "BrandMark.png", "idiom": "universal", "scale": "1x"],
        ["filename": "BrandMark@2x.png", "idiom": "universal", "scale": "2x"],
        ["idiom": "universal", "scale": "3x"],
      ],
      "info": catalogInfo,
    ],
    to: dir.appendingPathComponent("Contents.json")
  )
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
  FileHandle.standardError.write("usage: swift Tools/BrandKit/render.swift <TarteletteProjectDir>\n".data(using: .utf8)!)
  exit(64)
}

let projectDir = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
let appDir = projectDir.appendingPathComponent("Tartelette", isDirectory: true)
let catalog = appDir.appendingPathComponent("Assets.xcassets", isDirectory: true)

do {
  try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
  try writeJSON(["info": catalogInfo], to: catalog.appendingPathComponent("Contents.json"))

  try renderAppIcon(into: appDir)
  try renderAccentColor(into: catalog)
  try renderMenuBarIcon(named: "MenuBarIcon", filled: false, into: catalog)
  try renderMenuBarIcon(named: "MenuBarIconActive", filled: true, into: catalog)
  try renderBrandMark(into: catalog)
  print("BrandKit: rendered assets into \(appDir.path)")
} catch {
  FileHandle.standardError.write("BrandKit: \(error)\n".data(using: .utf8)!)
  exit(1)
}
