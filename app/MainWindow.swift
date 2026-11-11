import AppKit
import UniformTypeIdentifiers
import ApplicationServices
import ServiceManagement

private func label(_ value: String,_ size: CGFloat = 13,_ weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(labelWithString:value)
    field.font = .systemFont(ofSize:size,weight:weight)
    field.lineBreakMode = .byTruncatingTail
    // Sidebar and row labels are strictly single-line; never wrap.
    field.usesSingleLineMode = true; field.cell?.wraps = false
    return field
}
// Obsidian palette (direction C) with ONE neutral base tone shared by the
// titlebar, sidebar and content, so no region reads as a different colour.
private enum Ink {
    static let base = NSColor(srgbRed:0.086,green:0.094,blue:0.110,alpha:1)
    static let sidebar = NSColor(srgbRed:0.110,green:0.120,blue:0.139,alpha:1)
    static let rule = NSColor(srgbRed:0.173,green:0.184,blue:0.204,alpha:1)
    static let accent = NSColor(srgbRed:0.478,green:0.654,blue:1,alpha:1)
    static let accentText = NSColor(srgbRed:0.655,green:0.765,blue:1,alpha:1)
    static let hi = NSColor(srgbRed:0.902,green:0.925,blue:0.973,alpha:1)
    static let mid = NSColor(srgbRed:0.92,green:0.947,blue:1,alpha:0.62)
    static let low = NSColor(srgbRed:0.92,green:0.947,blue:1,alpha:0.34)
}
private final class WindowSurface: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Ink.base.setFill(); bounds.fill() }
}
private final class SidebarSurface: NSView {
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Ink.sidebar.setFill(); bounds.fill() }
}
private final class SectionScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView, documentView.frame.height > contentView.bounds.height + 0.5 else { return }
        super.scrollWheel(with: event)
    }
}
private final class GlassCard: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect:NSRect(x:0.5,y:0.5,width:bounds.width-1,height:bounds.height-1),xRadius:7,yRadius:7)
        NSColor.white.withAlphaComponent(0.04).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.08).setStroke(); path.lineWidth = 1; path.stroke()
    }
}
private final class TopAlignedStack: NSStackView {
    override var isFlipped: Bool { true }
}
// Actions, the direction picker and directory links share one text-only style.
// NSButton still supplies keyboard activation and accessibility, but never a bezel.
private class ActionButton: NSButton {
    override var isOpaque: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top:0,left:0,bottom:0,right:0) }
    var showsDisclosure: Bool { false }
    var isNavigation = false
    var isChip = false
    private var hovered = false
    var actionBlock: (()->Void)?
    init(_ title: String, action: @escaping ()->Void) {
        super.init(frame:.zero); self.title = title; isBordered = false; focusRingType = .none
        setButtonType(.momentaryPushIn); font = .systemFont(ofSize:12)
        actionBlock = action; target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:12)]).width
        return NSSize(width:ceil(width)+16+(image == nil ? 0:18)+(showsDisclosure ? 20:0),height:28)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = isNavigation && state == .on
        let radius: CGFloat = isNavigation ? 6:5
        if selected {
            let pill = NSBezierPath(roundedRect:NSRect(x:0.5,y:0.5,width:bounds.width-1,height:bounds.height-1),xRadius:radius,yRadius:radius)
            NSGradient(colors:[Ink.accent.withAlphaComponent(0.16),Ink.accent.withAlphaComponent(0.05)])?.draw(in:pill,angle:-90)
            Ink.accent.withAlphaComponent(0.38).setStroke(); pill.lineWidth = 1; pill.stroke()
        } else if isChip {
            let pill = NSBezierPath(roundedRect:NSRect(x:0.5,y:0.5,width:bounds.width-1,height:bounds.height-1),xRadius:radius,yRadius:radius)
            Ink.accent.withAlphaComponent(isHighlighted ? 0.18:hovered ? 0.14:0.10).setFill(); pill.fill()
            Ink.accent.withAlphaComponent(isEnabled ? 0.45:0.22).setStroke(); pill.lineWidth = 1; pill.stroke()
        }
        let color: NSColor
        if !isEnabled { color = Ink.low }
        else if selected { color = Ink.hi }
        else if isChip { color = hovered || isHighlighted ? Ink.hi : Ink.accentText }
        else { color = hovered || isHighlighted ? Ink.hi : Ink.mid }
        let size = font?.pointSize ?? 12
        let typeface = selected ? NSFont.systemFont(ofSize:size,weight:.semibold) : font ?? NSFont.systemFont(ofSize:size)
        let attrs: [NSAttributedString.Key:Any] = [.font:typeface,.foregroundColor:color]
        let textSize = (title as NSString).size(withAttributes:attrs)
        let iconSide: CGFloat = isNavigation ? 16:12
        let imageWidth: CGFloat = image == nil ? 0:iconSide+(isNavigation ? 8:6)
        let x = showsDisclosure || alignment == .left ? (isNavigation ? 12:10):max(4,(bounds.width-textSize.width-imageWidth)/2)
        if let image {
            let tinted = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[color])) ?? image
            tinted.draw(in:NSRect(x:x,y:bounds.midY-iconSide/2,width:iconSide,height:iconSide),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        (title as NSString).draw(at:NSPoint(x:x+imageWidth,y:bounds.midY-textSize.height/2),withAttributes:attrs)
        if showsDisclosure {
            let arrow = NSBezierPath(); let x = bounds.maxX-11; let y = bounds.midY
            let down: CGFloat = isFlipped ? 1:-1
            arrow.move(to:NSPoint(x:x-3,y:y-down)); arrow.line(to:NSPoint(x:x,y:y+2*down)); arrow.line(to:NSPoint(x:x+3,y:y-down)); arrow.lineWidth = 1.2
            color.setStroke(); arrow.stroke()
        }
        if window?.firstResponder === self,window?.isKeyWindow == true,NSApp.isFullKeyboardAccessEnabled {
            let underline = NSBezierPath(); underline.move(to:NSPoint(x:x+imageWidth,y:4)); underline.line(to:NSPoint(x:x+imageWidth+textSize.width,y:4))
            Ink.accentText.withAlphaComponent(0.8).setStroke(); underline.stroke()
        }
    }
    @objc private func invoke() {
        // Starting a sheet inside the action must not leave the origin pressed.
        highlight(false)
        if !isNavigation { state = .off }
        actionBlock?()
    }
}
// Self-drawn edge picker. Deliberately NOT NSMenu: the direction choice must
// match the app's own surfaces, not the system menu chrome.
private final class PickerSurface: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect:NSRect(x:0.5,y:0.5,width:bounds.width-1,height:bounds.height-1),xRadius:6,yRadius:6)
        NSColor(srgbRed:0.129,green:0.137,blue:0.157,alpha:0.98).setFill(); path.fill()
        NSColor(srgbRed:0.216,green:0.227,blue:0.251,alpha:1).setStroke(); path.lineWidth = 1; path.stroke()
    }
}
private final class PickerRow: NSButton {
    var hovered = false
    var selectedEdge = false
    override var isOpaque: Bool { false }
    init(_ title: String,selected: Bool) {
        super.init(frame:.zero); self.title = title; selectedEdge = selected
        isBordered = false; focusRingType = .none; setButtonType(.momentaryChange)
        font = .systemFont(ofSize:12)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || selectedEdge {
            let pill = NSBezierPath(roundedRect:NSRect(x:4,y:2,width:bounds.width-8,height:bounds.height-4),xRadius:5,yRadius:5)
            (selectedEdge ? Ink.accent.withAlphaComponent(0.16):NSColor.white.withAlphaComponent(0.07)).setFill(); pill.fill()
        }
        let color: NSColor = selectedEdge ? Ink.hi:hovered ? Ink.hi:Ink.mid
        let typeface = NSFont.systemFont(ofSize:12,weight:selectedEdge ? .semibold:.regular)
        let attrs: [NSAttributedString.Key:Any] = [.font:typeface,.foregroundColor:color]
        let size = (title as NSString).size(withAttributes:attrs)
        (title as NSString).draw(at:NSPoint(x:14,y:(bounds.height-size.height)/2),withAttributes:attrs)
        if selectedEdge {
            let dot = NSBezierPath(ovalIn:NSRect(x:bounds.width-18,y:bounds.midY-2.5,width:5,height:5))
            Ink.accent.setFill(); dot.fill()
        }
    }
}
// Hand-drawn stepper: a clear editable box between two glyph buttons, so it
// reads as "you can type here" without borrowing system control chrome.
private final class TimingFieldBox: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect:NSRect(x:0.5,y:0.5,width:bounds.width-1,height:bounds.height-1),xRadius:6,yRadius:6)
        NSColor.white.withAlphaComponent(0.05).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke(); path.lineWidth = 1; path.stroke()
    }
}
private final class StepGlyphButton: NSButton {
    var plus = true
    var hovered = false
    var actionBlock: (()->Void)?
    init(plus: Bool, action: @escaping ()->Void) {
        super.init(frame:.zero); self.plus = plus; actionBlock = action
        isBordered = false; focusRingType = .none; setButtonType(.momentaryChange)
        target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { actionBlock?() }
    override var isOpaque: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect:NSRect(x:1,y:1,width:bounds.width-2,height:bounds.height-2),xRadius:6,yRadius:6)
        NSColor.white.withAlphaComponent(hovered || isHighlighted ? 0.12:0.06).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke(); path.lineWidth = 1; path.stroke()
        let ink = !isEnabled ? Ink.low:(hovered || isHighlighted ? Ink.hi:Ink.mid)
        ink.setStroke()
        let glyph = NSBezierPath(); glyph.lineWidth = 1.4; glyph.lineCapStyle = .round
        let cx = bounds.midX, cy = bounds.midY, arm: CGFloat = 3.5
        glyph.move(to:NSPoint(x:cx-arm,y:cy)); glyph.line(to:NSPoint(x:cx+arm,y:cy))
        if plus { glyph.move(to:NSPoint(x:cx,y:cy-arm)); glyph.line(to:NSPoint(x:cx,y:cy+arm)) }
        glyph.stroke()
    }
}
private enum TimingSetting: String, CaseIterable {
    case showDelay, hideDelay, showDuration, hideDuration
    var title: String {
        switch self { case .showDelay: return "停留后展开"; case .hideDelay: return "离开后收起"; case .showDuration: return "展开时长"; case .hideDuration: return "收起时长" }
    }
    var isDelay: Bool { self == .showDelay || self == .hideDelay }
    var step: Double { isDelay ? 0.1:0.01 }
    var limit: Double { self == .showDelay ? 5:self == .hideDelay ? 10:1 }
    func value(in settings: HoverSettings) -> Double {
        switch self {
        case .showDelay: return settings.showDelay
        case .hideDelay: return settings.hideDelay
        case .showDuration: return settings.showDuration
        case .hideDuration: return settings.hideDuration
        }
    }
    func normalized(_ value: Double) -> Double {
        let scale = isDelay ? 10.0:100.0
        return max(0,min(limit,(value*scale).rounded()/scale))
    }
    func save(_ value: Double,to store: BindingStore) throws {
        switch self {
        case .showDelay: try store.configureHover(showDelay:value)
        case .hideDelay: try store.configureHover(hideDelay:value)
        case .showDuration: try store.configureHover(showDuration:value)
        case .hideDuration: try store.configureHover(hideDuration:value)
        }
    }
}
private final class DropdownButton: ActionButton {
    override var showsDisclosure: Bool { true }
}
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: BindingStore
    let hotkeys: GlobalShortcutManager
    private let mainPage = NSView()
    private let settingsPage = NSView()
    private let generalPage = NSView()
    private let aboutPage = NSView()
    private let rows = TopAlignedStack()
    private let settingsRows = TopAlignedStack()
    private let generalRows = TopAlignedStack()
    private let settingsError = label("",11)
    private var navigationButtons: [NSButton] = []
    private(set) var currentSection = 0
    private var recorderButton: NSButton?
    private var shortcutButtons: [UUID:NSButton] = [:]
    private var recordingTimer: Timer?
    private var recordingPulse = false
    var onPrepareChange: ((UUID,@escaping (Bool)->Void)->Void)?
    var onBindingsChanged: (()->Void)?
    var onRecordingChanged: ((Bool)->Void)?
    var onMenuBarIconChanged: (()->Void)?
    private(set) var brandIcon: NSImageView!
    private var statusLabels: [UUID:NSTextField] = [:]
    private var bindingStatus: [UUID:(String,Bool)] = [:]
    private var pendingDirectionBinding: AppBinding?
    private(set) var directionPanel: NSPanel?
    private var directionMonitor: Any?
    func closeOptions() { closeDirections() }
    private var permissionButton: ActionButton!
    private var permissionTimer: Timer?
    private var monitor: Any?
    private var recordingID: UUID?
    private(set) var lastPanel: NSOpenPanel?
    private var sections: [NSView] { [mainPage,settingsPage,generalPage,aboutPage] }
    init(store: BindingStore,hotkeys: GlobalShortcutManager) {
        self.store = store; self.hotkeys = hotkeys
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:340),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.contentView = WindowSurface(frame:NSRect(x:0,y:0,width:600,height:340))
        window.title = "Peek"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named:.darkAqua)
        window.backgroundColor = Ink.base
        // Fixed size: the window is a fixed panel, the app list scrolls instead.
        window.isReleasedWhenClosed = false
        // The panel is transient. Restorable windows made macOS prompt to restore
        // them after a forced quit, which blocked launch and left openWindow nil.
        window.isRestorable = false
        super.init(window:window); window.delegate = self; window.center()
        build(); window.setContentSize(NSSize(width:600,height:340)); reload(); showApps()
        let timer = Timer(timeInterval:1,repeats:true) { [weak self] _ in
            guard let self,self.window?.isVisible == true else { return }
            self.permissionButton?.isHidden = AXIsProcessTrusted()
        }
        RunLoop.main.add(timer,forMode:.common); permissionTimer = timer
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        permissionTimer?.invalidate(); recordingTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
    private func build() {
        guard let root = window?.contentView else { return }
        let sidebar = SidebarSurface(); sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo:root.leadingAnchor),sidebar.topAnchor.constraint(equalTo:root.topAnchor),sidebar.bottomAnchor.constraint(equalTo:root.bottomAnchor),sidebar.widthAnchor.constraint(equalToConstant:148)
        ])
        for page in sections {
            page.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor),page.trailingAnchor.constraint(equalTo:root.trailingAnchor),
                page.topAnchor.constraint(equalTo:root.topAnchor),page.bottomAnchor.constraint(equalTo:root.bottomAnchor)
            ])
        }
        // Single hairline between sidebar and content.
        let rule = NSBox(); rule.boxType = .custom; rule.fillColor = Ink.rule; rule.borderColor = Ink.rule
        rule.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor),rule.topAnchor.constraint(equalTo:root.topAnchor),
            rule.bottomAnchor.constraint(equalTo:root.bottomAnchor),rule.widthAnchor.constraint(equalToConstant:1)
        ])
        // Top-left brand mark: the plain P/e letters only — no plate, no wordmark.
        brandIcon = NSImageView(); brandIcon.image = PeekMark.image(size:NSSize(width:84,height:63),template:true)
        brandIcon.contentTintColor = Ink.hi; brandIcon.imageScaling = .scaleProportionallyUpOrDown
        brandIcon.setAccessibilityLabel("Peek")
        brandIcon.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(brandIcon)
        NSLayoutConstraint.activate([
            brandIcon.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:40),brandIcon.centerXAnchor.constraint(equalTo:sidebar.centerXAnchor),
            brandIcon.widthAnchor.constraint(equalToConstant:84),brandIcon.heightAnchor.constraint(equalToConstant:63)
        ])
        let apps = ActionButton("应用") { [weak self] in self?.showApps() }
        apps.image = NSImage(systemSymbolName:"square.grid.2x2",accessibilityDescription:nil)
        let settings = ActionButton("收放") { [weak self] in self?.showSettings() }
        settings.image = NSImage(systemSymbolName:"arrow.right.to.line",accessibilityDescription:nil)
        let general = ActionButton("通用") { [weak self] in self?.showGeneral() }
        general.image = NSImage(systemSymbolName:"gearshape",accessibilityDescription:nil)
        let about = ActionButton("关于") { [weak self] in self?.navigate(to:3) }
        about.image = NSImage(systemSymbolName:"info.circle",accessibilityDescription:nil)
        about.setAccessibilityLabel("关于")
        for button in [apps,settings,general,about] {
            button.isNavigation = true; button.alignment = .left; button.font = .systemFont(ofSize:13)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant:32).isActive = true
            button.widthAnchor.constraint(equalToConstant:124).isActive = true
        }
        apps.setAccessibilityLabel("应用"); settings.setAccessibilityLabel("收放"); general.setAccessibilityLabel("通用")
        navigationButtons = [apps,settings,general,about]
        let nav = NSStackView(views:[apps,settings,general,about]); nav.orientation = .vertical; nav.alignment = .leading; nav.spacing = 4
        nav.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(nav)
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo:brandIcon.bottomAnchor,constant:18),nav.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:12)
        ])
        let add = ActionButton("新增应用") { [weak self] in self?.addApplication() }
        add.image = NSImage(systemSymbolName:"plus",accessibilityDescription:nil)
        add.keyEquivalent = "n"; add.keyEquivalentModifierMask = .command
        add.isChip = true; add.setContentCompressionResistancePriority(.required,for:.horizontal)
        add.setAccessibilityLabel("新增应用")
        add.widthAnchor.constraint(greaterThanOrEqualToConstant:96).isActive = true
        let header = NSStackView(views:[label("应用",20,.semibold),NSView(),add]); header.orientation = .horizontal
        for stack in [rows,settingsRows,generalRows] { stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10 }
        rows.spacing = 8
        for error in [settingsError] { error.textColor = .systemRed; error.maximumNumberOfLines = 3; error.lineBreakMode = .byWordWrapping; error.isHidden = true }
        permissionButton = ActionButton("开启窗口控制") { [weak self] in self?.openAccessibility() }
        permissionButton.isChip = true
        permissionButton.isHidden = AXIsProcessTrusted()
        buildSection(mainPage,views:[header,rows,permissionButton])
        buildSection(settingsPage,views:[label("收放",20,.semibold),settingsRows])
        buildSection(generalPage,views:[label("通用",20,.semibold),settingsCard(generalRows)])
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"
        let author = Bundle.main.object(forInfoDictionaryKey:"PeekAuthor") as? String ?? "待填写"
        let versionLabel = label("版本：\(version)",12)
        versionLabel.textColor = Ink.mid
        let authorLabel = label("作者：\(author)",12)
        authorLabel.textColor = Ink.mid
        if let address = Bundle.main.object(forInfoDictionaryKey:"PeekAuthorURL") as? String,let url = URL(string:address) {
            let text = NSMutableAttributedString(string:authorLabel.stringValue,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:Ink.mid])
            let range = (authorLabel.stringValue as NSString).range(of:author,options:.backwards)
            text.addAttributes([.link:url,.foregroundColor:Ink.accentText,.underlineStyle:NSUnderlineStyle.single.rawValue],range:range)
            authorLabel.allowsEditingTextAttributes = true; authorLabel.isSelectable = true
            authorLabel.attributedStringValue = text; authorLabel.toolTip = "作者 GitHub："+address
        }
        let aboutRows = TopAlignedStack(views:[label("Peek",17,.semibold),label("用快捷键或屏幕边缘 Hover 收起、唤出窗口。",12),versionLabel,authorLabel])
        aboutRows.orientation = .vertical; aboutRows.alignment = .leading; aboutRows.spacing = 12
        buildSection(aboutPage,views:[label("关于",20,.semibold),settingsCard(aboutRows)])
    }
    // The same outer width as application cards, with a single shared inset.
    private func settingsCard(_ content: NSStackView) -> NSView {
        let card = GlassCard(); card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo:card.topAnchor,constant:10),
            content.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-10),
            content.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:12),
            content.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-12)
        ])
        return card
    }
    private func buildSection(_ page: NSView,views: [NSView]) {
        guard let header = views.first else { return }
        let scroll = SectionScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
        header.translatesAutoresizingMaskIntoConstraints = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(header); page.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo:page.topAnchor,constant:40),header.leadingAnchor.constraint(equalTo:page.leadingAnchor,constant:20),header.trailingAnchor.constraint(equalTo:page.trailingAnchor,constant:-20),
            scroll.topAnchor.constraint(equalTo:header.bottomAnchor,constant:18),scroll.leadingAnchor.constraint(equalTo:page.leadingAnchor,constant:20),
            scroll.trailingAnchor.constraint(equalTo:page.trailingAnchor,constant:-20),scroll.bottomAnchor.constraint(equalTo:page.bottomAnchor,constant:-20)
        ])
        let content = TopAlignedStack(views:Array(views.dropFirst()))
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo:scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo:scroll.contentView.topAnchor)
        ])
        for view in views.dropFirst() { view.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true }
    }
    @objc func showApps() { navigate(to:0) }
    @objc func showSettings() { navigate(to:1) }
    @objc func showGeneral() { reloadGeneral(); navigate(to:2) }
    private func navigate(to index: Int) {
        window?.makeFirstResponder(nil); stopRecording(); closeOptions()
        currentSection = index
        for (i,page) in sections.enumerated() { page.isHidden = i != index }
        for (i,button) in navigationButtons.enumerated() {
            button.state = i == index ? .on:.off; button.needsDisplay = true
        }
    }
    private func addSwitchRow(_ title: String,isOn: Bool,action: Selector,to stack: NSStackView) {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let caption = label(title,13); caption.textColor = Ink.mid
        let toggle = NSSwitch(); toggle.state = isOn ? .on:.off
        toggle.target = self; toggle.action = action
        toggle.setAccessibilityLabel(title)
        caption.translatesAutoresizingMaskIntoConstraints = false; toggle.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(caption); row.addSubview(toggle); stack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo:stack.widthAnchor),row.heightAnchor.constraint(equalToConstant:36),
            caption.leadingAnchor.constraint(equalTo:row.leadingAnchor),caption.centerYAnchor.constraint(equalTo:row.centerYAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo:toggle.leadingAnchor,constant:-12),
            toggle.trailingAnchor.constraint(equalTo:row.trailingAnchor),toggle.centerYAnchor.constraint(equalTo:row.centerYAnchor)
        ])
    }
    private func reloadSettings() {
        for view in settingsRows.arrangedSubviews { settingsRows.removeArrangedSubview(view); view.removeFromSuperview() }
        let settings = store.hoverSettings
        let rhythmRows = NSStackView(); rhythmRows.orientation = .vertical; rhythmRows.alignment = .leading; rhythmRows.spacing = 6
        let rhythm = settingsCard(rhythmRows)
        addSwitchRow("自动收放",isOn:settings.enabled,action:#selector(hoverChanged(_:)),to:rhythmRows)
        for setting in TimingSetting.allCases {
            let title = setting.title, value = setting.value(in:settings)
            let enabled = !setting.isDelay || settings.enabled
            let caption = label(title,12); caption.textColor = Ink.mid
            let minus = StepGlyphButton(plus:false) { [weak self] in self?.stepTiming(setting,-setting.step) }
            minus.setAccessibilityLabel(title+"减少 \(setting.step) 秒")
            let plus = StepGlyphButton(plus:true) { [weak self] in self?.stepTiming(setting,setting.step) }
            plus.setAccessibilityLabel(title+"增加 \(setting.step) 秒")
            minus.isEnabled = enabled; plus.isEnabled = enabled
            // Editable box: obvious enough that typing is expected, styled by us.
            let box = TimingFieldBox(); box.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(string:String(format:"%.2f",value))
            field.alignment = .center; field.isBordered = false; field.drawsBackground = false
            field.focusRingType = .none; field.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium)
            field.textColor = value > 0 ? Ink.hi:Ink.low
            field.identifier = NSUserInterfaceItemIdentifier(setting.rawValue)
            field.isEnabled = enabled
            field.target = self; field.action = #selector(timingFieldChanged(_:)); field.cell?.sendsActionOnEndEditing = true
            field.setAccessibilityLabel(title+"，秒")
            field.toolTip = "0–\(Int(setting.limit)) 秒；步进 \(setting.step) 秒"
            field.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:4),field.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-4),
                field.centerYAnchor.constraint(equalTo:box.centerYAnchor),box.widthAnchor.constraint(equalToConstant:44),box.heightAnchor.constraint(equalToConstant:22)
            ])
            for control in [minus,plus] {
                control.translatesAutoresizingMaskIntoConstraints = false
                control.widthAnchor.constraint(equalToConstant:24).isActive = true
                control.heightAnchor.constraint(equalToConstant:22).isActive = true
            }
            let unit = label("秒",11); unit.textColor = Ink.low
            let row = NSStackView(views:[caption,NSView(),minus,box,plus,unit])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 5
            row.translatesAutoresizingMaskIntoConstraints = false
            rhythmRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo:rhythmRows.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant:36).isActive = true
        }
        settingsRows.addArrangedSubview(rhythm)
        rhythm.widthAnchor.constraint(equalTo:settingsRows.widthAnchor).isActive = true
        rhythmRows.addArrangedSubview(settingsError)
        settingsError.widthAnchor.constraint(equalTo:rhythmRows.widthAnchor).isActive = true
    }
    private func reloadGeneral() {
        for view in generalRows.arrangedSubviews { generalRows.removeArrangedSubview(view); view.removeFromSuperview() }
        let state = SMAppService.mainApp.status
        addSwitchRow("开机自启",isOn:state == .enabled || state == .requiresApproval,action:#selector(loginChanged(_:)),to:generalRows)
        addSwitchRow("在菜单栏显示图标",isOn:store.menuBarIconVisible,action:#selector(menuBarIconChanged(_:)),to:generalRows)
        if state == .requiresApproval {
            let hint = label("请在系统设置的登录项中允许 Peek。",11); hint.textColor = .secondaryLabelColor; generalRows.addArrangedSubview(hint)
            let openLogin = ActionButton("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
            openLogin.isChip = true; generalRows.addArrangedSubview(openLogin)
        }
    }
    @objc private func timingFieldChanged(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue,let setting = TimingSetting(rawValue:key) else { return }
        guard let typed = Double(sender.stringValue.trimmingCharacters(in:.whitespaces)),typed.isFinite,typed >= 0,typed <= setting.limit else {
            sender.stringValue = String(format:"%.2f",setting.value(in:store.hoverSettings))
            setSettingsError("\(setting.title)为 0–\(Int(setting.limit)) 秒。"); return
        }
        do {
            try setting.save(setting.normalized(typed),to:store)
            onBindingsChanged?(); setSettingsError("")
        } catch { setSettingsError(error.localizedDescription) }
        let saved = setting.value(in:store.hoverSettings)
        sender.stringValue = String(format:"%.2f",saved)
        sender.textColor = saved > 0 ? Ink.hi:Ink.low
    }
    @objc private func hoverChanged(_ sender: NSSwitch) {
        do { try store.configureHover(enabled:sender.state == .on); onBindingsChanged?(); setSettingsError(""); reloadSettings() }
        catch { setSettingsError(error.localizedDescription); reloadSettings() }
    }
    @objc private func menuBarIconChanged(_ sender: NSSwitch) {
        store.setMenuBarIconVisible(sender.state == .on); onMenuBarIconChanged?(); reloadGeneral()
    }
    @objc private func loginChanged(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            output("login_item_changed",["status":SMAppService.mainApp.status.rawValue])
        } catch {
            let alert = NSAlert(); alert.messageText = "无法更改开机自启"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
        reloadGeneral()
    }
    // No status/footer region. Errors belong to the edited row or a transient alert.
    func setStatus(_ message: String) {
        guard !message.isEmpty else { return }
        if let id = recordingID {
            statusLabels[id]?.stringValue = message; statusLabels[id]?.isHidden = false; return
        }
        guard let window,window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = message
        alert.beginSheetModal(for:window)
    }
    private func setSettingsError(_ message: String) { settingsError.stringValue = message; settingsError.toolTip = message; settingsError.isHidden = message.isEmpty }
    func reload() {
        let section = currentSection
        stopRecording(); shortcutButtons.removeAll(); statusLabels.removeAll(); onBindingsChanged?()
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        rows.isHidden = store.bindings.isEmpty
        for binding in store.bindings {
            let icon = NSImageView(image:NSWorkspace.shared.icon(forFile:binding.resolvedURL?.path ?? binding.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant:28).isActive = true; icon.heightAnchor.constraint(equalToConstant:28).isActive = true
            let name = label(binding.name,13.5,.medium); name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            let title = NSStackView(views:[name]); title.orientation = .vertical; title.alignment = .leading; title.spacing = 1
            let shortcut = ActionButton(binding.shortcut?.title ?? "录制快捷键") { [weak self] in self?.record(binding.id) }
            shortcutButtons[binding.id] = shortcut; shortcut.font = .monospacedSystemFont(ofSize:12,weight:.medium); shortcut.isChip = true
            shortcut.widthAnchor.constraint(greaterThanOrEqualToConstant:52).isActive = true
            shortcut.setAccessibilityLabel("\(binding.name)：\(binding.shortcut?.title ?? "录制快捷键")")
            let remove = ActionButton("") { [weak self] in self?.remove(binding.id) }
            remove.image = NSImage(systemSymbolName:"xmark",accessibilityDescription:"删除 \(binding.name)")
            remove.setAccessibilityLabel("删除 \(binding.name)"); remove.toolTip = "删除绑定"
            remove.widthAnchor.constraint(equalToConstant:24).isActive = true
            let direction = DropdownButton(binding.selectedEdge.title,action:{})
            direction.isChip = true; direction.widthAnchor.constraint(equalToConstant:86).isActive = true
            direction.setAccessibilityLabel("收起方向："+binding.selectedEdge.title)
            direction.actionBlock = { [weak self,weak direction] in if let direction { self?.showDirections(binding,from:direction) } }
            for control in [shortcut,remove,direction] {
                control.translatesAutoresizingMaskIntoConstraints = false; control.heightAnchor.constraint(equalToConstant:28).isActive = true
                control.setContentCompressionResistancePriority(.required,for:.horizontal)
            }
            let topRow = NSStackView(views:[icon,title,NSView(),direction,shortcut,remove]); topRow.orientation = .horizontal; topRow.spacing = 10
            let message = bindingStatus[binding.id].flatMap{$0.1 ? $0.0:nil} ?? hotkeys.errors[binding.id] ?? ""
            let detail = label(message,11); detail.maximumNumberOfLines = 3; detail.lineBreakMode = .byWordWrapping
            detail.textColor = .systemRed; detail.isHidden = message.isEmpty; statusLabels[binding.id] = detail
            let card = GlassCard(); card.translatesAutoresizingMaskIntoConstraints = false
            let inner = NSStackView(views:[topRow,detail]); inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = 7
            inner.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.topAnchor.constraint(equalTo:card.topAnchor,constant:10),inner.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:12),
                inner.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-12),inner.bottomAnchor.constraint(lessThanOrEqualTo:card.bottomAnchor,constant:-10),
                topRow.widthAnchor.constraint(equalTo:inner.widthAnchor),detail.widthAnchor.constraint(equalTo:inner.widthAnchor)
            ])
            rows.addArrangedSubview(card); card.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive = true
        }
        reloadSettings(); reloadGeneral()
        setStatus(store.loadError ?? (hotkeys.errors.isEmpty ? "":"部分快捷键被占用，点击对应快捷键重新设置。"))
        navigate(to:section)
    }
    private func stepTiming(_ setting: TimingSetting,_ delta: Double) {
        // Commit a live text edit before changing its value or replacing the row.
        window?.makeFirstResponder(nil)
        let next = setting.normalized(setting.value(in:store.hoverSettings)+delta)
        do {
            try setting.save(next,to:store)
            onBindingsChanged?(); setSettingsError("")
        } catch { setSettingsError(error.localizedDescription) }
        reloadSettings()
    }
    static func applicationPanel() -> NSOpenPanel {
        let panel = NSOpenPanel(); panel.title = "选择应用"; panel.prompt = "添加"
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseFiles = true
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false; panel.directoryURL = URL(fileURLWithPath:"/Applications",isDirectory:true)
        return panel
    }
    @objc func addApplication() {
        guard let window,window.attachedSheet == nil else { return }
        showApps(); setStatus("")
        let panel = Self.applicationPanel(); lastPanel = panel
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self else { return }; self.lastPanel = nil
            guard result == .OK,let url = panel.url else { return }
            do { let id = try self.store.add(url); self.reload(); DispatchQueue.main.async { self.record(id) } }
            catch { self.setStatus(error.localizedDescription) }
        }
    }
    private func prepare(_ id: UUID, action: @escaping ()->Void) {
        stopRecording()
        if let onPrepareChange { onPrepareChange(id) { [weak self] success in
            if success { action() } else { self?.setStatus("窗口尚未恢复，暂时不能更改绑定。请稍后重试。") }
        } } else { action() }
    }
    private func remove(_ id: UUID) {
        prepare(id) { [weak self] in
            guard let self else { return }
            do { try self.store.remove(id); self.hotkeys.reload(self.store.bindings); self.reload() }
            catch { self.setStatus(error.localizedDescription) }
        }
    }
    func setBindingStatus(_ id: UUID,_ message: String,_ error: Bool) {
        bindingStatus[id] = (message,error)
        statusLabels[id]?.stringValue = error ? message:""; statusLabels[id]?.isHidden = !error
    }
    func showDirections(_ binding: AppBinding,from anchor: NSView) {
        stopRecording(); closeDirections()
        pendingDirectionBinding = binding
        let edges = WindowEdge.allCases
        let rowHeight: CGFloat = 28, padding: CGFloat = 6
        let width = max(104,anchor.bounds.width)
        let height = CGFloat(edges.count)*rowHeight + padding*2
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.appearance = NSAppearance(named:.darkAqua)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true
        let surface = PickerSurface(frame:NSRect(x:0,y:0,width:width,height:height))
        surface.autoresizingMask = [.width,.height]
        panel.contentView = surface
        for (index,edge) in edges.enumerated() {
            // Rows are laid out top-down: first edge sits at the top of the panel.
            let y = height - padding - CGFloat(index+1)*rowHeight
            let row = PickerRow(edge.title,selected:edge == binding.selectedEdge)
            row.frame = NSRect(x:0,y:y,width:width,height:rowHeight)
            row.autoresizingMask = [.width]
            row.tag = index; row.target = self; row.action = #selector(directionRowPressed(_:))
            row.setAccessibilityLabel("收起方向：\(edge.title)")
            surface.addSubview(row)
        }
        directionPanel = panel
        guard let window,let anchorWindow = anchor.window else { closeDirections(); return }
        let inWindow = anchor.convert(anchor.bounds,to:nil)
        let anchorRect = anchorWindow.convertToScreen(inWindow)
        var origin = NSPoint(x:anchorRect.minX,y:anchorRect.minY-height-6)
        if let screen = window.screen ?? NSScreen.main,origin.y < screen.visibleFrame.minY {
            origin.y = anchorRect.maxY+6
        }
        panel.setFrame(NSRect(origin:origin,size:NSSize(width:width,height:height)),display:false)
        window.addChildWindow(panel,ordered:.above)
        panel.orderFront(nil)
        directionMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.closeDirections(); return nil
            }
            if let content = panel.contentView,event.window === panel,
               content.bounds.contains(content.convert(event.locationInWindow,from:nil)) { return event }
            self.closeDirections(); return event
        }
    }
    private func closeDirections() {
        if let directionMonitor { NSEvent.removeMonitor(directionMonitor) }
        directionMonitor = nil
        if let directionPanel { directionPanel.parent?.removeChildWindow(directionPanel); directionPanel.orderOut(nil) }
        directionPanel = nil
    }
    @objc private func directionRowPressed(_ sender: NSButton) {
        guard let binding = pendingDirectionBinding,WindowEdge.allCases.indices.contains(sender.tag) else { closeDirections(); return }
        let edge = WindowEdge.allCases[sender.tag]
        closeDirections()
        setEdge(binding.id,edge)
    }
    private func setEdge(_ id: UUID,_ edge: WindowEdge) {
        prepare(id) { [weak self] in
            guard let self else { return }
            do { try self.store.configure(id,edge:edge,windowTitle:nil,changeWindow:true); self.bindingStatus.removeValue(forKey:id); self.reload() }
            catch { self.setStatus(error.localizedDescription) }
        }
    }
    func showPermissionNeeded() { permissionButton.isHidden = false; showApps() }
    private func openAccessibility() {
        if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary) }
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func record(_ id: UUID) {
        guard let window,window.attachedSheet == nil,let button = shortcutButtons[id] else { return }
        showApps(); setStatus("")
        hotkeys.suspend(); onRecordingChanged?(true); recordingID = id; recorderButton = button
        button.title = "● 按下快捷键"; button.toolTip = "Esc 取消，Delete 清除"; button.invalidateIntrinsicContentSize()
        window.makeFirstResponder(button)
        recordingTimer = Timer.scheduledTimer(withTimeInterval:0.6,repeats:true) { [weak self] _ in
            guard let self else { return }; self.recordingPulse.toggle()
            self.recorderButton?.title = self.recordingPulse ? "○ 按下快捷键":"● 按下快捷键"
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown { self.stopRecording(); return event }
            if event.keyCode == 53 && event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty {
                self.stopRecording(); self.reload(); return nil
            }
            guard !event.isARepeat else { return nil }
            if [UInt16(51),UInt16(117)].contains(event.keyCode) && event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty {
                do { try self.store.setShortcut(nil,for:id); self.stopRecording(); self.reload() }
                catch { self.setStatus(error.localizedDescription) }; return nil
            }
            guard let shortcut = Shortcut.capture(event) else { self.setStatus("请同时按住 ⌘、⌥ 或 ⌃。"); return nil }
            do {
                if self.store.bindings.contains(where:{$0.id != id && $0.shortcut?.matches(shortcut) == true}) { throw PeekError.message("这个快捷键已绑定到另一个应用。") }
                if let error = self.hotkeys.validate(shortcut) { throw PeekError.message(error) }
                try self.store.setShortcut(shortcut,for:id)
                self.stopRecording(); self.reload()
            } catch { self.setStatus(error.localizedDescription) }
            return nil
        }
    }
    private func stopRecording() {
        guard let id = recordingID else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        recordingTimer?.invalidate(); recordingTimer = nil
        recorderButton?.title = store.bindings.first(where:{$0.id == id})?.shortcut?.title ?? "录制快捷键"
        recorderButton?.invalidateIntrinsicContentSize(); recorderButton?.toolTip = nil; recorderButton = nil; recordingID = nil
        statusLabels[id]?.stringValue = ""; statusLabels[id]?.isHidden = true
        hotkeys.reload(store.bindings); onRecordingChanged?(false); setStatus("")
    }
    func windowDidBecomeKey(_ notification: Notification) { reloadGeneral() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }
    func windowWillClose(_ notification: Notification) { closeDirections(); stopRecording(); output("main_window_closed",["app_keeps_running":true]) }
}
