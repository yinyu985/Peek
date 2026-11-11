import AppKit
import ApplicationServices

func output(_ event: String,_ fields: [String:Any] = [:]) {
    var row = fields; row["event"] = event; row["time"] = ISO8601DateFormatter().string(from:Date())
    guard let data = try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys) else { return }
    let line = data + Data([10])
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Peek")
    try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let fd = Darwin.open(directory.appendingPathComponent("app-launch.jsonl").path,O_WRONLY|O_CREAT|O_APPEND,0o600)
    if fd >= 0 { line.withUnsafeBytes { _ = Darwin.write(fd,$0.baseAddress,line.count) }; Darwin.close(fd) }
}
final class Controller: NSObject,NSApplicationDelegate {
    let store = BindingStore()
    let hotkeys = GlobalShortcutManager()
    let toggler = WindowController()
    let hover = HoverController()
    var hoverWindows: [UUID:HoverWindow] = [:]
    var hoverDiscoveryTimer: Timer?
    var mainWindow: MainWindowController!
    var item: NSStatusItem?
    var statusMenu: NSMenu!
    var terminationPending = false
    var terminationApproved = false
    var terminateSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM,SIG_IGN)
        terminateSignal = DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
        terminateSignal?.setEventHandler { NSApp.terminate(nil) }; terminateSignal?.resume()
        for binding in store.bindings where binding.windowTitle != nil { try? store.configure(binding.id,windowTitle:nil,changeWindow:true) }
        mainWindow = MainWindowController(store:store,hotkeys:hotkeys)
        hotkeys.onPress = { [weak self] id in
            guard let self else { return }
            guard let binding = self.store.bindings.first(where:{$0.id == id}) else { return }
            self.toggler.toggle(binding)
        }
        mainWindow.onPrepareChange = { [weak self] id,completion in self?.toggler.forget(id,completion:completion) }
        mainWindow.onBindingsChanged = { [weak self] in
            guard let self else { return }
            self.toggler.animationSettings = self.store.hoverSettings
            self.hover.configure(self.store.bindings,settings:self.store.hoverSettings)
            self.refreshHoverTargets()
        }
        mainWindow.onRecordingChanged = { [weak self] recording in self?.hover.suspended = recording }
        mainWindow.onMenuBarIconChanged = { [weak self] in self?.updateMenuBarIcon() }
        toggler.animationSettings = store.hoverSettings
        hover.configure(store.bindings,settings:store.hoverSettings)
        hover.onInteractionEnded = { [weak self] in self?.refreshHoverTargets() }
        hover.onIntent = { [weak self] id,show in
            guard let self,let binding = self.store.bindings.first(where:{$0.id == id}) else { return }
            self.toggler.setVisible(show,binding:binding)
        }
        toggler.onWindowState = { [weak self] snapshot in self?.hoverWindows[snapshot.id] = snapshot; self?.hover.update(snapshot) }
        toggler.onWindowRemoved = { [weak self] id in self?.hoverWindows.removeValue(forKey:id); self?.hover.remove(id) }
        toggler.onBindingStatus = { [weak self] id,message,error in self?.mainWindow.setBindingStatus(id,message,error) }
        toggler.onPermissionNeeded = { [weak self] in self?.openWindow(); self?.mainWindow.showPermissionNeeded() }
        // Recovery is automatic, not a permanent control on the preferences page.
        if AXIsProcessTrusted() {
            toggler.restoreAll { [weak self] success in
                if !success { self?.mainWindow.setStatus("部分窗口尚未恢复，请打开目标应用后按其快捷键重试。") }
            }
        }
        let discovery = Timer(timeInterval:0.75,repeats:true) { [weak self] _ in self?.refreshHoverTargets() }
        RunLoop.main.add(discovery,forMode:.common); hoverDiscoveryTimer = discovery
        refreshHoverTargets()
        hotkeys.reload(store.bindings); mainWindow.reload()
        let menu = NSMenu()
        menu.addItem(withTitle:"打开 Peek",action:#selector(openWindow),keyEquivalent:",").target = self
        menu.addItem(.separator()); menu.addItem(withTitle:"退出 Peek",action:#selector(quit),keyEquivalent:"q").target = self
        statusMenu = menu; updateMenuBarIcon()
        let mainMenu = NSMenu(); let root = NSMenuItem(); mainMenu.addItem(root); root.submenu = menu.copy() as? NSMenu
        let fileMenu = NSMenu(title:"文件")
        let closeItem = fileMenu.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        closeItem.keyEquivalentModifierMask = .command
        let fileRoot = NSMenuItem(title:"文件",action:nil,keyEquivalent:""); fileRoot.submenu = fileMenu
        mainMenu.addItem(fileRoot)
        NSApp.mainMenu = mainMenu; openWindow()
        output("ready",["pid":ProcessInfo.processInfo.processIdentifier,"bindings":store.bindings.count,"hotkey_errors":hotkeys.errors.count,"mode":"window edge","trusted":AXIsProcessTrusted(),"menu_bar_icon":store.menuBarIconVisible])
    }
    func refreshHoverTargets() {
        guard store.hoverSettings.enabled,!terminationPending else { return }
        toggler.refreshHover(store.bindings)
    }
    func updateMenuBarIcon() {
        if store.menuBarIconVisible {
            guard item == nil else { return }
            let status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            status.button?.image = PeekMark.image()
            status.button?.toolTip = "Peek — One shortcut. Any window."; status.menu = statusMenu
            item = status
        } else if let existing = item {
            NSStatusBar.system.removeStatusItem(existing); item = nil
        }
        output("menu_bar_icon_changed",["visible":store.menuBarIconVisible])
    }
    @objc func openWindow() { guard let mainWindow else { return }; mainWindow.showWindow(nil); mainWindow.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); output("main_window_opened",["visible":true]) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard !terminationPending else { return .terminateCancel }
        terminationPending = true; hotkeys.suspend(); hover.stop()
        toggler.restoreForQuit { success in
            output("quit_restore",["success":success])
            if !success {
                self.terminationPending = false; self.hotkeys.reload(self.store.bindings); self.hover.configure(self.store.bindings,settings:self.store.hoverSettings)
                for snapshot in self.hoverWindows.values { self.hover.update(snapshot) }
                self.openWindow(); self.mainWindow.setStatus("部分应用尚未恢复，请稍后再退出。")
            }
            if success { self.terminationApproved = true; NSApp.terminate(nil) }
        }
        return .terminateCancel
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { guard mainWindow != nil else { return true }; openWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { hotkeys.suspend(); output("app_quitting") }
}
signal(SIGPIPE,SIG_IGN)
// Peek keeps running with no window, so macOS state restoration has nothing to
// restore but still prompts after a forced quit. That prompt blocks
// applicationDidFinishLaunching and made a reopen crash on a nil mainWindow.
UserDefaults.standard.set(true,forKey:"ApplePersistenceIgnoreState")
let app = NSApplication.shared; app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named:.darkAqua)
let controller = Controller(); app.delegate = controller; app.run()
