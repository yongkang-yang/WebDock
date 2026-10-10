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

        // Reserve just enough room for the globe, plus a count when a page is running.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // The bare symbol draws at the menu bar's small default and looks
            // undersized next to other round icons; bake the size in.
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "WebDock")?
                .withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panelController.onOpenSettings = { [weak self] in self?.openSettings(nil) }
        panelController.onClosePanel = { [weak self] in self?.closePanel() }
        panelController.onRunningPageCountChanged = { [weak self] count in
            self?.showRunningPageCount(count)
        }
        showRunningPageCount(0)
        // A page in its own window should be reachable from the Dock and ⌘Tab.
        panelController.onDetachedWindowsChanged = { count in
            NSApp.setActivationPolicy(count > 0 ? .regular : .accessory)
        }
        panel = GlassPanel(contentViewController: panelController)
        panel.onDismiss = { [weak self] in self?.closePanel() }
        // ⌘W closes the page on screen, like a tab; with no page left, the panel.
        panel.onClose = { [weak self] in
            guard let self else { return }
            if !self.panelController.closeCurrentPage() {
                self.closePanel()
            }
        }

        HotKeyCenter.shared.onPress = { [weak self] in self?.togglePanel() }
        HotKeyCenter.shared.start()

        // Development aid: `open WebDock.app --args --show-panel` opens the panel right away.
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPanel() }
        }
    }

    /// Show a count only while pages remain alive. No preview or extra menu is added.
    private func showRunningPageCount(_ count: Int) {
        guard let button = statusItem.button else { return }
        button.title = count > 0 ? String(count) : ""
        // Keep the original compact icon when no sites are running.
        statusItem.length = count > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        let label = count == 0 ? "WebDock, no running pages" :
            "WebDock, \(count) running \(count == 1 ? "page" : "pages")"
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    /// Switching to another app (Cmd+Tab, clicking its window, "open in browser") closes the panel.
    func applicationDidResignActive(_ notification: Notification) {
        closePanelUnlessBusy()
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

        // Center horizontally on the globe, not the full status button. Its width changes
        // when the count gains digits. Keep the bottom of the *button* as the drop anchor.
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let imageRect = (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds)
        let anchorRect = imageRect.flatMap { $0.isEmpty ? nil : $0 } ?? button.bounds
        let globeFrame = buttonWindow.convertToScreen(button.convert(anchorRect, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonFrame
        if panel.frame.size != PanelSize.saved {  // reset in Settings
            panel.setContentSize(PanelSize.saved)
        }
        let size = panel.frame.size
        let x = min(max(globeFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: buttonFrame.minY - 6 - size.height))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panelController.panelDidShow()
        panel.invalidateShadow()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanelUnlessBusy()
        }
    }

    private func closePanelUnlessBusy() {
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
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        // ⇧⌘H, as in Safari.
        viewMenu.addItem(withTitle: "Home", action: #selector(PanelViewController.goHome(_:)), keyEquivalent: "H")
        viewMenu.addItem(withTitle: "New Tab", action: #selector(PanelViewController.newTab(_:)), keyEquivalent: "t")
        viewMenu.addItem(withTitle: "Show All Pages", action: #selector(PanelViewController.toggleOverview(_:)), keyEquivalent: "\\")
            .keyEquivalentModifierMask = [.command, .shift]
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
