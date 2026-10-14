import AppKit
import SwiftUI
import Combine

@main
struct QuietBarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }),
           let url = existing.bundleURL {
            NSWorkspace.shared.open(url)
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var store: SettingsStore!
    private var catalog: ApplicationCatalog!
    private var monitor: InactivityMonitor!
    private var login: LoginItemManager!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement also declares this in Info.plist.
        NSApp.setActivationPolicy(.accessory)
        store = SettingsStore()
        catalog = ApplicationCatalog()
        monitor = InactivityMonitor(store: store)
        login = LoginItemManager()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.setAccessibilityLabel("QuietBar")
        popover.behavior = .transient
        popover.delegate = self
        subscription = store.$paused.sink { [weak self] paused in self?.updateIcon(paused: paused) }
        installMainMenu()
        if !UserDefaults.standard.bool(forKey: "hasShownWelcome") {
            showSettings()
            UserDefaults.standard.set(true, forKey: "hasShownWelcome")
        }
    }

    private func updateIcon(paused: Bool) {
        let image = NSImage(systemSymbolName: paused ? "pause.circle" : "moon.zzz", accessibilityDescription: "QuietBar")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = paused ? "QuietBar — paused" : "QuietBar — automatic app closing"
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        popover.contentViewController = NSHostingController(rootView: MenuView(store: store, monitor: monitor,
            openSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) }))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the TimelineView when hidden; no one-second UI updates in the background.
        popover.contentViewController = nil
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "QuietBar Settings"
        window.minSize = NSSize(width: 940, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(store: store, catalog: catalog, monitor: monitor, login: login))
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow?.contentView = nil
            settingsWindow = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { monitor.shutdown() }

    private func installMainMenu() {
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit QuietBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        menu.addItem(appMenuItem)
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
