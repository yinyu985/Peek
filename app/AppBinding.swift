import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    var title: String {
        [(controlKey,"⌃"),(optionKey,"⌥"),(shiftKey,"⇧"),(cmdKey,"⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined() + keyLabel
    }
    func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    static func capture(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require a command modifier: typing, arrows and Escape must remain available.
        guard !flags.intersection([.command,.option,.control]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.command,cmdKey),(.option,optionKey),(.control,controlKey),(.shift,shiftKey)] {
            if flags.contains(flag) { modifiers |= UInt32(carbon) }
        }
        let names: [UInt16:String] = [49:"Space",36:"↩",48:"⇥",51:"⌫",53:"Esc",123:"←",124:"→",125:"↓",126:"↑",117:"⌦",115:"Home",119:"End",116:"Page Up",121:"Page Down",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
        let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty else { return nil }
        return Shortcut(keyCode:UInt32(event.keyCode),modifiers:modifiers,keyLabel:label)
    }
}
enum WindowEdge: String, Codable, CaseIterable {
    case top, bottom, left, right
    static func available(topEnabled: Bool) -> [WindowEdge] { allCases.filter { topEnabled || $0 != .top } }
    var title: String { switch self { case .top: return L("↑ 顶部"); case .bottom: return L("↓ 底部"); case .left: return L("← 左侧"); case .right: return L("→ 右侧") } }
    func hidden(_ frame: CGRect, screen: CGRect, revealWidth: Double = 0) -> CGPoint {
        // Fully off-screen positions can make AppKit pull the window back by
        // a titlebar-sized strip. Keep the original 1pt foothold when set to 0.
        let extent = self == .bottom ? frame.height:frame.width
        let strip = min(max(1,CGFloat(HoverSettings.boundedRevealWidth(revealWidth))),max(0,extent-1))
        switch self {
        case .top: return CGPoint(x:frame.minX,y:screen.minY-frame.height+1)
        case .bottom: return CGPoint(x:frame.minX,y:screen.maxY-strip)
        case .left: return CGPoint(x:screen.minX-frame.width+strip,y:frame.minY)
        case .right: return CGPoint(x:screen.maxX-strip,y:frame.minY)
        }
    }
    func shown(_ frame: CGRect, visible: CGRect) -> CGPoint {
        var point = CGPoint(x:min(max(frame.minX,visible.minX),max(visible.minX,visible.maxX-frame.width)),
                            y:min(max(frame.minY,visible.minY),max(visible.minY,visible.maxY-frame.height)))
        switch self {
        case .left: point.x = visible.minX
        case .right: point.x = visible.maxX-frame.width
        case .top: point.y = visible.minY
        case .bottom: point.y = visible.maxY-frame.height
        }
        return point
    }
}
struct AppBinding: Codable, Identifiable {
    let id: UUID
    let bundleID: String
    let name: String
    var path: String
    var shortcut: Shortcut?
    var edge: WindowEdge?
    var windowTitle: String?
    var selectedEdge: WindowEdge { edge ?? .top }
    init(url: URL) throws {
        guard url.pathExtension.lowercased() == "app",let bundle = Bundle(url:url),
              let identifier = bundle.bundleIdentifier, bundle.executableURL != nil else {
            throw PeekError.message(L("请选择有效的 .app 应用。"))
        }
        guard identifier != Bundle.main.bundleIdentifier && identifier != "dev.local.Peek" else {
            throw PeekError.message(L("请选择需要控制的其他应用。"))
        }
        id = UUID(); bundleID = identifier; path = url.path
        name = (bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey:"CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
    var resolvedURL: URL? {
        let saved = URL(fileURLWithPath:path)
        if FileManager.default.fileExists(atPath:path),Bundle(url:saved)?.bundleIdentifier == bundleID { return saved }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID)
    }
}
enum PeekError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
private enum LegacyAnimationSpeed: Int, Codable {
    case slow, medium, fast
    var duration: Double { switch self { case .slow: return 0.45; case .medium: return 0.22; case .fast: return 0.10 } }
}
enum TopHideMode: String, Codable, CaseIterable {
    case shade, minimize
    var title: String { self == .shade ? L("标题条"):L("最小化") }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "shade", "compression": self = .shade
        case "minimize": self = .minimize
        default: throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Unknown top hide mode"))
        }
    }
}
struct HoverSettings: Codable, Equatable {
    var enabled = true
    var showDelay = 0.0
    var hideDelay = 0.0
    var showDuration = 0.22
    var hideDuration = 0.22
    var revealWidth = 8.0
    var topEnabled = false
    var topHideMode: TopHideMode = .minimize
    var allowSpaceSwitch = true
    static func boundedRevealWidth(_ value: Double) -> Double { value.isFinite ? max(0,min(100,value.rounded())):8 }
    static func boundedDuration(_ value: Double) -> Double { value.isFinite ? max(0,min(1,value)):0.22 }
    init(enabled: Bool = true, showDelay: Double = 0, hideDelay: Double = 0,
         showDuration: Double = 0.22, hideDuration: Double = 0.22, revealWidth: Double = 8, topEnabled: Bool = false, topHideMode: TopHideMode = .minimize, allowSpaceSwitch: Bool = true) {
        self.enabled = enabled; self.showDelay = showDelay; self.hideDelay = hideDelay
        self.showDuration = Self.boundedDuration(showDuration); self.hideDuration = Self.boundedDuration(hideDuration)
        self.revealWidth = Self.boundedRevealWidth(revealWidth)
        self.topEnabled = topEnabled; self.topHideMode = topHideMode; self.allowSpaceSwitch = allowSpaceSwitch
    }
    private enum CodingKeys: String, CodingKey { case enabled, showDelay, hideDelay, showDuration, hideDuration, showSpeed, hideSpeed, revealWidth, topEnabled, topHideMode, allowSpaceSwitch, topCompressionEnabled, topMinimizeEnabled }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        enabled = try values.decode(Bool.self,forKey:.enabled)
        showDelay = try values.decode(Double.self,forKey:.showDelay)
        hideDelay = try values.decode(Double.self,forKey:.hideDelay)
        func duration(_ key: CodingKeys,_ legacy: CodingKeys) throws -> Double {
            if let value = try values.decodeIfPresent(Double.self,forKey:key) { return Self.boundedDuration(value) }
            return try values.decodeIfPresent(LegacyAnimationSpeed.self,forKey:legacy)?.duration ?? 0.22
        }
        showDuration = try duration(.showDuration,.showSpeed)
        hideDuration = try duration(.hideDuration,.hideSpeed)
        revealWidth = Self.boundedRevealWidth(try values.decodeIfPresent(Double.self,forKey:.revealWidth) ?? 8)
        let legacyMinimize = try values.decodeIfPresent(Bool.self,forKey:.topMinimizeEnabled) ?? false
        topEnabled = try values.decodeIfPresent(Bool.self,forKey:.topEnabled)
            ?? values.decodeIfPresent(Bool.self,forKey:.topCompressionEnabled) ?? legacyMinimize
        // Keep the old decoder/backend for recovery. New hides only minimize.
        _ = try values.decodeIfPresent(TopHideMode.self,forKey:.topHideMode)
        topHideMode = .minimize
        allowSpaceSwitch = try values.decodeIfPresent(Bool.self,forKey:.allowSpaceSwitch) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy:CodingKeys.self)
        try values.encode(enabled,forKey:.enabled)
        try values.encode(showDelay,forKey:.showDelay); try values.encode(hideDelay,forKey:.hideDelay)
        try values.encode(showDuration,forKey:.showDuration); try values.encode(hideDuration,forKey:.hideDuration)
        try values.encode(revealWidth,forKey:.revealWidth)
        try values.encode(topEnabled,forKey:.topEnabled)
        try values.encode(topHideMode,forKey:.topHideMode)
        try values.encode(allowSpaceSwitch,forKey:.allowSpaceSwitch)
    }
}
final class BindingStore {
    private let defaults: UserDefaults
    private let key = "ApplicationBindings.v1"
    private(set) var bindings: [AppBinding] = []
    private(set) var hoverSettings = HoverSettings()
    private let hoverKey = "HoverSettings.v1"
    private let menuBarKey = "MenuBarIconVisible.v1"
    private(set) var menuBarIconVisible = true
    var loadError: String?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarIconVisible = defaults.object(forKey:menuBarKey) as? Bool ?? true
        if let data = defaults.data(forKey:hoverKey) {
            do { hoverSettings = try JSONDecoder().decode(HoverSettings.self,from:data) }
            catch { loadError = L("收放配置无法读取，原始数据已保留。") }
        }
        if let data = defaults.data(forKey:key) {
            do { bindings = try JSONDecoder().decode([AppBinding].self,from:data) }
            catch { loadError = L("应用配置无法读取，原始数据已保留。") }
        }
    }
    private func save(_ next: [AppBinding]) throws {
        guard loadError == nil else { throw PeekError.message(loadError!) }
        let data = try JSONEncoder().encode(next)
        defaults.set(data,forKey:key); bindings = next
    }
    @discardableResult func add(_ url: URL) throws -> UUID {
        var item = try AppBinding(url:url)
        item.edge = .right
        if let existing = bindings.first(where:{$0.bundleID == item.bundleID}) { return existing.id }
        try save(bindings + [item]); return item.id
    }
    func setShortcut(_ shortcut: Shortcut?, for id: UUID) throws {
        if let shortcut,bindings.contains(where:{$0.id != id && $0.shortcut?.matches(shortcut) == true}) {
            throw PeekError.message(L("这个快捷键已绑定到另一个应用。"))
        }
        var next = bindings
        guard let index = next.firstIndex(where:{$0.id == id}) else { return }
        next[index].shortcut = shortcut; try save(next)
    }
    func configure(_ id: UUID, edge: WindowEdge? = nil, windowTitle: String? = nil, changeWindow: Bool = false) throws {
        var next = bindings
        guard let index = next.firstIndex(where:{$0.id == id}) else { return }
        if let edge { next[index].edge = edge }
        if changeWindow { next[index].windowTitle = windowTitle }
        try save(next)
    }
    func configureHover(enabled: Bool? = nil, showDelay: Double? = nil, hideDelay: Double? = nil,
                        showDuration: Double? = nil, hideDuration: Double? = nil, revealWidth: Double? = nil, topEnabled: Bool? = nil, topHideMode: TopHideMode? = nil, allowSpaceSwitch: Bool? = nil) throws {
        guard loadError == nil else { throw PeekError.message(loadError!) }
        var next = hoverSettings
        if let enabled { next.enabled = enabled }
        if let topEnabled { next.topEnabled = topEnabled }
        if let topHideMode { next.topHideMode = topHideMode }
        if let allowSpaceSwitch { next.allowSpaceSwitch = allowSpaceSwitch }
        if let showDuration { next.showDuration = HoverSettings.boundedDuration(showDuration) }
        if let hideDuration { next.hideDuration = HoverSettings.boundedDuration(hideDuration) }
        if let revealWidth { next.revealWidth = HoverSettings.boundedRevealWidth(revealWidth) }
        if let value = showDelay,value.isFinite { next.showDelay = max(0,min(5,value)) }
        if let value = hideDelay,value.isFinite { next.hideDelay = max(0,min(10,value)) }
        let data = try JSONEncoder().encode(next)
        defaults.set(data,forKey:hoverKey); hoverSettings = next
    }
    func setMenuBarIconVisible(_ visible: Bool) {
        defaults.set(visible,forKey:menuBarKey); menuBarIconVisible = visible
    }
    func remove(_ id: UUID) throws { try save(bindings.filter{$0.id != id}) }
}
