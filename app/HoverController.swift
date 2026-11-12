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
    var revealWidth: CGFloat = 0
    var compressedFrame: CGRect? = nil
    var shadeTitle: String? = nil
    var onCurrentSpace = true
    var observedAt = ProcessInfo.processInfo.systemUptime
    // Use the window's segment, not the whole display edge. Half-open spans
    // keep adjoining windows from sharing a trigger at their common boundary.
    func containsTrigger(_ pointer: CGPoint) -> Bool {
        guard pointer.x >= screen.minX,pointer.x < screen.maxX,
              pointer.y >= screen.minY,pointer.y < screen.maxY else { return false }
        if hidden,onCurrentSpace,edge == .top,let strip = compressedFrame,
           pointer.x >= strip.minX,pointer.x < strip.maxX,pointer.y >= strip.minY,pointer.y < strip.maxY { return true }
        switch edge {
        case .left,.right:
            guard pointer.y >= max(frame.minY,screen.minY),pointer.y < min(frame.maxY,screen.maxY) else { return false }
            let width = max(3,revealWidth)
            return edge == .left ? pointer.x < screen.minX+width:pointer.x >= screen.maxX-width
        case .top,.bottom:
            guard pointer.x >= max(frame.minX,screen.minX),pointer.x < min(frame.maxX,screen.maxX) else { return false }
            return edge == .top ? pointer.y < screen.minY+3:pointer.y >= screen.maxY-max(3,revealWidth)
        }
    }
}
// Pure timing model. Hover sends explicit show/hide intent, never a toggle.
struct HoverTracker {
    var edgeSince: TimeInterval?
    var outsideSince: TimeInterval?
    var entered = false
    var rearm = true
    var fired = false
    mutating func update(hidden: Bool) { edgeSince = nil; outsideSince = nil; entered = false; rearm = hidden; fired = false }
    mutating func sample(_ pointer: CGPoint,window: HoverWindow,now: TimeInterval,showDelay: Double,hideDelay: Double,background: Bool = false,allowReveal: Bool = true) -> Bool? {
        let atEdge = window.containsTrigger(pointer)
        if window.hidden || (background && !entered) {
            if !atEdge { rearm = false; edgeSince = nil; fired = false; return nil }
            guard allowReveal else { edgeSince = nil; return nil }
            guard !rearm,!fired else { return nil }
            if edgeSince == nil { edgeSince = now }
            if now-edgeSince! >= showDelay { fired = true; return true }
        } else {
            if atEdge { outsideSince = nil; return nil }
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
    var foregroundProvider: ()->pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    private var wasInteracting = false
    private var geometryAfter: TimeInterval = 0
    private var awaitingGeometry = Set<UUID>()
    private var bindings: [UUID:AppBinding] = [:]
    private var bindingOrder: [UUID] = []
    // One reveal per continuous visit. State/focus refreshes cannot release it.
    private var edgeOwner: UUID?
    private var edgeConsumed = false
    private var settings = HoverSettings()
    private var windows: [UUID:HoverWindow] = [:]
    private var trackers: [UUID:HoverTracker] = [:]
    private var pendingReveals = Set<UUID>()
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
        bindingOrder = items.map(\.id)
        windows = windows.filter { settings.enabled && bindings[$0.key] != nil && (settings.allowSpaceSwitch || $0.value.onCurrentSpace) }
        trackers = trackers.filter { windows[$0.key] != nil }
        awaitingGeometry.formIntersection(windows.keys)
        pendingReveals.formIntersection(windows.keys)
        updateTimer()
    }
    func update(_ window: HoverWindow) {
        guard settings.enabled,bindings[window.id] != nil else { return }
        guard settings.allowSpaceSwitch || window.onCurrentSpace else { remove(window.id); return }
        let previous = windows.updateValue(window,forKey:window.id)
        let hoverRevealed = !window.hidden && pendingReveals.remove(window.id) != nil
        if !interactionProvider(),!wasInteracting,window.observedAt >= geometryAfter,
           awaitingGeometry.remove(window.id) != nil {
            var tracker = HoverTracker(); tracker.update(hidden:window.hidden)
            tracker.entered = hoverRevealed
            tracker.rearm = window.hidden && window.compressedFrame != nil && window.containsTrigger(mouseInAX())
            trackers[window.id] = tracker
            updateTimer(); return
        }
        // Geometry refreshes must not restart dwell timers or lose leave tracking.
        if !hoverRevealed,let previous, previous.hidden == window.hidden, previous.edge == window.edge,
           previous.screen == window.screen, previous.pid == window.pid, previous.onCurrentSpace == window.onCurrentSpace { return }
        var tracker = HoverTracker(); tracker.update(hidden:window.hidden)
        // A Hover reveal owns the leave gesture even if the pointer moves away
        // before the restored window can receive a sample inside its content.
        tracker.entered = hoverRevealed
        let point = mouseInAX()
        tracker.rearm = window.hidden && window.manualHide && window.containsTrigger(point)
        output("hover_tracking",["binding":window.id.uuidString,"hidden":window.hidden,"rearm":tracker.rearm,"mouse_x":point.x,"mouse_y":point.y,"screen_x":window.screen.minX,"screen_y":window.screen.minY,"screen_width":window.screen.width,"screen_height":window.screen.height])
        trackers[window.id] = tracker; updateTimer()
    }
    func remove(_ id: UUID) { windows.removeValue(forKey:id); trackers.removeValue(forKey:id); awaitingGeometry.remove(id); pendingReveals.remove(id); updateTimer() }
    func stop() {
        timer?.invalidate(); timer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        windows.removeAll(); trackers.removeAll(); awaitingGeometry.removeAll(); wasInteracting = false
        edgeOwner = nil; edgeConsumed = false
        pendingReveals.removeAll()
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
        let frontPID = foregroundProvider()
        let candidates = bindingOrder.filter { id in
            !awaitingGeometry.contains(id) && windows[id].map { window in
                (settings.topEnabled || window.edge != .top || window.hidden) && window.containsTrigger(pointer)
            } == true
        }
        if edgeOwner.map({ candidates.contains($0) }) != true {
            // Preserve the owner while the pointer stays in its segment. For
            // overlapping segments prefer the foreground app, then list order.
            edgeOwner = candidates.first(where:{ windows[$0]?.pid != nil && windows[$0]?.pid == frontPID }) ?? candidates.first
            edgeConsumed = false
        }
        if let owner = edgeOwner,let window = windows[owner],window.onCurrentSpace,!window.hidden,window.pid == frontPID,frontPID != nil {
            edgeConsumed = true
        }
        var intents: [(UUID,Bool)] = []
        for id in bindingOrder {
            guard let window = windows[id],!awaitingGeometry.contains(id),var tracker = trackers[id] else { continue }
            // Disabling the experiment still permits recall of an owned hidden
            // window, but must never enqueue another top hide.
            guard settings.topEnabled || window.edge != .top || window.hidden else { continue }
            let background = !window.onCurrentSpace || (window.pid.map { $0 != frontPID } ?? false)
            let intent = tracker.sample(pointer,window:window,now:now,showDelay:settings.showDelay,hideDelay:settings.hideDelay,background:background,
                                        allowReveal:id == edgeOwner && !edgeConsumed)
            trackers[id] = tracker
            if let intent {
                if intent { edgeConsumed = true; pendingReveals.insert(id) }
                intents.append((id,intent))
            }
        }
        // Finish sampling before callbacks can change focus or window state.
        for (id,intent) in intents { output("hover_intent",["binding":id.uuidString,"show":intent]); onIntent?(id,intent) }
    }
}
