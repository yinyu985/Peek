import AppKit

// A control for the real window, never a screenshot of its contents. All panel
// lifecycle work stays on the main queue; HoverController owns dwell timing.
final class ShadeBarController {
    private var panels: [UUID:NSPanel] = [:]
    var onReveal: ((UUID)->Void)?
    func update(_ snapshot: HoverWindow) {
        guard snapshot.hidden,snapshot.onCurrentSpace,let name = snapshot.shadeTitle,
              let strip = snapshot.compressedFrame else { remove(snapshot.id); return }
        let panel: NSPanel
        if let existing = panels[snapshot.id] { panel = existing }
        else {
            panel = NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.collectionBehavior = [.transient,.ignoresCycle]
            let control = ShadeBarView(frame:.zero)
            control.reveal = { [weak self] in self?.onReveal?(snapshot.id) }
            panel.contentView = control; panels[snapshot.id] = panel
        }
        let view = panel.contentView as! ShadeBarView
        view.title = name
        view.icon = snapshot.pid.flatMap { NSRunningApplication(processIdentifier:$0)?.icon }
        view.toolTip = L("{0} — 悬停或点击恢复窗口",name)
        view.setAccessibilityLabel(L("{0}，恢复窗口",name))
        let clipped = strip.intersection(snapshot.screen)
        guard !clipped.isNull,clipped.width > 0 else { remove(snapshot.id); return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        panel.setFrame(CGRect(x:clipped.minX,y:top-clipped.maxY,width:clipped.width,height:clipped.height),display:true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }
    func remove(_ id: UUID) { panels.removeValue(forKey:id)?.close() }
    func removeAll() { for id in Array(panels.keys) { remove(id) } }
    deinit { removeAll() }
}
private final class ShadeBarView: NSView {
    var title = ""
    var icon: NSImage?
    var reveal: (()->Void)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityPerformPress() -> Bool { reveal?(); return true }
    override func mouseUp(with event: NSEvent) { reveal?() }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:5,yRadius:5)
        NSColor(calibratedWhite:0.13,alpha:0.98).setFill(); outline.fill()
        NSColor(calibratedWhite:0.34,alpha:1).setStroke(); outline.lineWidth = 1; outline.stroke()
        icon?.draw(in:NSRect(x:9,y:(bounds.height-14)/2,width:14,height:14))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in:NSRect(x:30,y:(bounds.height-15)/2,width:max(0,bounds.width-57),height:15),withAttributes:[
            .font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor(calibratedWhite:0.91,alpha:1),.paragraphStyle:paragraph])
        if bounds.width > 60 {
            let x = bounds.width-14,y = bounds.midY
            let chevron = NSBezierPath(); chevron.move(to:NSPoint(x:x-3,y:y+1)); chevron.line(to:NSPoint(x:x,y:y-2)); chevron.line(to:NSPoint(x:x+3,y:y+1))
            chevron.lineWidth = 1.2; NSColor(calibratedWhite:0.64,alpha:1).setStroke(); chevron.stroke()
        }
    }
}
