import SwiftUI
import AppKit

@main
struct MultiBandEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var editor: NSWindow!
    private var statusItem: NSStatusItem!
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        NSApp.setActivationPolicy(.regular)
        editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 630),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        editor.title = "MultiBand EQ"
        editor.minSize = NSSize(width: 1040, height: 590)
        editor.contentView = NSHostingView(rootView: EqualizerView(model: model))
        editor.isReleasedWhenClosed = false; editor.delegate = self
        editor.setFrameAutosaveName("EqualizerWindow")
        editor.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "MultiBand EQ")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open MultiBand EQ", action: #selector(openEditor), keyEquivalent: "")
        menu.addItem(withTitle: "Enable / Stop EQ", action: #selector(toggleEQ), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MultiBand EQ", action: #selector(quitApp), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.didWake() }
        })
        openEditor()
    }
    @objc func openEditor() {
        editor.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func toggleEQ() {
        model.toggleRunning()
        if model.error != nil { openEditor() }
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.cancel(); return true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openEditor(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
