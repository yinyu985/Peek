import AppKit

// Conform full-bleed artwork to Apple's macOS icon grid: an 824x824 body
// centered on a 1024x1024 transparent canvas (100px margin), matching system
// icons (Notes/Calculator measure exactly 824 at (100,100)).
// Draw in the DEFAULT bottom-up bitmap context — no coordinate flip.
// NSGraphicsContext(bitmapImageRep:) already maps the drawing so the saved
// PNG comes out right-side-up; adding a flip mirrors the art.
// The artwork is only scaled + centered; nothing is redrawn.
let srcPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let canvas = 1024
let body: CGFloat = 824        // target solid-body size (Apple grid)
let bodyOrigin: CGFloat = 100  // target body position (Apple grid)
guard let src = NSImage(contentsOfFile:srcPath) else { fatalError("missing source") }

// The source body is a near-full-bleed rounded square centered on the canvas
// (measured 1021x1021 at (2,2) for the 1024 artwork). Scale the whole image
// so the body lands exactly on the Apple grid; centering is symmetric.
let srcBody: CGFloat = 1021
let srcBodyOffset: CGFloat = 2
let f = body / srcBody
let drawSize = CGFloat(canvas) * f
let drawOrigin = bodyOrigin - srcBodyOffset * f

let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:canvas,pixelsHigh:canvas,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
let ctx = NSGraphicsContext(bitmapImageRep:rep)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
NSColor.clear.setFill(); NSRect(x:0,y:0,width:canvas,height:canvas).fill()
src.draw(in:NSRect(x:drawOrigin,y:drawOrigin,width:drawSize,height:drawSize),from:.zero,operation:.sourceOver,fraction:1)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:outPath))
print("conformed: body \(Int(body)) at (\(Int(bodyOrigin)),\(Int(bodyOrigin))), scale \(String(format:"%.4f",f)), orientation unchanged")
