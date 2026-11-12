import AppKit
import ApplicationServices

// Read-only identity lookup. Never infer a recovery target from its title.
@_silgen_name("_AXUIElementGetWindow") private func axGetWindowNumber(_ element: AXUIElement,_ number: UnsafeMutablePointer<CGWindowID>) -> AXError
private func axWindowNumber(_ element: AXUIElement) -> CGWindowID? {
    var number: CGWindowID = 0
    return axGetWindowNumber(element,&number) == .success && number != 0 ? number:nil
}

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
private func serverFrame(_ number: CGWindowID) -> CGRect? {
    guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow,number) as? [[String:Any]])?.first,
          let bounds = info[kCGWindowBounds as String] as? [String:Any] else { return nil }
    return CGRect(dictionaryRepresentation:bounds as CFDictionary)
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
enum WindowAnimationMode: String { case windowMove, windowResize, systemMinimize }
enum WindowHideStrategy: String, Codable {
    case edgeMove, compression, minimize, shade, parked, appHide
    var animationMode: WindowAnimationMode {
        switch self { case .edgeMove, .shade, .parked, .appHide: return .windowMove; case .compression: return .windowResize; case .minimize: return .systemMinimize }
    }
}
struct WindowRecovery: Codable {
    let bindingID: UUID
    let pid: pid_t
    let launch: Double
    let bundle: String
    let title: String
    var original: CGRect
    var applicationHidden: Bool? = nil // True only after journaling our own app hide.
    var parkedFrame: CGRect? = nil
    var shadeFrame: CGRect? = nil
    var shadeSpaceIDs: [UInt64]? = nil
    var windowNumber: CGWindowID? = nil
    var hideStrategy: WindowHideStrategy? = nil
    var originalMinimized: Bool? = nil
    var compressedFrame: CGRect? = nil // Last geometry written by Peek, never the expanded size.
    var compressionInProgress: Bool? = nil
}
private final class ManagedWindow {
    var element: AXUIElement
    var recovery: WindowRecovery
    let number: CGWindowID
    var hidden = false
    var hasShown = false
    var generation = 0
    var tuckedOrigin: CGPoint?
    var revealWidth: CGFloat = 0
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
    private var detachedIDs = Set<UUID>() // Main queue only; discard late callbacks after removal.
    private var unsupportedCompression = Set<CGWindowID>() // Worker queue only.
    private var failedParking: [CGWindowID:(frame:CGRect,screens:[CGRect],until:TimeInterval)] = [:]
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
    var foregroundProvider: ()->pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
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
    private func compressionAlreadyRestored(_ record: WindowRecovery) -> Bool {
        guard record.hideStrategy == .compression,let number = record.windowNumber else { return false }
        // A read-only confirmation of the exact window's full original frame.
        // Electron can temporarily omit AXWindows even after restoring its size.
        for sample in 0..<4 {
            guard alive(record),
                  let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow,number) as? [[String:Any]])?.first,
                  (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == record.pid,
                  let bounds = info[kCGWindowBounds as String] as? [String:Any],
                  let actual = CGRect(dictionaryRepresentation:bounds as CFDictionary),
                  near(actual.origin,record.original.origin),sameSize(actual.size,record.original.size) else { return false }
            if sample < 3 { Thread.sleep(forTimeInterval:0.05) }
        }
        return true
    }
    private func recoveredElement(_ record: WindowRecovery) -> AXUIElement? {
        guard alive(record),let number = record.windowNumber else { return nil }
        let app = AXUIElementCreateApplication(record.pid); AXUIElementSetMessagingTimeout(app,0.35)
        guard let candidates = axRead(app,kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let matching = candidates.filter { axWindowNumber($0) == number }
        guard matching.count == 1 else { return nil }
        AXUIElementSetMessagingTimeout(matching[0],0.25)
        return matching[0]
    }
    private func select(_ binding: AppBinding,allowOtherSpaces: Bool = false) throws -> ManagedWindow {
        if let existing = windows[binding.id] {
            if axWindowNumber(existing.element) != existing.number || axFrame(existing.element) == nil,
               let refreshed = recoveredElement(existing.recovery) { existing.element = refreshed }
            if existing.recovery.hideStrategy == .appHide,alive(existing.recovery) { return existing }
            guard alive(existing.recovery),axWindowNumber(existing.element) == existing.number,axFrame(existing.element) != nil else {
                throw PeekError.message(L("原目标窗口已失效或暂时无法读取；请恢复后重新绑定，不会替换成其他窗口。"))
            }
            return existing
        }
        // Retry any saved crash recovery before selecting a fresh window.
        if let saved = records[binding.id],alive(saved),saved.windowNumber == nil {
            throw PeekError.message(L("旧恢复记录缺少窗口 ID。请手动恢复窗口，退出并重开目标应用后重试；不会按标题猜测窗口。"))
        }
        guard records[binding.id] == nil || restoreRecord(binding.id,allowSpaceSwitch:allowOtherSpaces) else {
            throw PeekError.message(L("窗口尚未恢复，请打开目标应用后再按快捷键重试。"))
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:binding.bundleID).first(where:{!$0.isTerminated}),let launch = app.launchDate else {
            throw PeekError.message(L("请先打开 {0} 的目标窗口，再按快捷键。",binding.name))
        }
        guard !app.isHidden else { throw PeekError.message(L("请先从 Dock 显示 {0}，再绑定窗口。",binding.name)) }
        let application = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(application,0.35)
        let all = (axRead(application,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            axRead($0,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole && (axRead($0,kAXMinimizedAttribute) as? Bool) == false
        }
        let selected: AXUIElement
        if let title = binding.windowTitle {
            let matches = all.filter { axRead($0,kAXTitleAttribute) as? String == title }
            guard matches.count == 1 else { throw PeekError.message(L("找不到唯一匹配的窗口，请重新选择窗口。")) }
            selected = matches[0]
        } else if let focused = axRead(application,kAXFocusedWindowAttribute),CFGetTypeID(focused) == AXUIElementGetTypeID(),all.contains(where:{CFEqual($0,focused)}) {
            selected = focused as! AXUIElement
        } else if let main = axRead(application,kAXMainWindowAttribute),CFGetTypeID(main) == AXUIElementGetTypeID(),all.contains(where:{CFEqual($0,main)}) {
            selected = main as! AXUIElement
        } else if let first = all.first { selected = first }
        else { throw PeekError.message(L("这个应用尚无可管理的普通窗口。")) }
        AXUIElementSetMessagingTimeout(selected,0.25)
        var observedFrame = axFrame(selected)
        func visibleNumber() -> CGWindowID? {
            guard let number = axWindowNumber(selected) else { return nil }
            let visible = onScreenWindows().contains(where:{
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number && ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
            })
            guard visible || (allowOtherSpaces && WindowSpaces.membership(number) == .other) else { return nil }
            return number
        }
        var observedNumber = visibleNumber()
        // AX and WindowServer snapshots can settle on different run-loop turns.
        for _ in 0..<8 where observedNumber == nil {
            Thread.sleep(forTimeInterval:0.04)
            observedFrame = axFrame(selected)
            observedNumber = visibleNumber()
        }
        guard let frame = observedFrame,let number = observedNumber else {
            throw PeekError.message(L("无法确认当前桌面的目标窗口；未移动或切换桌面。"))
        }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(selected,kAXPositionAttribute as CFString,&writable) == .success,writable.boolValue else { throw PeekError.message(L("这个窗口不支持位置控制。")) }
        let title = axRead(selected,kAXTitleAttribute) as? String ?? ""
        let record = WindowRecovery(bindingID:binding.id,pid:app.processIdentifier,launch:launch.timeIntervalSince1970,bundle:binding.bundleID,title:title,original:frame,windowNumber:number)
        let managed = ManagedWindow(selected,record,number); windows[binding.id] = managed
        return managed
    }
    private func serverOwns(_ record: WindowRecovery) -> Bool {
        guard alive(record),let number = record.windowNumber,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow,number) as? [[String:Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number &&
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == record.pid }
    }
    private func shadeMembership(_ record: WindowRecovery) -> WindowSpaceMembership {
        guard let number = record.windowNumber else { return .unknown }
        let direct = WindowSpaces.membership(number)
        // App hide removes windows from public WindowServer listings. Retain
        // their last confirmed Space assignment before hiding, not visibility.
        if direct == .unknown,record.hideStrategy == .appHide,
           let assigned = record.shadeSpaceIDs,let active = WindowSpaces.activeSpaceIDs() {
            return WindowSpaces.classify(assigned:Set(assigned),active:active)
        }
        return direct
    }
    private func saveShade(_ target: ManagedWindow) throws {
        records[target.recovery.bindingID] = target.recovery; try persist()
    }
    private func singleWindowApplication(_ target: ManagedWindow,screens: [CGRect]) -> Bool {
        let app = AXUIElementCreateApplication(target.recovery.pid)
        AXUIElementSetMessagingTimeout(app,0.35)
        // Count all AX windows, including minimized windows and dialogs. Unknown
        // identities or omitted visible siblings cannot authorize an app-wide hide.
        guard let list = axRead(app,kAXWindowsAttribute) as? [AXUIElement],list.count == 1,
              axWindowNumber(list[0]) == target.number,
              let all = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] else {
            output("shade_app_hide_rejected",["reason":"AX window count or identity unknown"]); return false
        }
        let siblings = all.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.recovery.pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value != target.number else { return false }
            // AppKit retains non-shareable, off-screen menu-bar backing surfaces
            // at layer zero. They are not user windows. Exclude only that exact
            // geometry; any other unknown layer-zero surface blocks app hide.
            if (info[kCGWindowSharingState as String] as? Int) == 0,
               (info[kCGWindowIsOnscreen as String] as? Bool) != true,
               let data = info[kCGWindowBounds as String] as? [String:Any],
               let bounds = CGRect(dictionaryRepresentation:data as CFDictionary),
               screens.contains(where:{ near(bounds.origin,$0.origin) && abs(bounds.width-$0.width)<2 && bounds.height > 0 && bounds.height <= 32 }) { return false }
            return true
        }
        if !siblings.isEmpty { output("shade_app_hide_rejected",["reason":"WindowServer siblings","count":siblings.count]) }
        return siblings.isEmpty
    }
    private func handOffShadeFocus(_ target: ManagedWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier:target.recovery.pid) else { return false }
        if !app.isActive { return true }
        // Activate only an already visible window on this Space. Hiding the
        // foreground application without a successor can unexpectedly switch Space.
        for info in onScreenWindows() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != target.recovery.pid,pid != ProcessInfo.processInfo.processIdentifier,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  WindowSpaces.membership(number) == .current,
                  let candidate = NSRunningApplication(processIdentifier:pid),candidate.activationPolicy == .regular else { continue }
            let application = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(application,0.25)
            guard let windows = axRead(application,kAXWindowsAttribute) as? [AXUIElement],
                  let window = windows.first(where:{axWindowNumber($0) == number}) else { continue }
            _ = AXUIElementSetAttributeValue(window,kAXMainAttribute as CFString,kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(application,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
            for _ in 0..<12 where app.isActive { Thread.sleep(forTimeInterval:0.025) }
            return !app.isActive
        }
        return false
    }
    private func unhideOwnedApplication(_ target: ManagedWindow) throws {
        guard target.recovery.hideStrategy == .appHide,target.recovery.applicationHidden == true,
              alive(target.recovery),let app = NSRunningApplication(processIdentifier:target.recovery.pid) else {
            throw PeekError.message(L("无法确认原窗口的隐藏记录，已保留恢复信息。"))
        }
        if app.isHidden { _ = app.unhide() }
        let deadline = ProcessInfo.processInfo.systemUptime+1.5
        repeat {
            if !app.isHidden,let element = recoveredElement(target.recovery) {
                target.element = element; return
            }
            Thread.sleep(forTimeInterval:0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw PeekError.message(L("应用尚未恢复可见，已保留标题条恢复记录。"))
    }
    private func waitShadeFrame(_ target: ManagedWindow,_ frame: CGRect) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime+1.2
        var stable = 0
        repeat {
            guard alive(target.recovery),axWindowNumber(target.element) == target.number else { return false }
            let matches = axFrame(target.element).map { near($0.origin,frame.origin) && sameSize($0.size,frame.size) } == true &&
                serverFrame(target.number).map { near($0.origin,frame.origin) && sameSize($0.size,frame.size) } == true
            stable = matches ? stable+1:0
            if stable >= 3 { return true }
            Thread.sleep(forTimeInterval:0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    private func hideShade(_ target: ManagedWindow,screens: [CGRect],epoch: Int) throws {
        let original = target.recovery.original
        let desktop = screens.reduce(CGRect.null) { $0.union($1) }
        guard !desktop.isNull else { throw PeekError.message(L("无法读取显示器范围。")) }
        // Horizontal parking preserves the titlebar's y coordinate. AppKit often
        // clamps vertical movement; no resize or private WindowServer writes.
        let cached = failedParking[target.number]
        let recentlyRejected = cached.map { $0.frame == original && $0.screens == screens && $0.until > ProcessInfo.processInfo.systemUptime } ?? false
        let candidates = recentlyRejected ? []:[CGPoint(x:desktop.maxX+32,y:original.minY),
                          CGPoint(x:desktop.minX-original.width-32,y:original.minY)]
        for point in candidates {
            try respectUserInteraction()
            guard spaceEpoch() == epoch,WindowSpaces.membership(target.number) == .current,
                  alive(target.recovery),axWindowNumber(target.element) == target.number else {
                throw PeekError.message(L("窗口或桌面状态改变，已停止收起。"))
            }
            let planned = CGRect(origin:point,size:original.size)
            target.recovery.hideStrategy = .parked; target.recovery.parkedFrame = planned
            try saveShade(target) // Journal before every write, including a rejected attempt.
            let moved = axMove(target.element,point)
            if moved && waitShadeFrame(target,planned),
               screens.allSatisfy({!$0.intersects(planned)}) {
                target.tuckedOrigin = planned.origin
                target.hidden = true
                return
            }
            if let actual = axFrame(target.element) {
                target.recovery.parkedFrame = actual; try saveShade(target)
            }
            try respectUserInteraction()
            guard spaceEpoch() == epoch,axMove(target.element,original.origin),waitShadeFrame(target,original) else {
                throw PeekError.message(L("屏外停放未完成，保留原窗口恢复记录。"))
            }
        }
        if !candidates.isEmpty {
            failedParking[target.number] = (original,screens,ProcessInfo.processInfo.systemUptime+30)
        }
        try respectUserInteraction()
        guard singleWindowApplication(target,screens:screens) else {
            throw PeekError.message(L("这个窗口无法停到屏外；应用还有其他窗口或窗口数量无法确认，未隐藏整个应用。可明确选择“最小化”。"))
        }
        guard handOffShadeFocus(target),spaceEpoch() == epoch,WindowSpaces.membership(target.number) == .current,
              singleWindowApplication(target,screens:screens) else {
            throw PeekError.message(L("当前无法安全隐藏应用，窗口已保持原状。"))
        }
        target.recovery.hideStrategy = .appHide; target.recovery.applicationHidden = true
        target.recovery.parkedFrame = nil; try saveShade(target)
        guard let app = NSRunningApplication(processIdentifier:target.recovery.pid),!app.isHidden else {
            throw PeekError.message(L("应用可见状态改变，已停止收起。"))
        }
        let hideResult = app.hide()
        output("shade_app_hide_requested",["accepted":hideResult])
        let deadline = ProcessInfo.processInfo.systemUptime+1.5
        repeat {
            guard alive(target.recovery),spaceEpoch() == epoch else { throw PeekError.message(L("桌面或应用状态改变，已保留隐藏恢复记录。")) }
            if app.isHidden,alive(target.recovery),
               !onScreenWindows().contains(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number}) {
                target.hidden = true; return
            }
            Thread.sleep(forTimeInterval:0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        output("shade_app_hide_observed",["hidden":app.isHidden,"server_identity":serverOwns(target.recovery),"onscreen":onScreenWindows().contains(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number}),"AX_hidden":axRead(AXUIElementCreateApplication(target.recovery.pid),kAXHiddenAttribute) as? Bool ?? false])
        throw PeekError.message(L("应用隐藏尚未确认，已尝试恢复。"))
    }
    private func revealShade(_ target: ManagedWindow,shown: CGPoint,focusPrepared: Bool) throws {
        if target.recovery.hideStrategy == .appHide { try unhideOwnedApplication(target) }
        guard alive(target.recovery),axWindowNumber(target.element) == target.number else { throw PeekError.message(L("原窗口暂时无法读取。")) }
        try respectUserInteraction()
        guard axMove(target.element,shown),waitShadeFrame(target,CGRect(origin:shown,size:target.recovery.original.size)) else {
            throw PeekError.message(L("原窗口位置尚未恢复，已保留恢复记录。"))
        }
        if !focusPrepared { try focus(target) }
        guard let actual = axFrame(target.element),sameSize(actual.size,target.recovery.original.size) else {
            throw PeekError.message(L("窗口尺寸发生变化，已停止操作。"))
        }
    }
    private func restoreShade(_ target: ManagedWindow) -> Bool {
        guard alive(target.recovery) else { return true }
        if target.recovery.hideStrategy == .appHide {
            guard shadeMembership(target.recovery) == .current else { return false }
            do { try unhideOwnedApplication(target) } catch { return false }
            return true // Hiding did not alter geometry.
        }
        guard serverOwns(target.recovery) else {
            guard let all = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] else { return false }
            return !all.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number }
        }
        guard WindowSpaces.membership(target.number) == .current else { return false }
        if let refreshed = recoveredElement(target.recovery) { target.element = refreshed }
        guard let actual = axFrame(target.element),axWindowNumber(target.element) == target.number else { return false }
        if near(actual.origin,target.recovery.original.origin) { return true }
        guard let parked = target.recovery.parkedFrame,near(actual.origin,parked.origin),sameSize(actual.size,parked.size) else {
            return false // Unknown ownership: retain the journal instead of undoing user edits.
        }
        guard axMove(target.element,target.recovery.original.origin) else { return false }
        return waitShadeFrame(target,CGRect(origin:target.recovery.original.origin,size:actual.size))
    }
    private func shadeSnapshot(_ target: ManagedWindow,binding: AppBinding,screens: [CGRect],allowOtherSpaces: Bool) -> HoverWindow? {
        guard alive(target.recovery),
              target.recovery.hideStrategy == .appHide || (target.recovery.hideStrategy == .parked && serverOwns(target.recovery)) else { return nil }
        let membership = shadeMembership(target.recovery)
        guard membership == .current || (allowOtherSpaces && membership == .other) else { return nil }
        let appHidden = NSRunningApplication(processIdentifier:target.recovery.pid)?.isHidden == true
        let actual = serverFrame(target.number)
        // External reveal (Dock, Command-Tab, new window) ends ownership; don't
        // hide the application again merely because a sibling became visible.
        let externallyShown = target.recovery.hideStrategy == .appHide ? !appHidden :
            actual.map { frame in screens.contains {
                let area = $0.intersection(frame)
                return !area.isNull && area.width*area.height > frame.width*frame.height*0.5
            } } == true
        if externallyShown,let actual {
            target.hidden = false; target.hasShown = true; target.recovery.original = actual
            target.recovery.hideStrategy = nil; target.recovery.applicationHidden = nil; target.recovery.parkedFrame = nil
            records.removeValue(forKey:binding.id); try? persist()
            guard let screen = screens.first(where:{$0.intersects(actual)}) else { return nil }
            return HoverWindow(id:binding.id,edge:.top,screen:screen,frame:actual,hidden:false,pid:target.recovery.pid,onCurrentSpace:membership == .current)
        }
        let frame = target.recovery.shadeFrame ?? target.recovery.original
        guard let screen = screens.max(by:{a,b in
            let aa = a.intersection(frame),bb = b.intersection(frame)
            return (aa.isNull ? 0:aa.width*aa.height) < (bb.isNull ? 0:bb.width*bb.height)
        }),screen.intersects(frame) else { return nil }
        return HoverWindow(id:binding.id,edge:.top,screen:screen,frame:frame,hidden:true,pid:target.recovery.pid,
            compressedFrame:CGRect(x:frame.minX,y:frame.minY,width:frame.width,height:24),shadeTitle:binding.name,onCurrentSpace:membership == .current)
    }
    private func setMinimized(_ minimized: Bool,_ target: ManagedWindow) throws {
        guard alive(target.recovery),axWindowNumber(target.element) == target.number else { throw PeekError.message(L("目标窗口身份已改变，已停止操作。")) }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target.element,kAXMinimizedAttribute as CFString,&writable) == .success,writable.boolValue else {
            throw PeekError.message(L("这个窗口不支持最小化；不会隐藏整个应用。"))
        }
        guard AXUIElementSetAttributeValue(target.element,kAXMinimizedAttribute as CFString,minimized ? kCFBooleanTrue:kCFBooleanFalse) == .success else {
            throw PeekError.message(L("窗口拒绝最小化状态变更。"))
        }
        let deadline = ProcessInfo.processInfo.systemUptime+2
        repeat {
            var number: CGWindowID = 0
            let identity = axGetWindowNumber(target.element,&number)
            if identity == .invalidUIElement || (identity == .success && number != 0 && number != target.number) {
                throw PeekError.message(L("目标窗口已关闭或身份已改变。"))
            }
            // Dock animation can temporarily make AX identity/state unreadable.
            // Retry reads within the deadline; never substitute another element.
            if identity == .success,number == target.number,(axRead(target.element,kAXMinimizedAttribute) as? Bool) == minimized { return }
            Thread.sleep(forTimeInterval:0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw PeekError.message(L("最小化状态未确认；保留恢复记录，不记作收起成功。"))
    }
    private func sameSize(_ a: CGSize,_ b: CGSize) -> Bool { abs(a.width-b.width)<2 && abs(a.height-b.height)<2 }
    private func rememberCompression(_ target: ManagedWindow,_ frame: CGRect,inProgress: Bool) throws {
        target.recovery.compressedFrame = frame; target.recovery.compressionInProgress = inProgress
        records[target.recovery.bindingID] = target.recovery; try persist()
    }
    private func synchronizeCompression(_ target: ManagedWindow,_ actual: CGRect) throws {
        guard target.recovery.hideStrategy == .compression,target.hidden,let compact = target.recovery.compressedFrame else { return }
        if target.recovery.compressionInProgress == true && (!sameSize(actual.size,compact.size) || !near(actual.origin,compact.origin)) {
            throw PeekError.message(L("压缩中断后的尺寸归属无法确认，已保留恢复记录；请手动恢复窗口，退出并重开目标应用后重试。"))
        }
        if !sameSize(actual.size,compact.size) {
            // An external resize belongs to the user. A mere move of the strip
            // must not replace the saved expanded height with its folded height.
            target.hidden = false; target.hasShown = true; target.generation += 1
            target.recovery.original = actual; target.recovery.hideStrategy = nil
            target.recovery.compressedFrame = nil; target.recovery.compressionInProgress = nil
            records.removeValue(forKey:target.recovery.bindingID); try persist()
        } else if !near(actual.origin,compact.origin) {
            target.recovery.original.origin = actual.origin
            try rememberCompression(target,actual,inProgress:false)
        }
    }
    private func compress(_ target: ManagedWindow,hide: Bool,shown: CGPoint,duration: Double,epoch: Int,focusPrepared: Bool) throws -> CGRect {
        if hide && unsupportedCompression.contains(target.number) {
            throw PeekError.message(L("这个窗口无法压成细条；请使用左右收起或自行选择最小化。"))
        }
        func checkIdentity() throws {
            try respectUserInteraction()
            guard spaceEpoch() == epoch else { throw PeekError.message(L("桌面已切换，停止压缩并保留恢复记录。")) }
            guard alive(target.recovery),axWindowNumber(target.element) == target.number,
                  (axRead(target.element,kAXMinimizedAttribute) as? Bool) == false else {
                throw PeekError.message(L("窗口身份或可见状态改变，已停止压缩。"))
            }
        }
        try checkIdentity()
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target.element,kAXSizeAttribute as CFString,&writable) == .success,writable.boolValue else {
            throw PeekError.message(L("这个窗口不支持高度压缩；不会改用最小化。"))
        }
        if !hide && !focusPrepared { try focus(target) }
        try checkIdentity()
        guard let initial = axFrame(target.element) else { throw PeekError.message(L("无法读取窗口尺寸。")) }
        // Some accessibility clients enable native AX frame animations. Do not
        // change that app-wide setting. Let positioning settle before resizing;
        // overlapping the two writes can cancel one another's native animation.
        if !near(initial.origin,shown) {
            guard axMove(target.element,shown) else { throw PeekError.message(L("顶部位置调整失败。")) }
            let deadline = ProcessInfo.processInfo.systemUptime+1.5
            var alignedReads = 0
            repeat {
                try checkIdentity()
                guard let moved = axFrame(target.element) else { throw PeekError.message(L("顶部位置无法读取。")) }
                try rememberCompression(target,moved,inProgress:true)
                let server = serverFrame(target.number)
                alignedReads = near(moved.origin,shown) && server.map({near($0.origin,shown) && sameSize($0.size,moved.size)}) == true ? alignedReads+1:0
                if alignedReads >= 3 { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw PeekError.message(L("顶部位置尚未稳定，已停止压缩。")) }
                Thread.sleep(forTimeInterval:0.025)
            } while true
        }
        guard let start = axFrame(target.element) else { throw PeekError.message(L("无法读取窗口尺寸。")) }
        let size = target.recovery.original.size
        let endHeight = hide ? min(10,size.height):size.height
        try rememberCompression(target,start,inProgress:true)
        let began = ProcessInfo.processInfo.systemUptime
        repeat {
            try checkIdentity()
            let t = duration == 0 ? 1:min(1,(ProcessInfo.processInfo.systemUptime-began)/duration)
            let eased = t*t*(3-2*t)
            let desired = CGSize(width:size.width,height:(start.height+(endHeight-start.height)*eased).rounded())
            if axFrame(target.element).map({!sameSize($0.size,desired)}) != false {
                guard axResize(target.element,desired) else { throw PeekError.message(L("窗口拒绝调整高度。")) }
            }
            guard let written = axFrame(target.element) else { throw PeekError.message(L("压缩位置无法确认，保留恢复记录。")) }
            try rememberCompression(target,written,inProgress:true)
            if t >= 1 { break }; Thread.sleep(forTimeInterval:1.0/60)
        } while true
        var previous: CGRect?,stableReads = 0
        let settleDeadline = ProcessInfo.processInfo.systemUptime+1.5
        repeat {
            Thread.sleep(forTimeInterval:0.04); try checkIdentity()
            guard let observed = axFrame(target.element) else { throw PeekError.message(L("压缩状态无法读取。")) }
            let server = serverFrame(target.number)
            stableReads = previous.map { near($0.origin,observed.origin) && sameSize($0.size,observed.size) } == true && server.map({near($0.origin,observed.origin) && sameSize($0.size,observed.size)}) == true ? stableReads+1:0
            previous = observed; try rememberCompression(target,observed,inProgress:true)
            if stableReads >= 3 && (hide || sameSize(observed.size,size)) { break }
            guard ProcessInfo.processInfo.systemUptime < settleDeadline else { throw PeekError.message(L("窗口尺寸尚未稳定，保留恢复记录。")) }
        } while true
        output("compression_readback",["x":axFrame(target.element)?.minX ?? -1,"y":axFrame(target.element)?.minY ?? -1,"height":axFrame(target.element)?.height ?? -1,"width":axFrame(target.element)?.width ?? -1,"shown_x":shown.x,"shown_y":shown.y,"visible":onScreenWindows().contains{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number}])
        guard let actual = axFrame(target.element),near(actual.origin,shown),abs(actual.width-size.width)<2,
              onScreenWindows().contains(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number && ($0[kCGWindowOwnerPID as String] as? Int32) == target.recovery.pid}) else {
            throw PeekError.message(L("顶部位置或窗口宽度不符，未确认压缩成功。"))
        }
        if hide {
            guard actual.height < size.height-2 else {
                unsupportedCompression.insert(target.number)
                throw PeekError.message(L("这个窗口无法继续压缩（实际高度 {0}pt）；正在恢复原尺寸，不会最小化。",Int(actual.height.rounded())))
            }
            guard actual.height <= 48 else {
                unsupportedCompression.insert(target.number)
                throw PeekError.message(L("这个窗口最低只能压至 {0}pt，无法形成细条；正在恢复原尺寸。",Int(actual.height.rounded())))
            }
        } else {
            let focused = axRead(AXUIElementCreateApplication(target.recovery.pid),kAXFocusedWindowAttribute)
            guard sameSize(actual.size,size),let focused,CFGetTypeID(focused) == AXUIElementGetTypeID(),
                  axWindowNumber(focused as! AXUIElement) == target.number else { throw PeekError.message(L("原尺寸或同一窗口的焦点尚未恢复。")) }
        }
        try rememberCompression(target,actual,inProgress:false)
        return actual
    }
    private func focus(_ target: ManagedWindow,allowSpaceSwitch: Bool = false) throws {
        try respectUserInteraction()
        guard alive(target.recovery),axWindowNumber(target.element) == target.number else {
            throw PeekError.message(L("目标窗口身份已改变，已停止操作。"))
        }
        let membership = WindowSpaces.membership(target.number)
        guard membership == .current || (allowSpaceSwitch && membership == .other) else {
            throw PeekError.message(L("目标窗口已离开当前桌面或归属未知，已停止聚焦。"))
        }
        let appAX = AXUIElementCreateApplication(target.recovery.pid)
        _ = AXUIElementSetAttributeValue(target.element,kAXMainAttribute as CFString,kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(appAX,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
        guard let app = NSRunningApplication(processIdentifier:target.recovery.pid) else { throw PeekError.message(L("目标应用已退出。")) }
        if result != .success { DispatchQueue.main.sync { _ = app.activate(options:[]) } }
        for _ in 0..<8 where !app.isActive { Thread.sleep(forTimeInterval:0.025) }
        guard app.isActive else { throw PeekError.message(L("窗口未能取得焦点，请再按快捷键重试。")) }
        _ = AXUIElementPerformAction(target.element,kAXRaiseAction as CFString)
        output("window_focused",["binding":target.recovery.bindingID.uuidString,"pid":target.recovery.pid])
    }
    // Discover without moving/focusing windows. The worker serializes this with
    // animations; polling keeps geometry current after external window changes.
    func refreshHover(_ bindings: [AppBinding]) {
        guard !quitting,!hoverRefreshPending,AXIsProcessTrusted() else { return }
        let bindings = bindings.filter { !detachedIDs.contains($0.id) }
        hoverRefreshPending = true
        let allowSpaceSwitch = animationSettings.allowSpaceSwitch
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map { CGRect(x:$0.frame.minX,y:top-$0.frame.maxY,width:$0.frame.width,height:$0.frame.height) }
        worker.async {
            var snapshots: [HoverWindow] = []
            var missing: [UUID] = []
            for binding in bindings {
                // Automatic recovery owns saved records; discovery never restores.
                if self.records[binding.id] != nil && self.windows[binding.id] == nil { continue }
                if let target = self.windows[binding.id],target.hidden,
                   target.recovery.hideStrategy == .appHide || target.recovery.hideStrategy == .parked {
                    if let state = self.shadeSnapshot(target,binding:binding,screens:screens,allowOtherSpaces:allowSpaceSwitch) {
                        snapshots.append(state)
                    } else { missing.append(binding.id) }
                    continue
                }
                guard let target = try? self.select(binding,allowOtherSpaces:allowSpaceSwitch),let actual = axFrame(target.element) else {
                    missing.append(binding.id); continue
                }
                let membership = WindowSpaces.membership(target.number)
                guard membership == .current || (allowSpaceSwitch && membership == .other) else { missing.append(binding.id); continue }
                guard (axRead(target.element,"AXFullScreen") as? Bool) != true,
                      let minimized = axRead(target.element,kAXMinimizedAttribute) as? Bool else { missing.append(binding.id); continue }
                if target.recovery.hideStrategy == .minimize {
                    target.hidden = minimized; target.hasShown = !minimized
                } else if minimized { missing.append(binding.id); continue } // User-owned minimization.
                do { try self.synchronizeCompression(target,actual) }
                catch { missing.append(binding.id); continue }
                if target.hidden,target.recovery.applicationHidden != true,target.recovery.hideStrategy != .minimize,target.recovery.hideStrategy != .compression,
                   target.tuckedOrigin.map({ near(actual.origin,$0) }) != true,
                   screens.contains(where: { let area = $0.intersection(actual); return !area.isNull && area.width*area.height > actual.width*actual.height*0.5 }) {
                    target.hidden = false; target.hasShown = true
                    self.records.removeValue(forKey:binding.id); try? self.persist()
                }
                if !target.hidden {
                    target.recovery.hideStrategy = nil; target.recovery.originalMinimized = nil
                    target.recovery.original = actual
                    target.generation += 1 // Invalidate any delayed correction.
                    if self.records.removeValue(forKey:binding.id) != nil { try? self.persist() }
                }
                var frame = target.hidden ? target.recovery.original:actual
                if target.hidden {
                    if target.recovery.hideStrategy == .compression { frame = actual }
                    else {
                        frame.size = actual.size
                        if binding.selectedEdge == .left || binding.selectedEdge == .right { frame.origin.y = actual.minY }
                        else if binding.selectedEdge == .bottom { frame.origin.x = actual.minX }
                    }
                }
                guard let screen = screens.max(by: { a,b in
                    let aa = a.intersection(frame),bb = b.intersection(frame)
                    return (aa.isNull ? 0:aa.width*aa.height) < (bb.isNull ? 0:bb.width*bb.height)
                }),screen.intersects(frame) else { missing.append(binding.id); continue }
                snapshots.append(HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen,frame:frame,hidden:target.hidden,pid:target.recovery.pid,revealWidth:target.revealWidth,compressedFrame:target.hidden && target.recovery.hideStrategy == .compression ? actual:nil,onCurrentSpace:membership == .current))
            }
            DispatchQueue.main.async {
                self.hoverRefreshPending = false
                guard !self.quitting else { return }
                for id in missing { self.onWindowRemoved?(id) }
                for snapshot in snapshots where !self.detachedIDs.contains(snapshot.id) { self.onWindowState?(snapshot) }
            }
        }
    }
    func toggle(_ binding: AppBinding) { request(binding,show:nil,source:"hotkey") }
    func setVisible(_ show: Bool,binding: AppBinding) { request(binding,show:show,source:"hover") }
    private func request(_ binding: AppBinding,show: Bool?,source: String) {
        output("window_request",["binding":binding.id.uuidString,"bundle":binding.bundleID,"source":source,"intent":show.map{$0 ? "show":"hide"} ?? "toggle"])
        guard !quitting,!detachedIDs.contains(binding.id) else { return }
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
        let frontPID = foregroundProvider()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = animationSettings
        worker.async {
            var message = ""; var success = false; var mutated = false; var snapshot: HoverWindow?
            var mutationEpoch: Int?
            do {
                try self.respectUserInteraction()
                let target = try self.select(binding,allowOtherSpaces:animation.allowSpaceSwitch)
                var currentEpoch = self.spaceEpoch(); mutationEpoch = currentEpoch
                if target.recovery.hideStrategy == .appHide {
                    let membership = self.shadeMembership(target.recovery)
                    guard membership == .current || (animation.allowSpaceSwitch && membership == .other) else {
                        throw PeekError.message(L("目标窗口不在当前桌面或归属未知，保留标题条恢复记录。"))
                    }
                    try self.unhideOwnedApplication(target)
                }
                guard (axRead(target.element,"AXFullScreen") as? Bool) != true else { throw PeekError.message(L("请先退出目标窗口的全屏模式，再使用收放。")) }
                let onScreen = onScreenWindows().contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number }
                guard let start = axFrame(target.element),let minimized = axRead(target.element,kAXMinimizedAttribute) as? Bool else {
                    throw PeekError.message(L("目标窗口状态无法确认，未执行收放。"))
                }
                if minimized && target.recovery.hideStrategy != .minimize { throw PeekError.message(L("窗口由你最小化；Peek 不会自动恢复。")) }
                if target.recovery.hideStrategy == .minimize && !minimized {
                    target.hidden = false; target.recovery.hideStrategy = nil; target.recovery.originalMinimized = nil
                    self.records.removeValue(forKey:binding.id); try self.persist()
                }
                try self.synchronizeCompression(target,start)
                // A window we cannot see is not an error: it may be tucked off the
                // edge, hidden by its app, or parked on another Space. Recall it.
                if !onScreen || target.hidden {
                    target.hidden = true; target.hasShown = false
                    if let saved = self.records[binding.id],saved.pid == target.recovery.pid,
                       saved.launch == target.recovery.launch,saved.windowNumber == target.number {
                        target.recovery = saved
                    }
                }
                // Other apps and macOS tiling can reveal a window while our state says hidden.
                // Trust its actual on-screen geometry before deciding or saving a layout.
                if target.hidden, target.recovery.applicationHidden != true,target.recovery.hideStrategy != .minimize,target.recovery.hideStrategy != .compression,
                   target.tuckedOrigin.map({ near(start.origin,$0) }) != true, screens.contains(where: { screen in
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
                }), screen.0.intersects(reference) else { throw PeekError.message(L("原显示器已断开，请恢复窗口后重新绑定。")) }
                // On-screen geometry does not mean the user can see the window.
                // From another app, a shortcut recalls it; from the target (or
                // Peek's own controls), the next shortcut can tuck it away.
                let canHide = frontPID == target.recovery.pid || (frontPID == ProcessInfo.processInfo.processIdentifier && target.hasShown)
                let hide = show.map{!$0} ?? (!target.hidden && canHide)
                // A visible window belongs to the user: remember their latest layout.
                if !target.hidden {
                    let old = target.recovery
                    target.recovery = WindowRecovery(bindingID:old.bindingID,pid:old.pid,launch:old.launch,bundle:old.bundle,title:old.title,original:start,windowNumber:target.number)
                }
                // Titlebar experiments remain available for old recovery records,
                // but every new top hide uses single-window minimization.
                let topStrategy: WindowHideStrategy = .minimize
                let strategy: WindowHideStrategy = target.recovery.hideStrategy ?? (binding.selectedEdge == .top ? topStrategy:.edgeMove)
                if hide,strategy == .compression,self.unsupportedCompression.contains(target.number) {
                    throw PeekError.message(L("这个窗口无法压成细条；请使用左右收起或自行选择最小化。"))
                }
                if hide && binding.selectedEdge == .top && !animation.topEnabled {
                    throw PeekError.message(L("顶部收放已关闭。请在“通用”开启，或选择底部、左侧、右侧。"))
                }
                let membership = WindowSpaces.membership(target.number)
                var focusPrepared = false
                if membership != .current {
                    guard !hide,animation.allowSpaceSwitch,membership == .other else {
                        throw PeekError.message(L("目标窗口不在当前桌面或归属未知；请手动切换，或开启“允许切换桌面”。"))
                    }
                    // Only activation may ask macOS to switch. Never move a window
                    // between Spaces, synthesize desktop keys, or change system settings.
                    if minimized && target.recovery.hideStrategy == .minimize { try self.setMinimized(false,target) }
                    try self.focus(target,allowSpaceSwitch:true)
                    let deadline = ProcessInfo.processInfo.systemUptime+2.5
                    var stableSince: TimeInterval?
                    var observedEpoch = currentEpoch
                    repeat {
                        try self.respectUserInteraction()
                        let now = ProcessInfo.processInfo.systemUptime,newEpoch = self.spaceEpoch()
                        // A parked window is intentionally outside every display.
                        // Its confirmed Space assignment, rather than visibility,
                        // permits restoring its position after activation switches.
                        let visible = target.recovery.hideStrategy == .parked || onScreenWindows().contains{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number}
                        if newEpoch != currentEpoch,newEpoch == observedEpoch,visible,WindowSpaces.membership(target.number) == .current {
                            if stableSince == nil { stableSince = now }
                            if now-stableSince! >= 0.15 { break }
                        } else { stableSince = nil }
                        observedEpoch = newEpoch
                        guard now < deadline else { throw PeekError.message(L("macOS 未确认切换到目标窗口的桌面；请手动切换，或将应用分配给所有桌面。")) }
                        Thread.sleep(forTimeInterval:0.04)
                    } while true
                    currentEpoch = self.spaceEpoch(); mutationEpoch = currentEpoch; focusPrepared = true
                }
                let stableSize = target.recovery.original.size
                let shown = binding.selectedEdge.shown(CGRect(origin:target.recovery.original.origin,size:stableSize),visible:screen.1)
                let destination = hide ? binding.selectedEdge.hidden(CGRect(origin:shown,size:stableSize),screen:screen.0,revealWidth:animation.revealWidth):shown
                let destinationFrame = CGRect(origin:destination,size:stableSize)
                if hide && binding.selectedEdge != .top && screens.contains(where:{$0.0 != screen.0 && $0.0.intersects(destinationFrame)}) { throw PeekError.message(L("该方向连接另一块显示器，请选择外侧边缘。")) }
                try self.respectUserInteraction()
                guard self.spaceEpoch() == currentEpoch,WindowSpaces.membership(target.number) == .current else {
                    throw PeekError.message(L("桌面状态已改变，已停止收放。"))
                }
                target.recovery.hideStrategy = strategy
                if hide && strategy == .shade {
                    target.recovery.shadeFrame = CGRect(origin:shown,size:stableSize)
                    target.recovery.shadeSpaceIDs = WindowSpaces.assignedSpaceIDs(target.number).map { Array($0) }
                }
                if strategy == .compression { target.recovery.compressedFrame = start; target.recovery.compressionInProgress = true }
                if hide && strategy == .minimize { target.recovery.originalMinimized = false }
                self.records[binding.id] = target.recovery; try self.persist() // Before any movement.
                mutated = true; target.generation += 1
                if strategy == .shade || strategy == .parked || strategy == .appHide {
                    if hide {
                        try self.hideShade(target,screens:screens.map { $0.0 },epoch:currentEpoch)
                    } else {
                        try self.revealShade(target,shown:shown,focusPrepared:focusPrepared)
                    }
                    target.hidden = hide; target.hasShown = !hide
                    let full = CGRect(origin:shown,size:stableSize)
                    snapshot = HoverWindow(id:binding.id,edge:.top,screen:screen.0,frame:full,hidden:hide,
                        manualHide:hide && source == "hotkey",pid:target.recovery.pid,
                        compressedFrame:hide ? CGRect(x:full.minX,y:full.minY,width:full.width,height:24):nil,
                        shadeTitle:hide ? binding.name:nil)
                    message = hide ? L("窗口已收为标题条，悬停或点击恢复"):L("窗口已展开")
                    output("window_toggle",["success":true,"bundle":binding.bundleID,"hidden":hide,"backend":target.recovery.hideStrategy?.rawValue ?? "shade"])
                    success = true
                } else if strategy == .compression {
                    let duration = reduceMotion ? 0:(hide ? animation.hideDuration:animation.showDuration)
                    let actual = try self.compress(target,hide:hide,shown:shown,duration:duration,epoch:currentEpoch,focusPrepared:focusPrepared)
                    target.hidden = hide; target.hasShown = !hide; target.tuckedOrigin = nil
                    snapshot = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:actual,hidden:hide,manualHide:hide && source == "hotkey",pid:target.recovery.pid,compressedFrame:hide ? actual:nil)
                    message = hide ? L("窗口已压至 {0}pt，悬停或快捷键恢复原高度",Int(actual.height.rounded())):L("窗口已恢复原高度")
                    output("window_toggle",["success":true,"bundle":binding.bundleID,"edge":"top","hidden":hide,"backend":"compression","animation_mode":"windowResize","height":actual.height,"original_height":stableSize.height,"animation_ms":duration*1000,"source":source])
                    success = true
                } else if strategy == .minimize {
                    let began = ProcessInfo.processInfo.systemUptime
                    if hide {
                        try self.setMinimized(true,target)
                    } else {
                        // An ordinary visible/background window may be recalled without
                        // ever being minimized. Never unminimize a user-owned window.
                        if minimized {
                            guard target.recovery.originalMinimized == false else { throw PeekError.message(L("这个最小化状态不属于 Peek，未执行恢复。")) }
                            try self.setMinimized(false,target)
                        }
                        try self.respectUserInteraction()
                        guard self.spaceEpoch() == currentEpoch else { throw PeekError.message(L("桌面已切换，停止召回并保留恢复记录。")) }
                        if !focusPrepared { try self.focus(target) }
                        try self.respectUserInteraction()
                        if let actual = axFrame(target.element),abs(actual.width-stableSize.width)>1 || abs(actual.height-stableSize.height)>1 { _ = axResize(target.element,stableSize) }
                        guard axMove(target.element,shown) else { throw PeekError.message(L("顶部位置恢复失败。")) }
                    }
                    Thread.sleep(forTimeInterval:0.1)
                    guard self.spaceEpoch() == currentEpoch else { throw PeekError.message(L("桌面已切换，未确认本次收放。")) }
                    guard axWindowNumber(target.element) == target.number,
                          (axRead(target.element,kAXMinimizedAttribute) as? Bool) == hide,
                          let actual = axFrame(target.element) else { throw PeekError.message(L("窗口状态无法确认，未记作成功。")) }
                    if !hide {
                        let focused = axRead(AXUIElementCreateApplication(target.recovery.pid),kAXFocusedWindowAttribute)
                        guard let focused,CFGetTypeID(focused) == AXUIElementGetTypeID(),axWindowNumber(focused as! AXUIElement) == target.number,
                              onScreenWindows().contains(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number}),
                              near(actual.origin,shown),abs(actual.width-stableSize.width)<2,abs(actual.height-stableSize.height)<2 else {
                            throw PeekError.message(L("同一窗口的位置或焦点尚未恢复，未记作召回成功。"))
                        }
                    }
                    target.hidden = hide; target.hasShown = !hide
                    snapshot = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:CGRect(origin:shown,size:stableSize),hidden:hide,manualHide:hide && source == "hotkey",pid:target.recovery.pid)
                    message = hide ? L("窗口已最小化，可从顶部唤回"):L("窗口已恢复至顶部")
                    output("window_toggle",["success":true,"bundle":binding.bundleID,"edge":binding.selectedEdge.rawValue,"hidden":hide,"backend":strategy.rawValue,"animation_mode":strategy.animationMode.rawValue,"duration_ms":(ProcessInfo.processInfo.systemUptime-began)*1000])
                    success = true
                } else {

                // Raising can change an application's layout. Do it before restoring geometry.
                if !hide && !focusPrepared { try self.focus(target) }
                let began = ProcessInfo.processInfo.systemUptime
                let duration = reduceMotion ? 0.0:(hide ? animation.hideDuration:animation.showDuration)
                repeat {
                    try self.respectUserInteraction()
                    guard self.spaceEpoch() == currentEpoch else { throw PeekError.message(L("桌面已切换，已停止动画。")) }
                    let t = duration == 0 ? 1:min(1,(ProcessInfo.processInfo.systemUptime-began)/duration)
                    let eased = t*t*(3-2*t)
                    let point = CGPoint(x:start.minX+(destination.x-start.minX)*eased,y:start.minY+(destination.y-start.minY)*eased)
                    guard axMove(target.element,point) else { throw PeekError.message(L("窗口拒绝移动，已尝试恢复原位。")) }
                    if t >= 1 { break }; Thread.sleep(forTimeInterval:1.0/60)
                } while true
                Thread.sleep(forTimeInterval:0.06)
                try self.respectUserInteraction()
                if let actual = axFrame(target.element),
                   abs(actual.width-stableSize.width)>1 || abs(actual.height-stableSize.height)>1 {
                    guard axResize(target.element,stableSize),axMove(target.element,destination) else {
                        throw PeekError.message(L("窗口尺寸恢复失败。"))
                    }
                    Thread.sleep(forTimeInterval:0.06)
                }
                guard let final = axFrame(target.element) else { throw PeekError.message(L("目标窗口已关闭。")) }
                // AppKit may enforce a minimum bottom title strip. Accept that
                // clamp and report the actual exposed height.
                let visibleStrip = screen.0.intersection(final)
                let bottomTitleStrip = hide && binding.selectedEdge == .bottom
                    && abs(final.minX-shown.x)<2 && final.minY > shown.y+2
                    && final.minY >= screen.0.maxY-64
                    && !visibleStrip.isNull && visibleStrip.height <= min(64,stableSize.height*0.2)
                guard near(final.origin,destination) || bottomTitleStrip else {
                    output("window_position_mismatch",["binding":binding.id.uuidString,"requested_x":destination.x,"requested_y":destination.y,"actual_x":axFrame(target.element)?.minX ?? 0,"actual_y":axFrame(target.element)?.minY ?? 0])
                    throw PeekError.message(L("目标应用拒绝了窗口移动，已恢复原位置。"))
                }
                if bottomTitleStrip && !near(final.origin,destination) {
                    output("window_edge_clamped",["edge":"bottom","requested_y":destination.y,"actual_y":final.minY,"visible_strip":visibleStrip.height])
                }
                if abs(final.width-stableSize.width)>1 || abs(final.height-stableSize.height)>1 {
                    output("window_size_observed",["binding":binding.id.uuidString,"width":final.width,"height":final.height,"original_width":stableSize.width,"original_height":stableSize.height])
                }
                guard abs(final.width-stableSize.width)<2 && abs(final.height-stableSize.height)<2 else {
                    throw PeekError.message(L("窗口宽高发生变化，已停止收起并恢复原尺寸。"))
                }
                target.hidden = hide; target.hasShown = !hide; target.generation += 1
                target.tuckedOrigin = hide ? final.origin:nil
                if hide {
                    target.revealWidth = visibleStrip.isNull ? 0:(binding.selectedEdge == .bottom ? visibleStrip.height:visibleStrip.width)
                }
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
                                let updated = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:later,hidden:false,pid:target.recovery.pid,revealWidth:target.revealWidth)
                                self.onWindowState?(updated)
                                self.onBindingStatus?(binding.id,L("检测到窗口位置变化，已同步状态；快捷键仍可使用。"),false)
                            }
                        }
                    }
                }
                snapshot = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:CGRect(origin:shown,size:stableSize),hidden:hide,manualHide:hide && source == "hotkey",pid:target.recovery.pid,revealWidth:target.revealWidth)
                message = hide ? L("窗口已收至{0}",binding.selectedEdge.title):L("窗口已展开")
                if bottomTitleStrip && !near(final.origin,destination) {
                    message = L("已收到底部；目标应用限制了位置，实际露出 {0} 像素（设置为 {1}）。",Int(visibleStrip.height.rounded()),Int(animation.revealWidth))
                }
                output("window_toggle",["success":true,"bundle":binding.bundleID,"edge":binding.selectedEdge.rawValue,"hidden":hide,"x":final.minX,"y":final.minY,"width":final.width,"height":final.height,"source":source,"animation_ms":duration*1000,"duration_ms":(ProcessInfo.processInfo.systemUptime-began)*1000])
                success = true
                }
                // A visible window no longer needs crash recovery. Keeping its old
                // frame would undo later user positioning on the next app launch.
                if snapshot?.hidden == false {
                    if let target = self.windows[binding.id] {
                        target.recovery.hideStrategy = nil; target.recovery.originalMinimized = nil
                        target.recovery.applicationHidden = nil; target.recovery.parkedFrame = nil
                        target.recovery.compressedFrame = nil; target.recovery.compressionInProgress = nil
                    }
                    self.records.removeValue(forKey:binding.id); try self.persist()
                }
            } catch WindowInterruption.userInteraction {
                // A partial compression still owns the original height. Do not
                // mistake its visible pixels for a fully expanded/user-sized window.
                if let target = self.windows[binding.id],target.recovery.hideStrategy == .parked || target.recovery.hideStrategy == .appHide {
                    target.hidden = true
                    snapshot = self.shadeSnapshot(target,binding:binding,screens:screens.map { $0.0 },allowOtherSpaces:animation.allowSpaceSwitch)
                } else if let target = self.windows[binding.id],target.recovery.hideStrategy == .compression,let actual = axFrame(target.element) {
                    target.hidden = !self.sameSize(actual.size,target.recovery.original.size); target.hasShown = !target.hidden
                    target.recovery.compressionInProgress = false
                    if target.hidden { self.records[binding.id] = target.recovery }
                    else { target.recovery.hideStrategy = nil; self.records.removeValue(forKey:binding.id) }
                    try? self.persist()
                    if let screen = screens.max(by:{ a,b in
                        let aa = a.0.intersection(actual),bb = b.0.intersection(actual)
                        return (aa.isNull ? 0:aa.width*aa.height) < (bb.isNull ? 0:bb.width*bb.height)
                    }) {
                        snapshot = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:actual,hidden:target.hidden,pid:target.recovery.pid,compressedFrame:target.hidden ? actual:nil)
                    }
                } else if let target = self.windows[binding.id],let actual = axFrame(target.element),
                   target.recovery.hideStrategy != .minimize || (axRead(target.element,kAXMinimizedAttribute) as? Bool) != nil {
                    target.generation += 1
                    let visible = target.recovery.hideStrategy == .minimize ? (axRead(target.element,kAXMinimizedAttribute) as? Bool) == false:screens.contains { screen in
                        let area = screen.0.intersection(actual)
                        return !area.isNull && area.width*area.height > actual.width*actual.height*0.5
                    }
                    target.hidden = !visible; target.hasShown = visible
                    if visible {
                        target.recovery.hideStrategy = nil; target.recovery.originalMinimized = nil
                        target.recovery.original = actual; target.recovery.applicationHidden = false
                        self.records.removeValue(forKey:binding.id); try? self.persist()
                    }
                    let frame = visible ? actual:target.recovery.original
                    if let screen = screens.max(by: { a,b in
                        let aa = a.0.intersection(frame),bb = b.0.intersection(frame)
                        return (aa.isNull ? 0:aa.width*aa.height) < (bb.isNull ? 0:bb.width*bb.height)
                    }) {
                        snapshot = HoverWindow(id:binding.id,edge:binding.selectedEdge,screen:screen.0,frame:frame,hidden:!visible,pid:target.recovery.pid,revealWidth:target.revealWidth)
                    }
                }
                output("window_yielded_to_user",["binding":binding.id.uuidString,"source":source])
            } catch {
                success = false; message = error.localizedDescription
                if mutated,let target = self.windows[binding.id],target.recovery.hideStrategy == .compression {
                    target.hidden = true; target.hasShown = false // Preserve partial geometry even after a Space change.
                }
                if mutated,!self.interactionProvider(),mutationEpoch == self.spaceEpoch(),let target = self.windows[binding.id],self.records[binding.id] != nil {
                    target.hidden = true
                    if self.restore(target) {
                        // Keep the exact handle even if it closed mid-animation;
                        // discovery must not silently select a sibling window.
                        target.hidden = false; target.hasShown = false; target.recovery.hideStrategy = nil
                        target.recovery.compressedFrame = nil; target.recovery.compressionInProgress = nil
                        self.records.removeValue(forKey:binding.id); try? self.persist()
                    }
                    else { message = L("{0} 恢复尚未完成，请稍后再按快捷键重试。",message) }
                }
                if let target = self.windows[binding.id],target.hidden {
                    snapshot = self.shadeSnapshot(target,binding:binding,screens:screens.map { $0.0 },allowOtherSpaces:animation.allowSpaceSwitch)
                }
                output("window_toggle",["success":false,"bundle":binding.bundleID,"message":message])
            }
            DispatchQueue.main.async {
                self.busyIDs.remove(binding.id)
                guard !self.detachedIDs.contains(binding.id) else { return }
                self.onBindingStatus?(binding.id,message,!success)
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
    private func restore(_ target: ManagedWindow,allowSpaceSwitch: Bool = false) -> Bool {
        guard alive(target.recovery) else { return true }
        if compressionAlreadyRestored(target.recovery) { return true }
        if target.recovery.hideStrategy == .appHide || target.recovery.hideStrategy == .parked || target.recovery.hideStrategy == .shade {
            return restoreShade(target)
        }
        if axWindowNumber(target.element) != target.number || axFrame(target.element) == nil,
           let refreshed = recoveredElement(target.recovery) { target.element = refreshed }
        var observedNumber: CGWindowID = 0
        let identity = axGetWindowNumber(target.element,&observedNumber)
        if identity == .invalidUIElement {
            // A stale AX element is not proof that the window closed.
            guard let listed = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] else { return false }
            return !listed.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.number }
        }
        guard identity == .success,observedNumber == target.number,axFrame(target.element) != nil else { return false }
        if target.recovery.hideStrategy == .compression,let actual = axFrame(target.element) {
            if sameSize(actual.size,target.recovery.original.size),near(actual.origin,target.recovery.original.origin) { return true }
            guard let compact = target.recovery.compressedFrame else { return false }
            if target.recovery.compressionInProgress == true && (!sameSize(actual.size,compact.size) || !near(actual.origin,compact.origin)) { return false }
            if !sameSize(actual.size,compact.size) { return true } // External resize: do not overwrite it.
            if !near(actual.origin,compact.origin) { target.recovery.original.origin = actual.origin }
            guard let minimized = axRead(target.element,kAXMinimizedAttribute) as? Bool else { return false }
            guard axMove(target.element,target.recovery.original.origin) else { return false }
            let positionDeadline = ProcessInfo.processInfo.systemUptime+1.5
            while axFrame(target.element).map({near($0.origin,target.recovery.original.origin)}) != true || (!minimized && serverFrame(target.number).map({near($0.origin,target.recovery.original.origin)}) != true) {
                guard ProcessInfo.processInfo.systemUptime < positionDeadline else { return false }
                Thread.sleep(forTimeInterval:0.025)
            }
            guard axResize(target.element,target.recovery.original.size) else { return false }
            let sizeDeadline = ProcessInfo.processInfo.systemUptime+1.5
            repeat {
                if axFrame(target.element).map({near($0.origin,target.recovery.original.origin) && sameSize($0.size,target.recovery.original.size)}) == true,
                   (minimized || serverFrame(target.number).map({near($0.origin,target.recovery.original.origin) && sameSize($0.size,target.recovery.original.size)}) == true) { return true }
                Thread.sleep(forTimeInterval:0.025)
            } while ProcessInfo.processInfo.systemUptime < sizeDeadline
            return false
        }
        if target.recovery.hideStrategy == .minimize {
            guard target.recovery.originalMinimized == false,let minimized = axRead(target.element,kAXMinimizedAttribute) as? Bool else { return false }
            if !minimized { return true } // Already restored externally: respect the user's geometry.
            guard WindowSpaces.membership(target.number) == .current || allowSpaceSwitch else { return false }
            do { try setMinimized(false,target) } catch { return false }
        }
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
    func detach(_ id: UUID) {
        detachedIDs.insert(id); pendingToggles.remove(id); pendingReveals.remove(id)
        onWindowRemoved?(id)
        worker.async {
            let restored = self.restoreRecord(id)
            // The recovery record remains independent of the deleted binding.
            self.windows.removeValue(forKey:id)
            output("binding_detached",["binding":id.uuidString,"restored":restored,"recovery_retained":self.records[id] != nil])
        }
    }
    private func restoreRecord(_ id: UUID,allowSpaceSwitch: Bool = false) -> Bool {
        if let record = records[id],compressionAlreadyRestored(record) {
            output("recovery_original_frame_confirmed",["binding":id.uuidString])
        } else if let managed = windows[id] {
            guard restore(managed,allowSpaceSwitch:allowSpaceSwitch) else { return false }
        } else if let record = records[id],alive(record) {
            guard let number = record.windowNumber else {
                output("recovery_identity_missing",["binding":id.uuidString]); return false
            }
            if record.hideStrategy == .appHide {
                guard alive(record),shadeMembership(record) == .current,
                      let app = NSRunningApplication(processIdentifier:record.pid) else { return false }
                if app.isHidden {
                    guard record.applicationHidden == true else { return false }
                    _ = app.unhide()
                    for _ in 0..<20 where app.isHidden { Thread.sleep(forTimeInterval:0.025) }
                    guard !app.isHidden else { return false }
                }
            }
            guard let element = recoveredElement(record) else { return false }
            let target = ManagedWindow(element,record,number); target.hidden = true
            guard restore(target,allowSpaceSwitch:allowSpaceSwitch) else { return false }
        }
        let previousWindow = windows.removeValue(forKey:id),previousRecord = records.removeValue(forKey:id)
        do { try persist() } catch {
            windows[id] = previousWindow; records[id] = previousRecord
            return false
        }
        DispatchQueue.main.async { self.onWindowRemoved?(id) }
        return true
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
        restoreAll { restored in
            self.worker.async {
                var saved = true
                do { try self.persist() } catch { saved = false }
                output("quit_recovery_saved",["restored":restored,"pending":self.records.count,"saved":saved])
                DispatchQueue.main.async { if !saved { self.quitting = false }; completion(saved) }
            }
        }
    }
}
