import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let panelController = PanelViewController()
    private var panel: GlassPanel!
    private var outsideClickMonitor: Any?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // The bare symbol draws at the menu bar's small default and looks
            // undersized next to other round icons; bake the size in.
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "WebDock")?
                .withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panelController.onOpenSettings = { [weak self] in self?.openSettings(nil) }
        panelController.onClosePanel = { [weak self] in self?.closePanel() }
        // A page in its own window should be reachable from the Dock and ⌘Tab.
        panelController.onDetachedWindowsChanged = { count in
            NSApp.setActivationPolicy(count > 0 ? .regular : .accessory)
        }
        panel = GlassPanel(contentViewController: panelController)
        panel.onDismiss = { [weak self] in self?.closePanel() }

        HotKeyCenter.shared.onPress = { [weak self] in self?.togglePanel() }
        HotKeyCenter.shared.start()

        // Development aid: `open WebDock.app --args --show-panel` opens the panel right away.
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPanel() }
        }
    }

    /// Switching to another app (Cmd+Tab, clicking its window, "open in browser") closes the panel,
    /// unless the page on screen is pinned.
    func applicationDidResignActive(_ notification: Notification) {
        closePanelUnlessPinned()
    }

    /// Clicking the Dock icon (shown while a page has its own window) with nothing on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPanel() }
        return true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    /// The global shortcut brings the panel forward if it's open behind another app's window.
    private func togglePanel() {
        if panel.isVisible && NSApp.isActive {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        // Drop down from the icon, centered on it but kept inside the screen.
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? iconFrame
        if panel.frame.size != PanelSize.saved {  // reset in Settings
            panel.setContentSize(PanelSize.saved)
        }
        let size = panel.frame.size
        let x = min(max(iconFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: iconFrame.minY - 6 - size.height))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panelController.panelDidShow()
        panel.invalidateShadow()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanelUnlessPinned()
        }
    }

    private func closePanelUnlessPinned() {
        if !panelController.keepsPanelOpen {
            closePanel()
        }
    }

    private func closePanel() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panelController.panelDidHide()
    }

    @objc func openSettings(_ sender: Any?) {
        closePanel()
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit WebDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Accessory apps have no visible menu bar, but the main menu still routes
    /// key equivalents — without it Cmd+C/V/A/Z don't work inside the web views.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit WebDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(PanelViewController.reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "New Tab", action: #selector(PanelViewController.newTab(_:)), keyEquivalent: "t")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Find…", action: #selector(PanelViewController.showFind(_:)), keyEquivalent: "f")
        viewMenu.addItem(withTitle: "Find Next", action: #selector(PanelViewController.findNext(_:)), keyEquivalent: "g")
        viewMenu.addItem(withTitle: "Find Previous", action: #selector(PanelViewController.findPrevious(_:)), keyEquivalent: "G")
        viewMenu.addItem(.separator())
        // ⌘= is ⌘+ without Shift; both zoom in.
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(PanelViewController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(PanelViewController.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(PanelViewController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(PanelViewController.actualSize(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        for number in 1...9 {
            let item = viewMenu.addItem(withTitle: "Site \(number)",
                                        action: #selector(PanelViewController.selectSiteByNumber(_:)),
                                        keyEquivalent: "\(number)")
            item.tag = number - 1
        }
        viewMenu.delegate = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// The menu bar shows while a page has its own window; name the ⌘1–⌘9 items after the sites.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let sites = SiteStore.shared.sites
        for item in menu.items where item.action == #selector(PanelViewController.selectSiteByNumber(_:)) {
            item.isHidden = !sites.indices.contains(item.tag)
            if sites.indices.contains(item.tag) {
                item.title = sites[item.tag].name
            }
        }
    }
}
