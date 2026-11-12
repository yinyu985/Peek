import AppKit
import Carbon

final class GlobalShortcutManager {
    static let signature: OSType = 0x5045454B
    private var handler: EventHandlerRef?
    private var refs: [UUID:EventHotKeyRef] = [:]
    private var ids: [UInt32:UUID] = [:]
    private var pressed = Set<UInt32>()
    private var shortcuts: [UInt32:Shortcut] = [:]
    private var releaseTimer: Timer?
    private var counter: UInt32 = 0
    var onPress: ((UUID)->Void)?
    private(set) var errors: [UUID:String] = [:]
    private(set) var handlerStatus: OSStatus = noErr
    init() {
        var specs = [EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        // The dispatcher receives registered hotkeys before AppKit routes events
        // to a key window. Delivery must not depend on the preferences window.
        handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), { _,event,context in
            guard let event,let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&key) == noErr,
                  key.signature == GlobalShortcutManager.signature else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(context).takeUnretainedValue()
            guard let id = manager.ids[key.id] else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                manager.pressed.remove(key.id); output("hotkey_released",["binding":id.uuidString]); return noErr
            }
            guard manager.pressed.insert(key.id).inserted else { return noErr }
            output("hotkey_pressed",["binding":id.uuidString])
            manager.onPress?(id); return noErr
        },specs.count,&specs,Unmanaged.passUnretained(self).toOpaque(),&handler)
        // A focus change can lose Carbon's release notification. Reconcile with
        // actual key state so a missing release cannot disable a shortcut forever.
        let timer = Timer(timeInterval:0.05,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.pressed = self.pressed.filter { number in
                guard let shortcut = self.shortcuts[number] else { return false }
                return CGEventSource.keyState(.combinedSessionState,key:CGKeyCode(shortcut.keyCode))
            }
        }
        RunLoop.main.add(timer,forMode:.common); releaseTimer = timer
    }
    deinit { releaseTimer?.invalidate(); suspend(); if let handler { RemoveEventHandler(handler) } }
    func suspend() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll(); ids.removeAll(); pressed.removeAll(); shortcuts.removeAll()
    }
    func reload(_ bindings: [AppBinding]) {
        suspend(); errors.removeAll()
        for binding in bindings {
            guard let shortcut = binding.shortcut else { continue }
            if let error = register(shortcut,for:binding.id) { errors[binding.id] = error }
        }
    }
    private func register(_ shortcut: Shortcut, for id: UUID) -> String? {
        guard handlerStatus == noErr else { return L("快捷键监听失败（{0}）。",handlerStatus) }
        counter &+= 1
        var ref: EventHotKeyRef?
        let code = RegisterEventHotKey(shortcut.keyCode,shortcut.modifiers,EventHotKeyID(signature:Self.signature,id:counter),GetEventDispatcherTarget(),0,&ref)
        guard code == noErr,let ref else { return L("快捷键被系统或其他应用占用（{0}）。",code) }
        refs[id] = ref; ids[counter] = id; shortcuts[counter] = shortcut; return nil
    }
    // Called while all Peek shortcuts are suspended by the recorder.
    func validate(_ shortcut: Shortcut) -> String? {
        let temporary = UUID()
        let error = register(shortcut,for:temporary)
        if let ref = refs.removeValue(forKey:temporary) { UnregisterEventHotKey(ref) }
        for number in ids.filter({ $0.value == temporary }).keys {
            ids.removeValue(forKey:number); shortcuts.removeValue(forKey:number)
        }
        return error
    }
}
