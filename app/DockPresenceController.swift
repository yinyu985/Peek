import AppKit

// Dock presence follows the settings window, not the lifetime of the worker.
// No timers, hotkeys, bindings or login-item registrations are changed here.
final class DockPresenceController {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName:NSWindow.willCloseNotification,object:nil,queue:.main) { [weak self] note in
            guard let self,let closing = note.object as? NSWindow,closing === self.window else { return }
            self.scheduleBackground()
        })
        observers.append(center.addObserver(forName:NSApplication.didHideNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }
            // Close also clears shortcut recording and transient settings panels.
            // Merely changing policy can otherwise leave a hidden key window.
            self.window?.close()
            self.scheduleBackground()
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func show(_ window: NSWindow) {
        self.window = window
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        // Policy changes can settle on the next run-loop turn. Do not reopen a
        // window that the user has already closed, hidden, or replaced meanwhile.
        DispatchQueue.main.async { [weak self,weak window] in
            guard let self,let window,self.window === window,window.isVisible,!NSApp.isHidden else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
        }
    }

    private func scheduleBackground() {
        // willClose arrives before isVisible changes. Recheck on the next turn;
        // a language change or immediate reopen may already show a new window.
        DispatchQueue.main.async { [weak self] in
            guard let self,NSApp.isHidden || self.window?.isVisible != true else { return }
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
