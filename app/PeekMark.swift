import AppKit

// Original Pe monogram. The e's upper counter forms an eyelid around its pupil.
enum PeekMark {
    static func draw(in rect: NSRect, ink: NSColor, pupil: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let scale = min(rect.width / 760,rect.height / 570)
        let transform = AffineTransform(translationByX:rect.midX-520*scale,byY:rect.midY-500*scale)
        var scaled = transform; scaled.scale(scale); (scaled as NSAffineTransform).concat()
        ink.setStroke()
        let p = NSBezierPath()
        p.move(to:NSPoint(x:205,y:265)); p.line(to:NSPoint(x:205,y:735)); p.line(to:NSPoint(x:350,y:735))
        p.curve(to:NSPoint(x:350,y:480),controlPoint1:NSPoint(x:540,y:735),controlPoint2:NSPoint(x:540,y:480))
        p.line(to:NSPoint(x:205,y:480)); p.lineWidth = 78; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
        let e = NSBezierPath()
        e.move(to:NSPoint(x:827,y:353))
        e.curve(to:NSPoint(x:558,y:466),controlPoint1:NSPoint(x:704,y:255),controlPoint2:NSPoint(x:558,y:326))
        e.curve(to:NSPoint(x:850,y:466),controlPoint1:NSPoint(x:558,y:650),controlPoint2:NSPoint(x:839,y:650))
        e.line(to:NSPoint(x:561,y:466)); e.lineWidth = 64; e.lineCapStyle = .round; e.lineJoinStyle = .round; e.stroke()
        pupil.setFill(); NSBezierPath(ovalIn:NSRect(x:687,y:500,width:52,height:52)).fill()
    }
    // Bundle lookup plus a repo-relative fallback: test binaries run unbundled,
    // so Bundle.main has no Resources and previously fell through to a different
    // drawing. Both paths must resolve to the SAME shipped PNG.
    private static func resourceURL(_ name: String,_ ext: String) -> URL? {
        if let url = Bundle.main.url(forResource:name,withExtension:ext) { return url }
        var dir = URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/\(name).\(ext)")
            if FileManager.default.fileExists(atPath:candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
    static func image(size: NSSize = NSSize(width:27,height:20),template: Bool = true) -> NSImage {
        if let url = resourceURL("MenuBarIcon-64","png"),let image = NSImage(contentsOf:url) {
            image.size = size
            image.isTemplate = template
            image.accessibilityDescription = "Peek"
            return image
        }
        let image = NSImage(size:size,flipped:false) { rect in
            draw(in:rect.insetBy(dx:1,dy:1),ink:template ? .black:.labelColor,pupil:template ? .black:.labelColor); return true
        }
        image.isTemplate = template; image.accessibilityDescription = "Peek"; return image
    }
}
