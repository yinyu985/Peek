import AppKit
import ApplicationServices

private func axRead(_ element: AXUIElement,_ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value:nil
}
private func axFrame(_ window: AXUIElement) -> CGRect? {
    guard let p = axRead(window,kAXPositionAttribute),CFGetTypeID(p) == AXValueGetTypeID(),
          let s = axRead(window,kAXSizeAttribute),CFGetTypeID(s) == AXValueGetTypeID(),
          AXValueGetType(p as! AXValue) == .cgPoint,AXValueGetType(s as! AXValue) == .cgSize else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size),
          point.x.isFinite,point.y.isFinite,size.width > 0,size.height > 0 else { return nil }
    return CGRect(origin:point,size:size)
}
private func axMove(_ window: AXUIElement,_ point: CGPoint) -> Bool {
    var value = CGPoint(x:point.x.rounded(),y:point.y.rounded())
    return AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,AXValueCreate(.cgPoint,&value)!) == .success
}
private func axResize(_ window: AXUIElement,_ size: CGSize) -> Bool {
    output("window_resize_requested",["width":size.width,"height":size.height])
    var value = size
    return AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&value)!) == .success
}
private func near(_ a: CGPoint,_ b: CGPoint) -> Bool { abs(a.x-b.x) < 2 && abs(a.y-b.y) < 2 }
private func onScreenWindows() -> [[String:Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
}
private func cgID(_ pid: pid_t,_ frame: CGRect) -> CGWindowID? {
    let matches = onScreenWindows().filter { info in
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let raw = info[kCGWindowBounds as String] as? [String:Any],let rect = CGRect(dictionaryRepresentation:raw as CFDictionary) else { return false }
        return near(rect.origin,frame.origin) && abs(rect.width-frame.width)<2 && abs(rect.height-frame.height)<2
    }
    guard matches.count == 1 else { return nil }
    return (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
}
struct WindowRecovery: Codable {
    let bindingID: UUID
    let pid: pid_t
    let launch: Double
    let bundle: String
    let title: String
    var original: CGRect
    var applicationHidden: Bool? = nil
}
private final class ManagedWindow {
    let element: AXUIElement
    var recovery: WindowRecovery
    let number: CGWindowID
    var hidden = false
    var hasShown = false
    var generation = 0
    init(_ element: AXUIElement,_ record: WindowRecovery,_ number: CGWindowID) {
        self.element = element; recovery = record; self.number = number
    }
}
private enum WindowInterruption: Error { case userInteraction }
final class WindowController {
    private let worker = DispatchQueue(label:"Peek.WindowControl",qos:.userInitiated)
    private var windows: [UUID:ManagedWindow] = [:] // Worker queue only.
    private var records: [UUID:WindowRecovery] = [:]
    private var busyIDs = Set<UUID>() // Main queue only.
    private var pendingToggles = Set<UUID>()
    private var pendingReveals = Set<UUID>()
    private var quitting = false
    private var hoverRefreshPending = false // Main queue only.
    private let epochLock = NSLock()
    private var epoch = 0
    private var observer: NSObjectProtocol?
    private let recoveryURL: URL
    var onWindowState: ((HoverWindow)->Void)?
    var onWindowRemoved: ((UUID)->Void)?
    var onBindingStatus: ((UUID,String,Bool)->Void)?
    var onPermissionNeeded: (()->Void)?
    var animationSettings = HoverSettings() // Read on main, captured per request.
    var interactionProvider: ()->Bool = { PointerInteraction.isBusy }
    private func respectUserInteraction() throws {
        if interactionProvider() { throw WindowInterruption.userInteraction }
    }
    init(recoveryURL: URL? = nil) {
        self.recoveryURL = recoveryURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Peek/window-recovery.json")
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }; self.epochLock.lock(); self.epoch += 1; self.epochLock.unlock()
        }
        if let data = try? Data(contentsOf:self.recoveryURL),let saved = try? JSONDecoder().decode([WindowRecovery].self,from:data) {
            records = Dictionary(saved.map{($0.bindingID,$0)},uniquingKeysWith:{ first,_ in first })
        }
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    private func spaceEpoch() -> Int { epochLock.lock(); defer { epochLock.unlock() }; return epoch }
    private func persist() throws {
        try FileManager.default.createDirectory(at:recoveryURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(Array(records.values)).write(to:recoveryURL,options:.atomic)
    }
    private func alive(_ record: WindowRecovery) -> Bool {
        guard let app = NSRunningApplication(processIdentifier:record.pid),app.bundleIdentifier == record.bundle,let launch = app.launchDate else { return false }
        return abs(launch.timeIntervalSince1970-record.launch)<0.001 && !app.isTerminated
    }
    private func select(_ binding: AppBinding) throws -> ManagedWindow {
        if let existing = windows[binding.id],alive(existing.recovery),axFrame(existing.element) != nil { return existing }
        // Retry any saved crash recovery before selecting a fresh window.
        guard records[binding.id] == nil || restoreRecord(binding.id) else {
            throw PeekError.message("窗口尚未恢复，请打开目标应用后再按快捷键重试。")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:binding.bundleID).first(where:{!$0.isTerminated}),let launch = app.launchDate else {
            throw PeekError.message("请先打开 \(binding.name) 的目标窗口，再按快捷键。")
        }
        if app.isHidden {
            // We hide the whole app for top-edge tucks. Recall means undoing that.
            if let saved = records[binding.id],saved.applicationHidden == true,saved.pid == app.processIdentifier {
                _ = app.unhide()
                for _ in 0..<20 where app.isHidden { Thread.sleep(forTimeInterval:0.02) }
            }
            guard !app.isHidden else { throw PeekError.message("请先从 Dock 显示 \(binding.name)，再绑定窗口。") }
        }
        let application = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(application,0.35)
        let all = (axRead(application,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            axRead($0,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole && (axRead($0,kAXMinimizedAttribute) as? Bool) == false
        }
        let selected: AXUIElement
        if let title = binding.windowTitle {
            let matches = all.filter { axRead($0,kAXTitleAttribute) as? String == title }
            guard matches.count == 1 else { throw PeekError.message("找不到唯一匹配的窗口，请重新选择窗口。") }
            selected = matches[0]
        } else if let focused = axRead(application,kAXFocusedWindowAttribute),CFGetTypeID(focused) == AXUIElementGetTypeID(),all.contains(where:{CFEqual($0,focused)}) {
            selected = focused as! AXUIElement
        } else if let main = axRead(application,kAXMainWindowAttribute),CFGetTypeID(main) == AXUIElementGetTypeID(),all.contains(where:{CFEqual($0,main)}) {
            selected = main as! AXUIElement
        } else if let first = all.first { selected = first }
        else { throw PeekError.message("这个应用尚无可管理的普通窗口。") }
        AXUIElementSetMessagingTimeout(selected,0.25)
        var observedFrame = axFrame(selected)
        var observedNumber = observedFrame.flatMap { cgID(app.processIdentifier,$0) }
        // AX and WindowServer snapshots can settle on different run-loop turns.
        for _ in 0..<8 where observedNumber == nil {
            Thread.sleep(forTimeInterval:0.04)
            observedFrame = axFrame(selected)
            observedNumber = observedFrame.flatMap { cgID(app.processIdentifier,$0) }
        }
        guard let frame = observedFrame,let number = observedNumber else {
            throw PeekError.message("无法确认当前桌面的目标窗口；未移动或切换桌面。")
        }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(selected,kAXPositionAttribute as CFString,&writable) == .success,writable.boolValue else { throw PeekError.message("这个窗口不支持位置控制。") }
        let title = axRead(selected,kAXTitleAttribute) as? String ?? ""
        let record = WindowRecovery(bindingID:binding.id,pid:app.processIdentifier,launch:launch.timeIntervalSince1970,bundle:binding.bundleID,title:title,original:frame)
        let managed = ManagedWindow(selected,record,number); windows[binding.id] = managed
        return managed
    }
    private func focus(_ target: ManagedWindow) throws {
        let appAX = AXUIElementCreateApplication(target.recovery.pid)
        _ = AXUIElementSetAttributeValue(target.element,kAXMainAttribute as CFString,kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(appAX,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
        guard let app = NSRunningApplication(processIdentifier:target.recovery.pid) else { throw PeekError.message("目标应用已退出。") }
        if result != .success { DispatchQueue.main.sync { _ = app.activate(options:[]) } }
        for _ in 0..<8 where !app.isActive { Thread.sleep(forTimeInterval:0.025) }
        guard app.isActive else { throw PeekError.message("窗口未能取得焦点，请再按快捷键重试。") }
        _ = AXUIElementPerformAction(target.element,kAXRaiseAction as CFString)
        output("window_focused",["binding":target.recovery.bindingID.uuidString,"pid":target.recovery.pid])
    }
    // Discover without moving/focusing windows. The worker serializes this with
    // animations; polling keeps geometry current after external window changes.
    func refreshHover(_ bindings: [AppBinding]) {
        guard !quitting,!hoverRefreshPending,AXIsProcessTrusted() else { return }
        hoverRefreshPending = true
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map { CGRect(x:$0.frame.minX,y:top-$0.frame.maxY,width:$0.frame.width,height:$0.frame.height) }
        worker.async {
            var snapshots: [HoverWindow] = []
            var missing: [UUID] = []
            for binding in bindings {
                // Automatic recovery owns saved records; discovery never restores.
                if self.records[binding.id] != nil && self.windows[binding.id] == nil { continue }
                guard let target = try? self.select(binding),let actual = axFrame(target.element) else {
                    missing.append(binding.id); continue
                }
                if target.hidden,target.recovery.applicationHidden != true,
                   screens.contains(where: { let area = $0.intersection(actual); return !area.isNull && area.width*area.height > actual.width*actual.height*0.5 }) {
                    target.hidden = false; target.hasShown = true
                    self.records.removeValue(forKey:binding.id); try? self.persist()
                }
                if !target.hidden {
                    target.recovery.original = actual
                    target.generation += 1 // Invalidate any delayed correction.
                    if self.records.removeValue(forKey:binding.id) != nil { try? self.persist() }
                }
                let frame = target.hidden ? target.recovery.original:actual
                guard let screen = screens.max(by: { a,b in
                    let aa = a.intersection(frame),bb = b.intersection(frame)
                    return (aa.isNull ? 0:aa.width*aa.height) < (bb.isNull ? 0:bb.width*bb.height)
                }),screen.intersects(frame) else { missing.append(binding.id); continue }
                snapshots.append(HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen,frame:frame,hidden:target.hidden,pid:target.recovery.pid))
            }
            DispatchQueue.main.async {
                self.hoverRefreshPending = false
                guard !self.quitting else { return }
                for id in missing { self.onWindowRemoved?(id) }
                for snapshot in snapshots { self.onWindowState?(snapshot) }
            }
        }
    }
    func toggle(_ binding: AppBinding) { request(binding,show:nil,source:"hotkey") }
    func setVisible(_ show: Bool,binding: AppBinding) { request(binding,show:show,source:"hover") }
    private func request(_ binding: AppBinding,show: Bool?,source: String) {
        output("window_request",["binding":binding.id.uuidString,"bundle":binding.bundleID,"source":source,"intent":show.map{$0 ? "show":"hide"} ?? "toggle"])
        guard !quitting else { return }
        guard AXIsProcessTrusted() else { onPermissionNeeded?(); return }
        if busyIDs.contains(binding.id) {
            if source == "hotkey" {
                if pendingToggles.contains(binding.id) { pendingToggles.remove(binding.id) }
                else { pendingToggles.insert(binding.id) }
            } else if show == true { pendingReveals.insert(binding.id) }
            output("window_request_coalesced",["binding":binding.id.uuidString,"source":source]); return
        }
        busyIDs.insert(binding.id)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map { screen -> (CGRect,CGRect) in
            func convert(_ frame: CGRect) -> CGRect { CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height) }
            return (convert(screen.frame),convert(screen.visibleFrame))
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = animationSettings
        worker.async {
            var message = ""; var success = false; var mutated = false; var snapshot: HoverWindow?
            do {
                try self.respectUserInteraction()
                let target = try self.select(binding)
                let currentEpoch = self.spaceEpoch()
                let onScreen = onScreenWindows().contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number }
                guard let start = axFrame(target.element) else { throw PeekError.message("目标窗口已关闭。") }
                // A window we cannot see is not an error: it may be tucked off the
                // edge, hidden by its app, or parked on another Space. Recall it.
                if !onScreen || target.hidden {
                    target.hidden = true; target.hasShown = false
                    if let saved = self.records[binding.id],saved.pid == target.recovery.pid,
                       saved.launch == target.recovery.launch,saved.title == target.recovery.title {
                        target.recovery = saved
                    }
                }
                // Other apps and macOS tiling can reveal a window while our state says hidden.
                // Trust its actual on-screen geometry before deciding or saving a layout.
                if target.hidden, target.recovery.applicationHidden != true, screens.contains(where: { screen in
                    let area = screen.0.intersection(start)
                    return !area.isNull && area.width * area.height > start.width * start.height * 0.5
                }) {
                    target.hidden = false; target.hasShown = true
                }
                output("window_before",["binding":binding.id.uuidString,"hidden":target.hidden,"x":start.minX,"y":start.minY,"width":start.width,"height":start.height,"saved_x":target.recovery.original.minX,"saved_y":target.recovery.original.minY])
                var reference = target.hidden ? target.recovery.original:start
                // If every saved coordinate is off-screen (display changed, edge
                // tuck from a dead session), fall back to the main screen centre
                // instead of refusing to recall the window.
                if !screens.contains(where:{ !$0.0.intersection(reference).isNull }) {
                    if let main = NSScreen.main,let mainScreen = screens.first(where:{ $0.0 == main.frame }) {
                        reference = CGRect(x:mainScreen.0.midX-start.width/2,y:mainScreen.0.midY-start.height/2,width:start.width,height:start.height)
                        target.recovery.original = reference
                    }
                }
                guard let screen = screens.max(by:{ a,b in
                    let aa = a.0.intersection(reference),bb = b.0.intersection(reference)
                    return (aa.isNull ? 0:aa.width*aa.height) < (bb.isNull ? 0:bb.width*bb.height)
                }), screen.0.intersects(reference) else { throw PeekError.message("原显示器已断开，请恢复窗口后重新绑定。") }
                // On-screen geometry does not mean the user can see the window.
                // From another app, a shortcut recalls it; from the target (or
                // Peek's own controls), the next shortcut can tuck it away.
                let canHide = frontPID == target.recovery.pid || (frontPID == ProcessInfo.processInfo.processIdentifier && target.hasShown)
                let hide = show.map{!$0} ?? (!target.hidden && canHide)
                // A visible window belongs to the user: remember their latest layout.
                if !target.hidden {
                    let old = target.recovery
                    target.recovery = WindowRecovery(bindingID:old.bindingID,pid:old.pid,launch:old.launch,bundle:old.bundle,title:old.title,original:start)
                }
                let stableSize = target.recovery.original.size
                let shown = binding.selectedEdge.shown(CGRect(origin:target.recovery.original.origin,size:stableSize),visible:screen.1)
                let destination = hide ? binding.selectedEdge.hidden(CGRect(origin:shown,size:stableSize),screen:screen.0):shown
                let destinationFrame = CGRect(origin:destination,size:stableSize)
                if hide && binding.selectedEdge != .top && screens.contains(where:{$0.0 != screen.0 && $0.0.intersects(destinationFrame)}) { throw PeekError.message("该方向连接另一块显示器，请选择外侧边缘。") }
                try self.respectUserInteraction()
                self.records[binding.id] = target.recovery; try self.persist() // Before any movement.
                mutated = true; target.generation += 1
                let application = NSRunningApplication(processIdentifier:target.recovery.pid)
                if binding.selectedEdge == .top || target.recovery.applicationHidden == true {
                    let axApp = AXUIElementCreateApplication(target.recovery.pid)
                    let ordinary = (axRead(axApp,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
                        axRead($0,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
                    }
                    guard ordinary.count == 1, let application else {
                        throw PeekError.message("顶部收起目前要求应用只有一个普通窗口。")
                    }
                    if hide {
                        target.recovery.applicationHidden = true
                        self.records[binding.id] = target.recovery; try self.persist()
                        guard AXUIElementSetAttributeValue(axApp,kAXHiddenAttribute as CFString,kCFBooleanTrue) == .success else { throw PeekError.message("应用拒绝收起。") }
                    } else {
                        guard AXUIElementSetAttributeValue(axApp,kAXHiddenAttribute as CFString,kCFBooleanFalse) == .success else { throw PeekError.message("应用恢复失败。") }
                        try self.focus(target)
                        try self.respectUserInteraction()
                        if let actual = axFrame(target.element),abs(actual.width-stableSize.width)>1 || abs(actual.height-stableSize.height)>1 { _ = axResize(target.element,stableSize) }
                        guard axMove(target.element,shown) else { throw PeekError.message("原位置恢复失败。") }
                    }
                    Thread.sleep(forTimeInterval:0.1)
                    guard application.isHidden == hide else { throw PeekError.message("应用可见状态未达到目标。") }
                    target.hidden = hide; target.hasShown = !hide
                    target.recovery.applicationHidden = hide
                    self.records[binding.id] = target.recovery; try self.persist()
                    snapshot = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:CGRect(origin:shown,size:stableSize),hidden:hide,manualHide:hide && source == "hotkey",pid:target.recovery.pid)
                    message = hide ? "窗口已收起，可从顶部唤回":"窗口已恢复原位"
                    output("window_toggle",["success":true,"bundle":binding.bundleID,"edge":binding.selectedEdge.rawValue,"hidden":hide,"backend":"single-window-app-hide","x":shown.x,"y":shown.y])
                    success = true
                } else {

                // Raising can change an application's layout. Do it before restoring geometry.
                if !hide { try self.focus(target) }
                let began = ProcessInfo.processInfo.systemUptime
                let duration = reduceMotion ? 0.0:(hide ? animation.hideDuration:animation.showDuration)
                repeat {
                    try self.respectUserInteraction()
                    guard self.spaceEpoch() == currentEpoch else { throw PeekError.message("桌面已切换，已停止动画。") }
                    let t = duration == 0 ? 1:min(1,(ProcessInfo.processInfo.systemUptime-began)/duration)
                    let eased = t*t*(3-2*t)
                    let point = CGPoint(x:start.minX+(destination.x-start.minX)*eased,y:start.minY+(destination.y-start.minY)*eased)
                    guard axMove(target.element,point) else { throw PeekError.message("窗口拒绝移动，已尝试恢复原位。") }
                    if t >= 1 { break }; Thread.sleep(forTimeInterval:1.0/60)
                } while true
                Thread.sleep(forTimeInterval:0.06)
                try self.respectUserInteraction()
                if let actual = axFrame(target.element),
                   abs(actual.width-stableSize.width)>1 || abs(actual.height-stableSize.height)>1 {
                    guard axResize(target.element,stableSize),axMove(target.element,destination) else {
                        throw PeekError.message("窗口尺寸恢复失败。")
                    }
                    Thread.sleep(forTimeInterval:0.06)
                }
                guard let final = axFrame(target.element) else { throw PeekError.message("目标窗口已关闭。") }
                // Tuck accepts the bottom title strip retained by AppKit. A real
                // tuck is not a failure merely because y was clamped by 28pt.
                let visibleStrip = screen.0.intersection(final)
                let bottomTitleStrip = hide && binding.selectedEdge == .bottom
                    && abs(final.minX-shown.x)<2 && final.minY > shown.y+2
                    && final.minY >= screen.0.maxY-64
                    && !visibleStrip.isNull && visibleStrip.height <= min(64,stableSize.height*0.2)
                guard near(final.origin,destination) || bottomTitleStrip else {
                    output("window_position_mismatch",["binding":binding.id.uuidString,"requested_x":destination.x,"requested_y":destination.y,"actual_x":axFrame(target.element)?.minX ?? 0,"actual_y":axFrame(target.element)?.minY ?? 0])
                    throw PeekError.message("目标应用拒绝了窗口移动，已恢复原位置。")
                }
                if bottomTitleStrip && !near(final.origin,destination) {
                    output("window_edge_clamped",["edge":"bottom","requested_y":destination.y,"actual_y":final.minY,"visible_strip":visibleStrip.height])
                }
                if abs(final.width-stableSize.width)>1 || abs(final.height-stableSize.height)>1 {
                    output("window_size_observed",["binding":binding.id.uuidString,"width":final.width,"height":final.height,"original_width":stableSize.width,"original_height":stableSize.height])
                }
                guard abs(final.width-stableSize.width)<2 && abs(final.height-stableSize.height)<2 else {
                    throw PeekError.message("窗口宽高发生变化，已停止收起并恢复原尺寸。")
                }
                target.hidden = hide; target.hasShown = !hide; target.generation += 1
                let generation = target.generation
                if hide {
                    self.worker.asyncAfter(deadline:.now()+0.6) { [weak self,weak target] in
                        guard let self,let target,!self.interactionProvider(),self.windows[binding.id] === target,target.generation == generation,target.hidden,
                              let later = axFrame(target.element) else { return }
                        // Delayed observation is read-only. A later resize may be
                        // the user's work, not drift that we are entitled to undo.
                        output("window_settled",["binding":binding.id.uuidString,"expected_x":destination.x,"expected_y":destination.y,"actual_x":later.minX,"actual_y":later.minY,"width":later.width,"height":later.height])
                        let visibleArea = screen.0.intersection(later)
                        if !near(later.origin,destination), !visibleArea.isNull,
                           visibleArea.width * visibleArea.height > later.width * later.height * 0.5 {
                            target.hidden = false; target.hasShown = true
                            target.recovery.original = later; target.generation += 1
                            self.records.removeValue(forKey:binding.id); try? self.persist()
                            DispatchQueue.main.async {
                                let updated = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:later,hidden:false,pid:target.recovery.pid)
                                self.onWindowState?(updated)
                                self.onBindingStatus?(binding.id,"检测到窗口位置变化，已同步状态；快捷键仍可使用。",false)
                            }
                        }
                    }
                }
                snapshot = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:CGRect(origin:shown,size:stableSize),hidden:hide,manualHide:hide && source == "hotkey",pid:target.recovery.pid)
                message = hide ? "窗口已收至\(binding.selectedEdge.title)":"窗口已展开"
                output("window_toggle",["success":true,"bundle":binding.bundleID,"edge":binding.selectedEdge.rawValue,"hidden":hide,"x":final.minX,"y":final.minY,"width":final.width,"height":final.height,"source":source,"animation_ms":duration*1000,"duration_ms":(ProcessInfo.processInfo.systemUptime-began)*1000])
                success = true
                }
                // A visible window no longer needs crash recovery. Keeping its old
                // frame would undo later user positioning on the next app launch.
                if snapshot?.hidden == false { self.records.removeValue(forKey:binding.id); try self.persist() }
            } catch WindowInterruption.userInteraction {
                // Never roll back geometry when the user takes over a drag.
                if let target = self.windows[binding.id],let actual = axFrame(target.element) {
                    target.generation += 1
                    let visible = screens.contains { screen in
                        let area = screen.0.intersection(actual)
                        return !area.isNull && area.width*area.height > actual.width*actual.height*0.5
                    }
                    target.hidden = !visible; target.hasShown = visible
                    if visible {
                        target.recovery.original = actual; target.recovery.applicationHidden = false
                        self.records.removeValue(forKey:binding.id); try? self.persist()
                    }
                    let frame = visible ? actual:target.recovery.original
                    if let screen = screens.max(by: { a,b in
                        let aa = a.0.intersection(frame),bb = b.0.intersection(frame)
                        return (aa.isNull ? 0:aa.width*aa.height) < (bb.isNull ? 0:bb.width*bb.height)
                    }) {
                        snapshot = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:frame,hidden:!visible,pid:target.recovery.pid)
                    }
                }
                output("window_yielded_to_user",["binding":binding.id.uuidString,"source":source])
            } catch {
                success = false; message = error.localizedDescription
                if mutated,!self.interactionProvider(),let target = self.windows[binding.id],self.records[binding.id] != nil {
                    target.hidden = true
                    if self.restore(target) { self.windows.removeValue(forKey:binding.id); self.records.removeValue(forKey:binding.id); try? self.persist() }
                    else { message += " 恢复尚未完成，请稍后再按快捷键重试。" }
                }
                output("window_toggle",["success":false,"bundle":binding.bundleID,"message":message])
            }
            DispatchQueue.main.async {
                self.busyIDs.remove(binding.id); self.onBindingStatus?(binding.id,message,!success)
                if let snapshot { self.onWindowState?(snapshot) } else { self.onWindowRemoved?(binding.id) }
                let pendingToggle = self.pendingToggles.remove(binding.id) != nil
                let pendingReveal = self.pendingReveals.remove(binding.id) != nil
                if success && !self.quitting {
                    if pendingToggle { self.toggle(binding) }
                    else if pendingReveal && snapshot?.hidden == true { self.setVisible(true,binding:binding) }
                }
            }
        }
    }
    private func restore(_ target: ManagedWindow) -> Bool {
        guard alive(target.recovery) else { return true }
        guard axFrame(target.element) != nil else { return true } // Closed windows need no mutation.
        if target.recovery.applicationHidden == true { _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(target.recovery.pid),kAXHiddenAttribute as CFString,kCFBooleanFalse) }
        if !target.hidden { return true } // Do not undo user edits to a visible window on quit.
        if let actual = axFrame(target.element),abs(actual.width-target.recovery.original.width)>1 || abs(actual.height-target.recovery.original.height)>1 { _ = axResize(target.element,target.recovery.original.size) }
        guard axMove(target.element,target.recovery.original.origin) else { return false }
        Thread.sleep(forTimeInterval:0.06)
        return axFrame(target.element).map { near($0.origin,target.recovery.original.origin) && abs($0.width-target.recovery.original.width)<2 && abs($0.height-target.recovery.original.height)<2 } ?? false
    }
    func forget(_ id: UUID,completion: @escaping (Bool)->Void) {
        worker.async {
            let success = self.restoreRecord(id)
            DispatchQueue.main.async { if success { self.onWindowRemoved?(id) }; completion(success) }
        }
    }
    private func restoreRecord(_ id: UUID) -> Bool {
        if let managed = windows[id] {
            guard restore(managed) else { return false }
        } else if let record = records[id],alive(record) {
            if record.applicationHidden == true { _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(record.pid),kAXHiddenAttribute as CFString,kCFBooleanFalse) }
            let app = AXUIElementCreateApplication(record.pid); AXUIElementSetMessagingTimeout(app,0.35)
            let matching = (axRead(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter { axRead($0,kAXTitleAttribute) as? String == record.title }
            guard matching.count == 1 else { return false }
            AXUIElementSetMessagingTimeout(matching[0],0.25)
            if let actual = axFrame(matching[0]),abs(actual.width-record.original.width)>1 || abs(actual.height-record.original.height)>1 { _ = axResize(matching[0],record.original.size) }
            guard axMove(matching[0],record.original.origin) else { return false }
            Thread.sleep(forTimeInterval:0.06)
            guard axFrame(matching[0]).map({near($0.origin,record.original.origin)}) == true else { return false }
        }
        windows.removeValue(forKey:id); records.removeValue(forKey:id)
        DispatchQueue.main.async { self.onWindowRemoved?(id) }
        do { try persist() } catch { return false }; return true
    }
    func restoreAll(completion: @escaping (Bool)->Void) {
        worker.async {
            var success = true
            for id in Array(self.records.keys) { if !self.restoreRecord(id) { success = false } }
            DispatchQueue.main.async { completion(success) }
        }
    }
    func restoreForQuit(completion: @escaping (Bool)->Void) {
        quitting = true
        restoreAll { success in if !success { self.quitting = false }; completion(success) }
    }
}
