// Reproducible, dependency-free vector drawing. Source geometry uses a 1024-point canvas.
// Run: swift Scripts/draw_app_icon.swift <workspace>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let exports = root.appendingPathComponent("Design/AppIcon/Exports", isDirectory: true)
try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255)/255,
        CGFloat((hex >> 8) & 255)/255, CGFloat(hex & 255)/255, alpha])!
}
func context(_ width: Int, _ height: Int) -> CGContext {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setShouldAntialias(true)
    c.setAllowsAntialiasing(true)
    return c
}
func linear(_ c: CGContext, _ colors: [CGColor], _ locations: [CGFloat], _ start: CGPoint, _ end: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    c.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func write(_ image: CGImage, _ name: String) throws {
    let url = exports.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed: \(url.path)") }
}

enum Appearance: String, CaseIterable { case `default`, dark, tinted }
func draw(_ c: CGContext, size: Int, appearance: Appearance, roundedPreview: Bool) {
    c.saveGState()
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: 1, y: -1)
    c.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    // Convert Quartz's bottom-up coordinates to the design document's top-down coordinates.
    if roundedPreview {
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerWidth: 224, cornerHeight: 224, transform: nil))
        c.clip()
    }
    let top: UInt32 = appearance == .dark ? 0x293B49 : appearance == .tinted ? 0x374A56 : 0x263542
    let bottom: UInt32 = appearance == .dark ? 0x101A24 : appearance == .tinted ? 0x1C2D39 : 0x15212B
    linear(c, [color(top), color(bottom)], [0,1], CGPoint(x: 512,y: 0), CGPoint(x:512,y:1024))

    // Master bounds remain exact. Standalone 16/32 px exports snap the bar and core
    // to the pixel grid, retaining one full background pixel between them.
    let step = 1024 / CGFloat(size)
    let small = size <= 32
    let lidRect = small ? CGRect(x:(242/step).rounded()*step, y:floor(418/step)*step,
        width:(540/step).rounded()*step, height:max(1,(64/step).rounded())*step)
        : CGRect(x:242,y:418,width:540,height:64)
    let radius = small ? max(1,(56/step).rounded())*step : 56
    let coreX = small ? (512/step).rounded()*step : 512
    let coreY = small ? (580/step).rounded()*step : 580
    c.saveGState()
    c.addPath(CGPath(roundedRect: lidRect, cornerWidth: lidRect.height/2, cornerHeight: lidRect.height/2, transform: nil))
    c.clip()
    if small {
        c.setFillColor(color(0xC4D0D0)); c.fill(lidRect)
    } else {
        linear(c, [color(0xF1F3EF), color(0xC4D0D0), color(0xB5C4C9), color(0x94A6AE)],
               [0,0.34,0.78,1], CGPoint(x:512,y:418), CGPoint(x:512,y:482))
    }
    // Inset rim, under a point at master scale, retained only where it can resolve.
    if size >= 128 {
        c.setStrokeColor(color(0xF7F8F4, 0.38))
        c.setLineWidth(1)
        c.addPath(CGPath(roundedRect: CGRect(x:242.5,y:418.5,width:539,height:63), cornerWidth:31.5, cornerHeight:31.5,transform:nil))
        c.strokePath()
    }
    c.restoreGState()

    let gold: UInt32 = appearance == .tinted ? 0xC6D8E2 : 0xD8B878
    // Halo ends at radius 76 = 56-point core + 20-point falloff.
    if size >= 64 {
        let halo = CGGradient(colorsSpace:space, colors:[color(gold,0.13),color(gold,0.10),color(gold,0)] as CFArray,
            locations:[0,56.0/76.0,1])!
        c.drawRadialGradient(halo, startCenter:CGPoint(x:512,y:580), startRadius:0,
            endCenter:CGPoint(x:512,y:580),endRadius:76,options:[])
    }
    c.saveGState()
    c.addEllipse(in:CGRect(x:coreX-radius,y:coreY-radius,width:radius*2,height:radius*2)); c.clip()
    let coreColors = appearance == .tinted ? [color(0xE4EDF0),color(0xC6D8E2),color(0x879FAC)]
        : [color(0xF2DCAF),color(0xD8B878),color(0xB88B48)]
    let core = CGGradient(colorsSpace:space, colors:coreColors as CFArray, locations:[0,0.62,1])!
    if small {
        c.setFillColor(color(gold));c.fill(CGRect(x:coreX-radius,y:coreY-radius,width:radius*2,height:radius*2))
    } else {
        c.drawRadialGradient(core, startCenter:CGPoint(x:494,y:559),startRadius:0,
            endCenter:CGPoint(x:512,y:580),endRadius:73,options:[.drawsAfterEndLocation])
    }
    c.restoreGState()
    c.restoreGState()
}

for appearance in Appearance.allCases {
    let full = context(1024,1024)
    draw(full,size:1024,appearance:appearance,roundedPreview:false)
    try write(full.makeImage()!,"Qiming-\(appearance.rawValue)-master-1024.png")
    let preview = context(1024,1024)
    draw(preview,size:1024,appearance:appearance,roundedPreview:true)
    try write(preview.makeImage()!,"Qiming-\(appearance.rawValue)-preview-1024.png")
    for size in [16,32,64,128,256,512] {
        let c = context(size,size)
        draw(c,size:size,appearance:appearance,roundedPreview:true)
        try write(c.makeImage()!,"Qiming-\(appearance.rawValue)-\(size).png")
    }
}
print("Vector geometry rendered to \(exports.path)")
