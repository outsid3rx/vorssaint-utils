// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 contributors
// Draws original, geometric assets for the independent fork.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("icon_16x16",16),("icon_16x16@2x",32),
    ("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),
    ("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),
    ("icon_512x512",512),("icon_512x512@2x",1024)]
func image(width: Int, height: Int, app: Bool) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let w = CGFloat(width), h = CGFloat(height)
    if app {
        NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: w*0.07, y: h*0.07, width: w*0.86, height: h*0.86), xRadius: w*0.22, yRadius: h*0.22).fill()
        NSColor.white.setFill()
    } else { NSColor.black.setFill() }
    let x = app ? w*0.25 : w*0.22, y = app ? h*0.31 : h*0.25
    let bw = app ? w*0.50 : w*0.56, bh = app ? h*0.09 : h*0.10
    for row in 0..<3 {
        NSBezierPath(roundedRect: NSRect(x: x, y: y + CGFloat(row)*bh*1.8, width: bw, height: bh), xRadius: bh/2, yRadius: bh/2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return data
}
let types = ["icon_16x16@2x":"ic11", "icon_32x32@2x":"ic12", "icon_128x128":"ic07",
             "icon_128x128@2x":"ic13", "icon_256x256":"ic08", "icon_256x256@2x":"ic14",
             "icon_512x512":"ic09", "icon_512x512@2x":"ic10"]
func u32(_ n: Int) -> Data { var value = UInt32(n).bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
var entries = Data()
for (name, px) in sizes {
    let png = try image(width: px, height: px, app: true)
    try png.write(to: out.appendingPathComponent(name + ".png"))
    if let type = types[name] { entries.append(contentsOf: type.utf8); entries.append(u32(png.count + 8)); entries.append(png) }
}
var icns = Data("icns".utf8); icns.append(u32(entries.count + 8)); icns.append(entries)
try icns.write(to: out.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
for scale in [1,2] {
    let name = scale == 1 ? "MenuBarIcon.png" : "MenuBarIcon@2x.png"
    try image(width: 26*scale, height: 20*scale, app: false).write(to: out.deletingLastPathComponent().appendingPathComponent(name))
}
try image(width: 640, height: 320, app: false).write(to: out.deletingLastPathComponent().appendingPathComponent("BrandMark.png"))
print("fork iconset written to \(out.path)")
