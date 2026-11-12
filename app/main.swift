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
    let shadeBars = ShadeBarController()
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
        makeMainWindow()
        hotkeys.onPress = { [weak self] id in
            guard let self else { return }
            guard let binding = self.store.bindings.first(where:{$0.id == id}) else { return }
            self.toggler.toggle(binding)
        }
        toggler.animationSettings = store.hoverSettings
        hover.configure(store.bindings,settings:store.hoverSettings)
        hover.onInteractionEnded = { [weak self] in self?.refreshHoverTargets() }
        hover.onIntent = { [weak self] id,show in
            guard let self,let binding = self.store.bindings.first(where:{$0.id == id}) else { return }
            self.toggler.setVisible(show,binding:binding)
        }
        shadeBars.onReveal = { [weak self] id in
            guard let self,let binding = self.store.bindings.first(where:{$0.id == id}) else { return }
            // Mouse-up leaves PointerInteraction busy briefly. Queue the click
            // after that interval; Hover still follows its configured dwell delay.
            DispatchQueue.main.asyncAfter(deadline:.now()+0.22) { [weak self] in
                guard let self,self.store.bindings.contains(where:{$0.id == id}) else { return }
                self.toggler.setVisible(true,binding:binding)
            }
        }
        toggler.onWindowState = { [weak self] snapshot in
            self?.hoverWindows[snapshot.id] = snapshot; self?.hover.update(snapshot); self?.shadeBars.update(snapshot)
        }
        toggler.onWindowRemoved = { [weak self] id in self?.hoverWindows.removeValue(forKey:id); self?.hover.remove(id); self?.shadeBars.remove(id) }
        toggler.onBindingStatus = { [weak self] id,message,error in self?.mainWindow.setBindingStatus(id,message,error) }
        toggler.onPermissionNeeded = { [weak self] in self?.openWindow(); self?.mainWindow.showPermissionNeeded() }
        // Recovery is automatic, not a permanent control on the preferences page.
        if AXIsProcessTrusted() {
            toggler.restoreAll { success in
                if !success { output("recovery_deferred",["records_preserved":true]) }
            }
        }
        let discovery = Timer(timeInterval:0.75,repeats:true) { [weak self] _ in self?.refreshHoverTargets() }
        RunLoop.main.add(discovery,forMode:.common); hoverDiscoveryTimer = discovery
        refreshHoverTargets()
        hotkeys.reload(store.bindings); mainWindow.reload()
        rebuildMenus(); openWindow()
        output("ready",["pid":ProcessInfo.processInfo.processIdentifier,"bindings":store.bindings.count,"hotkey_errors":hotkeys.errors.count,"mode":"window edge","trusted":AXIsProcessTrusted(),"menu_bar_icon":store.menuBarIconVisible])
    }
    private func makeMainWindow() {
        mainWindow = MainWindowController(store:store,hotkeys:hotkeys)
        mainWindow.onPrepareChange = { [weak self] id,completion in self?.toggler.forget(id,completion:completion) }
        mainWindow.onBindingRemoved = { [weak self] id in self?.toggler.detach(id) }
        mainWindow.onBindingsChanged = { [weak self] in
            guard let self else { return }
            self.toggler.animationSettings = self.store.hoverSettings
            self.hover.configure(self.store.bindings,settings:self.store.hoverSettings)
            self.refreshHoverTargets()
        }
        mainWindow.onRecordingChanged = { [weak self] recording in self?.hover.suspended = recording }
        mainWindow.onMenuBarIconChanged = { [weak self] in self?.updateMenuBarIcon() }
        mainWindow.onLanguageChanged = { [weak self] in
            guard let self else { return }
            let frame = self.mainWindow.window?.frame
            let statuses = self.mainWindow.bindingStatus
            self.mainWindow.close()
            self.makeMainWindow()
            if let frame { self.mainWindow.window?.setFrame(frame,display:false) }
            for (id,status) in statuses { self.mainWindow.setBindingStatus(id,status.0,status.1) }
            self.mainWindow.showGeneral()
            self.rebuildMenus(); self.openWindow()
        }
    }
    private func rebuildMenus() {
        let menu = NSMenu()
        menu.addItem(withTitle:L("打开 Peek"),action:#selector(openWindow),keyEquivalent:",").target = self
        menu.addItem(.separator()); menu.addItem(withTitle:L("退出 Peek"),action:#selector(quit),keyEquivalent:"q").target = self
        statusMenu = menu; updateMenuBarIcon()
        let mainMenu = NSMenu(); let root = NSMenuItem(); mainMenu.addItem(root); root.submenu = menu.copy() as? NSMenu
        let fileMenu = NSMenu(title:L("文件"))
        let closeItem = fileMenu.addItem(withTitle:L("关闭窗口"),action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        closeItem.keyEquivalentModifierMask = .command
        let fileRoot = NSMenuItem(title:L("文件"),action:nil,keyEquivalent:""); fileRoot.submenu = fileMenu
        mainMenu.addItem(fileRoot)
        NSApp.mainMenu = mainMenu
        item?.menu = statusMenu
        item?.button?.toolTip = L("Peek — 一个快捷键，唤回窗口。")
    }
    func refreshHoverTargets() {
        guard !terminationPending else { return }
        toggler.refreshHover(store.bindings)
    }
    func updateMenuBarIcon() {
        if store.menuBarIconVisible {
            guard item == nil else { return }
            let status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            status.button?.image = PeekMark.image()
            status.button?.toolTip = L("Peek — 一个快捷键，唤回窗口。"); status.menu = statusMenu
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
            output("quit_ready",["recovery_saved":success])
            if !success {
                self.terminationPending = false; self.hotkeys.reload(self.store.bindings); self.hover.configure(self.store.bindings,settings:self.store.hoverSettings)
                for snapshot in self.hoverWindows.values { self.hover.update(snapshot) }
                self.openWindow(); self.mainWindow.setStatus(L("窗口恢复记录无法保存，请检查磁盘空间后再退出。"))
            }
            if success { self.terminationApproved = true; NSApp.terminate(nil) }
        }
        return .terminateCancel
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { guard mainWindow != nil else { return true }; openWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { hotkeys.suspend(); shadeBars.removeAll(); output("app_quitting") }
}
signal(SIGPIPE,SIG_IGN)
// Peek keeps running with no window, so macOS state restoration has nothing to
// restore but still prompts after a forced quit. That prompt blocks
// applicationDidFinishLaunching and made a reopen crash on a nil mainWindow.
UserDefaults.standard.set(true,forKey:"ApplePersistenceIgnoreState")
let app = NSApplication.shared; app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named:.darkAqua)
let controller = Controller(); app.delegate = controller; app.run()
