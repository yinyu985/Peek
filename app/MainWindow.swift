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
// A shared neutral palette for the title bar, sidebar, and content.
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
private enum Layout {
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 2
    static let cardInset: CGFloat = 8
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
    var disclosureExpanded = false { didSet { needsDisplay = true } }
    var isNavigation = false
    var isChip = false
    var hasError = false { didSet { needsDisplay = true } }
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
            Ink.accent.withAlphaComponent(!isEnabled ? 0.04:isHighlighted || disclosureExpanded ? 0.18:hovered ? 0.14:0.10).setFill(); pill.fill()
            (hasError ? NSColor.systemRed:Ink.accent.withAlphaComponent(isEnabled ? 0.45:0.22)).setStroke(); pill.lineWidth = 1; pill.stroke()
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
            let down: CGFloat = (isFlipped ? 1:-1) * (disclosureExpanded ? -1:1)
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
// Both selectors share the same surface, rows and anchor geometry.
private final class PickerSurface: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect:NSRect(x:0.5,y:0.5,width:bounds.width-1,height:bounds.height-1),xRadius:5,yRadius:5)
        Ink.sidebar.setFill(); path.fill()
        Ink.accent.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke()
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
        (title as NSString).draw(at:NSPoint(x:10,y:(bounds.height-size.height)/2),withAttributes:attrs)
        if selectedEdge {
            let dot = NSBezierPath(ovalIn:NSRect(x:bounds.width-13.5,y:bounds.midY-2.5,width:5,height:5))
            Ink.accent.setFill(); dot.fill()
        }
    }
}
// Hand-drawn stepper: a clear editable box between two glyph buttons, so it
// reads as "you can type here" without borrowing system control chrome.
private final class NumericFieldBox: NSView {
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
private enum NumericSetting: String, CaseIterable {
    case revealWidth, showDelay, hideDelay, showDuration, hideDuration
    var title: String {
        switch self { case .revealWidth: return L("露出宽度"); case .showDelay: return L("停留后展开"); case .hideDelay: return L("离开后收起"); case .showDuration: return L("展开时长"); case .hideDuration: return L("收起时长") }
    }
    var isDelay: Bool { self == .showDelay || self == .hideDelay }
    var step: Double { self == .revealWidth ? 1:isDelay ? 0.1:0.01 }
    var limit: Double { self == .revealWidth ? 100:self == .showDelay ? 5:self == .hideDelay ? 10:1 }
    var unit: String { self == .revealWidth ? L("像素"):L("秒") }
    func formatted(_ value: Double) -> String { String(format:self == .revealWidth ? "%.0f":"%.2f",value) }
    func value(in settings: HoverSettings) -> Double {
        switch self {
        case .revealWidth: return settings.revealWidth
        case .showDelay: return settings.showDelay
        case .hideDelay: return settings.hideDelay
        case .showDuration: return settings.showDuration
        case .hideDuration: return settings.hideDuration
        }
    }
    func normalized(_ value: Double) -> Double {
        let scale = self == .revealWidth ? 1:isDelay ? 10.0:100.0
        return max(0,min(limit,(value*scale).rounded()/scale))
    }
    func save(_ value: Double,to store: BindingStore) throws {
        switch self {
        case .revealWidth: try store.configureHover(revealWidth:value)
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
    private var recorderButton: ActionButton?
    private var shortcutButtons: [UUID:ActionButton] = [:]
    private var directionButtons: [UUID:DropdownButton] = [:]
    private var statusButtons: [UUID:NSButton] = [:]
    private var recordingTimer: Timer?
    private var recordingPulse = false
    var onPrepareChange: ((UUID,@escaping (Bool)->Void)->Void)?
    var onBindingRemoved: ((UUID)->Void)?
    var onBindingsChanged: (()->Void)?
    var onRecordingChanged: ((Bool)->Void)?
    var onMenuBarIconChanged: (()->Void)?
    var onLanguageChanged: (()->Void)?
    private(set) var brandIcon: NSImageView!
    private(set) var bindingStatus: [UUID:(String,Bool)] = [:]
    private var pickerSelection: ((Int)->Void)?
    private weak var pickerAnchor: ActionButton?
    private(set) var selectionPanel: NSPanel?
    private var selectionMonitor: Any?
    private var spaceHelpPopover: NSPopover?
    func closeOptions() { closeSelection(); spaceHelpPopover?.close() }
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
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }
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
        let apps = ActionButton(L("应用")) { [weak self] in self?.showApps() }
        apps.image = NSImage(systemSymbolName:"square.grid.2x2",accessibilityDescription:nil)
        let settings = ActionButton(L("收放")) { [weak self] in self?.showSettings() }
        settings.image = NSImage(systemSymbolName:"arrow.right.to.line",accessibilityDescription:nil)
        let general = ActionButton(L("通用")) { [weak self] in self?.showGeneral() }
        general.image = NSImage(systemSymbolName:"gearshape",accessibilityDescription:nil)
        let about = ActionButton(L("关于")) { [weak self] in self?.navigate(to:3) }
        about.image = NSImage(systemSymbolName:"info.circle",accessibilityDescription:nil)
        about.setAccessibilityLabel(L("关于"))
        for button in [apps,settings,general,about] {
            button.isNavigation = true; button.alignment = .left; button.font = .systemFont(ofSize:13)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant:32).isActive = true
            button.widthAnchor.constraint(equalToConstant:124).isActive = true
        }
        apps.setAccessibilityLabel(L("应用")); settings.setAccessibilityLabel(L("收放")); general.setAccessibilityLabel(L("通用"))
        navigationButtons = [apps,settings,general,about]
        let nav = NSStackView(views:[apps,settings,general,about]); nav.orientation = .vertical; nav.alignment = .leading; nav.spacing = Layout.rowSpacing
        nav.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(nav)
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo:brandIcon.bottomAnchor,constant:18),nav.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:12)
        ])
        let add = ActionButton(L("新增应用")) { [weak self] in self?.addApplication() }
        add.image = NSImage(systemSymbolName:"plus",accessibilityDescription:nil)
        add.keyEquivalent = "n"; add.keyEquivalentModifierMask = .command
        add.isChip = true; add.setContentCompressionResistancePriority(.required,for:.horizontal)
        add.setAccessibilityLabel(L("新增应用"))
        add.widthAnchor.constraint(greaterThanOrEqualToConstant:96).isActive = true
        let header = NSStackView(views:[label(L("应用"),20,.semibold),NSView(),add]); header.orientation = .horizontal
        for stack in [rows,settingsRows,generalRows] { stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = Layout.rowSpacing }
        rows.spacing = 4
        for error in [settingsError] { error.textColor = .systemRed; error.maximumNumberOfLines = 3; error.lineBreakMode = .byWordWrapping; error.isHidden = true }
        permissionButton = ActionButton(L("开启窗口控制")) { [weak self] in self?.openAccessibility() }
        permissionButton.isChip = true
        permissionButton.isHidden = AXIsProcessTrusted()
        buildSection(mainPage,views:[header,rows,permissionButton])
        buildSection(settingsPage,views:[label(L("收放"),20,.semibold),settingsRows])
        buildSection(generalPage,views:[label(L("通用"),20,.semibold),settingsCard(generalRows)])
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"
        let author = Bundle.main.object(forInfoDictionaryKey:"PeekAuthor") as? String ?? L("待填写")
        let versionLabel = label(L("版本：{0}",version),12)
        versionLabel.textColor = Ink.mid
        let authorLabel = label(L("作者：{0}",author),12)
        authorLabel.textColor = Ink.mid
        if let address = Bundle.main.object(forInfoDictionaryKey:"PeekAuthorURL") as? String,let url = URL(string:address) {
            let text = NSMutableAttributedString(string:authorLabel.stringValue,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:Ink.mid])
            let range = (authorLabel.stringValue as NSString).range(of:author,options:.backwards)
            text.addAttributes([.link:url,.foregroundColor:Ink.accentText,.underlineStyle:NSUnderlineStyle.single.rawValue],range:range)
            authorLabel.allowsEditingTextAttributes = true; authorLabel.isSelectable = true
            authorLabel.attributedStringValue = text; authorLabel.toolTip = L("作者 GitHub：")+address
        }
        let description = NSTextField(wrappingLabelWithString:L("用快捷键或屏幕边缘 Hover 收起、唤出窗口。"))
        description.font = .systemFont(ofSize:12); description.textColor = Ink.mid; description.preferredMaxLayoutWidth = 348
        let aboutRows = TopAlignedStack(views:[label("Peek",17,.semibold),description,versionLabel,authorLabel])
        aboutRows.orientation = .vertical; aboutRows.alignment = .leading; aboutRows.spacing = 8
        buildSection(aboutPage,views:[label(L("关于"),20,.semibold),settingsCard(aboutRows)])
    }
    // The same outer width as application cards, with a single shared inset.
    private func settingsCard(_ content: NSStackView) -> NSView {
        let card = GlassCard(); card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo:card.topAnchor,constant:Layout.cardInset),
            content.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-Layout.cardInset),
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
    private func addSwitchRow(_ title: String,isOn: Bool,action: Selector,to stack: NSStackView,spaceHelp: Bool = false,topHelp: Bool = false) {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let caption = label(title,13); caption.textColor = Ink.mid
        let toggle = NSSwitch(); toggle.state = isOn ? .on:.off
        toggle.target = self; toggle.action = action
        toggle.setAccessibilityLabel(title)
        caption.translatesAutoresizingMaskIntoConstraints = false; toggle.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(caption); row.addSubview(toggle); stack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo:stack.widthAnchor),row.heightAnchor.constraint(equalToConstant:Layout.rowHeight),
            caption.leadingAnchor.constraint(equalTo:row.leadingAnchor),caption.centerYAnchor.constraint(equalTo:row.centerYAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo:toggle.leadingAnchor,constant:-12),
            toggle.trailingAnchor.constraint(equalTo:row.trailingAnchor,constant:stack === generalRows ? -24:0),toggle.centerYAnchor.constraint(equalTo:row.centerYAnchor)
        ])
        if spaceHelp || topHelp {
            let info = NSButton(image:NSImage(systemSymbolName:"exclamationmark.circle",accessibilityDescription:topHelp ? L("顶部收放说明"):L("桌面切换说明"))!,target:self,action:topHelp ? #selector(showTopHelp(_:)):#selector(showSpaceHelp(_:)))
            info.isBordered = false; info.contentTintColor = Ink.mid
            info.setAccessibilityLabel(topHelp ? L("顶部收放说明"):L("桌面切换说明"))
            info.toolTip = topHelp ? L("顶部可最小化窗口或隐藏整个应用。点击查看影响范围和动画说明。"):L("关闭：只在当前桌面收放。开启：允许激活窗口时切换到它所在的桌面，不搬动窗口的桌面归属。推荐把应用分配给所有桌面。")
            info.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(info)
            NSLayoutConstraint.activate([info.trailingAnchor.constraint(equalTo:row.trailingAnchor),info.centerYAnchor.constraint(equalTo:row.centerYAnchor),info.widthAnchor.constraint(equalToConstant:18),info.heightAnchor.constraint(equalToConstant:22)])
        }
    }
    @objc private func showTopHelp(_ sender: NSButton) {
        showHelp(L("macOS 和许多应用会限制窗口移出屏幕顶部。\n\n最小化窗口：只收起绑定窗口。隐藏整个应用：同一应用的所有窗口一起隐藏，恢复时将绑定窗口置前，保留原位置和尺寸。\n\n两种方式都通过顶部对应区段或快捷键恢复，鼠标移开后按离开延迟收起。停留和离开延迟有效；过渡由 macOS 控制，不使用 Peek 的展开、收起时长。\n\n关闭后，方向菜单移除“顶部”，已有顶部绑定暂停收起，已收起的窗口仍可召回。"),from:sender)
    }
    @objc private func showTopModeHelp(_ sender: NSButton) {
        showHelp(L("隐藏整个应用会同时隐藏该应用的所有窗口。\n\n如果应用有多个窗口，例如浏览器或 Finder，建议使用“最小化窗口”，只收起绑定窗口。\n\n这里设置通用默认方式。在“应用”的方向菜单中，可为每个应用选择“↑ 最小化”或“↑ 隐藏应用”；选择“↑ 顶部”则使用通用默认。"),from:sender)
    }
    @objc private func showSpaceHelp(_ sender: NSButton) {
        showHelp(L("关闭：只在当前桌面收放。\n\n开启：Hover 或快捷键可能切走当前桌面，转到窗口所在的桌面。不会把窗口搬到当前桌面；能否切换由 macOS 决定。\n\n推荐：Dock 中右键目标应用 → 选项 → 分配给 → 所有桌面。"),from:sender)
    }
    private func showHelp(_ message: String,from sender: NSButton) {
        spaceHelpPopover?.close()
        let text = NSTextField(wrappingLabelWithString:message)
        text.font = .systemFont(ofSize:12); text.textColor = Ink.mid
        let width: CGFloat = 288
        let measured = (message as NSString).boundingRect(with:NSSize(width:width-24,height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:text.font!]).height
        let content = NSViewController(); content.view = NSView(frame:NSRect(x:0,y:0,width:width,height:ceil(measured)+28))
        text.translatesAutoresizingMaskIntoConstraints = false; content.view.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:content.view.leadingAnchor,constant:12),text.trailingAnchor.constraint(equalTo:content.view.trailingAnchor,constant:-12),text.topAnchor.constraint(equalTo:content.view.topAnchor,constant:10),text.bottomAnchor.constraint(lessThanOrEqualTo:content.view.bottomAnchor,constant:-10)])
        let popover = NSPopover(); popover.behavior = .transient; popover.appearance = NSAppearance(named:.darkAqua)
        popover.contentViewController = content; spaceHelpPopover = popover
        popover.show(relativeTo:sender.bounds,of:sender,preferredEdge:.minY)
    }
    private func reloadSettings() {
        for view in settingsRows.arrangedSubviews { settingsRows.removeArrangedSubview(view); view.removeFromSuperview() }
        let settings = store.hoverSettings
        let rhythmRows = NSStackView(); rhythmRows.orientation = .vertical; rhythmRows.alignment = .leading; rhythmRows.spacing = Layout.rowSpacing
        let rhythm = settingsCard(rhythmRows)
        addSwitchRow(L("自动收放"),isOn:settings.enabled,action:#selector(hoverChanged(_:)),to:rhythmRows)
        for setting in NumericSetting.allCases {
            let title = setting.title, value = setting.value(in:settings)
            let enabled = !setting.isDelay || settings.enabled
            let caption = label(title,12); caption.textColor = Ink.mid
            let minus = StepGlyphButton(plus:false) { [weak self] in self?.stepValue(setting,-setting.step) }
            minus.setAccessibilityLabel(L("{0}：减少 {1} {2}",title,setting.step,setting.unit))
            let plus = StepGlyphButton(plus:true) { [weak self] in self?.stepValue(setting,setting.step) }
            plus.setAccessibilityLabel(L("{0}：增加 {1} {2}",title,setting.step,setting.unit))
            minus.isEnabled = enabled; plus.isEnabled = enabled
            // Editable box: obvious enough that typing is expected, styled by us.
            let box = NumericFieldBox(); box.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(string:setting.formatted(value))
            field.alignment = .center; field.isBordered = false; field.drawsBackground = false
            field.focusRingType = .none; field.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium)
            field.textColor = value > 0 ? Ink.hi:Ink.low
            field.identifier = NSUserInterfaceItemIdentifier(setting.rawValue)
            field.isEnabled = enabled
            field.target = self; field.action = #selector(numericFieldChanged(_:)); field.cell?.sendsActionOnEndEditing = true
            field.setAccessibilityLabel(title+"，\(setting.unit)")
            field.toolTip = setting == .revealWidth ? L("0–100 逻辑像素（macOS pt）；0 保留最小边缘。左、右、底部共用，下次收起时生效。底部可能受系统最小标题栏限制。"):(setting.isDelay ? L("0–{0} 秒；步进 {1} 秒",Int(setting.limit),setting.step):L("仅控制左、右、底部的移动动画；顶部最小化和隐藏应用的过渡由 macOS 控制。"))
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
            let unit = label(setting.unit,11); unit.textColor = Ink.low
            unit.widthAnchor.constraint(equalToConstant:24).isActive = true
            let row = NSStackView(views:[caption,NSView(),minus,box,plus,unit])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 5
            row.translatesAutoresizingMaskIntoConstraints = false
            rhythmRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo:rhythmRows.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant:Layout.rowHeight).isActive = true
        }
        settingsRows.addArrangedSubview(rhythm)
        rhythm.widthAnchor.constraint(equalTo:settingsRows.widthAnchor).isActive = true
        rhythmRows.addArrangedSubview(settingsError)
        settingsError.widthAnchor.constraint(equalTo:rhythmRows.widthAnchor).isActive = true
    }
    private func reloadGeneral() {
        for view in generalRows.arrangedSubviews { generalRows.removeArrangedSubview(view); view.removeFromSuperview() }
        let language = DropdownButton(Localization.language.title,action:{})
        language.isChip = true; language.setAccessibilityLabel(L("语言"))
        language.actionBlock = { [weak self,weak language] in
            guard let self,let language else { return }
            self.showPicker(AppLanguage.allCases.map(\.title),selected:AppLanguage.allCases.firstIndex(of:Localization.language) ?? 0,from:language,label:L("语言")) { [weak self] index in
                guard let self else { return }
                Localization.select(AppLanguage.allCases[index])
                self.onLanguageChanged?()
            }
        }
        let languageCaption = label(L("语言"),13); languageCaption.textColor = Ink.mid
        let languageRow = NSStackView(views:[languageCaption,NSView(),language]); languageRow.orientation = .horizontal; languageRow.alignment = .centerY
        languageRow.edgeInsets = NSEdgeInsets(top:0,left:0,bottom:0,right:24); generalRows.addArrangedSubview(languageRow)
        NSLayoutConstraint.activate([languageRow.widthAnchor.constraint(equalTo:generalRows.widthAnchor),languageRow.heightAnchor.constraint(equalToConstant:Layout.rowHeight),language.widthAnchor.constraint(equalToConstant:104),language.heightAnchor.constraint(equalToConstant:28)])
        let state = SMAppService.mainApp.status
        addSwitchRow(L("开机自启"),isOn:state == .enabled || state == .requiresApproval,action:#selector(loginChanged(_:)),to:generalRows)
        addSwitchRow(L("在菜单栏显示图标"),isOn:store.menuBarIconVisible,action:#selector(menuBarIconChanged(_:)),to:generalRows)
        addSwitchRow(L("顶部收放（实验）"),isOn:store.hoverSettings.topEnabled,action:#selector(topEnabledChanged(_:)),to:generalRows,topHelp:true)
        let caption = label(L("顶部收起方式"),13); caption.textColor = Ink.mid
        let mode = DropdownButton(store.hoverSettings.topHideMode.title,action:{})
        mode.isChip = true; mode.isEnabled = store.hoverSettings.topEnabled
        mode.setAccessibilityLabel(L("顶部收起方式"))
        mode.actionBlock = { [weak self,weak mode] in
            guard let self,let mode else { return }
            self.showPicker(TopHideMode.allCases.map(\.title),selected:TopHideMode.allCases.firstIndex(of:self.store.hoverSettings.topHideMode) ?? 0,from:mode,label:L("顶部收起方式")) { [weak self] index in
                guard let self else { return }
                do { try self.store.configureHover(topHideMode:TopHideMode.allCases[index]); self.onBindingsChanged?() }
                catch { self.setStatus(error.localizedDescription) }
                self.reloadGeneral()
            }
        }
        let modeRow = NSStackView(views:[caption,NSView(),mode]); modeRow.orientation = .horizontal; modeRow.alignment = .centerY
        modeRow.edgeInsets = NSEdgeInsets(top:0,left:0,bottom:0,right:24); generalRows.addArrangedSubview(modeRow)
        NSLayoutConstraint.activate([modeRow.widthAnchor.constraint(equalTo:generalRows.widthAnchor),modeRow.heightAnchor.constraint(equalToConstant:Layout.rowHeight),mode.widthAnchor.constraint(equalToConstant:156),mode.heightAnchor.constraint(equalToConstant:28)])
        let modeInfo = NSButton(image:NSImage(systemSymbolName:"exclamationmark.circle",accessibilityDescription:L("顶部收起方式说明"))!,target:self,action:#selector(showTopModeHelp(_:)))
        modeInfo.isBordered = false; modeInfo.contentTintColor = Ink.mid
        modeInfo.setAccessibilityLabel(L("顶部收起方式说明"))
        modeInfo.toolTip = L("多窗口应用建议使用最小化；隐藏应用会同时隐藏它的所有窗口。")
        modeInfo.translatesAutoresizingMaskIntoConstraints = false; modeRow.addSubview(modeInfo)
        NSLayoutConstraint.activate([modeInfo.trailingAnchor.constraint(equalTo:modeRow.trailingAnchor),modeInfo.centerYAnchor.constraint(equalTo:modeRow.centerYAnchor),modeInfo.widthAnchor.constraint(equalToConstant:18),modeInfo.heightAnchor.constraint(equalToConstant:22)])
        addSwitchRow(L("允许切换桌面"),isOn:store.hoverSettings.allowSpaceSwitch,action:#selector(spaceSwitchChanged(_:)),to:generalRows,spaceHelp:true)
        if state == .requiresApproval {
            let hint = label(L("请在系统设置的登录项中允许 Peek。"),11); hint.textColor = .secondaryLabelColor; generalRows.addArrangedSubview(hint)
            let openLogin = ActionButton(L("打开登录项设置")) { SMAppService.openSystemSettingsLoginItems() }
            openLogin.isChip = true; generalRows.addArrangedSubview(openLogin)
        }
    }
    @objc private func numericFieldChanged(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue,let setting = NumericSetting(rawValue:key) else { return }
        guard let typed = Double(sender.stringValue.trimmingCharacters(in:.whitespaces)),typed.isFinite,typed >= 0,typed <= setting.limit else {
            sender.stringValue = setting.formatted(setting.value(in:store.hoverSettings))
            setSettingsError(L("{0}为 0–{1} {2}。",setting.title,Int(setting.limit),setting.unit)); return
        }
        do {
            try setting.save(setting.normalized(typed),to:store)
            onBindingsChanged?(); setSettingsError("")
        } catch { setSettingsError(error.localizedDescription) }
        let saved = setting.value(in:store.hoverSettings)
        sender.stringValue = setting.formatted(saved)
        sender.textColor = saved > 0 ? Ink.hi:Ink.low
    }
    @objc private func hoverChanged(_ sender: NSSwitch) {
        do { try store.configureHover(enabled:sender.state == .on); onBindingsChanged?(); setSettingsError(""); reloadSettings() }
        catch { setSettingsError(error.localizedDescription); reloadSettings() }
    }
    @objc private func topEnabledChanged(_ sender: NSSwitch) {
        do { try store.configureHover(topEnabled:sender.state == .on); onBindingsChanged?() }
        catch { setStatus(error.localizedDescription) }
        closeOptions(); reload()
    }
    @objc private func spaceSwitchChanged(_ sender: NSSwitch) {
        do { try store.configureHover(allowSpaceSwitch:sender.state == .on); onBindingsChanged?() }
        catch { setStatus(error.localizedDescription) }
        reloadGeneral()
    }
    @objc private func menuBarIconChanged(_ sender: NSSwitch) {
        store.setMenuBarIconVisible(sender.state == .on); onMenuBarIconChanged?(); reloadGeneral()
    }
    @objc private func loginChanged(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            output("login_item_changed",["status":SMAppService.mainApp.status.rawValue])
        } catch {
            let alert = NSAlert(); alert.messageText = L("无法更改开机自启"); alert.informativeText = error.localizedDescription; alert.addButton(withTitle:L("好")); alert.runModal()
        }
        reloadGeneral()
    }
    // No status/footer region. Errors belong to the edited row or a transient alert.
    func setStatus(_ message: String) {
        guard !message.isEmpty else { return }
        if recordingID != nil {
            recorderButton?.hasError = true; recorderButton?.toolTip = message
            recorderButton?.setAccessibilityHelp(message); return
        }
        guard let window,window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = L("操作未完成"); alert.informativeText = message
        alert.addButton(withTitle:L("好")); alert.beginSheetModal(for:window)
    }
    private func setSettingsError(_ message: String) { settingsError.stringValue = message; settingsError.toolTip = message; settingsError.isHidden = message.isEmpty }
    func reload() {
        let section = currentSection
        stopRecording(); shortcutButtons.removeAll(); directionButtons.removeAll(); statusButtons.removeAll(); onBindingsChanged?()
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        rows.isHidden = store.bindings.isEmpty
        for binding in store.bindings {
            let icon = NSImageView(image:NSWorkspace.shared.icon(forFile:binding.resolvedURL?.path ?? binding.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant:28).isActive = true; icon.heightAnchor.constraint(equalToConstant:28).isActive = true
            let name = label(binding.name,13.5,.medium); name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            let title = NSStackView(views:[name]); title.orientation = .vertical; title.alignment = .leading; title.spacing = 1
            let shortcut = ActionButton(binding.shortcut?.title ?? L("录制快捷键")) { [weak self] in self?.record(binding.id) }
            shortcutButtons[binding.id] = shortcut; shortcut.font = .monospacedSystemFont(ofSize:12,weight:.medium); shortcut.isChip = true
            shortcut.widthAnchor.constraint(greaterThanOrEqualToConstant:52).isActive = true
            shortcut.setAccessibilityLabel(L("{0}：{1}",binding.name,binding.shortcut?.title ?? L("录制快捷键")))
            shortcut.hasError = hotkeys.errors[binding.id] != nil
            shortcut.toolTip = hotkeys.errors[binding.id].map(Localization.refresh); shortcut.setAccessibilityHelp(shortcut.toolTip)
            let remove = ActionButton("") { [weak self] in self?.remove(binding.id) }
            remove.image = NSImage(systemSymbolName:"xmark",accessibilityDescription:L("删除 {0}",binding.name))
            remove.setAccessibilityLabel(L("删除 {0}",binding.name)); remove.toolTip = L("删除绑定")
            remove.widthAnchor.constraint(equalToConstant:24).isActive = true
            let inactiveTop = binding.selectedEdge == .top && !store.hoverSettings.topEnabled
            let direction = DropdownButton(inactiveTop ? L("已停用"):binding.directionTitle,action:{})
            directionButtons[binding.id] = direction
            direction.toolTip = bindingStatus[binding.id].map { L("上次操作：")+$0.0 }
            direction.hasError = false
            direction.setAccessibilityHelp(bindingStatus[binding.id]?.0)
            direction.isChip = true; direction.widthAnchor.constraint(equalToConstant:110).isActive = true
            direction.setAccessibilityLabel(L("收起方向：")+binding.directionTitle)
            direction.actionBlock = { [weak self,weak direction] in if let direction { self?.showDirections(binding,from:direction) } }
            for control in [shortcut,remove,direction] {
                control.translatesAutoresizingMaskIntoConstraints = false; control.heightAnchor.constraint(equalToConstant:28).isActive = true
                control.setContentCompressionResistancePriority(.required,for:.horizontal)
            }
            let status = NSButton(image:NSImage(systemSymbolName:"exclamationmark.circle",accessibilityDescription:L("收放状态说明"))!,target:self,action:#selector(showBindingHelp(_:)))
            status.isBordered = false; status.contentTintColor = .systemRed
            status.identifier = NSUserInterfaceItemIdentifier(binding.id.uuidString)
            statusButtons[binding.id] = status
            let statusSlot = NSView(); statusSlot.translatesAutoresizingMaskIntoConstraints = false
            status.translatesAutoresizingMaskIntoConstraints = false; statusSlot.addSubview(status)
            NSLayoutConstraint.activate([statusSlot.widthAnchor.constraint(equalToConstant:18),statusSlot.heightAnchor.constraint(equalToConstant:28),status.centerYAnchor.constraint(equalTo:statusSlot.centerYAnchor),status.centerXAnchor.constraint(equalTo:statusSlot.centerXAnchor),status.widthAnchor.constraint(equalToConstant:18),status.heightAnchor.constraint(equalToConstant:22)])
            updateBindingStatus(binding.id)
            let topRow = NSStackView(views:[icon,title,NSView(),direction,shortcut,remove,statusSlot]); topRow.orientation = .horizontal; topRow.alignment = .centerY; topRow.spacing = 8
            let card = GlassCard(); card.translatesAutoresizingMaskIntoConstraints = false
            topRow.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(topRow)
            NSLayoutConstraint.activate([
                card.heightAnchor.constraint(equalToConstant:44),
                topRow.centerYAnchor.constraint(equalTo:card.centerYAnchor),topRow.heightAnchor.constraint(equalToConstant:28),
                topRow.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:12),topRow.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-12)
            ])
            rows.addArrangedSubview(card); card.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive = true
        }
        reloadSettings(); reloadGeneral()
        setStatus(store.loadError.map(Localization.refresh) ?? (hotkeys.errors.isEmpty ? "":L("部分快捷键被占用，点击对应快捷键重新设置。")))
        navigate(to:section)
    }
    private func stepValue(_ setting: NumericSetting,_ delta: Double) {
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
        let panel = NSOpenPanel(); panel.title = L("选择应用"); panel.prompt = L("添加")
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
            if success { action() } else { self?.setStatus(L("窗口尚未恢复，暂时不能更改绑定。请稍后重试。")) }
        } } else { action() }
    }
    private func remove(_ id: UUID) {
        stopRecording(); closeOptions()
        do {
            try store.remove(id)
            onBindingRemoved?(id)
            bindingStatus.removeValue(forKey:id)
            hotkeys.reload(store.bindings); reload()
        } catch { setStatus(error.localizedDescription) }
    }
    func setBindingStatus(_ id: UUID,_ message: String,_ error: Bool) {
        bindingStatus[id] = (Localization.refresh(message),error)
        updateBindingStatus(id)
    }
    private func statusMessage(_ id: UUID) -> String? {
        if let binding = store.bindings.first(where:{$0.id == id}),binding.selectedEdge == .top,!store.hoverSettings.topEnabled {
            return L("顶部收放已关闭。此绑定保留原方向，但不会自动收起。已收起的窗口仍可召回；可在下拉框选择其他方向，或到“通用”开启顶部收放。")
        }
        guard let status = bindingStatus[id],!status.0.isEmpty else { return nil }
        return Localization.refresh(status.0)
    }
    private func updateBindingStatus(_ id: UUID) {
        let message = statusMessage(id)
        let inactive = store.bindings.first(where:{$0.id == id}).map { $0.selectedEdge == .top && !store.hoverSettings.topEnabled } ?? false
        let noteworthy = inactive || bindingStatus[id]?.1 == true || bindingStatus[id].map { Localization.refresh($0.0).contains(L("实际露出")) } == true
        directionButtons[id]?.hasError = false
        directionButtons[id]?.toolTip = message
        directionButtons[id]?.setAccessibilityHelp(message)
        statusButtons[id]?.isHidden = !noteworthy
        statusButtons[id]?.toolTip = message
        statusButtons[id]?.setAccessibilityLabel(L("收放状态说明：")+(message ?? ""))
    }
    @objc private func showBindingHelp(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,let id = UUID(uuidString:key),let message = statusMessage(id) else { return }
        showHelp(message,from:sender)
    }
    func showDirections(_ binding: AppBinding,from anchor: NSView) {
        var options: [(WindowEdge,TopHideMode?)] = []
        if store.hoverSettings.topEnabled { options = [(.top,nil),(.top,.minimize),(.top,.appHide)] }
        options += [(.bottom,nil),(.left,nil),(.right,nil)]
        let titles = options.map { edge,mode in mode?.directionTitle ?? edge.title }
        let selected = options.firstIndex { edge,mode in
            edge == binding.selectedEdge && (edge != .top || mode == binding.topHideMode)
        } ?? -1
        showPicker(titles,selected:selected,from:anchor,label:L("收起方向")) { [weak self] index in
            let (edge,mode) = options[index]
            self?.setEdge(binding.id,edge,topHideMode:mode)
        }
    }

    private func showPicker(_ titles: [String],selected: Int,from anchor: NSView,label: String,onSelect: @escaping (Int)->Void) {
        stopRecording()
        if selectionPanel != nil,pickerAnchor === anchor { closeSelection(); return }
        closeOptions()
        anchor.window?.contentView?.layoutSubtreeIfNeeded()
        pickerSelection = onSelect; pickerAnchor = anchor as? ActionButton
        pickerAnchor?.disclosureExpanded = true
        let rowHeight: CGFloat = 28, padding: CGFloat = 4
        let width = anchor.bounds.width
        let height = CGFloat(titles.count)*rowHeight + padding*2
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.appearance = NSAppearance(named:.darkAqua)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true
        let surface = PickerSurface(frame:NSRect(x:0,y:0,width:width,height:height))
        surface.autoresizingMask = [.width,.height]
        panel.contentView = surface
        for (index,title) in titles.enumerated() {
            let y = height - padding - CGFloat(index+1)*rowHeight
            let row = PickerRow(title,selected:index == selected)
            row.frame = NSRect(x:0,y:y,width:width,height:rowHeight)
            row.autoresizingMask = [.width]
            row.tag = index; row.target = self; row.action = #selector(pickerRowPressed(_:))
            row.setAccessibilityLabel("\(label)：\(title)")
            row.setAccessibilityValue(index == selected ? L("已选择"):L("未选择"))
            surface.addSubview(row)
        }
        selectionPanel = panel
        guard let window,let anchorWindow = anchor.window else { closeSelection(); return }
        let inWindow = anchor.convert(anchor.bounds,to:nil)
        let anchorRect = anchorWindow.convertToScreen(inWindow)
        var origin = NSPoint(x:anchorRect.minX,y:anchorRect.minY-height-4)
        if let screen = window.screen ?? NSScreen.main,origin.y < screen.visibleFrame.minY {
            origin.y = anchorRect.maxY+4
        }
        panel.setFrame(NSRect(origin:origin,size:NSSize(width:width,height:height)),display:false)
        window.addChildWindow(panel,ordered:.above)
        panel.orderFront(nil)
        selectionMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown,.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.closeSelection(); return nil
            }
            if let content = panel.contentView,event.window === panel,
               content.bounds.contains(content.convert(event.locationInWindow,from:nil)) { return event }
            // Leave a second click on the anchor for its action to close the menu.
            if event.type == .leftMouseDown,event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow,from:nil)) { return event }
            self.closeSelection(); return event
        }
    }
    private func closeSelection() {
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }
        selectionMonitor = nil
        if let selectionPanel { selectionPanel.parent?.removeChildWindow(selectionPanel); selectionPanel.orderOut(nil) }
        selectionPanel = nil; pickerSelection = nil
        pickerAnchor?.disclosureExpanded = false; pickerAnchor = nil
    }
    @objc private func pickerRowPressed(_ sender: NSButton) {
        let selection = pickerSelection
        closeSelection()
        selection?(sender.tag)
    }
    private func setEdge(_ id: UUID,_ edge: WindowEdge,topHideMode: TopHideMode? = nil) {
        guard edge != .top || store.hoverSettings.topEnabled,
              let current = store.bindings.first(where:{$0.id == id}) else { return }
        let save = { [weak self] in
            guard let self else { return }
            do {
                try self.store.configure(id,edge:edge,windowTitle:nil,changeWindow:edge != current.selectedEdge,
                    topHideMode:topHideMode,changeTopHideMode:edge == .top)
                self.bindingStatus.removeValue(forKey:id); self.reload()
            } catch { self.setStatus(error.localizedDescription) }
        }
        // A method-only change applies on the next hide; the existing journal
        // still controls how an already-hidden window is restored.
        if edge == current.selectedEdge { save() } else { prepare(id,action:save) }
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
        button.title = L("● 按下快捷键"); button.toolTip = L("Esc 取消，Delete 清除"); button.invalidateIntrinsicContentSize()
        window.makeFirstResponder(button)
        recordingTimer = Timer.scheduledTimer(withTimeInterval:0.6,repeats:true) { [weak self] _ in
            guard let self else { return }; self.recordingPulse.toggle()
            self.recorderButton?.title = self.recordingPulse ? L("○ 按下快捷键"):L("● 按下快捷键")
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
            guard let shortcut = Shortcut.capture(event) else { self.setStatus(L("请同时按住 ⌘、⌥ 或 ⌃。")); return nil }
            do {
                if self.store.bindings.contains(where:{$0.id != id && $0.shortcut?.matches(shortcut) == true}) { throw PeekError.message(L("这个快捷键已绑定到另一个应用。")) }
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
        recorderButton?.title = store.bindings.first(where:{$0.id == id})?.shortcut?.title ?? L("录制快捷键")
        recorderButton?.invalidateIntrinsicContentSize(); recorderButton?.toolTip = nil
        recorderButton?.hasError = false; recorderButton?.setAccessibilityHelp(nil); recorderButton = nil; recordingID = nil
        hotkeys.reload(store.bindings); onRecordingChanged?(false); setStatus("")
    }
    func windowDidBecomeKey(_ notification: Notification) { reloadGeneral() }
    func windowDidResignKey(_ notification: Notification) { closeOptions(); stopRecording() }
    func windowWillClose(_ notification: Notification) { closeOptions(); stopRecording(); output("main_window_closed",["app_keeps_running":true]) }
}
