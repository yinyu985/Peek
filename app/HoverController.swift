import AppKit

// AppKit and AX run on different queues. Use WindowServer button state so
// window writes also stop when a drag starts between two Hover samples.
enum PointerInteraction {
    static var isBusy: Bool {
        CGEventSource.buttonState(.combinedSessionState,button:.left) ||
        CGEventSource.buttonState(.combinedSessionState,button:.right) ||
        CGEventSource.buttonState(.combinedSessionState,button:.center) ||
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.leftMouseUp) < 0.2
    }
}
struct HoverWindow {
    let id: UUID
    let edge: WindowEdge
    let screen: CGRect
    let frame: CGRect
    let hidden: Bool
    var manualHide: Bool = false
    var pid: pid_t? = nil
    var observedAt = ProcessInfo.processInfo.systemUptime
}
// Pure timing model. Hover sends explicit show/hide intent, never a toggle.
struct HoverTracker {
    var edgeSince: TimeInterval?
    var outsideSince: TimeInterval?
    var entered = false
    var rearm = true
    var fired = false
    mutating func update(hidden: Bool) { edgeSince = nil; outsideSince = nil; entered = false; rearm = hidden; fired = false }
    mutating func sample(_ pointer: CGPoint,window: HoverWindow,now: TimeInterval,showDelay: Double,hideDelay: Double,background: Bool = false) -> Bool? {
        let along: Bool; let near: Bool
        switch window.edge {
        case .left,.right:
            along = pointer.y >= window.screen.minY && pointer.y <= window.screen.maxY
            near = abs(pointer.x-(window.edge == .left ? window.screen.minX:window.screen.maxX)) <= 3
        case .top,.bottom:
            along = pointer.x >= window.screen.minX && pointer.x <= window.screen.maxX
            near = abs(pointer.y-(window.edge == .top ? window.screen.minY:window.screen.maxY)) <= 3
        }
        let atEdge = along && near
        if window.hidden || background {
            if !atEdge { rearm = false; edgeSince = nil; fired = false; return nil }
            guard !rearm,!fired else { return nil }
            if edgeSince == nil { edgeSince = now }
            if now-edgeSince! >= showDelay { fired = true; return true }
        } else {
            if atEdge { outsideSince = nil; fired = false; return nil }
            if window.frame.insetBy(dx:-2,dy:-2).contains(pointer) { entered = true; outsideSince = nil; fired = false }
            else if entered && !fired {
                if outsideSince == nil { outsideSince = now }
                if now-outsideSince! >= hideDelay { fired = true; return false }
            }
        }
        return nil
    }
}
final class HoverController {
    var onIntent: ((UUID,Bool)->Void)?
    var onInteractionEnded: (()->Void)?
    var interactionProvider: ()->Bool = { PointerInteraction.isBusy }
    private var wasInteracting = false
    private var geometryAfter: TimeInterval = 0
    private var awaitingGeometry = Set<UUID>()
    private var bindings: [UUID:AppBinding] = [:]
    private var settings = HoverSettings()
    private var windows: [UUID:HoverWindow] = [:]
    private var trackers: [UUID:HoverTracker] = [:]
    private var timer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var pointerProvider: ()->CGPoint = {
        let point = NSEvent.mouseLocation
        return CGPoint(x:point.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-point.y)
    }
    private func mouseInAX() -> CGPoint { pointerProvider() }
    var suspended = false
    private var lastTick: TimeInterval = 0
    func configure(_ items: [AppBinding],settings: HoverSettings = HoverSettings()) {
        self.settings = settings
        bindings = Dictionary(items.map{($0.id,$0)},uniquingKeysWith:{$1})
        windows = windows.filter { settings.enabled && bindings[$0.key] != nil }
        trackers = trackers.filter { windows[$0.key] != nil }
        awaitingGeometry.formIntersection(windows.keys)
        updateTimer()
    }
    func update(_ window: HoverWindow) {
        guard settings.enabled,bindings[window.id] != nil else { return }
        let previous = windows.updateValue(window,forKey:window.id)
        if !interactionProvider(),!wasInteracting,window.observedAt >= geometryAfter,
           awaitingGeometry.remove(window.id) != nil {
            var tracker = HoverTracker(); tracker.update(hidden:window.hidden)
            tracker.rearm = false
            trackers[window.id] = tracker
            updateTimer(); return
        }
        // Geometry refreshes must not restart dwell timers or lose leave tracking.
        if let previous, previous.hidden == window.hidden, previous.edge == window.edge,
           previous.screen == window.screen, previous.pid == window.pid { return }
        var tracker = HoverTracker(); tracker.update(hidden:window.hidden)
        let point = mouseInAX()
        let onEdge: Bool
        switch window.edge {
        case .left: onEdge = abs(point.x-window.screen.minX)<=3
        case .right: onEdge = abs(point.x-window.screen.maxX)<=3
        case .top: onEdge = abs(point.y-window.screen.minY)<=3
        case .bottom: onEdge = abs(point.y-window.screen.maxY)<=3
        }
        tracker.rearm = window.hidden && window.manualHide && onEdge
        output("hover_tracking",["binding":window.id.uuidString,"hidden":window.hidden,"rearm":tracker.rearm,"mouse_x":point.x,"mouse_y":point.y,"screen_x":window.screen.minX,"screen_y":window.screen.minY,"screen_width":window.screen.width,"screen_height":window.screen.height])
        trackers[window.id] = tracker; updateTimer()
    }
    func remove(_ id: UUID) { windows.removeValue(forKey:id); trackers.removeValue(forKey:id); awaitingGeometry.remove(id); updateTimer() }
    func stop() {
        timer?.invalidate(); timer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        windows.removeAll(); trackers.removeAll(); awaitingGeometry.removeAll(); wasInteracting = false
    }
    deinit { stop() }
    private func updateTimer() {
        if windows.isEmpty { stop(); return }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.mouseMoved,.leftMouseDragged]) { [weak self] _ in self?.tick() }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.leftMouseDragged]) { [weak self] event in self?.tick(); return event }
        }
        if timer == nil {
            let value = Timer(timeInterval:0.05,repeats:true) { [weak self] _ in self?.tick() }
            value.tolerance = 0.01; RunLoop.main.add(value,forMode:.common); timer = value
        }
    }
    private func tick() {
        guard !suspended else { return }
        if interactionProvider() {
            wasInteracting = true
            awaitingGeometry.formUnion(windows.keys)
            return
        }
        if wasInteracting {
            wasInteracting = false
            geometryAfter = ProcessInfo.processInfo.systemUptime
            onInteractionEnded?() // Read fresh AX frames before any leave decision.
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now-lastTick >= 1.0/60 else { return }; lastTick = now
        let pointer = mouseInAX()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (id,window) in windows {
            guard bindings[id] != nil,!awaitingGeometry.contains(id),var tracker = trackers[id] else { continue }
            let background = window.pid.map { $0 != frontPID } ?? false
            let intent = tracker.sample(pointer,window:window,now:now,showDelay:settings.showDelay,hideDelay:settings.hideDelay,background:background)
            trackers[id] = tracker
            if let intent { output("hover_intent",["binding":id.uuidString,"show":intent]); onIntent?(id,intent) }
        }
    }
}
