// Render the production AppKit wing paths for visual QA. Does not create an app/session.
import AppKit

@main @MainActor struct IconReviewRenderer {
    static let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        .appendingPathComponent("design-assets/qiming-icon-v2/exports",isDirectory:true)
    static func bitmap(width:Int,height:Int,scale:Int=1,_ draw:()->Void)->NSBitmapImageRep {
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width*scale,pixelsHigh:height*scale,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        let context=NSGraphicsContext(bitmapImageRep:rep)!
        NSGraphicsContext.current=context
        context.cgContext.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func save(_ rep:NSBitmapImageRep,_ name:String)throws {
        try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
    }
    static func main()throws {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let W=1200,H=710
        func rect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat)->NSRect { NSRect(x:x,y:CGFloat(H)-y-h,width:w,height:h) }
        func label(_ string:String,x:CGFloat,y:CGFloat,w:CGFloat,size:CGFloat,color:NSColor,center:Bool=false) {
            let paragraph=NSMutableParagraphStyle();paragraph.alignment=center ? .center : .left
            (string as NSString).draw(in:rect(x,y,w,size+9),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color,.paragraphStyle:paragraph])
        }
        let modes:[(DisplayMode,String,String)]=[
            (.system,"Follow System","Both wings outlined"),
            (.closed,"Screen Off When Closed","Outer wing filled · Work continues"),
            (.always,"Always On","Both wings filled · Screen stays on")]
        let board=bitmap(width:W,height:H) {
            NSColor(srgbRed:0.94,green:0.95,blue:0.93,alpha:1).setFill();NSRect(x:0,y:0,width:W,height:H).fill()
            label("Qiming · Quiet wings, living light",x:64,y:32,w:1060,size:26,color:.darkGray)
            label("Production AppKit paths · shared silhouette, three fill states",x:64,y:76,w:1060,size:15,color:.gray)
            for row in 0..<2 {
                let appearance=NSAppearance(named:row==0 ? .aqua : .darkAqua)!
                let ink=NSColor(srgbRed:row==0 ? 0.16:0.93,green:row==0 ? 0.24:0.94,blue:row==0 ? 0.29:0.93,alpha:1)
                for (i,item) in modes.enumerated() {
                    let x=CGFloat(48+i*372),y=CGFloat(130+row*270)
                    (row==0 ? NSColor(srgbRed:0.98,green:0.985,blue:0.975,alpha:1):NSColor(srgbRed:0.09,green:0.14,blue:0.18,alpha:1)).setFill()
                    NSBezierPath(roundedRect:rect(x,y,352,242),xRadius:24,yRadius:24).fill()
                    appearance.performAsCurrentDrawingAppearance {
                        UI.brandImage(mode:item.0,size:88).draw(in:rect(x+132,y+18,88,88))
                        UI.brandImage(mode:item.0,size:22).draw(in:rect(x+165,y+140,22,22))
                    }
                    label(item.1,x:x+10,y:y+185,w:332,size:17,color:ink,center:true)
                    label(item.2,x:x+10,y:y+212,w:332,size:12,color:ink.withAlphaComponent(0.7),center:true)
                }
            }
            label("22 pt template · 1× / 2× exports · alert markers use separate width",x:64,y:676,w:1060,size:13,color:.gray)
        }
        try save(board,"Qiming-menubar-native-states.png")
        for (mode,_,_) in modes {
            for scale in [1,2] {
                let rep=bitmap(width:22,height:22,scale:scale) {
                    NSAppearance(named:.aqua)!.performAsCurrentDrawingAppearance {
                        UI.brandImage(mode:mode,size:22).draw(in:NSRect(x:0,y:0,width:22,height:22))
                    }
                }
                try save(rep,"menubar-\(mode.rawValue)\(scale==2 ? "@2x":"").png")
            }
        }
        for badge in [IconBadge.paused,.attention] {
            let rep=bitmap(width:30,height:22,scale:2) {
                NSAppearance(named:.aqua)!.performAsCurrentDrawingAppearance {
                    UI.brandImage(mode:.system,size:22,badge:badge).draw(in:NSRect(x:0,y:0,width:30,height:22))
                }
            }
            try save(rep,"menubar-\(badge.rawValue)@2x.png")
        }
        print(output.path)
    }
}
