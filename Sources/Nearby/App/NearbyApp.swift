import AppKit
import SwiftUI
import Combine
import NearbyCore

@main
struct NearbyApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSMenuDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = AppModel()
    private var devicesWindow: NSWindow?
    private var pairingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var terminating = false
    private var subscriptions = Set<AnyCancellable>()
    private let isPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        model.onShowDevices = { [weak self] in self?.openDevices() }
        model.onShowPairing = { [weak self] in self?.openPairing() }
        model.onClosePairing = { [weak self] in self?.pairingWindow?.orderOut(nil) }
        model.onShowSettings = { [weak self] in self?.openSettings() }
        model.onUISettingsChanged = { [weak self] in self?.updateStatusItem() }
        model.onStatusChanged = { [weak self] in self?.updateStatusMenu() }
        model.$errorMessage.compactMap { $0 }.sink { [weak self] message in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.model.errorMessage != nil else { return }
                let alert = NSAlert(); alert.messageText = "Nearby"; alert.informativeText = message
                alert.addButton(withTitle: "OK"); alert.runModal(); self.model.errorMessage = nil
            }
        }.store(in: &subscriptions)
        updateStatusItem(); openDevices()
        if isPreview {
            model.devices = [DeviceRecord(id: "preview-only", serial: "preview-only", name: "My Pixel", state: .available, isWireless: true)]
            model.discoveryMessage = "Design preview — no device connection."
            if ProcessInfo.processInfo.arguments.contains("--show-pairing") { model.openPairing() }
        } else {
            model.start()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openDevices(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await model.shutdownAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title; window.titleVisibility = .visible; window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact; window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.minSize, .preferredContentSize]
        window.contentViewController = hosting
        window.center(); window.delegate = self
        return window
    }
    @objc func openDevices() {
        if !isPreview { model.start() }
        if devicesWindow == nil {
            let w = makeWindow(title: "Nearby", size: NSSize(width: 500, height: 300), content: DevicesView(model: model))
            let toolbar = NSToolbar(identifier: "Nearby.Devices.Toolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false; w.toolbar = toolbar
            w.setFrameAutosaveName("Nearby.Devices")
            devicesWindow = w
        }
        devicesWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func openPairing() {
        if pairingWindow == nil {
            pairingWindow = makeWindow(title: "Pair Device", size: NSSize(width: 620, height: 490), content: PairingView(model: model))
            pairingWindow?.identifier = NSUserInterfaceItemIdentifier("pairing")
            pairingWindow?.setFrameAutosaveName("Nearby.Pairing")
        }
        pairingWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Nearby Settings", size: NSSize(width: 540, height: 500), content: SettingsView(model: model))
            settingsWindow?.setFrameAutosaveName("Nearby.Settings")
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow, w === pairingWindow { model.closePairing() }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("pair"), .init("settings")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("pair"), .init("settings")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id.rawValue {
        case "pair": item.label = "Pair Device"; item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Pair Device"); item.target = self; item.action = #selector(pairDevice)
        case "settings": item.label = "Settings"; item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings"); item.target = self; item.action = #selector(openSettings)
        default: return nil
        }
        item.isBordered = true
        return item
    }

    private func buildMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        let app = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)
        add(app, "About Nearby", #selector(about), "")
        app.addItem(.separator()); add(app, "Settings…", #selector(openSettings), ",")
        app.addItem(.separator()); add(app, "Hide Nearby", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        let others = add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", target: NSApp); others.keyEquivalentModifierMask = [.command, .option]
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "", target: NSApp)
        app.addItem(.separator()); add(app, "Quit Nearby", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = submenu("File", to: main)
        add(file, "Pair Device…", #selector(pairDevice), "n")
        add(file, "Devices", #selector(openDevices), "1")
        add(file, "Show Mirror", #selector(showMirror), "2")
        file.addItem(.separator()); add(file, "Take Screenshot…", #selector(screenshot), "s").keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator()); add(file, "Close", #selector(NSWindow.performClose(_:)), "w", target: nil)
        let edit = submenu("Edit", to: main)
        add(edit, "Cut", #selector(NSText.cut(_:)), "x", target: nil)
        add(edit, "Copy", #selector(NSText.copy(_:)), "c", target: nil)
        add(edit, "Paste", #selector(NSText.paste(_:)), "v", target: nil)
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a", target: nil)
        let view = submenu("View", to: main)
        add(view, "Show Controls", #selector(showControls), "t").keyEquivalentModifierMask = [.command, .option]
        add(view, "Fit to Screen", #selector(fitMirror), "0")
        add(view, "Refresh Devices", #selector(refreshDevices), "r")
        let phone = submenu("Phone", to: main)
        add(phone, "Paste to Pixel", #selector(pasteToPixel), "v").keyEquivalentModifierMask = [.command, .shift]
        add(phone, "Clipboard & Files…", #selector(showSharing), "f").keyEquivalentModifierMask = [.command, .shift]
        phone.addItem(.separator())
        add(phone, "Back", #selector(back), "b").keyEquivalentModifierMask = [.command, .control]
        add(phone, "Home", #selector(home), "h").keyEquivalentModifierMask = [.command, .control]
        add(phone, "Overview", #selector(overview), "o").keyEquivalentModifierMask = [.command, .control]
        phone.addItem(.separator()); add(phone, "Disconnect", #selector(disconnect), "")
        let window = submenu("Window", to: main); NSApp.windowsMenu = window
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)), "", target: nil)
        window.addItem(.separator()); add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", target: NSApp)
        let help = submenu("Help", to: main)
        add(help, "Pixel Setup Help", #selector(setupHelp), "")
    }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? (action == #selector(NSWindow.performClose(_:)) || action == #selector(NSWindow.performMiniaturize(_:)) || action == #selector(NSWindow.performZoom(_:)) || ["cut:", "copy:", "paste:", "selectAll:"].contains(NSStringFromSelector(action)) ? nil : self)
        menu.addItem(item); return item
    }
    private func submenu(_ title: String, to parent: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title), item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = menu; parent.addItem(item); return menu
    }
    @objc private func pairDevice() { model.openPairing() }
    @objc private func showMirror() { model.showMirror() }
    @objc private func screenshot() { model.takeScreenshot() }
    @objc private func showControls() { model.showMirrorControls() }
    @objc private func pasteToPixel() { model.pasteToPixel() }
    @objc private func showSharing() { model.showSharing() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(pasteToPixel) { return model.session?.isStreaming == true }
        if menuItem.action == #selector(showSharing) { return model.session != nil }
        return true
    }
    @objc private func fitMirror() { model.fitMirror() }
    @objc private func refreshDevices() { model.refresh() }
    @objc private func back() { model.session?.keycode(4) }
    @objc private func home() { model.session?.keycode(3) }
    @objc private func overview() { model.session?.keycode(187) }
    @objc private func disconnect() { model.disconnect() }
    @objc private func setupHelp() { model.openPairing(); model.showDeveloperHelp = true }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Nearby", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development", .credits: NSAttributedString(string: "Native wireless Android mirroring for Mac.\nPowered by the scrcpy Android server and Android Debug Bridge.\nOpen-source notices are included in the app bundle.")])
    }
    private func updateStatusItem() {
        if model.showMenuBar {
            if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
            statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Nearby")
            updateStatusMenu()
        } else if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
    }
    private func updateStatusMenu() {
        guard let statusItem, statusItem.menu == nil else { return }
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        if let device = model.activeDevice ?? model.devices.first {
            let header = NSMenuItem(title: "\(device.name) — \(device.state.displayLabel)", action: nil, keyEquivalent: "")
            if let live = model.session?.screenshot(), model.session?.isStreaming == true {
                header.image = NSImage(cgImage: live, size: NSSize(width: 20, height: 44))
            } else if let path = device.imagePath, let image = NSImage(contentsOfFile: path) { image.size = NSSize(width: 20, height: 44); header.image = image }
            menu.addItem(header); menu.addItem(.separator())
            if model.session != nil { add(menu, "Show Mirror", #selector(showMirror), ""); add(menu, "Disconnect", #selector(disconnect), "") }
            else if device.state == .available { add(menu, "Mirror", #selector(mirrorFirst), "") }
        }
        add(menu, "Devices…", #selector(openDevices), "")
        add(menu, "Pair Device…", #selector(pairDevice), "")
        add(menu, "Settings…", #selector(openSettings), ",")
        menu.addItem(.separator()); add(menu, "Quit Nearby", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
    }
    @objc private func mirrorFirst() { if let d = model.devices.first(where: { $0.state == .available }) { model.mirror(d) } }
}
