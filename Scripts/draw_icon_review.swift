// Compose a review sheet from actual Apple-rendered PNGs; never part of the app target.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("design-assets/qiming-icon-v2/exports")
let colorSpace = CGColorSpace(name:CGColorSpace.sRGB)!
func color(_ hex:UInt32)->CGColor { CGColor(colorSpace:colorSpace,components:[CGFloat((hex>>16)&255)/255,CGFloat((hex>>8)&255)/255,CGFloat(hex&255)/255,1])! }
let width=1520, height=1000
let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
c.translateBy(x:0,y:CGFloat(height)); c.scaleBy(x:1,y:-1)
c.setFillColor(color(0xF4F5F3));c.fill(CGRect(x:0,y:0,width:width,height:height))
func text(_ string:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ shade:UInt32 = 0x304957) {
    let font=CTFontCreateWithName("HelveticaNeue" as CFString,size,nil)
    let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String):color(shade)]
    let line=CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:attributes))
    c.saveGState(); c.translateBy(x:x,y:y+size);c.scaleBy(x:1,y:-1);c.textPosition = .zero;CTLineDraw(line,c);c.restoreGState()
}
func image(_ name:String,_ rect:CGRect, nearest:Bool=false) {
    let url=base.appendingPathComponent(name)
    guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { fatalError("Missing \(name)") }
    c.saveGState(); c.interpolationQuality = nearest ? .none : .high
    c.translateBy(x:rect.minX,y:rect.maxY);c.scaleBy(x:1,y:-1)
    c.draw(image,in:CGRect(x:0,y:0,width:rect.width,height:rect.height));c.restoreGState()
}
text("Qiming",80,48,42)
text("栖羽含光  /  FOLDED WINGS, LIVING LIGHT",82,105,16,0x6A7D87)
text("NATIVE ICON STUDY",1190,79,13,0x6A7D87)
let variants=[("Default","默认 / Default"),("Dark","深色 / Dark"),("TintedDark","系统着色 / Tinted")]
for (index,item) in variants.enumerated() {
    let x=CGFloat(88+index*480)
    image("Qiming-native-\(item.0)-1024.png",CGRect(x:x,y:192,width:384,height:384))
    text(item.1,x,608,18)
}
c.setStrokeColor(color(0xD8DEDE));c.setLineWidth(1);c.move(to:CGPoint(x:80,y:684));c.addLine(to:CGPoint(x:1440,y:684));c.strokePath()
text("尺寸核查 / SCALE CHECK",80,717,14,0x6A7D87)
let sizes=[16,32,64,128]
for (i,size) in sizes.enumerated() {
    let x=CGFloat(80+i*242)
    let file = "Qiming-native-Default-\(size).png"
    // Actual-size icon beside an 80-point nearest-neighbor inspection of the same rendered pixels.
    image(file,CGRect(x:x,y:822-CGFloat(size)/2,width:CGFloat(size),height:CGFloat(size)))
    if size <= 32 {
        image(file,CGRect(x:x+66,y:782,width:80,height:80),nearest:true)
    }
    text("\(size) px",x,910,14,0x6A7D87)
}
image("Qiming-native-Default-256.png",CGRect(x:1148,y:735,width:176,height:176))
text("256 · 512 · 1024 px",1125,928,14,0x6A7D87)
text("PEARL SILVER  /  CHAMPAGNE GOLD  /  SHARED WING SILHOUETTE",80,959,12,0x6A7D87)
let output=base.appendingPathComponent("Qiming-icon-review.png")
let destination=CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(destination,c.makeImage()!,nil)
assert(CGImageDestinationFinalize(destination))
print(output.path)
